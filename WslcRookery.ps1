<#
.SYNOPSIS
    WSLC Rookery - a lightweight, local-only desktop GUI for managing WSL
    containers (wslc.exe) - a big piece missing for `wslc` compared to other
    desktop container runtimes. A rookery is a penguin colony; this one lets you
    watch over your whole flock of WSL containers at a glance.

.DESCRIPTION
    A single-window WPF app (PowerShell 7) that polls `wslc.exe ... --format json`
    every few seconds and shows Containers (with live stats), Images, and Volumes
    in sortable grids. Supports management actions (start/stop/kill/remove, rmi,
    volume remove, prune) plus logs/inspect popups.

    WPF requires an STA thread; pwsh 7 has no -STA switch, so this script relaunches
    its UI on a dedicated STA runspace when needed. Just run it with pwsh.

    NOTE: shared state and event-handler helpers are kept at $script: scope on
    purpose - WPF event handlers cannot see function-local variables when they
    fire later.

.PARAMETER Demo
    Fill the grids with synthetic placeholder data instead of querying wslc.exe.
    Nothing real is touched - handy for screenshots and docs. Real wslc calls are
    skipped entirely in this mode.

.EXAMPLE
    pwsh -File .\WslcRookery.ps1 -Demo

.NOTES
    Local-only informal tool. Licensed under the MIT License.
#>
param([switch]$Demo)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Demo mode. The STA bootstrap re-hosts this script's raw text on a fresh runspace
# (see bottom), where a bound -Demo param would reset to $false; so honor an
# injected $DemoMode variable when present, exactly like $AppDir below.
if (Test-Path variable:DemoMode) { $script:DemoMode = [bool]$DemoMode }
else { $script:DemoMode = $Demo.IsPresent }

# Resolve the app directory (holds the window icon). $PSScriptRoot is empty when
# this script is re-hosted as raw text on the STA runspace further below, so the
# STA bootstrap injects $AppDir into that runspace before invoking.
if (-not (Test-Path variable:AppDir) -or [string]::IsNullOrEmpty($AppDir)) {
    $AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}
$script:AppDir = $AppDir
$script:AppVersion = '0.3'

# --- Shared helpers (injected into both the UI thread and the background poller)
$CommonFunctions = @'
function Resolve-WslcPath {
    $cmd = Get-Command wslc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    $fallback = Join-Path $env:ProgramFiles 'WSL\wslc.exe'
    if (Test-Path $fallback) { return $fallback }
    throw "wslc.exe not found (checked PATH and '$fallback'). Install the WSL container feature."
}

# `wslc ... --format json` emits NDJSON: one standalone JSON object per line, not
# a JSON array. Feeding the whole blob to ConvertFrom-Json fails on line 2 with
# "Additional text encountered after finished reading JSON content", so parse
# line by line and only fall back to a whole-text parse (a real array) if that
# yields nothing.
function Invoke-WslcJson {
    param([string]$Wslc, [string[]]$ArgList)
    $out = & $Wslc @ArgList --format json 2>&1
    $text = ($out | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "wslc $($ArgList -join ' ') exited $LASTEXITCODE`n$text"
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    $rows = @()
    foreach ($line in ($text -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        try { $rows += ($t | ConvertFrom-Json) }
        catch { throw "wslc $($ArgList -join ' ') returned unparsable JSON: $($_.Exception.Message)`n$t" }
    }
    if ($rows.Count -eq 0) {
        $data = $text | ConvertFrom-Json
        if ($null -eq $data) { return @() }
        return @($data)
    }
    return @($rows)
}

# Strict mode makes a missing property a terminating error, and wslc's field set
# varies by subcommand and version - so every JSON read goes through this.
function Get-JsonProp {
    param($Object, [string[]]$Names, $Default = '')
    if ($null -eq $Object) { return $Default }
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    }
    return $Default
}

# wslc reports State as a string ('running', 'exited', ...). Older builds used an
# int, so keep mapping those rather than surfacing a bare number.
function Get-ContainerStatusText {
    param($State)
    if ($null -eq $State) { return '' }
    $s = "$State".Trim()
    if ($s -match '^\d+$') {
        switch ([int]$s) {
            1 { return 'created' }
            2 { return 'running' }
            3 { return 'exited' }
            default { return "state-$s" }
        }
    }
    return $s.ToLowerInvariant()
}

# Container IDs are 64 chars with --no-trunc but 12 without, and `stats` always
# returns the full ID - normalize to a 12-char prefix so the two can be joined.
function Get-IdKey {
    param($Id)
    $s = "$Id"
    if ($s.StartsWith('sha256:')) { $s = $s.Substring(7) }
    if ($s.Length -gt 12) { return $s.Substring(0, 12) }
    return $s
}

# Only containers whose init process was created interactive can be attached to
# with `wslc start -ai`; the rest fail with ERROR_INVALID_STATE and need an
# `wslc exec -i -t` shell instead. wslc exposes no Tty/OpenStdin field, but the
# Labels string carries
#   com.microsoft.wsl.container.metadata={"V1":{...,"InitProcessFlags":3,...}}
# and InitProcessFlags is non-zero exactly for the attachable ones (verified
# against wslc 2.9.12.0). Any parse failure degrades to "not interactive".
function Get-ContainerInteractive {
    param($Labels)
    $s = "$Labels"
    $marker = 'com.microsoft.wsl.container.metadata='
    $i = $s.IndexOf($marker)
    if ($i -lt 0) { return $false }
    $rest = $s.Substring($i + $marker.Length)
    # The value is JSON and contains commas, so the label list cannot simply be
    # split on ',' - walk braces to find where this value ends.
    $depth = 0; $end = -1
    for ($k = 0; $k -lt $rest.Length; $k++) {
        if ($rest[$k] -eq '{') { $depth++ }
        elseif ($rest[$k] -eq '}') { $depth--; if ($depth -eq 0) { $end = $k; break } }
    }
    if ($end -lt 0) { return $false }
    try {
        $meta = $rest.Substring(0, $end + 1) | ConvertFrom-Json
        $v1 = $meta.PSObject.Properties['V1']
        if (-not $v1 -or $null -eq $v1.Value) { return $false }
        $flags = $v1.Value.PSObject.Properties['InitProcessFlags']
        if (-not $flags -or $null -eq $flags.Value) { return $false }
        return ([int]$flags.Value -ne 0)
    } catch { return $false }
}

# --- Sort keys -------------------------------------------------------------
# Grid columns show wslc's preformatted strings, which sort lexically ("9.00%"
# after "12.58%", "622MB" after "4GB"). These build hidden numeric/date keys the
# columns point at via SortMemberPath, so the display text stays untouched.
# All return a low sentinel instead of throwing - strict mode is on and wslc's
# field values vary by subcommand and version.

function ConvertTo-SortPercent {
    param($Text)
    $s = "$Text".Trim().TrimEnd('%')
    $n = 0.0
    if ([double]::TryParse($s, [ref]$n)) { return $n }
    return -1.0
}

function ConvertTo-SortNumber {
    param($Text)
    $n = 0.0
    if ([double]::TryParse("$Text".Trim(), [ref]$n)) { return $n }
    return -1.0
}

# Handles SI (kB/MB/GB) and IEC (KiB/MiB/GiB) units. For "A / B" pairs - as used
# by Mem Usage, Net I/O and Block I/O - sorts on the first value.
function ConvertTo-SortBytes {
    param($Text)
    $s = "$Text".Trim()
    if (-not $s) { return -1.0 }
    if ($s.Contains('/')) { $s = $s.Split('/')[0].Trim() }
    if ($s -notmatch '^\s*([0-9]*\.?[0-9]+)\s*([a-zA-Z]*)\s*$') { return -1.0 }
    $value = [double]$Matches[1]
    $unit = $Matches[2].ToLowerInvariant()
    $mult = switch ($unit) {
        ''    { 1 }
        'b'   { 1 }
        'k'   { 1000 }        'kb'  { 1000 }
        'm'   { 1000000 }     'mb'  { 1000000 }
        'g'   { 1000000000 }  'gb'  { 1000000000 }
        't'   { 1000000000000 } 'tb' { 1000000000000 }
        'kib' { 1024 }
        'mib' { 1048576 }
        'gib' { 1073741824 }
        'tib' { 1099511627776 }
        default { 1 }
    }
    return $value * $mult
}

# wslc emits CreatedAt like "2026-09-03 15:19:53 -0400 EDT". The trailing zone
# abbreviation is not parseable, so drop it and keep the numeric offset.
function ConvertTo-SortDate {
    param($Text)
    $s = "$Text".Trim()
    if (-not $s) { return [DateTimeOffset]::MinValue }
    $s = $s -replace '\s+[A-Za-z]{2,5}$', ''
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($s, [ref]$dto)) { return $dto }
    return [DateTimeOffset]::MinValue
}

