# Android Debloat Toolkit

A personal, no-root toolkit to find and remove bloatware on **any Android phone or tablet (Android 9 to 16)**:
OEM junk, carrier apps, preloaded third-party apps, Google apps, or anything else you pick.

It never blocks you. Every package on the device is listed and labelled with a risk level, and you decide what goes.

```
SETUP-ANDROID-REMOVE-BLOATWARES/
├── scripts/
│   ├── scanner.ps1      scan + classify + generate an editable removal list
│   ├── remover.ps1      uninstall / disable / restore any packages
│   └── debloat.sh       on-device remover (Shizuku or adb shell, no PC needed)
├── gui/                 local web GUI (Vite + React) that runs the two scripts
├── output/              generated per device (git-ignored)
│   ├── <brand>_<model>_<serial>/
│   │   ├── latest.json                  last scan (used by the GUI)
│   │   ├── report.md                    readable report
│   │   ├── auto_remove_bloatware.ps1    your editable removal list
│   │   └── history/                     older scans and lists
│   ├── selections/                      every package list run from the GUI
│   └── logs/                            one log per run
└── apks/                your own APKs (git-ignored)
```

## Requirements

- Windows with PowerShell 7 (`pwsh`) or Windows PowerShell 5.1
- [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) (`adb`) on `PATH`
- On the device: **Developer options → USB debugging** on, then accept the "Allow USB debugging" prompt
- Node.js 20.19+ (only for the GUI)

## Quick start (GUI)

```bash
cd gui
npm install
npm run dev
```

This opens `http://127.0.0.1:5178`. The GUI does everything below, through the same scripts:

