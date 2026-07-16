[README.md](https://github.com/user-attachments/files/30095821/README.md)
# BHE Power BI Toolkit

PowerShell collectors + a Power BI dashboard for BloodHound Enterprise: certification/attestation status, findings, data quality, Tier Zero composition, and collector activity.

## Quick start

1. Clone the repo and copy `.env.example` to `.env`, then fill in your tenant details:
   ```
   BHE_API_URL=http://localhost:8080
   BHE_TOKEN_ID=...
   BHE_TOKEN_KEY=...
   ```
2. First run - get everything:
   ```powershell
   .\Update-BHEData.ps1
   ```
   Runs every collector in the right order (handles the Extract → Flatten dependency, logs the run, tells you if a new environment appeared). **Known gap:** this predates Certifications, so also run those two once manually:
   ```powershell
   .\Get-BHECertifications.ps1
   .\Get-BHECertificationSelectors.ps1
   ```
   (or add them as steps inside `Update-BHEData.ps1`'s `$steps` array so future runs cover them automatically)
3. Open **`BHE-Dashboard_v1.0.pbix`** in Power BI Desktop, click **Refresh** (Home ribbon). Don't need every page? Right-click a page tab → **Delete** — safe, the file is self-contained.

That's it. No manual table setup, no re-wiring measures or relationships.

## Two ways to run collectors

- **`Update-BHEData.ps1`** — the real orchestrator. Runs everything in dependency order, logs to `Data\logs\`, detects new/removed environments, exits non-zero on failure (so Task Scheduler can flag it). Use this for full refreshes and scheduling.
- **`Launch-BHEPowerBI.ps1`** — a menu for *selective* runs, when you only want data for specific dashboard pages rather than everything. Picking `A` in its menu just delegates to `Update-BHEData.ps1` rather than duplicating that logic.

## What each collector pulls

| Collector | Pulls | Feeds | Notes |
|---|---|---|---|
| `Invoke-BHEExtract.ps1` | available-domains, clients, posture-stats, completeness, audit (raw) | Base tables | **Must run before Flatten Extract** |
| `Flatten-BHEData.ps1` | Flattens audit.csv/clients.csv into PBI-ready tables | Activity / Collectors & Schedules | Depends on Generic Extract's output |
| `Get-BHECertifications.ps1` | Tier Zero / privilege-zone certification status (Pending, Auto, Manual, Revoked) per object | Certifications page | Not yet in Update-BHEData.ps1 - see Quick Start |
| `Get-BHECertificationSelectors.ps1` | The selector rule(s) that placed each object into its tag | Certifications page | Run after Certifications |
| `Get-BHEFindings.ps1` | Attack path finding counts/detail per environment | Findings Detail page | |
| `Get-BHEPosture.ps1` | Posture history/stats per environment | Overview page | Possible overlap with Generic Extract's posture-history files - unconfirmed |
| `Get-BHEPanels.ps1` | Data quality, finding trends, Tier Zero composition | Overview page | |
| `Get-BHECollectorHealth.ps1` | Collector/client status - check-in, schedule, job success | Collectors & Schedules page | |
| `Get-BHEVersion.ps1` | Tenant host, BHE version, API version, logged-in user | Footer bar (all pages) | |

This table is also `Collectors.manifest.json`, in the same order — `Launch-BHEPowerBI.ps1`'s menu reads it directly. If you edit the manifest, update this table by hand (not auto-synced). Add a row for any collector not listed and it'll show up in the menu automatically.

### Utility scripts (not collectors)

`Test-BHE-API_(Using Env).ps1` is a connectivity/auth check, not something that produces dashboard data - it's intentionally left out of the manifest. Run it manually if you need to sanity-check `.env` before a full run.

## Picking which widgets you want

Power BI doesn't support picking individual visuals at import time — a report is one file. The practical equivalent:
- **Want everything:** `.\Update-BHEData.ps1`, then open the `.pbix` and Refresh.
- **Want a subset:** use `.\Launch-BHEPowerBI.ps1`'s menu to run only the collectors feeding the pages you care about (check the Notes column above for dependencies first), then delete the unneeded report pages in Power BI Desktop (right-click tab → Delete). Pages with no data just show blank visuals - harmless, but worth trimming.

## Scheduled collection

```powershell
.\Launch-BHEPowerBI.ps1 -RegisterTask
```
Walks you through Daily or Hourly, and registers a Windows Scheduled Task that runs `Update-BHEData.ps1` unattended. Set Power BI's own scheduled refresh (Service) or just reopen/refresh the desktop file to see the latest pull.

## Security

`.env` holds your API credentials and is git-ignored — never commit it. Commit `.env.example` (no real values) instead.

## Repo structure

```
BHE-PowerBI-Toolkit/
├── Update-BHEData.ps1           # full-run orchestrator (use this for scheduling)
├── Launch-BHEPowerBI.ps1        # selective-run menu (delegates "all" to Update-BHEData.ps1)
├── Collectors.manifest.json     # collector list + descriptions (drives the menu)
├── Invoke-BHEExtract.ps1        # base data - must run before Flatten
├── Flatten-BHEData.ps1
├── Get-BHE*.ps1                 # individual collectors
├── Test-BHE-API_(Using Env).ps1 # utility, not a collector
├── BHE-Dashboard_v1.0.pbix      # full dashboard - Refresh after running collectors
├── .env.example
├── .gitignore
└── Data/                        # generated - git-ignored
```

## Publishing to GitHub

```powershell
cd BHE-PowerBI-Toolkit
git init
git add .
git commit -m "Initial commit: BHE Power BI toolkit"
gh repo create bhe-powerbi-toolkit --private --source=. --push
```
No `gh` CLI? Create the empty repo on github.com first, then:
```powershell
git remote add origin https://github.com/<you>/bhe-powerbi-toolkit.git
git branch -M main
git push -u origin main
```