function Get-WslcSnapshot {
    param([string]$Wslc)
    $containersRaw = Invoke-WslcJson -Wslc $Wslc -ArgList @('container','list','--all','--no-trunc')
    $statsRaw      = Invoke-WslcJson -Wslc $Wslc -ArgList @('stats','--all','--no-trunc')
    $imagesRaw     = Invoke-WslcJson -Wslc $Wslc -ArgList @('images','--no-trunc')
    $volumesRaw    = Invoke-WslcJson -Wslc $Wslc -ArgList @('volume','list')

    $statsById = @{}
    foreach ($s in $statsRaw) {
        $sid = Get-JsonProp -Object $s -Names @('ID','Id')
        if ($sid) { $statsById[(Get-IdKey $sid)] = $s }
    }

    $containers = foreach ($c in $containersRaw) {
        $id = [string](Get-JsonProp -Object $c -Names @('ID','Id'))
        $st = if ($id) { $statsById[(Get-IdKey $id)] } else { $null }
        $cpu      = if ($st) { Get-JsonProp -Object $st -Names @('CPUPerc') } else { '' }
        $mem      = if ($st) { Get-JsonProp -Object $st -Names @('MemPerc') } else { '' }
        $memUsage = if ($st) { Get-JsonProp -Object $st -Names @('MemUsage') } else { '' }
        $netIO    = if ($st) { Get-JsonProp -Object $st -Names @('NetIO') } else { '' }
        $blockIO  = if ($st) { Get-JsonProp -Object $st -Names @('BlockIO') } else { '' }
        $pids     = if ($st) { [string](Get-JsonProp -Object $st -Names @('PIDs')) } else { '' }
        $interactive = Get-ContainerInteractive (Get-JsonProp -Object $c -Names @('Labels'))
        [pscustomobject]@{
            Name     = Get-JsonProp -Object $c -Names @('Names','Name')
            IdShort  = Get-IdKey $id
            Image    = Get-JsonProp -Object $c -Names @('Image')
            Status   = Get-ContainerStatusText -State (Get-JsonProp -Object $c -Names @('State') -Default $null)
            Interactive     = $interactive
            InteractiveText = if ($interactive) { 'yes' } else { '' }
            CPU      = $cpu
            Mem      = $mem
            MemUsage = $memUsage
            NetIO    = $netIO
            BlockIO  = $blockIO
            PIDs     = $pids
            Created  = Get-JsonProp -Object $c -Names @('RunningFor','CreatedSince','CreatedAt')
            FullId   = $id
            # Hidden sort keys (SortMemberPath targets); never rendered as columns.
            CpuSort      = ConvertTo-SortPercent $cpu
            MemSort      = ConvertTo-SortPercent $mem
            MemUsageSort = ConvertTo-SortBytes $memUsage
            NetIOSort    = ConvertTo-SortBytes $netIO
            BlockIOSort  = ConvertTo-SortBytes $blockIO
            PIDsSort     = ConvertTo-SortNumber $pids
            CreatedSort  = ConvertTo-SortDate (Get-JsonProp -Object $c -Names @('CreatedAt'))
        }
    }

    $images = foreach ($im in $imagesRaw) {
        $id = [string](Get-JsonProp -Object $im -Names @('ID','Id'))
        $size = Get-JsonProp -Object $im -Names @('Size')
        [pscustomobject]@{
            Repository = Get-JsonProp -Object $im -Names @('Repository') -Default '<none>'
            Tag        = Get-JsonProp -Object $im -Names @('Tag') -Default '<none>'
            IdShort    = Get-IdKey $id
            Size       = $size
            Created    = Get-JsonProp -Object $im -Names @('CreatedSince','CreatedAt')
            FullId     = $id
            SizeSort    = ConvertTo-SortBytes $size
            CreatedSort = ConvertTo-SortDate (Get-JsonProp -Object $im -Names @('CreatedAt'))
        }
    }

    $volumes = foreach ($vol in $volumesRaw) {
        [pscustomobject]@{
            Name   = Get-JsonProp -Object $vol -Names @('Name')
            Driver = Get-JsonProp -Object $vol -Names @('Driver')
        }
    }

    return [pscustomobject]@{
        Containers = @($containers)
        Images     = @($images)
        Volumes    = @($volumes)
    }
}

