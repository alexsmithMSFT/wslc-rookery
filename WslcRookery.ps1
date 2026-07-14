<#
.SYNOPSIS
    WSLC Rookery - an informal, local-only Docker-Desktop-style GUI for the
    WSL container feature (wslc.exe). Watch over your whole container rookery.

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

.PARAMETER Hidden
    Hide this process's own console window on startup (SW_HIDE). The double-click
    launcher (Start-WslcRookery.cmd) passes this so no empty pwsh console lingers
    while the WPF window is open. A brief flash may still occur as the console is
    created and then immediately hidden. Do NOT pass this when running from an
    existing terminal - it would hide that terminal too.

.EXAMPLE
    pwsh -File .\WslcRookery.ps1 -Demo

.NOTES
    Local-only informal tool. Licensed under the MIT License.
#>
param([switch]$Demo, [switch]$Hidden)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Hide our own console ASAP so no empty pwsh window lingers behind the WPF UI.
# Only when -Hidden is passed (by the launcher) so an interactive `pwsh -File ...`
# from a terminal never hides the user's console. The STA re-host below runs this
# same text with -Hidden unbound (false), so it only fires once, in this process.
if ($Hidden) {
    try {
        Add-Type -Namespace WslcRookery -Name NativeWin -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        $consoleHwnd = [WslcRookery.NativeWin]::GetConsoleWindow()
        if ($consoleHwnd -ne [IntPtr]::Zero) { [WslcRookery.NativeWin]::ShowWindow($consoleHwnd, 0) | Out-Null } # 0 = SW_HIDE
    } catch { }
}

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
$script:AppVersion = '0.1'

# --- Shared helpers (injected into both the UI thread and the background poller)
$CommonFunctions = @'
function Resolve-WslcPath {
    $cmd = Get-Command wslc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    $fallback = Join-Path $env:ProgramFiles 'WSL\wslc.exe'
    if (Test-Path $fallback) { return $fallback }
    throw "wslc.exe not found (checked PATH and '$fallback'). Install the WSL container feature."
}

