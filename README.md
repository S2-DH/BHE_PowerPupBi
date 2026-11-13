[README.md](https://github.com/user-attachments/files/34812101/README.md)
# BH-PowerPupBI

PowerShell collectors + a Power BI dashboard for BloodHound Enterprise: certifications/attestation status, findings, finding movement, data quality, Tier Zero composition, collector health, API token hygiene, and a live audit log — all refreshed with one script.

> "PowerPupBI" is just the project's display name, used in this README and in the scripts' own console banners/log filenames. It doesn't rename any of the actual `.ps1` files, CSV outputs, or PowerShell function names — those stay as `BHE-*` / `Get-BHE*` throughout, so nothing you've already got wired up in Power BI or Task Scheduler breaks.

**New here?** [`GETTING-STARTED.md`](./GETTING-STARTED.md) is a one-page version of everything below — use that if you just want to get running. This file is the fuller reference.

**Requires:** a BloodHound **Enterprise** tenant (not CE) with an API token, network access to it, Windows + PowerShell, and Power BI Desktop (free). Full prerequisites table in `GETTING-STARTED.md`.

## Quick start

1. Clone the repo and copy `.env.example` to `.env`, then fill in your tenant details:
   ```
   BHE_API_URL=http://localhost:8080
   BHE_TOKEN_ID=...
   BHE_TOKEN_KEY=...
   ```
2. Run everything:
   ```powershell
   .\Update-BHEData.ps1
   ```
   Runs every collector in the right order (handles the Extract → Flatten dependency, logs the run to `Data\logs\powerpupbi_<timestamp>.log`, tells you if a new environment appeared).
3. Open the `.pbit` dashboard template in Power BI Desktop, click **Refresh** (Home ribbon). Don't need every page? Right-click a page tab → **Delete** — safe, the file is self-contained.

That's it. No manual table setup, no re-wiring measures or relationships.


<img width="546" height="1121" alt="PowerPupBI - Scripts" src="https://github.com/user-attachments/assets/283574cb-7c00-421f-8833-42c95f9724b6" />

## Two ways to run collectors

- **`Update-BHEData.ps1`** — the real orchestrator. Runs everything in dependency order, logs to `Data\logs\`, detects new/removed environments, exits non-zero on failure (so Task Scheduler can flag it). Use this for full refreshes and scheduling.
- **`Launch-BHEPowerBI.ps1`** — a menu for *selective* runs, when you only want data for specific dashboard pages rather than everything. Picking `A` in its menu just delegates to `Update-BHEData.ps1` rather than duplicating that logic.

## What each collector pulls

| Collector | Pulls | Feeds | Notes |
|---|---|---|---|
| `Invoke-BHEExtract.ps1` | available-domains, clients, posture-stats, completeness, audit (raw) | Base tables | **Must run before Flatten Extract** |
| `Flatten-BHEData.ps1` | Flattens audit.csv/clients.csv into PBI-ready tables | Activity / Collectors & Schedules | Depends on Generic Extract's output |
| `Get-BHEFindings.ps1` | Attack path finding counts/detail per environment | Findings Detail page | |
| `Get-BHECertifications.ps1` | Tier Zero / privilege-zone certification status (Pending, Auto, Manual, Revoked) per object | Certifications page | |
| `Get-BHECertificationSelectors.ps1` | The selector rule(s) that placed each object into its tag | Certifications page | Run after Certifications |
| `Get-BHEFindingTrends.ps1` | Finding count movement over a time window (default 30 days) — new vs. shrinking finding types | Findings Detail (trend section) | Answers "is risk going up or down" |
| `Get-BHEPosture.ps1` | Posture history/stats per environment | Overview page | |
| `Get-BHEPanels.ps1` | Data quality, finding trends, Tier Zero composition | Overview page | |
| `Get-BHECollectorHealth.ps1` | Collector/client status — check-in, schedule, job success | Collectors & Schedules page | |
| `Get-BHETokens.ps1` | API token inventory — name, owning user/collector, created date, last used, expiry | Collectors & Schedules (or a Security/Admin page) | |
| `Get-BHEAuditLog.ps1` | Last 50 audit trail entries — date/time, actor, action, status, with a Today/Past-7-Days/Older recency column | Overview or a new Activity page | |
| `Get-BHEVersion.ps1` | Tenant host, BHE version, API version, logged-in user | Footer bar (all pages) | |

This table is also `Collectors.manifest.json`, in the same order — `Launch-BHEPowerBI.ps1`'s menu reads it directly. If you edit the manifest, update this table by hand (not auto-synced). Add a row for any collector not listed and it'll show up in the menu automatically.

### Utility scripts (not collectors)

`Test-BHE-API_(Using Env).ps1` is a connectivity/auth check, not something that produces dashboard data — it's intentionally left out of the manifest. Run it manually if you need to sanity-check `.env` before a full run.

## Picking which widgets you want

Power BI doesn't support picking individual visuals at import time — a report is one file. The practical equivalent:
- **Want everything:** `.\Update-BHEData.ps1`, then open the dashboard file and Refresh.
- **Want a subset:** use `.\Launch-BHEPowerBI.ps1`'s menu to run only the collectors feeding the pages you care about (check the Notes column above for dependencies first), then delete the unneeded report pages in Power BI Desktop (right-click tab → Delete). Pages with no data just show blank visuals — harmless, but worth trimming.

Dashboard / Widgets
<img width="1443" height="810" alt="PowerPupBI - Dashboard 1" src="https://github.com/user-attachments/assets/e280fa9e-f551-4765-a835-12d0ef3f7c82" />
<img width="1871" height="1052" alt="PowerPupBI - Dashboard 2" src="https://github.com/user-attachments/assets/4a496b1f-0efd-4dc6-88bd-cbe66c41d8ec" />
<img width="1872" height="1052" alt="PowerPupBI - Dashboard 3" src="https://github.com/user-attachments/assets/7bac720f-c79e-407a-a094-ac00a908fd8c" />
<img width="1875" height="1056" alt="PowerPupBI - Dashboard 4" src="https://github.com/user-attachments/assets/96f91395-d3e8-4f0c-8469-8aa97a238c1e" />

## Scheduled collection

```powershell
.\Launch-BHEPowerBI.ps1 -RegisterTask
```
Walks you through Daily or Hourly, and registers a Windows Scheduled Task that runs `Update-BHEData.ps1` unattended. Set Power BI's own scheduled refresh (Service) or just reopen/refresh the desktop file to see the latest pull.

## How the Power BI fields are wired together

<img width="2166" height="579" alt="PowerPupBI - Model View" src="https://github.com/user-attachments/assets/b7a2cef8-4e3c-4de8-8d34-45ec6d61e07d" />

Each collector writes its own CSV into `Data\`, and Power Query imports each one as its own query (not a single combined-folder query) — so adding a new collector means adding a new `Get Data → Text/CSV` query pointed at its CSV, not editing an existing one. See `Get-BHEAuditLog.ps1`'s CSV (`Data\audit-log.csv`) for the most recently added example of this pattern, including its `DaysAgo`/`RecencyBucket` helper columns used for conditional formatting.

## Security

`.env` holds your API credentials and is git-ignored — never commit it. Commit `.env.example` (no real values) instead.

## Repo structure

```
BH-PowerPupBI/
├── Update-BHEData.ps1               # full-run orchestrator (use this for scheduling)
├── Launch-BHEPowerBI.ps1            # selective-run menu (delegates "all" to Update-BHEData.ps1)
├── Collectors.manifest.json         # collector list + descriptions (drives the menu)
├── Invoke-BHEExtract.ps1            # base data - must run before Flatten
├── Flatten-BHEData.ps1
├── Get-BHEFindings.ps1
├── Get-BHECertifications.ps1
├── Get-BHECertificationSelectors.ps1
├── Get-BHEFindingTrends.ps1
├── Get-BHEPosture.ps1
├── Get-BHEPanels.ps1
├── Get-BHECollectorHealth.ps1
├── Get-BHETokens.ps1
├── Get-BHEAuditLog.ps1
├── Get-BHEVersion.ps1
├── Test-BHE-API_(Using Env).ps1     # utility, not a collector
├── PowerPUPBi_BH-Dashboard.pbit     # dashboard template - Refresh after running collectors
├── .env.example
├── .gitignore
├── README.md
├── GETTING-STARTED.md
└── Data/                            # generated at runtime - git-ignored
```