function Get-DemoSnapshot {
    # Fully synthetic snapshot for screenshots/docs. Rows match the exact shape
    # produced by Get-WslcSnapshot so the UI needs no changes. Running containers
    # get lightly jittered metrics each call so the grid looks alive across
    # auto-refreshes; stopped containers have blank metrics (as real ones do).
    $rand = [Random]::new()
    $jit = { param($base, $span) ('{0:0.00}%' -f [Math]::Max(0.0, $base + ($rand.NextDouble() - 0.5) * $span)) }
    # Real rows carry wslc's relative text ("2 weeks ago"), so demo rows do too.
    $rel = { param($n, $unit) if ($n -eq 1) { "1 $unit ago" } else { "$n ${unit}s ago" } }

    $running = @(
        @{ Name = 'web-frontend'; Image = 'nginx:1.27';         Cpu = 4.2;  Mem = 6.1;  MemUsage = '124.5 MiB / 2 GiB';  Net = '3.4 MB / 1.2 MB';   Block = '8.1 MB / 0 B';   PIDs = 9;  Ago = 3;  Tty = $false },
        @{ Name = 'api-gateway';  Image = 'traefik:v3';          Cpu = 7.8;  Mem = 9.4;  MemUsage = '188.2 MiB / 2 GiB';  Net = '12.7 MB / 9.1 MB';  Block = '2.3 MB / 512 kB'; PIDs = 14; Ago = 5;  Tty = $false },
        @{ Name = 'cache';        Image = 'redis:7';             Cpu = 1.5;  Mem = 3.2;  MemUsage = '64.8 MiB / 2 GiB';   Net = '820 kB / 640 kB';   Block = '0 B / 0 B';      PIDs = 5;  Ago = 6;  Tty = $true },
        @{ Name = 'db';           Image = 'postgres:16';         Cpu = 3.1;  Mem = 15.7; MemUsage = '321.0 MiB / 2 GiB';  Net = '5.6 MB / 4.2 MB';   Block = '44.9 MB / 12 MB';PIDs = 21; Ago = 8;  Tty = $true },
        @{ Name = 'worker';       Image = 'python:3.12-slim';    Cpu = 12.6; Mem = 8.8;  MemUsage = '176.4 MiB / 2 GiB';  Net = '2.1 MB / 3.8 MB';   Block = '6.0 MB / 1.1 MB'; PIDs = 7;  Ago = 4;  Tty = $false }
    )
    $stopped = @(
        @{ Name = 'hello-penguin'; Image = 'helloworld:latest';  Ago = 2;  Tty = $true },
        @{ Name = 'migration-job'; Image = 'postgres:16';        Ago = 9;  Tty = $false },
        @{ Name = 'old-build';     Image = 'node:20-alpine';     Ago = 30; Tty = $true }
    )

    $ci = 0
    $now = [DateTimeOffset]::Now
    $containers = @()
    $containers += foreach ($r in $running) {
        $id = ('{0:x12}' -f (0x100000000000 + $ci * 0x1a2b3c)); $ci++
        $cpu = (& $jit $r.Cpu 2.0)
        $mem = (& $jit $r.Mem 1.5)
        [pscustomobject]@{
            Name     = $r.Name
            IdShort  = $id.Substring(0, 12)
            Image    = $r.Image
            Status   = 'running'
            Interactive     = $r.Tty
            InteractiveText = if ($r.Tty) { 'yes' } else { '' }
            CPU      = $cpu
            Mem      = $mem
            MemUsage = $r.MemUsage
            NetIO    = $r.Net
            BlockIO  = $r.Block
            PIDs     = [string]$r.PIDs
            Created  = (& $rel $r.Ago 'hour')
            FullId   = "$id$id`demo"
            CpuSort      = ConvertTo-SortPercent $cpu
            MemSort      = ConvertTo-SortPercent $mem
            MemUsageSort = ConvertTo-SortBytes $r.MemUsage
            NetIOSort    = ConvertTo-SortBytes $r.Net
            BlockIOSort  = ConvertTo-SortBytes $r.Block
            PIDsSort     = ConvertTo-SortNumber $r.PIDs
            CreatedSort  = $now.AddHours(-1 * $r.Ago)
        }
    }
    $containers += foreach ($r in $stopped) {
        $id = ('{0:x12}' -f (0x200000000000 + $ci * 0x1a2b3c)); $ci++
        [pscustomobject]@{
            Name     = $r.Name
            IdShort  = $id.Substring(0, 12)
            Image    = $r.Image
            Status   = 'exited'
            Interactive     = $r.Tty
            InteractiveText = if ($r.Tty) { 'yes' } else { '' }
            CPU      = ''
            Mem      = ''
            MemUsage = ''
            NetIO    = ''
            BlockIO  = ''
            PIDs     = ''
            Created  = (& $rel $r.Ago 'day')
            FullId   = "$id$id`demo"
            CpuSort      = -1.0
            MemSort      = -1.0
            MemUsageSort = -1.0
            NetIOSort    = -1.0
            BlockIOSort  = -1.0
            PIDsSort     = -1.0
            CreatedSort  = $now.AddDays(-1 * $r.Ago)
        }
    }

    $imageDefs = @(
        @{ Repo = 'nginx';        Tag = '1.27';    Id = 'a1b2c3d4e5f6'; Size = '187.4 MB'; Ago = 6 },
        @{ Repo = 'postgres';     Tag = '16';      Id = 'b2c3d4e5f6a7'; Size = '431.2 MB'; Ago = 8 },
        @{ Repo = 'redis';        Tag = '7';       Id = 'c3d4e5f6a7b8'; Size = '117.8 MB'; Ago = 12 },
        @{ Repo = 'helloworld';   Tag = 'latest';  Id = 'd4e5f6a7b8c9'; Size = '9.1 kB';   Ago = 2 }
    )
    $images = foreach ($im in $imageDefs) {
        [pscustomobject]@{
            Repository = $im.Repo
            Tag        = $im.Tag
            IdShort    = $im.Id
            Size       = $im.Size
            Created    = (& $rel $im.Ago 'day')
            FullId     = "sha256:$($im.Id)demofulliddemofulliddemofulliddemofull"
            SizeSort    = ConvertTo-SortBytes $im.Size
            CreatedSort = $now.AddDays(-1 * $im.Ago)
        }
    }

    $volumes = @(
        [pscustomobject]@{ Name = 'pgdata';      Driver = 'local' },
        [pscustomobject]@{ Name = 'redis-data';  Driver = 'local' },
        [pscustomobject]@{ Name = 'app-config';  Driver = 'local' },
        [pscustomobject]@{ Name = 'build-cache'; Driver = 'local' }
    )

    return [pscustomobject]@{
        Containers = @($containers)
        Images     = @($images)
        Volumes    = @($volumes)
    }
}
'@

