# Copilot instructions for WSLC Rookery

WSLC Rookery is a single-file, local-only WPF GUI (PowerShell 7) for the WSL
container feature (`wslc.exe`) — a Docker-Desktop-style window that polls `wslc`
and shows Containers (with live stats), Images, and Volumes with lifecycle action
buttons. The entire application lives in `WslcRookery.ps1` (~975 lines). Everything
else is launchers, icons, and docs.

## Run and test

There is no build system, test suite, or linter. To run:

```powershell
pwsh -File .\WslcRookery.ps1
```

- Requires **PowerShell 7** (`pwsh`) and `wslc.exe` on PATH or at
  `%ProgramFiles%\WSL\wslc.exe` (resolved by `Resolve-WslcPath`).
- Double-click testing goes through `Start-WslcRookery.cmd`, which launches
  `pwsh` through `conhost.exe --headless`. This gives PowerShell the console APIs
  it expects without creating a visible console window; the `.cmd` exits
  immediately while the WPF process continues.
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

Data flow: `wslc <cmd> --format json` (**NDJSON** — one object per line, not an
array, so `Invoke-WslcJson` parses line by line) → `Get-WslcSnapshot` shapes
`[pscustomobject]` rows → `$sync` → DataGrids.

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
- **Connect does not use `$script:DoAction`.** `$script:RunWslc` captures output
  and waits, which would hang the UI thread for a whole interactive session.
  `$script:ConnectContainer` writes a small wrapper `.ps1` to `$env:TEMP` and
  launches it detached (`wt.exe -w -1 new-tab`, else plain `pwsh`); the wrapper
  self-deletes, tries `wslc start -ai`, and falls back to `wslc exec -i -t` on
  `ERROR_NOT_SUPPORTED`. Note `wt.exe` re-parses its own command line and strips
  per-argument quoting, so its arguments are passed as one pre-quoted string and
  the tab title is set from inside the wrapper, not with `--title`.
- **Container status** is `wslc`'s own `State` string, normalised by
  `Get-ContainerStatusText`.
- **Interactive detection** (`Get-ContainerInteractive`) brace-counts the JSON
  value out of the `com.microsoft.wsl.container.metadata` label and treats a
  non-zero `V1.InitProcessFlags` as interactive. The label value is JSON
  containing commas, so the label list cannot be split on `,`. Any parse failure
  degrades to "not interactive"; it is only a hint, never a gate.
- **Selection, sort and scroll are preserved across refreshes** by
  `$script:UpdateGrid`. Assigning `ItemsSource` builds a new CollectionView, so
  `Items.SortDescriptions` and each column's `SortDirection` must be captured
  before the swap and restored after; scroll offset is restored last, after
  selection. Grids need a stable key prop (`FullId` for containers/images,
  `Name` for volumes). Columns that display formatted text but must sort
  numerically use `SortMemberPath` pointing at a hidden numeric property.
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` are set;
  keep new code strict-mode-safe (guard property access, e.g. the `if ($st)`
  stat lookups).
- The window icon and About-dialog logo load from `$script:AppDir`; keep asset
  paths relative to it.

## Scope boundaries

Read + basic lifecycle management only (start/stop/kill/remove, rmi, volume
remove, prune, logs, inspect), plus **Connect**, which opens a container in a
host terminal. No build/run/create/pull/push, networks, or registries — those
stay in the `wslc` CLI. `exec` is used only as the Connect fallback shell, not
as a general capability. Version is `0.3`, tracked in `$script:AppVersion`.