function Invoke-WslcJson {
    param([string]$Wslc, [string[]]$ArgList)
    $out = & $Wslc @ArgList --format json 2>&1
    $text = ($out | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "wslc $($ArgList -join ' ') exited $LASTEXITCODE`n$text"
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $data = $text | ConvertFrom-Json
    if ($null -eq $data) { return @() }
    return @($data)
}

function Format-Bytes {
    param($Bytes)
    if ($null -eq $Bytes) { return '' }
    $units = 'B','KB','MB','GB','TB','PB'
    $v = [double]$Bytes; $i = 0
    while ($v -ge 1024 -and $i -lt $units.Count - 1) { $v /= 1024; $i++ }
    return ('{0:0.##} {1}' -f $v, $units[$i])
}

function ConvertFrom-Epoch {
    param($Epoch)
    if ($null -eq $Epoch -or [long]$Epoch -le 0) { return '' }
    return [DateTimeOffset]::FromUnixTimeSeconds([long]$Epoch).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
}

function Get-ContainerStatusText {
    param([int]$State)
    switch ($State) {
        1 { 'created' }
        2 { 'running' }
        3 { 'exited' }
        default { "state-$State" }
    }
}

function Get-WslcSnapshot {
    param([string]$Wslc)
    $containersRaw = Invoke-WslcJson -Wslc $Wslc -ArgList @('container','list','--all')
    $statsRaw      = Invoke-WslcJson -Wslc $Wslc -ArgList @('stats','--all','--no-trunc')
    $imagesRaw     = Invoke-WslcJson -Wslc $Wslc -ArgList @('images','--no-trunc')
    $volumesRaw    = Invoke-WslcJson -Wslc $Wslc -ArgList @('volume','list')

    $statsById = @{}
    foreach ($s in $statsRaw) { if ($s.ID) { $statsById[$s.ID] = $s } }

    $containers = foreach ($c in $containersRaw) {
        $st = $statsById[$c.Id]
        [pscustomobject]@{
            Name     = $c.Name
            IdShort  = if ($c.Id) { $c.Id.Substring(0, [Math]::Min(12, $c.Id.Length)) } else { '' }
            Image    = $c.Image
            Status   = Get-ContainerStatusText -State ([int]$c.State)
            CPU      = if ($st) { $st.CPUPerc } else { '' }
            Mem      = if ($st) { $st.MemPerc } else { '' }
            MemUsage = if ($st) { $st.MemUsage } else { '' }
            NetIO    = if ($st) { $st.NetIO } else { '' }
            BlockIO  = if ($st) { $st.BlockIO } else { '' }
            PIDs     = if ($st) { $st.PIDs } else { '' }
            Created  = ConvertFrom-Epoch -Epoch $c.CreatedAt
            FullId   = $c.Id
        }
    }

    $images = foreach ($im in $imagesRaw) {
        $id = [string]$im.Id
        $short = if ($id.StartsWith('sha256:')) { $id.Substring(7, [Math]::Min(12, $id.Length - 7)) }
                 elseif ($id) { $id.Substring(0, [Math]::Min(12, $id.Length)) } else { '' }
        [pscustomobject]@{
            Repository = if ($im.Repository) { $im.Repository } else { '<none>' }
            Tag        = if ($im.Tag) { $im.Tag } else { '<none>' }
            IdShort    = $short
            Size       = Format-Bytes -Bytes $im.Size
            Created    = ConvertFrom-Epoch -Epoch $im.Created
            FullId     = $id
        }
    }

    $volumes = foreach ($vol in $volumesRaw) {
        [pscustomobject]@{
            Name   = $vol.Name
            Driver = $vol.Driver
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
    $now = Get-Date

    $running = @(
        @{ Name = 'web-frontend'; Image = 'nginx:1.27';         Cpu = 4.2;  Mem = 6.1;  MemUsage = '124.5 MiB / 2 GiB';  Net = '3.4 MB / 1.2 MB';   Block = '8.1 MB / 0 B';   PIDs = 9;  Ago = 3 },
        @{ Name = 'api-gateway';  Image = 'traefik:v3';          Cpu = 7.8;  Mem = 9.4;  MemUsage = '188.2 MiB / 2 GiB';  Net = '12.7 MB / 9.1 MB';  Block = '2.3 MB / 512 kB'; PIDs = 14; Ago = 5 },
        @{ Name = 'cache';        Image = 'redis:7';             Cpu = 1.5;  Mem = 3.2;  MemUsage = '64.8 MiB / 2 GiB';   Net = '820 kB / 640 kB';   Block = '0 B / 0 B';      PIDs = 5;  Ago = 6 },
        @{ Name = 'db';           Image = 'postgres:16';         Cpu = 3.1;  Mem = 15.7; MemUsage = '321.0 MiB / 2 GiB';  Net = '5.6 MB / 4.2 MB';   Block = '44.9 MB / 12 MB';PIDs = 21; Ago = 8 },
        @{ Name = 'worker';       Image = 'python:3.12-slim';    Cpu = 12.6; Mem = 8.8;  MemUsage = '176.4 MiB / 2 GiB';  Net = '2.1 MB / 3.8 MB';   Block = '6.0 MB / 1.1 MB'; PIDs = 7;  Ago = 4 }
    )
    $stopped = @(
        @{ Name = 'hello-penguin'; Image = 'helloworld:latest';  Ago = 2 },
        @{ Name = 'migration-job'; Image = 'postgres:16';        Ago = 9 },
        @{ Name = 'old-build';     Image = 'node:20-alpine';     Ago = 30 }
    )

    $ci = 0
    $containers = @()
    $containers += foreach ($r in $running) {
        $id = ('{0:x12}' -f (0x100000000000 + $ci * 0x1a2b3c)); $ci++
        [pscustomobject]@{
            Name     = $r.Name
            IdShort  = $id.Substring(0, 12)
            Image    = $r.Image
            Status   = 'running'
            CPU      = (& $jit $r.Cpu 2.0)
            Mem      = (& $jit $r.Mem 1.5)
            MemUsage = $r.MemUsage
            NetIO    = $r.Net
            BlockIO  = $r.Block
            PIDs     = [string]$r.PIDs
            Created  = $now.AddHours(-1 * $r.Ago).ToString('yyyy-MM-dd HH:mm:ss')
            FullId   = "$id$id`demo"
        }
    }
    $containers += foreach ($r in $stopped) {
        $id = ('{0:x12}' -f (0x200000000000 + $ci * 0x1a2b3c)); $ci++
        [pscustomobject]@{
            Name     = $r.Name
            IdShort  = $id.Substring(0, 12)
            Image    = $r.Image
            Status   = 'exited'
            CPU      = ''
            Mem      = ''
            MemUsage = ''
            NetIO    = ''
            BlockIO  = ''
            PIDs     = ''
            Created  = $now.AddDays(-1 * $r.Ago).ToString('yyyy-MM-dd HH:mm:ss')
            FullId   = "$id$id`demo"
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
            Created    = $now.AddDays(-1 * $im.Ago).ToString('yyyy-MM-dd HH:mm:ss')
            FullId     = "sha256:$($im.Id)demofulliddemofulliddemofulliddemofull"
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
      <TextBlock Text="WSLC Rookery" FontSize="16" FontWeight="Bold"
                 VerticalAlignment="Center"/>
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
              <DataGridTextColumn Header="Image"     Binding="{Binding Image}"    Width="150"/>
              <DataGridTextColumn Header="CPU"       Binding="{Binding CPU}"      Width="70"/>
              <DataGridTextColumn Header="Mem%"      Binding="{Binding Mem}"      Width="70"/>
              <DataGridTextColumn Header="Mem Usage" Binding="{Binding MemUsage}" Width="140"/>
              <DataGridTextColumn Header="Net I/O"   Binding="{Binding NetIO}"    Width="120"/>
              <DataGridTextColumn Header="Block I/O" Binding="{Binding BlockIO}"  Width="120"/>
              <DataGridTextColumn Header="PIDs"      Binding="{Binding PIDs}"     Width="55"/>
              <DataGridTextColumn Header="Container ID" Binding="{Binding IdShort}" Width="110"/>
              <DataGridTextColumn Header="Created"   Binding="{Binding Created}"  Width="150"/>
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
              <DataGridTextColumn Header="Size"       Binding="{Binding Size}"       Width="110"/>
              <DataGridTextColumn Header="Created"    Binding="{Binding Created}"    Width="160"/>
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
    $iconPath = Join-Path $script:AppDir 'docs\WslcRookery.ico'
    if (Test-Path -LiteralPath $iconPath) {
        try {
            $script:window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath))
        } catch { }
    }

    # Element refs
    $script:ui = @{}
    foreach ($n in     'AutoRefreshCheck','RefreshBtn','AboutBtn','StatusText',
                   'ContainersGrid','CStartBtn','CStopBtn','CKillBtn','CRemoveBtn','CLogsBtn','CInspectBtn','CPruneBtn',
                   'ImagesGrid','IRemoveBtn','IInspectBtn','IPruneBtn',
                   'VolumesGrid','VRemoveBtn','VInspectBtn','VPruneBtn') {
        $script:ui[$n] = $script:window.FindName($n)
    }

    # ---- UI-thread helpers (script scope so event handlers can see them) ----
    $script:LastVersion = -1

    $script:UpdateGrid = {
        param($grid, $items, $keyProp)
        $prevKey = if ($grid.SelectedItem) { $grid.SelectedItem.$keyProp } else { $null }
        $grid.ItemsSource = $items
        if ($prevKey) {
            foreach ($it in $items) {
                if ($it.$keyProp -eq $prevKey) { $grid.SelectedItem = $it; $grid.ScrollIntoView($it); break }
            }
        }
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
