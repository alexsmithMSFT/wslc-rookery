# Copilot instructions for WSLC Rookery

WSLC Rookery is a single-file, local-only WPF GUI (PowerShell 7) for the WSL
container feature (`wslc.exe`) — a Docker-Desktop-style window that polls `wslc`
and shows Containers (with live stats), Images, and Volumes with lifecycle action
buttons. The entire application lives in `WslcRookery.ps1` (~490 lines). Everything
else is launchers, icons, and docs.

## Run and test

There is no build system, test suite, or linter. To run:

```powershell
pwsh -File .\WslcRookery.ps1
```

- Requires **PowerShell 7** (`pwsh`) and `wslc.exe` on PATH or at
  `%ProgramFiles%\WSL\wslc.exe` (resolved by `Resolve-WslcPath`).
- Double-click testing goes through `Start-WslcRookery.cmd`, which runs `pwsh …
  -Hidden`; the script then hides its own console window (`ShowWindow` `SW_HIDE`)
  so no empty pwsh console lingers. `-Hidden` must NOT be passed when running from
  an existing terminal (it would hide that terminal too).
- The app needs a live `wslc` environment to show real data (unless run with
  `-Demo`, which fills the grids with synthetic data and makes no `wslc` calls);
  there is no mock layer. Validate changes by running the window and watching the
  status bar, which surfaces object counts, last-refresh time, and `wslc` errors.

## Architecture (three cooperating threads)

1. **STA bootstrap** (bottom of the file): WPF requires an STA thread but pwsh 7
   defaults to MTA and has no `-STA` switch. When the current thread is not STA,
   the script re-hosts *its own raw source text* on a fresh STA runspace and
   injects `$AppDir` (because `$PSScriptRoot` is empty in that re-hosted context).
   `Start-WslcRookeryUi` runs on that STA thread.
2. **Background poller** (`$worker` runspace, MTA): loops calling
   `Get-WslcSnapshot`, writing results into the shared `$script:sync`
   synchronized hashtable and bumping `$sync.Version`. Never touches WPF.
3. **UI DispatcherTimer** (400ms): when `$sync.Version` changed, copies the
   latest snapshot into the DataGrids and updates the status bar. This is the
   only code that reads `$sync` on the UI thread.

Data flow: `wslc <cmd> --format json` → `Invoke-WslcJson`/`ConvertFrom-Json` →
`Get-WslcSnapshot` shapes `[pscustomobject]` rows → `$sync` → DataGrids.

## Key conventions

- **`$CommonFunctions` is a here-string, not real functions.** The shared data
  helpers (`Resolve-WslcPath`, `Invoke-WslcJson`, `Get-WslcSnapshot`, formatters)
  are defined inside a single-quoted `@'...'@` block so the *same text* can be
  `Invoke-Expression`'d on both the UI thread and the background runspace. When
  editing these helpers, edit them inside that string; they cannot reference
  anything outside it.
- **`$script:` scope everywhere in the UI.** WPF event handlers fire later and
  cannot see function-local variables, so all shared state, UI element refs
  (`$script:ui`), and handler helpers (`$script:DoAction`, `$script:Confirm`,
  `$script:ShowText`, etc.) are kept at script scope on purpose. Follow this
  pattern for any new handler or helper.
- **Actions go through `$script:DoAction`**: it sets a busy label, runs `wslc`
  via `$script:RunWslc`, shows a warning popup on failure, then sets
  `$sync.ForceRefresh = $true` so the poller repaints. Destructive actions
  (kill/remove/prune) must first pass `$script:Confirm`.
- **Container status** comes from the JSON `State` int mapped by
  `Get-ContainerStatusText` (`1=created`, `2=running`, `3=exited`).
- **Selection is preserved across refreshes** by `$script:UpdateGrid`, which
  re-selects the row whose key (`FullId` for containers/images, `Name` for
  volumes) matches the prior selection. New grids need a stable key prop.
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` are set;
  keep new code strict-mode-safe (guard property access, e.g. the `if ($st)`
  stat lookups).
- The window icon and About-dialog logo load from `$script:AppDir`; keep asset
  paths relative to it.

## Scope boundaries

Read + basic lifecycle management only (start/stop/kill/remove, rmi, volume
remove, prune, logs, inspect). No build/run/create/exec/pull/push, networks, or
registries — those stay in the `wslc` CLI. Version is `0.1`, tracked in
`$script:AppVersion`.