# Make the shared helpers available on the UI thread too.
Invoke-Expression $CommonFunctions

# --- The WPF application (must run on an STA thread) ----------------------------
function Start-WslcRookeryUi {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    # Give this process an explicit taskbar identity so the taskbar button uses
    # our window icon instead of the generic host (pwsh) icon it would otherwise
    # inherit. Must run before the window is shown.
    try {
        Add-Type -Namespace WslcRookery -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", PreserveSig = false)]
public static extern void SetCurrentProcessExplicitAppUserModelID([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string AppID);
'@
        [WslcRookery.Shell]::SetCurrentProcessExplicitAppUserModelID('WslcRookery.App')
    } catch { }

    $script:wslc = if ($script:DemoMode) { 'wslc' } else { Resolve-WslcPath }

    # Shared state written by the background poller, read by the UI timer.
    $script:sync = [hashtable]::Synchronized(@{
        Version      = 0
        Containers   = @()
        Images       = @()
        Volumes      = @()
        LastRefresh  = $null
        Error        = $null
        Stop         = $false
        ForceRefresh = $true
        IntervalSec  = 3
    })

    # Background polling runspace: fetches snapshots off the UI thread.
    $worker = {
        param($sync, $wslc, $commonFns, $demo)
        Invoke-Expression $commonFns
        $last = [datetime]::MinValue
        while (-not $sync.Stop) {
            $due = ((Get-Date) - $last).TotalSeconds -ge $sync.IntervalSec
            if ($sync.ForceRefresh -or $due) {
                try {
                    $snap = if ($demo) { Get-DemoSnapshot } else { Get-WslcSnapshot -Wslc $wslc }
                    $sync.Containers = $snap.Containers
                    $sync.Images     = $snap.Images
                    $sync.Volumes    = $snap.Volumes
                    $sync.Error      = $null
                } catch {
                    $sync.Error = $_.Exception.Message
                }
                $sync.LastRefresh  = Get-Date
                $sync.ForceRefresh = $false
                $sync.Version++
                $last = Get-Date
            }
            Start-Sleep -Milliseconds 200
        }
    }

    $script:bgRunspace = [runspacefactory]::CreateRunspace()
    $script:bgRunspace.ApartmentState = 'MTA'
    $script:bgRunspace.ThreadOptions  = 'ReuseThread'
    $script:bgRunspace.Open()
    $script:bgPs = [powershell]::Create()
    $script:bgPs.Runspace = $script:bgRunspace
    $null = $script:bgPs.AddScript($worker).AddArgument($script:sync).AddArgument($script:wslc).AddArgument($CommonFunctions).AddArgument($script:DemoMode)
    $script:bgHandle = $script:bgPs.BeginInvoke()

    # ---- XAML UI ----
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WSLC Rookery" Height="640" Width="1080"
        WindowStartupLocation="CenterScreen">
  <DockPanel>
    <DockPanel DockPanel.Dock="Top" Margin="8,8,8,4">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="WSLC Rookery" FontSize="16" FontWeight="Bold"
                   VerticalAlignment="Center"/>
        <Border x:Name="DemoBadge" Visibility="Collapsed" Background="#D97706"
                CornerRadius="3" Padding="7,1" Margin="12,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="DEMO - placeholder data" FontSize="12" FontWeight="Bold"
                     Foreground="White"/>
        </Border>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <CheckBox x:Name="AutoRefreshCheck" Content="Auto-refresh (3s)" IsChecked="True"
                  VerticalAlignment="Center" Margin="0,0,12,0"/>
        <Button x:Name="RefreshBtn" Content="Refresh now" Padding="10,3"/>
        <Button x:Name="AboutBtn" Content="About" Padding="10,3" Margin="8,0,0,0"/>
      </StackPanel>
    </DockPanel>

    <StatusBar DockPanel.Dock="Bottom">
      <StatusBarItem><TextBlock x:Name="StatusText" Text="Starting..."/></StatusBarItem>
    </StatusBar>

    <TabControl Margin="8,4,8,4">
      <!-- Containers -->
      <TabItem Header="Containers">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="CStartBtn"   Content="Start"   Padding="8,3" Margin="0,0,6,0"/>
            <Button x:Name="CStopBtn"    Content="Stop"    Padding="8,3" Margin="0,0,6,0"/>
            <Button x:Name="CKillBtn"    Content="Kill"    Padding="8,3" Margin="0,0,6,0"/>
            <Button x:Name="CRemoveBtn"  Content="Remove"  Padding="8,3" Margin="0,0,6,0"/>
            <Separator Width="1" Margin="4,0"/>
            <Button x:Name="CConnectBtn" Content="Connect" Padding="8,3" Margin="6,0,6,0"/>
            <Button x:Name="CLogsBtn"    Content="Logs"    Padding="8,3" Margin="0,0,6,0"/>
            <Button x:Name="CInspectBtn" Content="Inspect" Padding="8,3" Margin="0,0,6,0"/>
            <Separator Width="1" Margin="4,0"/>
            <Button x:Name="CPruneBtn"   Content="Prune stopped" Padding="8,3" Margin="6,0,0,0"/>
          </StackPanel>
          <DataGrid x:Name="ContainersGrid" AutoGenerateColumns="False" IsReadOnly="True"
                    SelectionMode="Single" CanUserSortColumns="True" GridLinesVisibility="Horizontal">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Name"      Binding="{Binding Name}"     Width="180"/>
              <DataGridTextColumn Header="Status"    Binding="{Binding Status}"   Width="80"/>
              <DataGridTextColumn Header="Interactive" Binding="{Binding InteractiveText}" Width="75"/>
              <DataGridTextColumn Header="Image"     Binding="{Binding Image}"    Width="150"/>
              <DataGridTextColumn Header="CPU"       Binding="{Binding CPU}"      Width="70"  SortMemberPath="CpuSort"/>
              <DataGridTextColumn Header="Mem%"      Binding="{Binding Mem}"      Width="70"  SortMemberPath="MemSort"/>
              <DataGridTextColumn Header="Mem Usage" Binding="{Binding MemUsage}" Width="140" SortMemberPath="MemUsageSort"/>
              <DataGridTextColumn Header="Net I/O"   Binding="{Binding NetIO}"    Width="120" SortMemberPath="NetIOSort"/>
              <DataGridTextColumn Header="Block I/O" Binding="{Binding BlockIO}"  Width="120" SortMemberPath="BlockIOSort"/>
              <DataGridTextColumn Header="PIDs"      Binding="{Binding PIDs}"     Width="55"  SortMemberPath="PIDsSort"/>
              <DataGridTextColumn Header="Container ID" Binding="{Binding IdShort}" Width="110"/>
              <DataGridTextColumn Header="Created"   Binding="{Binding Created}"  Width="150" SortMemberPath="CreatedSort"/>
            </DataGrid.Columns>
          </DataGrid>
        </DockPanel>
      </TabItem>

      <!-- Images -->
      <TabItem Header="Images">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="IRemoveBtn"  Content="Remove (rmi)" Padding="8,3" Margin="0,0,6,0"/>
            <Button x:Name="IInspectBtn" Content="Inspect"      Padding="8,3" Margin="0,0,6,0"/>
            <Separator Width="1" Margin="4,0"/>
            <Button x:Name="IPruneBtn"   Content="Prune unused" Padding="8,3" Margin="6,0,0,0"/>
          </StackPanel>
          <DataGrid x:Name="ImagesGrid" AutoGenerateColumns="False" IsReadOnly="True"
                    SelectionMode="Single" CanUserSortColumns="True" GridLinesVisibility="Horizontal">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Repository" Binding="{Binding Repository}" Width="260"/>
              <DataGridTextColumn Header="Tag"        Binding="{Binding Tag}"        Width="120"/>
              <DataGridTextColumn Header="Image ID"   Binding="{Binding IdShort}"    Width="130"/>
              <DataGridTextColumn Header="Size"       Binding="{Binding Size}"       Width="110" SortMemberPath="SizeSort"/>
              <DataGridTextColumn Header="Created"    Binding="{Binding Created}"    Width="160" SortMemberPath="CreatedSort"/>
            </DataGrid.Columns>
          </DataGrid>
        </DockPanel>
      </TabItem>

      <!-- Volumes -->
      <TabItem Header="Volumes">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="VRemoveBtn"  Content="Remove"       Padding="8,3" Margin="0,0,6,0"/>
            <Button x:Name="VInspectBtn" Content="Inspect"      Padding="8,3" Margin="0,0,6,0"/>
            <Separator Width="1" Margin="4,0"/>
            <Button x:Name="VPruneBtn"   Content="Prune unused" Padding="8,3" Margin="6,0,0,0"/>
          </StackPanel>
          <DataGrid x:Name="VolumesGrid" AutoGenerateColumns="False" IsReadOnly="True"
                    SelectionMode="Single" CanUserSortColumns="True" GridLinesVisibility="Horizontal">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Name"   Binding="{Binding Name}"   Width="320"/>
              <DataGridTextColumn Header="Driver" Binding="{Binding Driver}" Width="120"/>
            </DataGrid.Columns>
          </DataGrid>
        </DockPanel>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@

    $script:window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

    # Window icon (top-left title-bar + taskbar). Loaded from the app folder.
    $iconPath = Join-Path $script:AppDir 'WslcRookery.ico'
    if (Test-Path -LiteralPath $iconPath) {
        try {
            $script:window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath))
        } catch { }
    }

    # Element refs
    $script:ui = @{}
    foreach ($n in     'AutoRefreshCheck','RefreshBtn','AboutBtn','StatusText','DemoBadge',
                   'ContainersGrid','CStartBtn','CStopBtn','CKillBtn','CRemoveBtn','CConnectBtn','CLogsBtn','CInspectBtn','CPruneBtn',
                   'ImagesGrid','IRemoveBtn','IInspectBtn','IPruneBtn',
                   'VolumesGrid','VRemoveBtn','VInspectBtn','VPruneBtn') {
        $script:ui[$n] = $script:window.FindName($n)
    }

    # Surface demo mode in the top bar so placeholder data isn't mistaken for real.
    if ($script:DemoMode) { $script:ui.DemoBadge.Visibility = [System.Windows.Visibility]::Visible }

    # ---- UI-thread helpers (script scope so event handlers can see them) ----
    $script:LastVersion = -1

    # Assigning ItemsSource builds a brand-new CollectionView, which drops the
    # user's sort (Items.SortDescriptions plus the column header arrows) and the
    # scroll position. Capture all three before the swap and put them back after.
    $script:FindScrollViewer = {
        param($dep)
        if ($null -eq $dep) { return $null }
        if ($dep -is [System.Windows.Controls.ScrollViewer]) { return $dep }
        $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($dep)
        for ($i = 0; $i -lt $count; $i++) {
            $found = & $script:FindScrollViewer ([System.Windows.Media.VisualTreeHelper]::GetChild($dep, $i))
            if ($found) { return $found }
        }
        return $null
    }

    $script:UpdateGrid = {
        param($grid, $items, $keyProp)
        $prevKey = if ($grid.SelectedItem) { $grid.SelectedItem.$keyProp } else { $null }

        # SortDescriptions is live on the outgoing view, so copy it out by value.
        $sorts = @()
        foreach ($sd in $grid.Items.SortDescriptions) {
            $sorts += New-Object System.ComponentModel.SortDescription($sd.PropertyName, $sd.Direction)
        }
        $dirs = @{}
        foreach ($col in $grid.Columns) {
            if ($null -ne $col.SortDirection) { $dirs[$col.DisplayIndex] = $col.SortDirection }
        }
        $sv = & $script:FindScrollViewer $grid
        $offset = if ($sv) { $sv.VerticalOffset } else { $null }

        $grid.ItemsSource = $items

        if ($sorts.Count -gt 0) {
            $grid.Items.SortDescriptions.Clear()
            foreach ($sd in $sorts) { $grid.Items.SortDescriptions.Add($sd) }
            foreach ($col in $grid.Columns) {
                if ($dirs.ContainsKey($col.DisplayIndex)) { $col.SortDirection = $dirs[$col.DisplayIndex] }
            }
            $grid.Items.Refresh()
        }

        if ($prevKey) {
            foreach ($it in $items) {
                if ($it.$keyProp -eq $prevKey) { $grid.SelectedItem = $it; break }
            }
        }

        # Last, so it wins over any scrolling the selection restore triggered.
        if ($sv -and $null -ne $offset) { $sv.ScrollToVerticalOffset($offset) }
    }

    $script:RunWslc = {
        param([string[]]$argList)
        if ($script:DemoMode) {
            return [pscustomobject]@{ Ok = $true; Text = "Demo mode: '$($argList -join ' ')' not executed."; Code = 0 }
        }
        $out = & $script:wslc @argList 2>&1
        [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = ($out | Out-String); Code = $LASTEXITCODE }
    }

    $script:ShowText = {
        param([string]$title, [string]$text)
        $win = New-Object System.Windows.Window
        $win.Title = $title; $win.Width = 820; $win.Height = 560
        $win.WindowStartupLocation = 'CenterScreen'; $win.Owner = $script:window
        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Text = $text; $tb.IsReadOnly = $true; $tb.TextWrapping = 'NoWrap'
        $tb.VerticalScrollBarVisibility = 'Auto'; $tb.HorizontalScrollBarVisibility = 'Auto'
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Cascadia Mono, Consolas')
        $tb.FontSize = 12
        $win.Content = $tb
        $win.ShowDialog() | Out-Null
    }

    $script:ShowAbout = {
        $win = New-Object System.Windows.Window
        $win.Title = 'About WSLC Rookery'
        $win.SizeToContent = 'WidthAndHeight'; $win.ResizeMode = 'NoResize'
        $win.WindowStartupLocation = 'CenterOwner'; $win.Owner = $script:window

        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Margin = '20'; $panel.Width = 380

        $logoPath = Join-Path $script:AppDir 'docs\WSLC Rookery Logo.png'
        if (Test-Path -LiteralPath $logoPath) {
            try {
                $img = New-Object System.Windows.Controls.Image
                $img.Source = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($logoPath))
                $img.Width = 160; $img.Height = 160
                $img.HorizontalAlignment = 'Center'; $img.Margin = '0,0,0,12'
                [void]$panel.Children.Add($img)
            } catch { }
        }

        $addLine = {
            param([string]$text, [int]$size, [bool]$bold, [string]$margin)
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = $text; $t.FontSize = $size
            $t.HorizontalAlignment = 'Center'; $t.TextAlignment = 'Center'
            $t.TextWrapping = 'Wrap'; $t.Margin = $margin
            if ($bold) { $t.FontWeight = 'Bold' }
            [void]$panel.Children.Add($t)
        }

        & $addLine 'WSLC Rookery' 18 $true '0,0,0,2'
        & $addLine "Version $script:AppVersion" 12 $false '0,0,0,10'
        & $addLine 'A local GUI for WSL containers (wslc.exe).' 12 $false '0,0,0,12'
        & $addLine 'Author: Alex Smith' 12 $true '0,0,0,2'
        & $addLine 'GitHub: alexsmithMSFT' 12 $false '0,0,0,12'

        $ok = New-Object System.Windows.Controls.Button
        $ok.Content = 'OK'; $ok.Width = 80; $ok.Padding = '0,3'
        $ok.HorizontalAlignment = 'Center'; $ok.IsDefault = $true
        $ok.Add_Click({ $win.Close() }.GetNewClosure())
        [void]$panel.Children.Add($ok)

        $win.Content = $panel
        $win.ShowDialog() | Out-Null
    }

    $script:Confirm = {
        param([string]$msg)
        $r = [System.Windows.MessageBox]::Show($script:window, $msg, 'WSLC Rookery',
             [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        return ($r -eq [System.Windows.MessageBoxResult]::Yes)
    }

    $script:Warn = {
        param([string]$msg)
        [System.Windows.MessageBox]::Show($script:window, $msg, 'WSLC Rookery',
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
    }

    # Runs a wslc action, reports failure, then forces a refresh.
    $script:DoAction = {
        param([string[]]$argList, [string]$busyLabel)
        $script:ui.StatusText.Text = $busyLabel
        $res = & $script:RunWslc $argList
        if (-not $res.Ok) {
            & $script:Warn ("Command failed (exit $($res.Code)):`n`n$($res.Text)")
        }
        $script:sync.ForceRefresh = $true
    }

    # Opens the selected container in a terminal window on the host.
    #
    # This deliberately does NOT go through $script:DoAction / $script:RunWslc:
    # those capture output and wait for the process, which would hang the UI
    # thread for the whole length of an interactive session. The terminal is
    # launched detached instead.
    #
    # Because it is detached, the app cannot see commands fail afterwards. The
    # spawned wrapper uses the Interactive flag to choose attach or exec before
    # connecting. It must not fall back after an interactive session exits:
    # `start -ai` returns the container process exit code, which may be non-zero
    # after a valid attached session.
    $script:ConnectContainer = {
        param($c)
        if ($script:DemoMode) {
            [System.Windows.MessageBox]::Show($script:window,
                "Demo mode: no terminal launched.`n`nInteractive containers use:`n  wslc start -ai $($c.Name)`n`nNon-interactive containers use:`n  wslc exec -i -t $($c.Name) <shell>",
                'WSLC Rookery', [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information) | Out-Null
            return
        }

        # The wrapper is written to a temp script and launched with -File rather
        # than being passed inline: wt.exe re-parses the command line it is given,
        # which mangles a long -EncodedCommand argument and kills the pane before
        # anything runs. A file path survives that second parse intact. Values are
        # embedded as single-quoted PowerShell literals (doubling any quote).
        $q = { param($s) "'" + ("$s" -replace "'", "''") + "'" }
        $interactiveLiteral = if ($c.Interactive) { '$true' } else { '$false' }
        $wrapper = @"
`$ErrorActionPreference = 'Continue'
Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
`$wslc = $(& $q $script:wslc)
`$id   = $(& $q $c.FullId)
`$name = $(& $q $c.Name)
`$interactive = $interactiveLiteral
`$Host.UI.RawUI.WindowTitle = "WSLC Rookery - `$name"
Write-Host "Connecting to `$name ..." -ForegroundColor Cyan
if (`$interactive) {
    & `$wslc start -ai `$id
    `$sessionExit = `$LASTEXITCODE
    if (`$sessionExit -ne 0) {
        Write-Host ''
        Write-Host "Interactive container session ended with exit `$sessionExit." -ForegroundColor Red
        Write-Host 'No fallback shell was opened.'
    }
} else {
    Write-Host ''
    Write-Host "Container is not interactive; opening an exec shell." -ForegroundColor Yellow
    & `$wslc start `$id | Out-Null
    `$shell = (& `$wslc exec `$id /bin/sh -c 'command -v bash || command -v sh' 2>`$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace(`$shell)) { `$shell = '/bin/sh' }
    Write-Host "Running: wslc exec -i -t `$name `$shell" -ForegroundColor Cyan
    & `$wslc exec -i -t `$id `$shell
    if (`$LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host "Could not connect to `$name (exit `$LASTEXITCODE)." -ForegroundColor Red
        Write-Host 'This window is left open so the error above stays readable.'
    }
}
"@
        $wrapperPath = Join-Path $env:TEMP ("WslcRookery-connect-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $wrapperPath -Value $wrapper -Encoding UTF8

        # `-w -1` forces a brand new Windows Terminal window; without it the tab
        # is attached to whatever terminal window the user was last using.
        # wt.exe re-parses its own command line and strips the quoting that
        # Start-Process would add per argument, so the arguments are passed as a
        # single pre-quoted string. For the same reason the tab title is set from
        # inside the wrapper instead of with `--title`: a container name with a
        # space in it would otherwise be split into a stray command.
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        try {
            if ($wt) {
                Start-Process -FilePath $wt.Path `
                    -ArgumentList ('-w -1 new-tab pwsh -NoProfile -NoExit -File "{0}"' -f $wrapperPath)
            } else {
                Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NoExit', '-File', $wrapperPath)
            }
            $script:ui.StatusText.Text = "Connecting to $($c.Name)..."
        } catch {
            Remove-Item -LiteralPath $wrapperPath -Force -ErrorAction SilentlyContinue
            & $script:Warn "Could not launch a terminal:`n`n$($_.Exception.Message)"
            return
        }
        # The container may have been started by the connect, so repaint.
        $script:sync.ForceRefresh = $true
    }

    # ---- Container actions ----
    $script:RequireContainer = {
        if (-not $script:ui.ContainersGrid.SelectedItem) { & $script:Warn 'Select a container first.'; return $null }
        return $script:ui.ContainersGrid.SelectedItem
    }
    $script:ui.CStartBtn.Add_Click({
        $c = & $script:RequireContainer; if ($c) { & $script:DoAction @('start', $c.FullId) "Starting $($c.Name)..." }
    })
    $script:ui.CStopBtn.Add_Click({
        $c = & $script:RequireContainer; if ($c) { & $script:DoAction @('stop', $c.FullId) "Stopping $($c.Name)..." }
    })
    $script:ui.CKillBtn.Add_Click({
        $c = & $script:RequireContainer; if (-not $c) { return }
        if (& $script:Confirm "Kill container '$($c.Name)'?") { & $script:DoAction @('kill', $c.FullId) "Killing $($c.Name)..." }
    })
    $script:ui.CRemoveBtn.Add_Click({
        $c = & $script:RequireContainer; if (-not $c) { return }
        if (& $script:Confirm "Remove container '$($c.Name)'? (uses --force)") {
            & $script:DoAction @('container','remove','--force', $c.FullId) "Removing $($c.Name)..."
        }
    })
    $script:ui.CConnectBtn.Add_Click({
        $c = & $script:RequireContainer; if ($c) { & $script:ConnectContainer $c }
    })
    $script:ui.CLogsBtn.Add_Click({
        $c = & $script:RequireContainer; if (-not $c) { return }
        $res = & $script:RunWslc @('logs','--tail','500', $c.FullId)
        & $script:ShowText "Logs - $($c.Name)" $res.Text
    })
    $script:ui.CInspectBtn.Add_Click({
        $c = & $script:RequireContainer; if (-not $c) { return }
        $res = & $script:RunWslc @('container','inspect', $c.FullId)
        & $script:ShowText "Inspect - $($c.Name)" $res.Text
    })
    $script:ui.CPruneBtn.Add_Click({
        if (& $script:Confirm 'Remove ALL stopped containers?') { & $script:DoAction @('container','prune') 'Pruning stopped containers...' }
    })

    # ---- Image actions ----
    $script:RequireImage = {
        if (-not $script:ui.ImagesGrid.SelectedItem) { & $script:Warn 'Select an image first.'; return $null }
        return $script:ui.ImagesGrid.SelectedItem
    }
    $script:ui.IRemoveBtn.Add_Click({
        $im = & $script:RequireImage; if (-not $im) { return }
        $label = if ($im.Repository -ne '<none>') { "$($im.Repository):$($im.Tag)" } else { $im.IdShort }
        if (& $script:Confirm "Remove image '$label'?") { & $script:DoAction @('image','remove', $im.FullId) "Removing image $label..." }
    })
    $script:ui.IInspectBtn.Add_Click({
        $im = & $script:RequireImage; if (-not $im) { return }
        $res = & $script:RunWslc @('image','inspect', $im.FullId)
        & $script:ShowText "Inspect image - $($im.IdShort)" $res.Text
    })
    $script:ui.IPruneBtn.Add_Click({
        if (& $script:Confirm 'Remove all unused (dangling) images?') { & $script:DoAction @('image','prune') 'Pruning unused images...' }
    })

    # ---- Volume actions ----
    $script:RequireVolume = {
        if (-not $script:ui.VolumesGrid.SelectedItem) { & $script:Warn 'Select a volume first.'; return $null }
        return $script:ui.VolumesGrid.SelectedItem
    }
    $script:ui.VRemoveBtn.Add_Click({
        $v = & $script:RequireVolume; if (-not $v) { return }
        if (& $script:Confirm "Remove volume '$($v.Name)'?") { & $script:DoAction @('volume','remove', $v.Name) "Removing volume $($v.Name)..." }
    })
    $script:ui.VInspectBtn.Add_Click({
        $v = & $script:RequireVolume; if (-not $v) { return }
        $res = & $script:RunWslc @('volume','inspect', $v.Name)
        & $script:ShowText "Inspect volume - $($v.Name)" $res.Text
    })
    $script:ui.VPruneBtn.Add_Click({
        if (& $script:Confirm 'Remove all unused local volumes?') { & $script:DoAction @('volume','prune') 'Pruning unused volumes...' }
    })

    # ---- Toolbar ----
    $script:ui.RefreshBtn.Add_Click({ $script:sync.ForceRefresh = $true })
    $script:ui.AboutBtn.Add_Click({ & $script:ShowAbout })

    # ---- UI timer: pull latest snapshot into the grids ----
    $script:timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:timer.Add_Tick({
        # keep auto-refresh checkbox in sync with poll interval
        $script:sync.IntervalSec = if ($script:ui.AutoRefreshCheck.IsChecked) { 3 } else { 86400 }

        if ($script:sync.Version -ne $script:LastVersion) {
            $script:LastVersion = $script:sync.Version
            & $script:UpdateGrid $script:ui.ContainersGrid $script:sync.Containers 'FullId'
            & $script:UpdateGrid $script:ui.ImagesGrid     $script:sync.Images     'FullId'
            & $script:UpdateGrid $script:ui.VolumesGrid    $script:sync.Volumes    'Name'

            $ts = if ($script:sync.LastRefresh) { $script:sync.LastRefresh.ToString('HH:mm:ss') } else { '-' }
            $counts = "Containers: $($script:sync.Containers.Count)  |  Images: $($script:sync.Images.Count)  |  Volumes: $($script:sync.Volumes.Count)"
            if ($script:sync.Error) {
                $script:ui.StatusText.Text = "ERROR @ $ts : $($script:sync.Error)"
            } else {
                $script:ui.StatusText.Text = "$counts   -   last refresh $ts"
            }
        }
    })
    $script:timer.Start()

    # ---- Shutdown ----
    $script:window.Add_Closed({
        $script:timer.Stop()
        $script:sync.Stop = $true
        try { $script:bgPs.EndInvoke($script:bgHandle) } catch {}
        $script:bgPs.Dispose(); $script:bgRunspace.Close(); $script:bgRunspace.Dispose()
    })

    $script:window.ShowDialog() | Out-Null
}

# --- STA bootstrap -------------------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
    Start-WslcRookeryUi
} else {
    # pwsh 7 defaults to MTA and has no -STA switch; host the UI on an STA runspace.
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.Runspace.SessionStateProxy.SetVariable('AppDir', $PSScriptRoot)
    $ps.Runspace.SessionStateProxy.SetVariable('DemoMode', $script:DemoMode)
    $null = $ps.AddScript((Get-Content -Raw -LiteralPath $PSCommandPath))
    $ps.Invoke() | Out-Null
    foreach ($e in $ps.Streams.Error) { Write-Error $e }
    $ps.Dispose(); $rs.Close(); $rs.Dispose()
}
