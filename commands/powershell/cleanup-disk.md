# Windows Disk Cleanup Commands

Follow these steps in order. Run each command exactly as shown.

## 1) Turn off hibernation
Deletes `hiberfil.sys` (about 4-16 GB gain).

```powershell
powercfg.exe -h off
```

## 2) Stop update-related services
Preparation step before clearing update caches (no immediate space gain).

```cmd
net stop wuauserv /y
net stop bits /y
net stop dosvc /y
net stop cryptsvc /y
```

## 3) Clear `SoftwareDistribution\Download`
Removes old Windows Update download files (about 1-12 GB gain).

```cmd
rd /s /q C:\Windows\SoftwareDistribution\Download & md C:\Windows\SoftwareDistribution\Download
```

## 4) Clear Delivery Optimization cache
Removes peer-to-peer update cache files (about 1-8 GB gain).

```cmd
rd /s /q C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache & md "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
```

## 5) Delete old restore points and shadow copies
Can free about 3-15 GB.

```cmd
vssadmin delete shadows /all /quiet
```

## 6) Run DISM component cleanup
Cleans WinSxS (about 2-7 GB gain, usually 2-10 minutes).

```cmd
Dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart
```

## 7) Configure Disk Cleanup preset
Preparation for the next step (no immediate space gain).

```cmd
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Update Cleanup" /v StateFlags0001 /t REG_DWORD /d 2 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Temporary Files" /v StateFlags0001 /t REG_DWORD /d 2 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Windows Upgrade Log Files" /v StateFlags0001 /t REG_DWORD /d 2 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Previous Installations" /v StateFlags0001 /t REG_DWORD /d 2 /f
```

## 8) Run silent Disk Cleanup
Usually the biggest gain (Windows.old, update leftovers, temp files; about 8-30 GB).

```cmd
cleanmgr.exe /sagerun:1
```

## 9) Clear miscellaneous temp files and recycle bin
Can free about 1-5 GB.

```powershell
Get-ChildItem -Path "$env:SystemDrive\" -Include "Windows.old","$Recycle.Bin","*.tmp","~*" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
```

## 10) Restart previously stopped services
Final stability step (no direct space gain).

```cmd
net start wuauserv
net start bits
net start dosvc
net start cryptsvc
```
