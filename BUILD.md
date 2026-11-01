# Build Guide

Two apps, three exes: the two release builds, plus a simulator that cycles through 46 fake CPUs.

---

## Prerequisites

```powershell
Install-Module ps2exe -Scope CurrentUser    # one time
```

Inno Setup 6.x from https://jrsoftware.org/isinfo.php for the installers.

---

## 1. CS2 Affinity Manager — release build

```powershell
Invoke-ps2exe -InputFile CS2-AffinityManager.ps1 `
              -OutputFile CS2-AffinityManager.exe `
              -RequireAdmin -STA -noConsole `
              -iconFile icon.ico `
              -title "CS2 Affinity Manager" `
              -version "1.9.4"
```

Then:

```powershell
iscc installer-cs2.iss
```

`-STA` is not optional. Without it every `FindName` returns null and the UI dies with a wall of null-reference errors — the script catches this at startup and tells you, but it's easier to just not do it.

---

## 2. CS2 Affinity Manager — **simulation build** (no installer)

Use the separate `CS2-AffinityManager-SIM.ps1` file. It is the same script with
`-simulate` defaulted on, so the compiled exe needs no arguments — just
double-click it. `-RequireAdmin` is dropped because the simulator never touches
a process.

```powershell
Invoke-ps2exe -InputFile CS2-AffinityManager-SIM.ps1 `
              -OutputFile CS2-AffinityManager-SIM.exe `
              -STA -noConsole `
              -iconFile icon.ico `
              -title "CS2 Affinity Manager (SIM)"
```

The title bar reads **(SIM)** when it's the simulator. See `HOW-TO-TEST.md` for
what to actually look at once it's running.

(The normal `CS2-AffinityManager.ps1` also accepts `-simulate` if you'd rather
pass it on a shortcut, but the SIM file exists so you don't have to.)

### What the simulation build does differently

| | Release | Simulation |
|---|---|---|
| Reads real CPU | yes | no — uses the preset table |
| Reads/writes `config.json` | yes | **never** |
| Sets process affinity | yes | **never** |
| Touches Task Scheduler | yes | **never** |
| Writes the log file | yes | no (screen only) |
| Single-instance lock | yes | no — runs alongside the real app |
| CPU picker | — | dropdown + `Next →` button |

Every guard is a `$script:SimMode` check at the point of the actual OS call, not a UI-level nicety. It cannot accidentally pin anything.

### How to use it

Launch it → **Configure...** → the amber **SIMULATED CPU** bar at the top. Pick a CPU or hammer `Next →` to walk the whole list. Each switch rebuilds the window from scratch and resets to that CPU's genuine first-run defaults, so you're seeing what a real user on that chip would see.

Back on the main window, the log prints a report per CPU:

```
--- Simulated: Intel Core i9-13900K (8P+16E) ---
  Topology       : 24c / 32t   SMT=2   Hybrid=True   MultiCCD=False
  Hybrid layout  : 8 P-cores (16 threads) + 16 E-cores
  Supported      : True
  Profiles       : Balanced, IntelHybrid, HybridOnePerCore
  Recommended    : IntelHybrid
  Active profile : Intel Hybrid
  CS2 threads    : 1-15   [15 threads]
  BG threads     : 16-31  [16 threads]
  CS2 mask       : 0xFFFE
  BG mask        : 0xFFFF0000
```

### The 46 presets

Chosen to break things, not to flatter the tool. Every entry declares its own
layout — P-cores, E-cores, CCD count — rather than letting the tool infer it,
which is what lets the simulator reproduce the awkward chips faithfully.

- **1c/1t Hyper-V vCPU** — degenerate case. Only Balanced should be offered.
- **2c/4t Pentium G4560, Athlon 3000G** — the low-end case. Balanced only; isolation would be actively harmful.
- **4c/4t i3-8100, i5-7500** — no SMT. Verifies one-per-core doesn't assume HT.
- **4c/8t Ryzen 3 3100, i3-12100F, i7-7700K** — smallest CPUs where OnePerCore makes sense.
- **6c/6t i5-9400F** vs **6c/12t 3600 / 5600X / 7600X / 9600X / 12400F** — same core count, different profile sets. This is 27.5% of the Steam survey.
- **8c/8t i7-9700K** vs **8c/16t 5700X3D / 5800X3D / 7800X3D / 9800X3D / 9900K / 10700K** — your chip and its no-SMT twin. 8-core is now the single most common class at 27.9%.
- **10c/20t i9-10900K** — single-die Intel above 8 cores. Should *not* offer Single Die.
- **12c/24t 3900X, 5900X, 7900X3D** — dual CCD, **6+6**. Single Die must stop at thread 11. Getting this wrong was a real bug: an assumed 8-core CCD ran the list to thread 15, four threads of which sit on CCD1.
- **16c/32t 5950X, 7950X3D, 9950X3D** — dual CCD, **8+8**. Single Die runs to thread 15 here, and that's correct.
- **10c/16t 12600K, 13400F** · **14c/20t 13600K, 14600K** · **12c/20t 12700K** · **16c/24t 12900K, 13700K** · **20c/28t 14700K** · **24c/32t 13900K, 14900KS** — every Alder/Raptor hybrid shape.
- **14c/14t Ultra 5 245K, 20c/20t Ultra 7 265K, 24c/24t Ultra 9 285K** — hybrid **without** HT. `threads == cores`, so no heuristic can recover the P/E split; these come from the CPU table. Previously all three were misread as uniform many-core CPUs and got no Intel Hybrid profile at all.
- **32c/64t Threadripper 3970X** — exactly at the 64-thread affinity ceiling.
- **64c/128t Threadripper 3990X** — past it. Threads 64+ render disabled in the matrix, the summary warns, and the mask drops them instead of wrapping to bit 0 like the old build did.

Each report line now also prints where the layout came from — `CPU table`,
`Windows topology API`, or `heuristic`. If a CPU is ever wrong, that tells you
whether it needs a table entry or whether the logic itself is at fault.


---

## 3. Debloatimizer

```powershell
Invoke-ps2exe -inputFile Debloatimizer.ps1 `
              -outputFile Debloatimizer.exe `
              -noConsole -STA -requireAdmin `
              -title "Debloatimizer" `
              -iconFile optimization.ico `
              -version "2.0.7"
```

```powershell
iscc installer-debloatimizer.iss
```

Start Menu shortcut only. There's no `[Tasks]` desktop icon entry and no `{autodesktop}` line — the comment at the top of the .iss says not to add one.

---

## Where things live at runtime

```
%LOCALAPPDATA%\CS2-AffinityManager\
    config.json
    affinity-YYYY-MM-DD.log

%LOCALAPPDATA%\Debloatimizer\
    config.json
    backups\
        journal_YYYYMMDD_HHMMSS.json    <- powers "Revert Last Run"
        reg_YYYYMMDD_HHMMSS\*.reg       <- raw hive exports
```

The Debloatimizer uninstaller deliberately leaves `backups\` alone. Removing the tool shouldn't destroy your ability to undo what it did.
