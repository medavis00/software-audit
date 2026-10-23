# Software audit

Checks that your computers have the same apps at the same versions, and flags apps that should be removed.

## Files

| File | What it is |
|---|---|
| `collect-windows.bat` / `collect-windows.ps1` | Run on each Windows PC. Lists installed apps. |
| `collect-mac-linux.sh` | Run on each Mac or Linux machine. Lists installed apps. |
| `approved-apps.csv` | **Your list** of apps every machine should have, and which version. |
| `deprecated-apps.csv` | **Your list** of apps that should be removed. |
| `audit.py` | Compares every machine against both lists and writes the report. |
| `inventories/` | Each machine's app list lands here as `<computer name>.json`. |

## How to run it

The easiest setup is to keep this folder somewhere all three computers can see (OneDrive, Dropbox, iCloud Drive, a USB stick, or a network share). Then:

1. **On each computer, collect its app list:**
   - Windows: double-click `collect-windows.bat`.
     Add `-IncludeStoreApps` (run the `.ps1` from PowerShell) to include Microsoft Store apps.
   - Mac / Linux: open Terminal in this folder and run `bash collect-mac-linux.sh`.
     On Linux it lists packages you installed yourself, plus Flatpak and Snap apps; add `--all` for every system package.
2. **On any one computer, run the audit:** `python3 audit.py` (on Windows: `py audit.py`).
   Python 3 is the only requirement (free from python.org, or `winget install Python.Python.3.12`).
3. **Open `report.html`.** Each app gets a row and each computer a column:
   - green **OK**, red **BEHIND** (older than expected), yellow **MISSING**, red **REMOVE** (deprecated app found),
     blue **NEWER** (newer than the exact version you pinned; informational).
   - A collapsible section at the bottom lists every app that isn't on either list yet, so you can decide where it belongs.
   - `report.csv` holds the same results for Excel.

## Editing the lists

Both lists are plain CSV files; edit them in Excel, Numbers, or any text editor.

### approved-apps.csv

| Column | Meaning |
|---|---|
| `app` | The name you want to see in the report. |
| `match` | How the app is named on each machine, separated by `;`. `*` is a wildcard and case doesn't matter. Leave blank to use `app` exactly. Example: `Microsoft Visual Studio Code*;Visual Studio Code` covers the Windows and Mac names. |
| `expected_version` | Blank or `latest`: every machine should match the newest version found on any of them. `24.08`: exactly this version. `>=24.0`: at least this version. |
| `machines` | Blank = all computers. Or list computer names separated by `;` if an app only belongs on some of them. |
| `notes` | Anything you want shown in the report. |

**Tip for building the list:** run `python3 audit.py --suggest`. It writes `suggested-apps.csv` with every app found on 2 or more machines that isn't listed yet. Copy the rows you want into `approved-apps.csv`.

Names differ by OS (Windows says `7-Zip 23.01 (x64)`, a Mac says `7-Zip`), which is why `match` takes several patterns. Check the "not on either list" section of the report for the exact names on each machine.

### deprecated-apps.csv

Columns `app`, `match` (same rules as above), and `reason`. Any machine that has a matching app shows **REMOVE**.

The starter rows in both files are only examples; replace them with your own apps.