- pick a device (devices with a saved scan show as `offline`, so you can plan without the device connected)
- scan, then filter by status, risk, category or search text
- quick-select **Recommended / Aggressive / Maximum**, **Visible** rows, or **Removed** apps (for restore)
- add **any** package name (for example an app the scanner doesn't know)
- protect a package (`○` / `●`) so it is never selected on that device
- run **Uninstall / Disable / Restore**, with **Dry run** and **Keep data** options
- live console output, cancel, and an automatic rescan after each run
- dark (`#000` / `#0a0a0a`) and light theme

Other scripts: `npm run serve` (no browser auto-open), `npm run build`, `npm start` (build + preview).
The API only listens on `127.0.0.1` and refuses requests from other origins.

## Quick start (command line)

```powershell
.\scripts\scanner.ps1                                   # scan, writes output\<device>\...
.\output\<device>\auto_remove_bloatware.ps1 -DryRun     # preview the plan
.\output\<device>\auto_remove_bloatware.ps1             # run it
```

Both scripts print their full usage with `-h` (or `-Help`).

### scanner.ps1

| Option | What it does |
|---|---|
| `-Serial <id>` | choose a device when several are connected |
| `-Level Recommended\|Aggressive\|Maximum` | which risks start **active** in the generated list (default Recommended) |
| `-NoScript` | scan and report only |
| `-OutputDir <dir>` | where results go (default `output\`) |
| `-ListDevices` | list adb devices as JSON (used by the GUI) |
| `-h`, `-Help` | show help |

The whole scan is one adb round-trip (about 1 to 2 seconds). It reads every package (including ones already removed for your user), its install path (system / product / vendor / data partition), whether it is an updated system app, who installed it, and whether it is disabled.

Re-scanning keeps your edits to `auto_remove_bloatware.ps1`: lines you commented or uncommented keep that state. Passing `-Level` explicitly starts a fresh list (the old one is backed up to `history\`).

### remover.ps1

| Option | What it does |
|---|---|
| `-Packages a,b,c` | packages to process (comma, space or semicolon separated) |
| `-ListFile <file>` | one package per line, `#` starts a comment |
| `-Mode Uninstall\|Disable\|Restore` | default `Uninstall` |
| `-DryRun` | show the plan, change nothing |
| `-KeepData` | uninstall with `-k` (keeps data/cache, faster restore) |
| `-Serial <id>` | choose device |
| `-LogDir <dir>` | where logs go (default `output\logs`) |
| `-h`, `-Help` | show help |

## On the phone, without a PC (Shizuku)

[Shizuku](https://shizuku.rikka.app/) gives apps and terminals the same "shell" rights as adb, so `scripts/debloat.sh` can run directly on the phone. It uses the same removal strategy and checks as `remover.ps1`; the classification (safe / optional / ...) stays on the PC, so plan there and run on the phone.

1. Install **Shizuku** and **Termux**, start Shizuku (Wireless debugging on Android 11+, or once via a PC).
2. In Shizuku: **Use Shizuku in terminal apps → Export files** to a folder Termux can reach. Set `RISH_APPLICATION_ID="com.termux"` in the exported `rish` file, as the Shizuku docs describe.
3. Copy `debloat.sh` and a list file to the phone, for example `/sdcard/Download/`. In the GUI, **export** (next to the selected count) downloads the current selection as `debloat-list.txt`.
4. In Termux:

```bash
sh rish -c 'sh /sdcard/Download/debloat.sh uninstall -n -f /sdcard/Download/debloat-list.txt'
sh rish -c 'sh /sdcard/Download/debloat.sh uninstall -f /sdcard/Download/debloat-list.txt'
```

| Command | What it does |
|---|---|
| `uninstall` / `disable` / `restore` | same as the remover modes |
| `status [pkg ...]` | state of the given packages, or every package |
| `-f <file>` | read packages from a list file (`#` = comment) |
| `-n` | dry run |
| `-k` | keep data on uninstall |
| `-h` | help |

It also works over USB: `adb push scripts/debloat.sh /data/local/tmp/` then `adb shell sh /data/local/tmp/debloat.sh status`.

## How removal works (no root)

The remover checks each package on the live device and picks the strongest removal possible:

| Package type | Commands | Result |
|---|---|---|
| App on `/data` (user or preloaded-to-data) | `pm uninstall` (falls back to `--user 0` if refused) | **gone for good** |
| Updated system app | `pm uninstall` (removes updates), then `pm uninstall --user 0` | removed for you |
| System app | `pm uninstall --user 0` | removed for you |

"Removed for you" means the app no longer runs, uses no RAM, CPU or battery, and doesn't show anywhere. Its APK stays on the read-only `/system` partition; deleting that file needs root. This is the maximum possible without root. A factory reset brings system apps back.

All commands for a run are pushed to the device as one shell script and executed in a single pass, then checked against a fresh package list. Each package is reported as `PERMANENT`, `REMOVED`, `DISABLED`, `RESTORED`, `SKIPPED` or `FAILED`.

**Restore** uses `pm install-existing --user 0` plus `pm enable`, which works for anything removed "for you". Apps that were fully uninstalled have to be reinstalled from a store or APK.

## Categories and risk levels

| Category | Examples |
|---|---|
| Third-party preloads | Facebook services, Netflix stub, Glance, Opera preinstall, ad installers (Aura, AppLovin, ironSource, Digital Turbine), games |
| OEM / ODM | Samsung, Xiaomi/POCO, OPPO/Realme/OnePlus, vivo/iQOO, Huawei/Honor, Lenovo/Motorola, Nokia, ASUS, Sony, LG, Transsion, Nothing, ZTE, TCL, ODMs (Wingtech, Huaqin, Longcheer) |
| Carrier | Jio, Airtel, Vodafone, Verizon, AT&T, T-Mobile, ... |
| Google | every Google app and service, classified one by one |
| Chipset | Qualcomm, MediaTek, Unisoc, Dolby |
| Your installed apps | anything you installed (Play Store, F-Droid, APK) |
| Unrecognised system | system packages that match no rule |
| Android system | AOSP framework components |

| Risk | Meaning | Recommended | Aggressive | Maximum |
|---|---|:-:|:-:|:-:|
| `safe` | junk, ads, demos, setup leftovers | ✓ | ✓ | ✓ |
| `optional` | real apps; fine to remove if you use alternatives | | ✓ | ✓ |
| `caution` | services; removing may break a feature (camera, sync, OTA, SIM...) | | | ✓ |
| `keep` | core OS; removing can break boot or the UI | | | |

Your own installed apps and `keep` packages are never pre-selected, but you can still select them yourself.
Removing core packages, your **current launcher** or your **current keyboard** prints a warning instead of being blocked.

To change a classification, edit the rules table at the top of `scripts/scanner.ps1`:

```
com.example.app        | thirdparty | safe     | Label      # exact package
com.example.*          | oem        | caution  | Label      # prefix (longest match wins)
```

## Tips

- Always do a **Dry run** first on a new device.
- Remove in batches and reboot between big ones. If something breaks, run **Restore** on the last batch (every run's list is in `output/selections/`).
- If the device boot-loops after removing core packages: `adb shell pm install-existing --user 0 <package>` works as soon as adb is reachable. Otherwise, factory reset.
- OTA updates can bring removed apps back. Just rescan and run again.

## License

[MIT](LICENSE)
