## Automated Provisioning Script

Most of the Windows Setup steps above are wrapped in `scripts/powershell/new-build-windows.ps1`. Copy the whole `new-build-windows/` folder to `C:\temp\new-build-windows\` (the script resolves `itm-wallpaper.png` and `itm-profile.png` from its own folder via `$PSScriptRoot`), then run it from an elevated PowerShell on the `itm` local admin account once Windows install is complete and the device is online.

```powershell
cd C:\temp\new-build-windows
powershell -ExecutionPolicy Bypass -File .\new-build-windows.ps1
```

Expected folder contents:

```
C:\temp\new-build-windows\
  new-build-windows.ps1
  itm-wallpaper.png   # set as desktop background for itm
  itm-profile.png     # set as itm's account picture (resized to 32/40/48/96/192/240/448)
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
- `-WindowsUpdateTimeoutMinutes <n>` — default 120, raise for slow lines.
- `-Only <steps>` — run only the listed step numbers. e.g. `-Only 10` to just re-apply the profile picture, or `-Only 9,10` for wallpaper + picture. Every other step is recorded as SKIPPED.
- `-Skip <steps>` — skip the listed step numbers. e.g. `-Skip 4,6` to skip Windows Update and Office on a re-run. `-Only` takes precedence: anything listed in `-Only` always runs, even if also in `-Skip`.

> **Spaces in step lists**: when launching via `powershell -File`, the CLI splits unquoted args on whitespace. Use `-Only 9,10` (no spaces) or quote the list — otherwise only the first number is bound to `-Only` and the rest leak into the next positional parameter. The script logs the parsed lists on start-up so you can verify (look for `-Only parsed as: [...]`).

Step numbers:

| # | Step |
|---|------|
| 1 | Set power plan to never sleep on AC |
| 2 | Remove Microsoft consumer bloatware |
| 3 | Remove OEM bloatware (Dell/HP/Lenovo/Samsung) |
| 4 | Install Windows updates (including drivers) |
| 5 | Download and install NinjaRMM agent |
| 6 | Install Microsoft 365 Apps for Business via ODT |
| 7 | Install Chrome and Adobe Acrobat Reader via winget |
| 8 | Pin core apps to taskbar |
| 9 | Set desktop wallpaper from `itm-wallpaper.png` |
| 10 | Set itm user account picture from `itm-profile.png` |
| 11 | Clean temp files from installation |

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
9. Copies `itm-wallpaper.png` to `C:\Windows\Web\Wallpaper\itm\` and sets it as the desktop background for the current (itm) user via `HKCU\Control Panel\Desktop` + `SystemParametersInfo(SPI_SETDESKWALLPAPER)`.
10. Resizes `itm-profile.png` to the standard account-tile sizes (32/40/48/96/192/240/448), writes them to `C:\Users\Public\AccountPictures\<itm-SID>\`, points `HKLM\...\AccountPicture\Users\<SID>` at them, and clears `C:\Users\itm\AppData\Roaming\Microsoft\Windows\AccountPictures\*.accountpicture-ms` so the cached tile is invalidated. Note: per Microsoft Learn, `UserInformation.SetAccountPictureAsync` is deprecated and `Windows.System.User` has no setter, so there is no first-party API — the registry path is the supported route. **Sign out and back in as itm for the new tile to render** on Start / sign-in screen.
11. Clears temp files from the installation.

### What still has to be done by hand
- Reboot and re-run the script with `-Skip 6` to pick up any remaining Windows Updates without re-installing Office.
- Run the OEM driver update tool (HP Support Assistant, Dell Command Update, Lenovo Vantage) while it still exists — the script removes it afterwards, so do this **before** the driver-update pass if you want to use it.
- Enrol the device in Ninja (verify it has checked in after the agent install).
- Sign the user into Office / Teams to activate the licence.
- Taskbar pins only apply to *new* user profiles on Windows 11 — the `itm` account will not see them; the end user will on first sign-in.

### Logs
Transcript is written to `C:\itm-build\new-build-<ddMMyyyy-HHmm>.txt`. The end-of-run summary prints per-step success / failure.
