## Automated Provisioning Script

Most of the Windows Setup steps above are wrapped in `scripts/powershell/new-build-windows.ps1`. Run it from an elevated PowerShell on the `itm` local admin account once Windows install is complete and the device is online.

```powershell
powershell -ExecutionPolicy Bypass -File .\new-build-windows.ps1
```

Optional parameters:

- `-NinjaInstallerUrl <url>` — skip the interactive prompt by passing the URL up front.
- `-OdtUrl <url>` — skip the interactive prompt for the Office Deployment Tool.
- `-OfficeChannel <Current|MonthlyEnterprise|SemiAnnualEnterprise>` — default `Current` (safest for retail M365 Business SKUs). Only change this if the tenant is explicitly set up for Monthly/Semi-Annual Enterprise channels.
- `-OfficeProductId <id>` — default `O365BusinessRetail`. Per [Microsoft's product-ID table](https://learn.microsoft.com/troubleshoot/microsoft-365-apps/office-suite-issues/product-ids-supported-office-deployment-click-to-run), match it to the tenant SKU:
    - `O365BusinessRetail` → Microsoft 365 Business Standard or Business Premium
    - `O365BusinessEEANoTeamsRetail` → Microsoft 365 **Apps for business** (standalone, EEA incl. Ireland)
    - `O365ProPlusRetail` → Microsoft 365 Apps for Enterprise / E3 / E5
    - `O365ProPlusEEANoTeamsRetail` → Apps for Enterprise / E3 / E5 in the EEA
  A wrong Product ID can cause the install to hang or silently fail to activate.
- `-OfficeTimeoutMinutes <n>` — default 90. Office step kills itself and reports the log tail if it exceeds this.
- `-SkipWindowsUpdate` — useful on a second pass after reboot.
- `-SkipOffice` — skip the ODT install (e.g. re-running after a failure).
- `-WindowsUpdateTimeoutMinutes <n>` — default 120, raise for slow lines.

### Getting the URLs before you start
Grab both of these before you run the script (both are prompted interactively if not passed):

1. **NinjaRMM installer URL** — Ninja admin > Add a device > copy the installer link. These links expire; regenerate if you get a download error.
2. **Office Deployment Tool URL** — open https://www.microsoft.com/en-us/download/details.aspx?id=49117 , click Download, and copy the resulting `download.microsoft.com/...` link. Microsoft rotates this URL with every ODT release, which is why the script asks for it instead of hard-coding it.

### What it does
1. Sets power plan to never sleep / hibernate on AC.
2. Removes Microsoft consumer bloatware (Xbox, Bing*, Solitaire, Clipchamp, Teams consumer, Candy Crush, etc.).
3. Removes Dell / HP / Lenovo / Samsung preinstalled apps + McAfee / Norton.
4. Installs all available Windows Updates, including driver updates from Microsoft Update (via `PSWindowsUpdate`).
5. Prompts for the NinjaRMM installer URL, downloads, and silent-installs the agent.
6. Installs Microsoft 365 Apps for Business (Word, Excel, PowerPoint, Outlook classic, Teams, OneDrive) via the Office Deployment Tool.
7. Installs Google Chrome and Adobe Acrobat Reader via `winget`.
8. Writes a `TaskbarLayoutModification` XML and applies it via Explorer policy so Chrome, Outlook, Word, Excel, PowerPoint, Teams and Acrobat are pinned for new users.
9. Clears temp files from the installation.

### What still has to be done by hand
- Reboot and re-run the script with `-SkipOffice` to pick up any remaining Windows Updates.
- Run the OEM driver update tool (HP Support Assistant, Dell Command Update, Lenovo Vantage) while it still exists — the script removes it afterwards, so do this **before** the driver-update pass if you want to use it.
- Enrol the device in Ninja (verify it has checked in after the agent install).
- Sign the user into Office / Teams to activate the licence.
- Taskbar pins only apply to *new* user profiles on Windows 11 — the `itm` account will not see them; the end user will on first sign-in.

### Logs
Transcript is written to `C:\itm-build\new-build-<ddMMyyyy-HHmm>.txt`. The end-of-run summary prints per-step success / failure.
