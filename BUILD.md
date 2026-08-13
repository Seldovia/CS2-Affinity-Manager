# Build Guide

## Prerequisites

```powershell
Install-Module ps2exe -Scope CurrentUser    # one time
```

Inno Setup 6.x from https://jrsoftware.org/isinfo.php to build the installer.

---

## Building the exe

```powershell
Invoke-ps2exe -InputFile CS2-AffinityManager.ps1 `
              -OutputFile CS2-AffinityManager.exe `
              -RequireAdmin -STA -noConsole `
              -iconFile icon.ico `
              -title "CS2 Affinity Manager" `
              -version "1.9.2"
```

`-STA` is not optional. Without it every `FindName` returns null and the UI dies with a wall of null-reference errors — the script catches this at startup and tells you, but it's easier to just not do it.

Then:

```powershell
iscc installer.iss
```

Output lands in `Output\CS2-AffinityManager-Setup.exe`.

---

## Where things live at runtime

```
%LOCALAPPDATA%\CS2-AffinityManager\
    config.json
    affinity-YYYY-MM-DD.log
```
