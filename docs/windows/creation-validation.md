# Windows creation tool validation

`Windows/scripts/creation-check.ps1` exercises the development CLI across separate processes using synthetic data. Its default run needs no provider credential or Internet access. It refuses an existing output directory and does not delete user data, change provider credentials or notify the user's desktop host.

## Offline acceptance

Build the shared assets, native engine and Windows solution as described in [README.md](README.md), then run:

```powershell
powershell -NoProfile -File Windows/scripts/creation-check.ps1
```

Use `-CliPath <swcli.exe>` to select a build and `-Output <new-directory>` to retain results at a chosen location. Default output is a unique directory under `Windows/artifacts`.

The script checks saved-conversation discovery, accurate publication results when a read-only conversation file prevents saving, normal application, selecting an old version, installation-identity and nested/binary-file preservation, forks, rejection of stale application after a manual edit, explicit network-host approval, three native preview sizes, package export/import, and Skill import/selection/export/removal/restoration. It uses authored conversation fixtures for version operations; this offline mode does not claim to test real model generation.

After `ai apply`, `ok: true` means the widget was published. Check `conversationSaved` separately. If it is false, use the returned widget name/installation to locate the saved code; starting a new conversation with `ai new --package <name> ...` can continue from it once storage is writable. Do not blindly repeat a new-widget publication after restarting the CLI: its previous package binding may not have been persisted. Studio keeps that binding in memory, updates the editor and offers an explicit warning to keep the window open and retry.

Each command has stdout/stderr evidence. `acceptance.json` records an overall `ok` value, every check, the executable SHA-256 and the selected modes. A failed command or assertion stops the script with a nonzero exit code and `ok: false`. Existing output directories are rejected so a failed run cannot be confused with old passing artifacts.

The Windows workflow is configured to run this offline acceptance on x64 and ARM64 after building the CLI and upload its synthetic artifacts. A workflow change is not evidence of a successful remote run; local results and unexecuted CI/hardware checks are listed in [testing.md](testing.md).

## Optional live services

```powershell
powershell -NoProfile -File Windows/scripts/creation-check.ps1 -OnlineGallery
powershell -NoProfile -File Windows/scripts/creation-check.ps1 -OnlineGallery -LiveAi
```

`-OnlineGallery` checks the trusted catalog and installs/runs its offline Hello Card. `-LiveAi` reads the active profile's metadata from `%LOCALAPPDATA%\ScriptWidget` or the directory supplied with `-ProfileData`. The script reconstructs a metadata-only profile in its isolated data folder and reads the existing key through Credential Locker. It neither sets nor removes a provider key. Model calls use synthetic widget code and may incur provider charges.

Live mode tests generation, application, refusal to overwrite an external edit, repair of a deliberately failing entry, execution of the repaired package and recovery after terminating its own test CLI process once a durable running turn exists. The next CLI process must read that turn as interrupted. This is crash recovery; graceful cancellation and bounded repair behavior have separate deterministic Core tests.

## Animation stress testing

The desktop check uses 30 minutes as its maximum stress interval, with several simultaneous widgets:

```powershell
powershell -NoProfile -File Windows/scripts/desktop-check.ps1 -HostPath <ScriptWidget.exe> -Output <scratch-directory> -AnimationStressSeconds 1800 -AnimationStressCopies 4
```

Quit the user's host first. The check uses its own data folder; its output directory is replaced, so choose and verify a disposable absolute path. To build a new package during a stress run, first copy the tested layout to a separate directory and run that copy.

Each stress widget plays both a sampled GIF and a native swing. The test disables full-screen pausing and uses a 24-hour automatic refresh interval in scratch settings so scheduled script runs do not contaminate the animation-only check. Half-second samples are appended to `animation-samples.csv`; the final `animation-performance.json` includes CPU time, private/working-set memory, handles, widget count and host SHA-256. The host must stay running, all windows must remain, memory/handles must stay within the stated warm-sample thresholds, and animation ticks must not increment the script's storage counter.

The script also checks independent GIF playback, posted session lock/unlock, removal, actions and desktop-window behavior. Posted messages and native captures do not substitute for real unlocked pointer/keyboard, mixed-DPI, sign-in, physical sleep or ARM64-device acceptance.
