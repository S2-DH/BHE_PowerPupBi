# BHE Power BI Dashboard — Getting Started

**What this does:** pulls data from your BloodHound Enterprise tenant into CSVs, then loads a ready-made Power BI dashboard on top of them.

## Prerequisites
- Power BI Desktop installed
- PowerShell (Windows, built-in)
- A BHE API token (Tenant → your user → API Tokens)

## Steps

| # | Do this | What it does |
|---|---|---|
| 1 | Copy the whole toolkit folder to your machine | Gets you all scripts, the manifest, and the dashboard template |
| 2 | Copy `.env.example` → `.env`, open it, fill in your tenant URL and API token | This is how the scripts authenticate to BHE. Never share this file. |
| 3 | Open PowerShell **in the folder** and run:<br>`.\Update-BHEData.ps1` | Pulls everything - findings, posture, panels, collector health, tenant info - into `Data\` |
| 4 | Also run, once:<br>`.\Get-BHECertifications.ps1`<br>`.\Get-BHECertificationSelectors.ps1` | Certifications data isn't in step 3 yet (known gap) - these add it to `Data\` |
| 5 | Open the `.pbit` file in Power BI Desktop | Loads the pre-built dashboard, empty - pages, visuals, and measures are already configured |
| 6 | Click **Refresh** (Home ribbon) | Pulls the CSVs from step 3-4 into the report |

**Done.** No table setup, no rebuilding visuals, no measures to write.

## Only want some pages?
Run `.\Launch-BHEPowerBI.ps1` instead of step 3 - it's a menu where you pick individual collectors. Then in Power BI, right-click and **Delete** any report page you don't need (safe - the file is self-contained).

## Keeping data fresh automatically
```powershell
.\Launch-BHEPowerBI.ps1 -RegisterTask
```
Sets up a Windows Scheduled Task to re-run the pull daily/hourly. You still need to open Power BI and click Refresh to see the latest (or use Power BI Service's own scheduled refresh if you publish it there).

## Passing this on to someone else
If you're the one handing this toolkit off (not the new person - that's everything above), don't just zip your working folder - it has your real API token and pulled data in it. Instead:
```powershell
.\New-DistributionCopy.ps1 -Destination "C:\Path\To\New\Folder"
```
This copies everything needed into a clean folder, stripped of `.env`, `Data\`, logs, and backup files, and checks the copy is actually clean before you send it. It'll remind you to Save As a `.pbit` in Power BI Desktop first (that one step has to be done manually) - do that, then zip the new folder and hand it over. The person receiving it starts at step 1 above.

## Files at a glance

| File | Purpose |
|---|---|
| `.env` | Your credentials (you create this - never commit or share it) |
| `Update-BHEData.ps1` | Runs every collector, in the right order, with logging |
| `Get-BHECertifications.ps1` / `...Selectors.ps1` | Certification data (run manually - see step 4) |
| `Launch-BHEPowerBI.ps1` | Menu for running only specific collectors |
| `New-DistributionCopy.ps1` | Makes a clean, shareable copy of this whole toolkit |
| `Collectors.manifest.json` | List of collectors + what each one does |
| `Data\` | Where the CSVs land - this is what Power BI reads |
| `*.pbit` | The empty dashboard template - what a new person opens |

Full details: see `README.md` in this folder.
