param(
    [switch]$background,
    [switch]$quick,
    [switch]$configureNow,
    [switch]$installtask,
    [switch]$simulate,
    [int]$awaitPid = 0
)

# ============================================================
#  CS2 Affinity Manager  --  v1.9.2
#  WPF / PowerShell.  Compile with ps2exe:
#
#    Release build (installer ships this one):
#      Invoke-ps2exe -InputFile CS2-AffinityManager.ps1 `
#        -OutputFile CS2-AffinityManager.exe -RequireAdmin -STA -noConsole `
#        -iconFile icon.ico -title "CS2 Affinity Manager"
#
#    Simulation / test build (NO installer -- standalone exe):
#      Invoke-ps2exe -InputFile CS2-AffinityManager.ps1 `
#        -OutputFile CS2-AffinityManager-SIM.exe -STA -noConsole `
#        -iconFile icon.ico -title "CS2 Affinity Manager (SIM)"
#    ...then launch it with:  CS2-AffinityManager-SIM.exe -simulate
#    (or see BUILD-TEST-EXE.md for a build that hardcodes -simulate on)
# ============================================================

# ============================================================
# STA GUARD (WPF requires a Single-Threaded Apartment)
# ============================================================
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $staMsg = "CS2 Affinity Manager was compiled without STA (Single-Threaded Apartment) mode, which WPF requires.`n`n" +
              "This is why the UI throws null-reference errors on startup.`n`n" +
              "Recompile using:`n" +
              "Invoke-ps2exe -InputFile CS2-AffinityManager.ps1 -OutputFile CS2-AffinityManager.exe -RequireAdmin -STA"
    try { [System.Windows.Forms.MessageBox]::Show($staMsg, "CS2 Affinity Manager - Startup Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null } catch {}
    exit 1
}

# ============================================================
# GAME / PATHS
# ============================================================
$gameProcess = "cs2"
$configDir   = Join-Path $env:LOCALAPPDATA "CS2-AffinityManager"
$configPath  = Join-Path $configDir "config.json"
$logDir      = $configDir
$logPath     = Join-Path $logDir "affinity-$(Get-Date -Format 'yyyy-MM-dd').log"

New-Item -ItemType Directory -Path $configDir -Force -ErrorAction SilentlyContinue | Out-Null

# In simulation mode nothing may touch a real process. Belt and braces:
# every write path checks this flag before calling into the OS.
$script:SimMode = [bool]$simulate

# ============================================================
# COLOR MATH
# ------------------------------------------------------------
# The old build hardcoded a rainbow palette whose first entry (#FF5C5C, red)
# landed on a #A8396E magenta window background -- red on red, effectively
# invisible. Rather than hand-pick colors per theme, every foreground color
# is run through Get-ReadableColor against the surface it will actually sit
# on, which lightens/darkens it until it clears a WCAG contrast ratio.
# Add a theme with any background you like; text stays legible for free.
# ============================================================

function ConvertFrom-Hex([string]$hex) {
    $h = $hex.TrimStart('#')
    if ($h.Length -eq 8) { $h = $h.Substring(2) }   # strip AARRGGBB alpha
    if ($h.Length -eq 3) { $h = "$($h[0])$($h[0])$($h[1])$($h[1])$($h[2])$($h[2])" }
    return @{
        R = [Convert]::ToInt32($h.Substring(0, 2), 16)
        G = [Convert]::ToInt32($h.Substring(2, 2), 16)
        B = [Convert]::ToInt32($h.Substring(4, 2), 16)
    }
}

function ConvertTo-Hex([int]$r, [int]$g, [int]$b) {
    $r = [math]::Max(0, [math]::Min(255, $r))
    $g = [math]::Max(0, [math]::Min(255, $g))
    $b = [math]::Max(0, [math]::Min(255, $b))
    return ("#{0:X2}{1:X2}{2:X2}" -f $r, $g, $b)
}

function Get-RelativeLuminance([string]$hex) {
    $c = ConvertFrom-Hex $hex
    $vals = @()
    foreach ($ch in @($c.R, $c.G, $c.B)) {
        $s = $ch / 255.0
        $vals += if ($s -le 0.03928) { $s / 12.92 } else { [math]::Pow((($s + 0.055) / 1.055), 2.4) }
    }
    return (0.2126 * $vals[0]) + (0.7152 * $vals[1]) + (0.0722 * $vals[2])
}

function Get-ContrastRatio([string]$a, [string]$b) {
    $la = Get-RelativeLuminance $a
    $lb = Get-RelativeLuminance $b
    $hi = [math]::Max($la, $lb)
    $lo = [math]::Min($la, $lb)
    return (($hi + 0.05) / ($lo + 0.05))
}

function ConvertTo-Hsl([string]$hex) {
    $c = ConvertFrom-Hex $hex
    $r = $c.R / 255.0; $g = $c.G / 255.0; $b = $c.B / 255.0
    $max = [math]::Max($r, [math]::Max($g, $b))
    $min = [math]::Min($r, [math]::Min($g, $b))
    $l = ($max + $min) / 2.0
    $d = $max - $min
    if ($d -eq 0) { return @{ H = 0.0; S = 0.0; L = $l } }
    $s = if ($l -gt 0.5) { $d / (2.0 - $max - $min) } else { $d / ($max + $min) }
    $h = switch ($max) {
        $r       { (($g - $b) / $d) % 6 }
        $g       { (($b - $r) / $d) + 2 }
        default  { (($r - $g) / $d) + 4 }
    }
    $h = $h * 60.0
    if ($h -lt 0) { $h += 360.0 }
    return @{ H = $h; S = $s; L = $l }
}

function ConvertFrom-Hsl([double]$h, [double]$s, [double]$l) {
    $s = [math]::Max(0.0, [math]::Min(1.0, $s))
    $l = [math]::Max(0.0, [math]::Min(1.0, $l))
    if ($s -eq 0) {
        $v = [int][math]::Round($l * 255)
        return ConvertTo-Hex $v $v $v
    }
    $q = if ($l -lt 0.5) { $l * (1 + $s) } else { $l + $s - ($l * $s) }
    $p = (2 * $l) - $q
    $hk = ($h % 360) / 360.0
    $conv = {
        param($t)
        if ($t -lt 0) { $t += 1 }
        if ($t -gt 1) { $t -= 1 }
        if ($t -lt (1.0 / 6.0)) { return $p + (($q - $p) * 6 * $t) }
        if ($t -lt (1.0 / 2.0)) { return $q }
        if ($t -lt (2.0 / 3.0)) { return $p + (($q - $p) * ((2.0 / 3.0) - $t) * 6) }
        return $p
    }
    $r = & $conv ($hk + (1.0 / 3.0))
    $g = & $conv $hk
    $b = & $conv ($hk - (1.0 / 3.0))
    return ConvertTo-Hex ([int][math]::Round($r * 255)) ([int][math]::Round($g * 255)) ([int][math]::Round($b * 255))
}

# Walks a foreground color's lightness away from the background until it clears
# $MinRatio, preserving hue/saturation so themed colors still read as themselves.
function Get-ReadableColor {
    param([string]$Foreground, [string]$Background, [double]$MinRatio = 4.5)
    if ((Get-ContrastRatio $Foreground $Background) -ge $MinRatio) { return $Foreground }

    $hsl    = ConvertTo-Hsl $Foreground
    $bgLum  = Get-RelativeLuminance $Background
    # Dark surface -> push text lighter. Light surface -> push it darker.
    $dir    = if ($bgLum -lt 0.5) { 1 } else { -1 }
    $best   = $Foreground
    $bestCr = Get-ContrastRatio $Foreground $Background

    for ($i = 1; $i -le 25; $i++) {
        $newL = $hsl.L + ($dir * 0.04 * $i)
        if ($newL -le 0.02 -or $newL -ge 0.98) { break }
        $cand = ConvertFrom-Hsl $hsl.H $hsl.S $newL
        $cr   = Get-ContrastRatio $cand $Background
        if ($cr -gt $bestCr) { $best = $cand; $bestCr = $cr }
        if ($cr -ge $MinRatio) { return $cand }
    }
    # Nothing in-hue cleared the bar (very saturated color on a mid-tone bg).
    # Fall back to plain white/black, which always will.
    if ($bestCr -lt $MinRatio) {
        return $(if ($bgLum -lt 0.5) { "#FFFFFF" } else { "#101010" })
    }
    return $best
}

function Get-Shade([string]$hex, [double]$delta) {
    $hsl = ConvertTo-Hsl $hex
    return ConvertFrom-Hsl $hsl.H $hsl.S ([math]::Max(0.0, [math]::Min(1.0, $hsl.L + $delta)))
}

# ============================================================
# THEME CATALOG
# ------------------------------------------------------------
# Only the six base colors need defining per theme. Everything else --
# hover states, semantic good/warn/bad, the rainbow title, marker colors --
# is derived and contrast-corrected against the surface it lands on.
# ============================================================
$script:ThemeCatalog = [ordered]@{
    "Toothpaste" = @{ Chrome = "#A8396E"; Panel = "#1E1E1E"; Border = "#2E2E2E"; Text = "#EAEAEA"; Muted = "#8A8A8A"; Accent = "#40CEC9"; Blurb = "The original -- wine chrome, mint accent" }
    "Midnight"   = @{ Chrome = "#12161C"; Panel = "#1A1F27"; Border = "#2B3340"; Text = "#E6EDF3"; Muted = "#8B98A8"; Accent = "#4AB8FF"; Blurb = "Near-black, cool blue accent" }
    "Graphite"   = @{ Chrome = "#1B1B1B"; Panel = "#242424"; Border = "#383838"; Text = "#ECECEC"; Muted = "#909090"; Accent = "#FF9F43"; Blurb = "Neutral grey, amber accent" }
    "Nord"       = @{ Chrome = "#2E3440"; Panel = "#3B4252"; Border = "#4C566A"; Text = "#ECEFF4"; Muted = "#9AA5B4"; Accent = "#88C0D0"; Blurb = "Muted arctic blue-grey" }
    "Matrix"     = @{ Chrome = "#080D08"; Panel = "#101810"; Border = "#1E2E1E"; Text = "#D8F0D8"; Muted = "#6E8A6E"; Accent = "#4CFF8F"; Blurb = "Black terminal, phosphor green" }
    "Synthwave"  = @{ Chrome = "#241539"; Panel = "#32204D"; Border = "#48326B"; Text = "#F2E9FF"; Muted = "#A18CC0"; Accent = "#FF6BD6"; Blurb = "Deep purple, hot pink accent" }
    "Ember"      = @{ Chrome = "#1A100E"; Panel = "#261A17"; Border = "#3A2823"; Text = "#F5E8E3"; Muted = "#A08880"; Accent = "#FF7043"; Blurb = "Warm charcoal, burnt orange" }
    "Dracula"    = @{ Chrome = "#282A36"; Panel = "#343746"; Border = "#474B5E"; Text = "#F8F8F2"; Muted = "#9AA0B5"; Accent = "#BD93F9"; Blurb = "Classic dark violet palette" }
    "Paper"      = @{ Chrome = "#E4E8EE"; Panel = "#FFFFFF"; Border = "#C9D1DB"; Text = "#1A1F27"; Muted = "#5C6773"; Accent = "#0E7C86"; Blurb = "Light mode -- teal on white" }
}

$script:SemanticBase = @{ Good = "#3FBF6A"; Warn = "#D9A441"; Bad = "#E5484D"; Info = "#3B9EFF" }
$script:RainbowBase  = @("#FF5C5C", "#FF9F4A", "#FFE24A", "#8CFF6B", "#4AFFD6", "#4AB8FF", "#B36BFF", "#FF6BD6")

# Expands a theme's six base colors into the full brush table the UI needs.
# Renamed in v1.8: the default theme used to be called "Cyberpunk",
# which described nothing about it. Existing config.json files still say so,
# so map the old name forward rather than silently resetting the user's theme.
$script:ThemeAliases = @{ "Cyberpunk" = "Toothpaste" }
function Resolve-ThemeName([string]$name) {
    if ($script:ThemeAliases.ContainsKey($name)) { return $script:ThemeAliases[$name] }
    return $name
}

function Resolve-Theme([string]$name) {
    $name = Resolve-ThemeName $name
    if (-not $script:ThemeCatalog.Contains($name)) { $name = "Toothpaste" }
    $b       = $script:ThemeCatalog[$name]
    $isLight = (Get-RelativeLuminance $b.Panel) -gt 0.5

    $t = @{
        Name       = $name
        Chrome     = $b.Chrome
        Panel      = $b.Panel
        PanelAlt   = $(if ($isLight) { Get-Shade $b.Panel -0.04 } else { Get-Shade $b.Panel -0.03 })
        PanelHi    = $(if ($isLight) { Get-Shade $b.Panel -0.07 } else { Get-Shade $b.Panel  0.05 })
        Border     = $b.Border
        Text       = $b.Text
        Muted      = $b.Muted
        Accent     = $b.Accent
        AccentHov  = Get-Shade $b.Accent $(if ($isLight) { -0.10 } else { 0.10 })
        OnAccent   = $(if ((Get-RelativeLuminance $b.Accent) -gt 0.45) { "#101010" } else { "#FFFFFF" })
        LogBg      = $(if ($isLight) { "#F4F6F9" } else { Get-Shade $b.Panel -0.06 })
        IsLight    = $isLight
    }
    $t.ButtonBg    = $(if ($isLight) { Get-Shade $b.Panel -0.08 } else { Get-Shade $b.Panel 0.06 })
    $t.ButtonHov   = $(if ($isLight) { Get-Shade $b.Panel -0.14 } else { Get-Shade $b.Panel 0.12 })
    $t.LogText     = Get-ReadableColor $b.Text $t.LogBg 7.0

    # Semantic colors, resolved separately for each surface they can appear on.
    foreach ($k in @("Good", "Warn", "Bad", "Info")) {
        $t["$($k)OnPanel"]  = Get-ReadableColor $script:SemanticBase[$k] $t.Panel  4.5
        $t["$($k)OnChrome"] = Get-ReadableColor $script:SemanticBase[$k] $t.Chrome 4.5
        $t["$($k)OnLog"]    = Get-ReadableColor $script:SemanticBase[$k] $t.LogBg  4.5
    }
    # Accent text on the chrome surface -- this is the pairing that was unreadable
    # in v1 (cyan #40CEC9 sitting on the default white control background).
    $t.AccentOnPanel  = Get-ReadableColor $b.Accent $t.Panel  4.5
    $t.AccentOnChrome = Get-ReadableColor $b.Accent $t.Chrome 4.5
    $t.MutedOnChrome  = Get-ReadableColor $b.Muted  $t.Chrome 3.5
    $t.TextOnChrome   = Get-ReadableColor $b.Text   $t.Chrome 4.5

    # CS2 / background thread markers.
    $t.Cs2OnPanel = $t.GoodOnPanel
    $t.BgOnPanel  = $t.BadOnPanel

    # Rainbow title, per surface.
    $t.RainbowOnChrome = @($script:RainbowBase | ForEach-Object { Get-ReadableColor $_ $t.Chrome 4.5 })
    $t.RainbowOnPanel  = @($script:RainbowBase | ForEach-Object { Get-ReadableColor $_ $t.Panel  4.5 })
    $t.RainbowOnLog    = @($script:RainbowBase | ForEach-Object { Get-ReadableColor $_ $t.LogBg  4.5 })
    return $t
}

# ============================================================
# COMPREHENSIVE SAFE EXCLUSIONS (never have their affinity changed)
# ============================================================
$safeExceptions = @(
    # === THIS APPLICATION ===
    "CS2-AffinityManager",

    # === CRITICAL SYSTEM PROCESSES (Microsoft official list) ===
    "System", "Idle", "Registry", "Memory Compression",
    "smss", "csrss", "wininit", "winlogon", "services", "lsass", "lsaiso",
    "svchost", "dwm", "explorer", "fontdrvhost", "audiodg", "taskhostw",
    "sihost", "conhost", "ctfmon", "dllhost", "spoolsv", "WmiPrvSE",
    "wbengine", "msdtc", "WUDFHost", "LsaIso", "SecurityHealthHost",
    
    # === SEARCH / INDEXING ===
    "SearchIndexer", "SearchApp", "SearchHost", "wsearch",
    
    # === SHELL EXPERIENCE ===
    "ShellExperienceHost", "StartMenuExperienceHost", "RuntimeBroker",
    "ApplicationFrameHost", "TextInputHost", "LockApp", "LogonUI",
    
    # === SECURITY / ANTIMALWARE (Windows Defender + third-party) ===
    "MsMpEng", "MpDefenderCoreService", "NisSrv", "SecurityHealthSystray",
    "SecurityHealthService", "SgrmBroker", "smartscreen", "WinDefend",
    "MpCmdRun", "MpSigStub",
    
    # === WINDOWS UPDATE ===
    "wuauclt", "UsoClient", "WaaSMedicAgent", "TiWorker", "TrustedInstaller",
    "MoUsoCoreWorker", "WU", "WSUSService", "updater",
    
    # === FONTS / RENDERING ===
    "PresentationFontCache", "clr_optimization_v4", "ngen",
    
    # === NVIDIA GPU / DRIVERS ===
    "nvcontainer", "nvsphelper64", "nvvsvc", "nvxdsync", "nvbackend",
    "nvidia-share", "nvidia shadowplay helper", "nvidia web helper",
    "nvtelemetry", "nvtray", "nvoverlay", "nvstreamer", "nvidia-smi",
    "NvOAWrapperCache", "NvNodeLauncher", "NvBroadcast", "nvcplui", "nvsettings",
    "NvCplDaemon", "NvNetworkService", "GoogleUpdate", "nvcleaninstall",
    "NVIDIA Share", "NVIDIA Settings", "NVIDIA DLSS Updater",
    
    # === AMD GPU / DRIVERS ===
    "RadeonSoftware", "RadeonsoftwareSlimStreamer", "amddvr", "amdow", "AMDRSServ",
    "cnext", "AMDACEService", "AMD Radeon Settings Service", "amdafd",
    "amdacpusvc", "amdkmafd",
    
    # === INTEL GPU / DRIVERS ===
    "igfxEM", "igfxHK", "igfxTray", "IntelCpHDCPSvc", "igfxCUIService",
    "oemdrivers", "igfxext",
    
    # === AUDIO DRIVERS / SERVICES ===
    "RtkAudioService", "RtkAudUService64", "RAVBg64", "RAVCpl64", "RTKVHD64",
    "AudioDeviceBackgroundTaskHost", "AudioSrvGroupPolicy", "Audiosrv",
    "Nahimic", "NahimicService", "VBaudioMMEService", "Waves Audio Service",
    
    # === VOICE COMMUNICATION / VOIP ===
    "voicemeeter", "voicemeeterpro", "audiorelay", "vb-audio", "SteamVR",
    
    # === GRAPHICS / VIDEO ===
    "vgc", "vgk", "GraphicsDetective", "NVIDIA GeForce NOW", "AMD Adrenalin",
    
    # === ANTI-CHEAT / GAME PROTECTION ===
    "faceit", "faceitclient", "FACEITservice", "FACEITClient",
    "BEService", "EasyAntiCheat", "EasyAntiCheat_EOS", "EAC", "EACAC",
    "mhyprot2", "mhyprot3", "nprotect", "npggnt", "GameGuard", "GameGuardian",
    "xigncode", "xingameprotect", "WhiteListService", "Punkbuster",
    "HonorShield", "VAC", "SpecialK", "SpecialKService",
    
    # === MONITORING / DIAGNOSTICS ===
    "HWiNFO64", "HWiNFO32", "CPUID HWMonitor", "OpenHardwareMonitor",
    "MSIAfterburner", "RTSS", "EncoderServer", "ProcessMonitor",
    "Perfmon", "PerfWatson2", "WdiServiceHost", "WdiSystemHost",
    
    # === PERIPHERALS / INPUT DEVICES ===
    "LGHUB", "LogiOptions", "LogiOptionsMgr", "iCUE", "logi_gaming_mouse",
    "CorsairGamingAudioConfig", "CorsairService", "CUE",
    "SteelSeriesEngine3", "SteelSeriesGG", "GGOverlay", "SteelSeriesDiagnostics",
    "razer synapse", "RazerCentralService", "RzSDKService", "Razer Central",
    "HiddenZone", "Asus Aura",
    
    # === XBOX / GAMING ===
    "GameBar", "GameBarFTServer", "GameBarPresenceWriter", "GameInputService",
    "XboxPcApp", "XboxGameBarSpotify", "GamingServices", "GamingServicesNet",
    "GameInputService", "XboxLiveAuth",
    
    # === CPU UTILITIES ===
    "RyzenMasterMonitorService", "PrecisionXOC", "EVGA_Precision", "ZenTimings",
    "AMD Ryzen Master", "Intel Core Utilities", "CPUControl",
    
    # === VPN / NETWORKING ===
    "Nordvpn", "nordvpn-service", "ExpressVPN", "ProtonVPN", "Mullvad VPN",
    "ProtonVPNService", "openvpn", "wg", "tailscale", "SurfsharkService",
    "CyberGhostService", "IPVanish", "Windscribe",
    
    # === ANTIVIRUS / SECURITY SUITES (third-party) ===
    "MBAMService", "mbam", "avgnt", "avguard", "ekrn", "bdagent", "fmon",
    "FortiEDR", "F-Secure", "Kaspersky", "ESET", "Norton",
    "McAfee", "Symantec", "Avast", "AVG", "Bitdefender",
    "Sophos", "ClamAV", "Malwarebytes", "SUPERAntiSpyware",
    "Webroot", "ZoneAlarm", "Trend Micro",
    
    # === CLOUD SYNC / BACKUP ===
    "OneDrive", "Dropbox", "GoogleDriveFS", "iCloud", "NextCloud",
    "Synology", "BackBlaze", "CrashPlan", "Carbonite", "IDrive",
    
    # === STEAM / LAUNCHER ===
    "Steam", "SteamService", "SteamWebHelper", "steamwebhelper",
    "EpicOnlineServicesEOS", "Epic Games", "Ubisoft Connect", "Battle.net",
    "Origin", "EA App", "GOG Galaxy",
    
    # === DISK / STORAGE ===
    "StorageUsage", "defrag", "chkdsk", "SamSs", "partmgr",
    
    # === HARDWARE MONITORING ===
    "DellFanMonitor", "LenovoFanMonitor", "HPPowerAssistant",
    
    # === MISCELLANEOUS CRITICAL ===
    "svchost", "services", "dwm", "explorer", "csrss",
    "conhost", "audiodg", "svchost",
    
    $gameProcess
)

# ============================================================
# CPU TOPOLOGY
# ============================================================
# ============================================================
# CPU LAYOUT DATABASE
# ------------------------------------------------------------
# (cores, threads) alone is NOT enough to describe a modern CPU.
#
#   * A hybrid Intel part with no SMT reports threads == cores, which is
#     indistinguishable from a plain many-core CPU. Every Arrow Lake desktop
#     chip is in this category -- the Core Ultra 9 285K is 8 P-cores + 16
#     E-cores and reports 24c/24t, exactly like a hypothetical 24-core
#     monolith. Inferring P-cores as (threads - cores) yields zero.
#   * AMD's 12-core Ryzen 9 parts are two CCDs with two cores disabled on
#     each -- 6+6, not 8+4. Assuming a full 8-core CCD puts a third of the
#     "single die" thread list on the wrong chiplet, which is the exact
#     latency the profile exists to avoid.
#
# So layout comes from, in order: this table, then Windows' own topology
# API, then a heuristic. Patterns are matched case-insensitively against
# the CPU's brand string as reported by Win32_Processor.
#
#   PCores/ECores : hybrid split. ECores = 0 means not hybrid.
#   CcdCount      : chiplets. 1 means monolithic.
# ============================================================
$script:CpuDatabase = @(
    # ---- Intel Arrow Lake: hybrid WITHOUT SMT. Undetectable heuristically.
    @{ Pattern = 'Ultra\s*9\s*2[0-9]5K';        PCores = 8; ECores = 16; CcdCount = 1 }
    @{ Pattern = 'Ultra\s*7\s*2[0-9]5K';        PCores = 8; ECores = 12; CcdCount = 1 }
    @{ Pattern = 'Ultra\s*5\s*2[0-9]5K';        PCores = 6; ECores =  8; CcdCount = 1 }
    @{ Pattern = 'Ultra\s*9\s*285';             PCores = 8; ECores = 16; CcdCount = 1 }
    @{ Pattern = 'Ultra\s*7\s*265';             PCores = 8; ECores = 12; CcdCount = 1 }
    @{ Pattern = 'Ultra\s*5\s*245';             PCores = 6; ECores =  8; CcdCount = 1 }
    @{ Pattern = 'Ultra\s*5\s*235';             PCores = 6; ECores =  8; CcdCount = 1 }
    @{ Pattern = 'Ultra\s*5\s*225';             PCores = 6; ECores =  4; CcdCount = 1 }

    # ---- AMD 12-core Ryzen 9: 6+6 across two CCDs, not 8+4.
    @{ Pattern = 'Ryzen\s*9\s*3900';            PCores = 12; ECores = 0; CcdCount = 2 }
    @{ Pattern = 'Ryzen\s*9\s*5900';            PCores = 12; ECores = 0; CcdCount = 2 }
    @{ Pattern = 'Ryzen\s*9\s*7900';            PCores = 12; ECores = 0; CcdCount = 2 }
    @{ Pattern = 'Ryzen\s*9\s*9900';            PCores = 12; ECores = 0; CcdCount = 2 }
    # ---- AMD 16-core Ryzen 9: full 8-core CCDs.
    @{ Pattern = 'Ryzen\s*9\s*3950';            PCores = 16; ECores = 0; CcdCount = 2 }
    @{ Pattern = 'Ryzen\s*9\s*5950';            PCores = 16; ECores = 0; CcdCount = 2 }
    @{ Pattern = 'Ryzen\s*9\s*7950';            PCores = 16; ECores = 0; CcdCount = 2 }
    @{ Pattern = 'Ryzen\s*9\s*9950';            PCores = 16; ECores = 0; CcdCount = 2 }
)

function Get-CpuDbEntry([string]$name) {
    if (-not $name) { return $null }
    foreach ($e in $script:CpuDatabase) {
        if ($name -match $e.Pattern) { return $e }
    }
    return $null
}

# ------------------------------------------------------------
# Windows' own topology, for anything the table doesn't cover.
#
# GetLogicalProcessorInformationEx reports an EfficiencyClass per physical
# core (higher = faster, so P-cores outrank E-cores) and the thread mask of
# every L3 cache. On AMD each CCD carries its own L3, so counting distinct
# L3 masks counts chiplets. This is how the tool stays right on CPUs that
# did not exist when it was written, and on machines where SMT or some
# cores have been disabled in firmware.
#
# Entirely best-effort: any failure returns $null and the caller falls
# through to the heuristic. It is never allowed to throw.
# ------------------------------------------------------------
function Get-NativeCoreLayout {
    try {
        if (-not ("Native.CpuTopo" -as [type])) {
            Add-Type -Namespace Native -Name CpuTopo -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
private static extern bool GetLogicalProcessorInformationEx(int rel, IntPtr buf, ref int len);

public static string Query() {
    System.Text.StringBuilder sb = new System.Text.StringBuilder();
    Collect(0, sb);   // RelationProcessorCore
    Collect(2, sb);   // RelationCache
    return sb.ToString();
}

private static void Collect(int rel, System.Text.StringBuilder sb) {
    int len = 0;
    GetLogicalProcessorInformationEx(rel, IntPtr.Zero, ref len);
    if (len <= 0) return;
    IntPtr buf = Marshal.AllocHGlobal(len);
    try {
        if (!GetLogicalProcessorInformationEx(rel, buf, ref len)) return;
        int off = 0;
        while (off + 8 <= len) {
            IntPtr p = new IntPtr(buf.ToInt64() + off);
            int relationship = Marshal.ReadInt32(p, 0);
            int size = Marshal.ReadInt32(p, 4);
            if (size <= 0) break;
            if (relationship == 0) {
                byte eff = Marshal.ReadByte(p, 9);
                short gc = Marshal.ReadInt16(p, 30);
                if (gc >= 1) {
                    long mask = Marshal.ReadIntPtr(p, 32).ToInt64();
                    short grp = Marshal.ReadInt16(p, 32 + IntPtr.Size);
                    if (grp == 0) sb.Append("CORE|" + mask + "|" + eff + "\n");
                }
            } else if (relationship == 2) {
                byte level = Marshal.ReadByte(p, 8);
                short gc = Marshal.ReadInt16(p, 38);
                if (level == 3 && gc >= 1) {
                    long mask = Marshal.ReadIntPtr(p, 40).ToInt64();
                    short grp = Marshal.ReadInt16(p, 40 + IntPtr.Size);
                    if (grp == 0) sb.Append("L3|" + mask + "\n");
                }
            }
            off += size;
        }
    } finally { Marshal.FreeHGlobal(buf); }
}
'@ -UsingNamespace @('System.Runtime.InteropServices') -ErrorAction Stop
        }

        $raw = [Native.CpuTopo]::Query()
        if (-not $raw) { return $null }

        $coreEff = @()
        $l3Count = 0
        foreach ($line in ($raw -split "`n")) {
            $parts = $line.Trim() -split '\|'
            if ($parts[0] -eq "CORE" -and $parts.Count -ge 3) { $coreEff += [int]$parts[2] }
            elseif ($parts[0] -eq "L3") { $l3Count++ }
        }
        if ($coreEff.Count -lt 1) { return $null }

        # Highest efficiency class = performance cores. A single class across
        # the board means a uniform CPU, not a hybrid.
        $maxEff = ($coreEff | Measure-Object -Maximum).Maximum
        $minEff = ($coreEff | Measure-Object -Minimum).Minimum
        $pc = if ($maxEff -gt $minEff) { @($coreEff | Where-Object { $_ -eq $maxEff }).Count } else { $coreEff.Count }
        $ec = $coreEff.Count - $pc

        # Zen 2 splits L3 per 4-core CCX, so a 3900X reports four L3 masks for
        # two physical chiplets. Confining the game to 3 cores would be far
        # too aggressive, so treat any L3 group smaller than 4 cores as half a
        # CCD and merge pairs.
        $ccd = if ($l3Count -gt 1) { $l3Count } else { 1 }
        if ($ccd -gt 1 -and ($coreEff.Count / $ccd) -lt 4) { $ccd = [math]::Max(1, [int]($ccd / 2)) }

        return @{ PCores = $pc; ECores = $ec; CcdCount = $ccd; Cores = $coreEff.Count }
    } catch {
        return $null
    }
}

function Get-CpuTopology {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cores = $cpu.NumberOfCores
    if (-not $cores -or $cores -lt 1) { $cores = $cpu.NumberOfLogicalProcessors }
    $threads      = $cpu.NumberOfLogicalProcessors
    $manufacturer = ($cpu.Manufacturer).Trim()
    $name         = ($cpu.Name).Trim()

    # Curated table first -- it is the only source that is definitely right
    # for the CPUs it covers. Windows' topology API second, for everything
    # else. Heuristic last.
    $pc = 0; $ec = 0; $ccd = 0; $src = "heuristic"

    $db = Get-CpuDbEntry $name
    if ($db) {
        $pc = [int]$db.PCores; $ec = [int]$db.ECores; $ccd = [int]$db.CcdCount
        $src = "database"
        # A firmware-disabled core or SMT toggle makes the table disagree with
        # the live CPU. Trust the hardware and drop back to detection.
        if (($pc + $ec) -ne $cores) { $pc = 0; $ec = 0; $ccd = 0; $src = "heuristic" }
    }

    if ($src -eq "heuristic") {
        $nat = Get-NativeCoreLayout
        if ($nat -and $nat.Cores -eq $cores) {
            $pc = [int]$nat.PCores; $ec = [int]$nat.ECores; $ccd = [int]$nat.CcdCount
            $src = "windows"
        }
    }

    $topo = New-Topology -Name $name -Manufacturer $manufacturer -Cores $cores -Threads $threads `
                         -PCoreCount $pc -ECoreCount $ec -CcdCountOverride $ccd
    $topo | Add-Member -NotePropertyName LayoutSource -NotePropertyValue $src -Force
    return $topo
}

# Single place where a (name, vendor, cores, threads) tuple becomes the full
# topology object. Real detection and simulated CPUs both go through it, so a
# simulated Ryzen is described by exactly the same code path as a real one --
# which is the whole point of the simulator being trustworthy.
function New-Topology {
    param([string]$Name, [string]$Manufacturer, [int]$Cores, [int]$Threads,
          [int]$PCoreCount = 0, [int]$ECoreCount = 0, [int]$CcdCountOverride = 0,
          [int]$ForcePCores = 0)

    if ($Cores -lt 1)        { $Cores = 1 }
    if ($Threads -lt $Cores) { $Threads = $Cores }

    # SMT width. E-cores never have SMT, so any surplus of threads over cores
    # comes entirely from the P-cores on a hybrid, or from every core on a
    # uniform part. threads == cores therefore means no SMT anywhere -- which
    # is true of both an old i5-9400F and a brand new Core Ultra 9.
    $tpc = if ($Threads -gt $Cores) { 2 } else { 1 }

    $isIntel = $Manufacturer -match "Intel|GenuineIntel"
    $isAmd   = $Manufacturer -match "AMD|Advanced Micro|AuthenticAMD"

    # ---- hybrid layout ----
    if ($ForcePCores -gt 0 -and $PCoreCount -le 0) { $PCoreCount = $ForcePCores }

    if ($PCoreCount -gt 0 -and ($PCoreCount + $ECoreCount) -eq $Cores) {
        # Authoritative: supplied by the CPU table, by Windows, or by a
        # simulated CPU definition.
        $pCores = $PCoreCount
        $eCores = $ECoreCount
    } else {
        # Fallback. This can only ever spot an SMT-enabled hybrid; a hybrid
        # with SMT removed looks identical to a uniform many-core CPU from
        # (cores, threads) alone, which is precisely why the table exists.
        $guessHybrid = $isIntel -and ($Threads -lt ($Cores * 2)) -and ($Threads -gt $Cores)
        $pCores = if ($guessHybrid) { $Threads - $Cores } else { $Cores }
        $eCores = if ($guessHybrid) { $Cores - $pCores } else { 0 }
    }
    $isHybrid = ($eCores -gt 0)
    $pThreads = $pCores * $tpc

    # ---- chiplet layout ----
    # CCD size is derived, never assumed. AMD's 12-core Ryzen 9 parts are two
    # CCDs of six, not one of eight plus a remainder, so hardcoding 8 puts a
    # third of the Single Die thread list on the wrong die.
    if ($CcdCountOverride -gt 0) {
        $ccdCount = $CcdCountOverride
    } elseif ($isAmd -and $Cores -gt 8) {
        $ccdCount = [int][math]::Ceiling($Cores / 8)
    } else {
        $ccdCount = 1
    }
    if ($ccdCount -lt 1) { $ccdCount = 1 }
    $ccdSize = [int][math]::Floor($Cores / $ccdCount)
    if ($ccdSize -lt 1) { $ccdSize = $Cores; $ccdCount = 1 }

    return [pscustomobject]@{
        Name           = $Name
        Manufacturer   = $Manufacturer
        Cores          = $Cores
        Threads        = $Threads
        ThreadsPerCore = $tpc
        IsHybrid       = $isHybrid
        PCores         = $pCores
        ECores         = $eCores
        PThreads       = $pThreads
        IsAmd          = $isAmd
        CcdCount       = $ccdCount
        CcdSize        = $ccdSize
        IsMultiCcd     = ($ccdCount -gt 1)
        LayoutSource   = "supplied"
        Simulated      = $false
    }
}

# Which physical core does logical thread $i belong to, and what kind is it?
# Windows enumerates hybrid CPUs P-cores-first, both HT siblings adjacent,
# then E-cores one thread each.
function Get-ThreadCoreMap($topo) {
    $map = @{}
    if ($topo.IsHybrid) {
        $t = 0
        # ThreadsPerCore, not a literal 2. Arrow Lake is hybrid with no SMT at
        # all, so its P-cores get one thread each; assuming two would map half
        # the E-cores onto P-core indices and shift the whole grid.
        for ($c = 0; $c -lt $topo.PCores; $c++) {
            for ($s = 0; $s -lt $topo.ThreadsPerCore; $s++) {
                if ($t -lt $topo.Threads) { $map[$t] = @{ Core = [int]$c; Kind = "P"; Sibling = [int]$s; Ccd = 0 }; $t++ }
            }
        }
        for ($c = 0; $c -lt $topo.ECores; $c++) {
            if ($t -lt $topo.Threads) { $map[$t] = @{ Core = [int]($topo.PCores + $c); Kind = "E"; Sibling = 0; Ccd = 0 }; $t++ }
        }
    } else {
        for ($t = 0; $t -lt $topo.Threads; $t++) {
            # The [int] casts are load-bearing, not decoration.
            #
            # PowerShell's / returns an int when the division is exact and a
            # double when it isn't, so 0/2 and 2/2 are ints while 1/2 and 3/2
            # are doubles. [math]::Floor overloads on double AND decimal, so an
            # int argument binds to the decimal overload and a double argument
            # binds to the double one. The result: even threads produced
            # [decimal]0 and odd threads produced [double]0 for the same core.
            #
            # Hashtables compare keys with Object.Equals, and [decimal]0 does
            # not equal [double]0 -- so each core ended up as two separate
            # entries, the grid drew one card per thread instead of one per
            # core, and sorting a mix of decimal and double keys gave the
            # inconsistent T1,T0 / T4,T5 ordering.
            $core = [int][math]::Floor($t / $topo.ThreadsPerCore)
            $map[$t] = @{
                Core    = $core
                Kind    = "N"
                Sibling = [int]($t % $topo.ThreadsPerCore)
                Ccd     = $(if ($topo.IsMultiCcd) { [int][math]::Floor($core / $topo.CcdSize) } else { 0 })
            }
        }
    }
    return $map
}

# ============================================================
# SIMULATED CPU PRESETS  (test build only)
# ------------------------------------------------------------
# Deliberately spans the whole range: a 1-thread VM, no-SMT budget quads,
# the common 6c/12t midrange, single- and dual-CCD AMD, both Intel hybrid
# shapes, and a 128-thread Threadripper that sits past the 64-bit affinity
# mask ceiling. If the matrix and tier gating survive all of these, they
# survive anything a user will actually own.
# ============================================================
$script:SimulatedCpus = @(
    # Name, vendor, cores, threads, then the explicit layout. PCores/ECores
    # of 0 means uniform; CcdCount 1 means monolithic. Supplying the layout
    # here rather than inferring it is what lets the simulator reproduce
    # Arrow Lake and the 6+6 Ryzen 9 parts faithfully.
    @{ Name = "Hyper-V vCPU (1 core)";                   Vendor = "GenuineIntel"; Cores = 1;  Threads = 1;   PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Pentium G4560";                     Vendor = "GenuineIntel"; Cores = 2;  Threads = 4;   PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Athlon 3000G";                        Vendor = "AuthenticAMD"; Cores = 2;  Threads = 4;   PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i3-8100";                      Vendor = "GenuineIntel"; Cores = 4;  Threads = 4;   PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i5-7500";                      Vendor = "GenuineIntel"; Cores = 4;  Threads = 4;   PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i7-7700K";                     Vendor = "GenuineIntel"; Cores = 4;  Threads = 8;   PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i3-12100F";                    Vendor = "GenuineIntel"; Cores = 4;  Threads = 8;   PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Ryzen 3 3100";                        Vendor = "AuthenticAMD"; Cores = 4;  Threads = 8;   PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i5-9400F";                     Vendor = "GenuineIntel"; Cores = 6;  Threads = 6;   PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i7-8700K";                     Vendor = "GenuineIntel"; Cores = 6;  Threads = 12;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i5-10400F";                    Vendor = "GenuineIntel"; Cores = 6;  Threads = 12;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i5-12400F";                    Vendor = "GenuineIntel"; Cores = 6;  Threads = 12;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Ryzen 5 3600";                        Vendor = "AuthenticAMD"; Cores = 6;  Threads = 12;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Ryzen 5 5600X";                       Vendor = "AuthenticAMD"; Cores = 6;  Threads = 12;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Ryzen 5 7600X";                       Vendor = "AuthenticAMD"; Cores = 6;  Threads = 12;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Ryzen 5 9600X";                       Vendor = "AuthenticAMD"; Cores = 6;  Threads = 12;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i7-9700K";                     Vendor = "GenuineIntel"; Cores = 8;  Threads = 8;   PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i9-9900K";                     Vendor = "GenuineIntel"; Cores = 8;  Threads = 16;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i7-10700K";                    Vendor = "GenuineIntel"; Cores = 8;  Threads = 16;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Ryzen 7 3700X";                       Vendor = "AuthenticAMD"; Cores = 8;  Threads = 16;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Ryzen 7 5700X3D";                     Vendor = "AuthenticAMD"; Cores = 8;  Threads = 16;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Ryzen 7 5800X3D";                     Vendor = "AuthenticAMD"; Cores = 8;  Threads = 16;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Ryzen 7 7800X3D";                     Vendor = "AuthenticAMD"; Cores = 8;  Threads = 16;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "AMD Ryzen 7 9800X3D";                     Vendor = "AuthenticAMD"; Cores = 8;  Threads = 16;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i9-10900K";                    Vendor = "GenuineIntel"; Cores = 10; Threads = 20;  PCores = 0;  ECores = 0;  CcdCount = 1 }
    @{ Name = "Intel Core i5-12600K (6P+4E)";            Vendor = "GenuineIntel"; Cores = 10; Threads = 16;  PCores = 6;  ECores = 4;  CcdCount = 1 }
    @{ Name = "Intel Core i5-13400F (6P+4E)";            Vendor = "GenuineIntel"; Cores = 10; Threads = 16;  PCores = 6;  ECores = 4;  CcdCount = 1 }
    @{ Name = "Intel Core i5-13600K (6P+8E)";            Vendor = "GenuineIntel"; Cores = 14; Threads = 20;  PCores = 6;  ECores = 8;  CcdCount = 1 }
    @{ Name = "Intel Core i5-14600K (6P+8E)";            Vendor = "GenuineIntel"; Cores = 14; Threads = 20;  PCores = 6;  ECores = 8;  CcdCount = 1 }
    @{ Name = "Intel Core i7-12700K (8P+4E)";            Vendor = "GenuineIntel"; Cores = 12; Threads = 20;  PCores = 8;  ECores = 4;  CcdCount = 1 }
    @{ Name = "Intel Core i7-13700K (8P+8E)";            Vendor = "GenuineIntel"; Cores = 16; Threads = 24;  PCores = 8;  ECores = 8;  CcdCount = 1 }
    @{ Name = "Intel Core i7-14700K (8P+12E)";           Vendor = "GenuineIntel"; Cores = 20; Threads = 28;  PCores = 8;  ECores = 12; CcdCount = 1 }
    @{ Name = "Intel Core i9-12900K (8P+8E)";            Vendor = "GenuineIntel"; Cores = 16; Threads = 24;  PCores = 8;  ECores = 8;  CcdCount = 1 }
    @{ Name = "Intel Core i9-13900K (8P+16E)";           Vendor = "GenuineIntel"; Cores = 24; Threads = 32;  PCores = 8;  ECores = 16; CcdCount = 1 }
    @{ Name = "Intel Core i9-14900KS (8P+16E)";          Vendor = "GenuineIntel"; Cores = 24; Threads = 32;  PCores = 8;  ECores = 16; CcdCount = 1 }
    @{ Name = "Intel Core Ultra 5 245K (6P+8E, no HT)";  Vendor = "GenuineIntel"; Cores = 14; Threads = 14;  PCores = 6;  ECores = 8;  CcdCount = 1 }
    @{ Name = "Intel Core Ultra 7 265K (8P+12E, no HT)"; Vendor = "GenuineIntel"; Cores = 20; Threads = 20;  PCores = 8;  ECores = 12; CcdCount = 1 }
    @{ Name = "Intel Core Ultra 9 285K (8P+16E, no HT)"; Vendor = "GenuineIntel"; Cores = 24; Threads = 24;  PCores = 8;  ECores = 16; CcdCount = 1 }
    @{ Name = "AMD Ryzen 9 3900X (2 CCD, 6+6)";          Vendor = "AuthenticAMD"; Cores = 12; Threads = 24;  PCores = 0;  ECores = 0;  CcdCount = 2 }
    @{ Name = "AMD Ryzen 9 5900X (2 CCD, 6+6)";          Vendor = "AuthenticAMD"; Cores = 12; Threads = 24;  PCores = 0;  ECores = 0;  CcdCount = 2 }
    @{ Name = "AMD Ryzen 9 7900X3D (2 CCD, 6+6)";        Vendor = "AuthenticAMD"; Cores = 12; Threads = 24;  PCores = 0;  ECores = 0;  CcdCount = 2 }
    @{ Name = "AMD Ryzen 9 5950X (2 CCD, 8+8)";          Vendor = "AuthenticAMD"; Cores = 16; Threads = 32;  PCores = 0;  ECores = 0;  CcdCount = 2 }
    @{ Name = "AMD Ryzen 9 7950X3D (2 CCD, 8+8)";        Vendor = "AuthenticAMD"; Cores = 16; Threads = 32;  PCores = 0;  ECores = 0;  CcdCount = 2 }
    @{ Name = "AMD Ryzen 9 9950X3D (2 CCD, 8+8)";        Vendor = "AuthenticAMD"; Cores = 16; Threads = 32;  PCores = 0;  ECores = 0;  CcdCount = 2 }
    @{ Name = "AMD Threadripper 3970X (32 core)";        Vendor = "AuthenticAMD"; Cores = 32; Threads = 64;  PCores = 0;  ECores = 0;  CcdCount = 4 }
    @{ Name = "AMD Threadripper 3990X (64 core)";        Vendor = "AuthenticAMD"; Cores = 64; Threads = 128; PCores = 0;  ECores = 0;  CcdCount = 8 }
)

function Get-SimulatedTopology([int]$index) {
    if ($index -lt 0 -or $index -ge $script:SimulatedCpus.Count) { $index = 0 }
    $s = $script:SimulatedCpus[$index]
    $topo = New-Topology -Name $s.Name -Manufacturer $s.Vendor -Cores $s.Cores -Threads $s.Threads `
                         -PCoreCount ([int]$s.PCores) -ECoreCount ([int]$s.ECores) `
                         -CcdCountOverride ([int]$s.CcdCount)
    $topo | Add-Member -NotePropertyName SimIndex -NotePropertyValue $index -Force
    $topo.Simulated = $true
    return $topo
}

# ============================================================
# AFFINITY MASK
# ------------------------------------------------------------
# v1 used `$mask = 0` (Int32) with `1 -shl $i`. Two failures fell out of that:
#   * thread 31 produced Int32.MinValue, corrupting every 32-thread mask
#   * thread >= 64 wrapped modulo 64 and silently set the WRONG bit
# Int64 fixes the first. The second is a hard Windows limit -- a single
# ProcessorAffinity value cannot address beyond one 64-thread processor
# group -- so threads at/above 64 are dropped with a warning rather than
# quietly pinning the game to the wrong cores.
# ============================================================
$script:MaxAffinityBit = 63

function Build-MaskFromList($indices) {
    $list = @($indices | Where-Object { $_ -ge 0 -and $_ -le $script:MaxAffinityBit })
    if ($list.Count -eq 0) { return [IntPtr](-1) }
    [int64]$mask = 0
    foreach ($i in $list) { $mask = $mask -bor ([int64]1 -shl [int]$i) }
    return [IntPtr]$mask
}

function Test-MaskTruncation($indices) {
    return (@($indices | Where-Object { $_ -gt $script:MaxAffinityBit }).Count -gt 0)
}

function Format-ThreadRanges($indices) {
    $sorted = @($indices) | Sort-Object -Unique
    if ($sorted.Count -eq 0) { return "none" }
    $ranges = @()
    $start = $sorted[0]; $prev = $sorted[0]
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        if ($sorted[$i] -eq ($prev + 1)) { $prev = $sorted[$i]; continue }
        $ranges += $(if ($start -eq $prev) { "$start" } else { "$start-$prev" })
        $start = $sorted[$i]; $prev = $sorted[$i]
    }
    $ranges += $(if ($start -eq $prev) { "$start" } else { "$start-$prev" })
    return ($ranges -join ",")
}

# ============================================================
# TIER / PROFILE DEFINITIONS
# ------------------------------------------------------------
# v1 shipped "Full" and "Extreme" tiers whose bodies were character-for-character
# identical to "Standard" -- three names, one behaviour, gated only on core
# count. They're gone. Every profile below produces a genuinely different
# thread assignment, and each is gated on the topology it actually applies to.
# ============================================================
$script:MinSupportedThreads = 2

function Test-CpuSupported($topo) {
    return ($topo.Threads -ge $script:MinSupportedThreads)
}

function Get-StridedList($from, $to, $stride) {
    $list = @()
    for ($i = $from; $i -lt $to; $i += $stride) { $list += $i }
    return @($list)
}

function Get-TierDefinitions($topo) {
    $tiers   = [ordered]@{}
    $threads = $topo.Threads
    $cores   = $topo.Cores
    $tpc     = $topo.ThreadsPerCore
    $reserve = 1     # logical thread 0 only, not both siblings of core 0
    $script:ReservedCount = $reserve

    # --- Balanced: no isolation at all. Always available; the only sane
    #     option on 1-4 thread machines where holding anything back hurts.
    $tiers["Balanced"] = @{
        Label = "Balanced"
        Desc  = "CS2 uses every thread, nothing is reserved or isolated. Safest on low-thread-count CPUs."
        CS2   = @(0..($threads - 1))
        BG    = @()
    }

    if ($threads -lt 4) { return $tiers }

    if ($topo.IsHybrid -and $topo.PThreads -gt 2) {
        # --- Intel Hybrid: P-cores run the game, E-cores absorb background.
        #     This is what the E-cores are for; no reason to do anything else.
        $tiers["IntelHybrid"] = @{
            Label = "Intel Hybrid"
            Desc  = "CS2 on P-cores (thread 0 reserved for Windows), all background work pushed onto the E-cores."
            CS2   = @($reserve..($topo.PThreads - 1))
            BG    = @($topo.PThreads..($threads - 1))
        }
        # --- Hybrid + one-per-core: as above but CS2 gets only the primary
        #     thread of each P-core, so no two CS2 threads share a core's
        #     execution resources. Pointless without SMT -- on Arrow Lake each
        #     P-core already has exactly one thread, so this would be a
        #     duplicate of Intel Hybrid.
        if ($tpc -eq 2) {
        $tiers["HybridOnePerCore"] = @{
            Label = "Hybrid / One Per Core"
            Desc  = "One primary thread per P-core for CS2 (no HT sibling contention), E-cores handle background."
            CS2   = @(Get-StridedList $reserve $topo.PThreads 2)
            BG    = @($topo.PThreads..($threads - 1))
        }
        }
    }

    if ($cores -gt 2 -and -not $topo.IsHybrid) {
        # --- Standard: the v1 default, kept because it's a good default.
        $cs2    = @($reserve..($threads - 1))
        $bgList = @($cs2 | Select-Object -Last ([math]::Ceiling($cs2.Count / 2)))
        $tiers["Standard"] = @{
            Label = "Standard"
            Desc  = "Thread 0 reserved for Windows. CS2 gets every remaining thread; background is corralled into the upper half."
            CS2   = $cs2
            BG    = @($bgList)
        }
    }

    if ($tpc -eq 2 -and $cores -ge 4) {
        # --- One Per Core: CS2 gets the primary thread of each physical core
        #     and nothing else, so it never contends with itself across an SMT
        #     pair. Background gets all the sibling threads. This is the
        #     Process Lasso-style layout.
        # Built from the core map rather than a stride of 2. A stride is only
        # correct while every core has two threads; on a hybrid CPU the E-core
        # block past the P-cores has one thread per core, so stepping by two
        # walks straight past every second E-core and silently leaves it
        # unassigned. Taking the highest thread of each core gives the exact
        # same answer on a uniform SMT part and the right one on a hybrid.
        $cmap = Get-ThreadCoreMap $topo
        $perCore = @{}
        foreach ($k in $cmap.Keys) {
            $cc = $cmap[$k].Core
            if (-not $perCore.ContainsKey($cc) -or $k -gt $perCore[$cc]) { $perCore[$cc] = $k }
        }
        $cs2 = @($perCore.Values | Sort-Object | Where-Object { $_ -ge $reserve })
        $bg  = @(0..($threads - 1) | Where-Object { $cs2 -notcontains $_ -and $_ -ne 0 })
        $tiers["OnePerCore"] = @{
            Label = "One Per Core"
            Desc  = "CS2 gets one primary thread per physical core -- no SMT sibling contention. Background runs on the sibling threads."
            CS2   = $cs2
            BG    = @($bg)
        }
    }

    if ($threads -ge 8) {
        # --- Isolated: hard partition, zero overlap. Background physically
        #     cannot touch a CS2 thread. Highest isolation, lowest headroom.
        $split = [math]::Max(2, [int][math]::Floor($threads * 0.75))
        $cs2   = @($reserve..($split - 1))
        $bg    = @($split..($threads - 1))
        $tiers["Isolated"] = @{
            Label = "Isolated"
            Desc  = "Hard split with no overlap -- background processes are physically barred from every thread CS2 uses."
            CS2   = $cs2
            BG    = $bg
        }
    }

    if ($topo.IsMultiCcd) {
        # --- Single Die: on multi-CCD Ryzen, keeping the game inside one
        #     chiplet avoids cross-die Infinity Fabric latency, which is the
        #     single biggest affinity win available on those parts. On X3D
        #     SKUs the first CCD is the cache-stacked one.
        # CcdSize is now cores-per-chiplet as actually derived, so this is the
        # true CCD0 boundary rather than an assumed 8-core die.
        $ccdThreads = $topo.CcdSize * $tpc
        $cs2 = @($reserve..([math]::Min($ccdThreads, $threads) - 1))
        $bg  = @($ccdThreads..($threads - 1))
        $tiers["SingleDie"] = @{
            Label = "Single Die (CCD0)"
            Desc  = "Confines CS2 to the first chiplet so it never pays cross-CCD latency. Everything else runs on the other die(s). On X3D parts CCD0 is the cache-stacked die."
            CS2   = $cs2
            BG    = @($bg)
        }
    }

    return $tiers
}

function Get-RecommendedTierName($topo, $tiers) {
    $prefer = @()
    if ($topo.IsHybrid)        { $prefer = @("IntelHybrid", "Balanced") }
    elseif ($topo.IsMultiCcd)  { $prefer = @("SingleDie", "Standard", "Balanced") }
    elseif ($topo.Cores -ge 6) { $prefer = @("Standard", "OnePerCore", "Balanced") }
    elseif ($topo.Cores -ge 4) { $prefer = @("Standard", "Balanced") }
    else                       { $prefer = @("Balanced") }
    foreach ($p in $prefer) { if ($tiers.Contains($p)) { return $p } }
    return @($tiers.Keys)[0]
}

# ============================================================
# CONFIG PERSISTENCE
# ============================================================
function Get-DefaultConfig {
    return [ordered]@{
        planTier           = "Auto"
        pinningMode        = "Both"
        theme              = "Toothpaste"
        userExceptions     = @()
        customCs2Threads   = @()
        customBgThreads    = @()
        needsConfiguration = $false
        configPending      = $false
        savedCpuCores      = 0
        savedCpuThreads    = 0
    }
}

function Load-Config {
    $cfg = Get-DefaultConfig
    if ($script:SimMode) { return $cfg }     # simulator never reads real config
    if (Test-Path $configPath) {
        try {
            $loaded = Get-Content $configPath -Raw | ConvertFrom-Json
            foreach ($key in @($cfg.Keys)) {
                if ($loaded.PSObject.Properties.Name -contains $key) {
                    $val = $loaded.$key
                    if ($key -in @("userExceptions", "customCs2Threads", "customBgThreads")) { $val = @($val) }
                    $cfg[$key] = $val
                }
            }
        } catch {}
    }
    $cfg.theme = Resolve-ThemeName ([string]$cfg.theme)
    if (-not $script:ThemeCatalog.Contains([string]$cfg.theme)) { $cfg.theme = "Toothpaste" }
    return $cfg
}

function Save-Config($cfg) {
    if ($script:SimMode) { return }           # simulator never writes real config
    New-Item -ItemType Directory -Path $configDir -Force -ErrorAction SilentlyContinue | Out-Null
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding utf8
}

# ============================================================
# SHARED WPF HELPERS
# ============================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

function New-WpfWindow([string]$xamlString) {
    [xml]$xml = $xamlString
    $reader = New-Object System.Xml.XmlNodeReader $xml
    return [Windows.Markup.XamlReader]::Load($reader)
}

function New-Brush([string]$hex) {
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

# ============================================================
# STYLE DICTIONARY (built from the active theme)
# ------------------------------------------------------------
# The v1 bug worth calling out: RadioButton/CheckBox templates bound
# Background="{TemplateBinding Background}" but the Style never SET Background.
# WPF's default control background is near-white, so every option row rendered
# as a white bar -- which is why accent-colored option text was unreadable.
# Both styles now set Background explicitly to Transparent.
#
# Second fix: the template roots were horizontal StackPanels, which give the
# ContentPresenter unbounded width, so long option labels ran off the edge
# instead of wrapping (the clipped "background shares the upper half (Re..."
# line). They're Grids with an Auto/* column pair now, so content wraps.
# ============================================================
function Build-StyleXaml($t) {
    $onCs2 = if ((Get-RelativeLuminance $t.Cs2OnPanel) -gt 0.45) { "#101010" } else { "#FFFFFF" }
    $onBg  = if ((Get-RelativeLuminance $t.BgOnPanel)  -gt 0.45) { "#101010" } else { "#FFFFFF" }

    $tpl = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                     xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <SolidColorBrush x:Key="AccentBrush"   Color="@ACCENTPANEL@"/>
    <SolidColorBrush x:Key="AccentRaw"     Color="@ACCENT@"/>
    <SolidColorBrush x:Key="ChromeBrush"   Color="@CHROME@"/>
    <SolidColorBrush x:Key="PanelBrush"    Color="@PANEL@"/>
    <SolidColorBrush x:Key="PanelAltBrush" Color="@PANELALT@"/>
    <SolidColorBrush x:Key="PanelHiBrush"  Color="@PANELHI@"/>
    <SolidColorBrush x:Key="BorderBrush2"  Color="@BORDER@"/>
    <SolidColorBrush x:Key="TextBrush"     Color="@TEXT@"/>
    <SolidColorBrush x:Key="MutedBrush"    Color="@MUTED@"/>
    <SolidColorBrush x:Key="GoodBrush"     Color="@GOOD@"/>
    <SolidColorBrush x:Key="WarnBrush"     Color="@WARN@"/>
    <SolidColorBrush x:Key="BadBrush"      Color="@BAD@"/>
    <SolidColorBrush x:Key="LogBgBrush"    Color="@LOGBG@"/>

    <Style TargetType="TextBlock">
        <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
    </Style>

    <Style x:Key="CardHeader" TargetType="TextBlock">
        <Setter Property="FontSize" Value="11"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
        <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
        <Setter Property="Background" Value="{StaticResource PanelBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="CornerRadius" Value="8"/>
        <Setter Property="Padding" Value="16"/>
        <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>

    <Style TargetType="RadioButton">
        <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Margin" Value="0,3,0,3"/>
        <Setter Property="Padding" Value="10,8"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="HorizontalAlignment" Value="Stretch"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="RadioButton">
                    <Border x:Name="Row" Background="Transparent" BorderBrush="Transparent"
                            BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid Grid.Column="0" Width="16" Height="16" VerticalAlignment="Top" Margin="0,1,0,0">
                                <Ellipse x:Name="Ring" Stroke="{StaticResource BorderBrush2}" StrokeThickness="1.5" Fill="{StaticResource PanelAltBrush}"/>
                                <Ellipse x:Name="Dot" Width="8" Height="8" Fill="{StaticResource AccentBrush}" Visibility="Collapsed"/>
                            </Grid>
                            <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"
                                              TextElement.Foreground="{TemplateBinding Foreground}"/>
                        </Grid>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="Dot"  Property="Visibility" Value="Visible"/>
                            <Setter TargetName="Ring" Property="Stroke" Value="{StaticResource AccentBrush}"/>
                            <Setter TargetName="Row"  Property="Background" Value="{StaticResource PanelHiBrush}"/>
                            <Setter TargetName="Row"  Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Row" Property="Background" Value="{StaticResource PanelAltBrush}"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.4"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="CheckBox">
        <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Margin" Value="0,4,0,4"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <Grid Background="Transparent">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Border x:Name="Box" Grid.Column="0" Width="17" Height="17"
                                BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1.5"
                                Background="{StaticResource PanelAltBrush}" CornerRadius="4"
                                VerticalAlignment="Top" Margin="0,1,0,0">
                            <Path x:Name="CheckMark" Data="M 3,8 L 6.5,11.5 L 13,3.5"
                                  Stroke="@ONACCENT@" StrokeThickness="2"
                                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                                  Visibility="Collapsed"/>
                        </Border>
                        <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"
                                          TextElement.Foreground="{TemplateBinding Foreground}"/>
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="{x:Null}">
                            <Setter TargetName="Box" Property="Background" Value="{StaticResource MutedBrush}"/>
                            <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource MutedBrush}"/>
                        </Trigger>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                            <Setter TargetName="Box" Property="Background" Value="{StaticResource AccentBrush}"/>
                            <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.4"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style x:Key="Cs2Toggle" TargetType="ToggleButton">
        <Setter Property="Width" Value="23"/>
        <Setter Property="Height" Value="21"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FontSize" Value="10"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="{StaticResource PanelAltBrush}"
                            BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1" CornerRadius="4">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                          TextElement.Foreground="{TemplateBinding Foreground}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="Bd" Property="Background"  Value="@CS2@"/>
                            <Setter TargetName="Bd" Property="BorderBrush" Value="@CS2@"/>
                            <Setter Property="Foreground" Value="@ONCS2@"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="BorderBrush" Value="@CS2@"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style x:Key="BgToggle" TargetType="ToggleButton" BasedOn="{StaticResource Cs2Toggle}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="{StaticResource PanelAltBrush}"
                            BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1" CornerRadius="4">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                          TextElement.Foreground="{TemplateBinding Foreground}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="Bd" Property="Background"  Value="@BGC@"/>
                            <Setter TargetName="Bd" Property="BorderBrush" Value="@BGC@"/>
                            <Setter Property="Foreground" Value="@ONBG@"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="BorderBrush" Value="@BGC@"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style x:Key="SwatchToggle" TargetType="ToggleButton">
        <Setter Property="Width" Value="34"/>
        <Setter Property="Height" Value="26"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Margin" Value="0,0,6,0"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" BorderBrush="#00000000" BorderThickness="2" CornerRadius="6" Padding="1">
                        <ContentPresenter/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="Bd" Property="BorderBrush" Value="@TEXTCHROME@"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="BorderBrush" Value="@MUTEDCHROME@"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBox">
        <Setter Property="Background" Value="{StaticResource PanelAltBrush}"/>
        <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="8,6"/>
        <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
        <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style TargetType="ListBox">
        <Setter Property="Background" Value="{StaticResource PanelAltBrush}"/>
        <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
        <Setter Property="BorderThickness" Value="1"/>
    </Style>

    <Style TargetType="ListBoxItem">
        <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        <Setter Property="Padding" Value="8,5"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ListBoxItem">
                    <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
                        <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsSelected" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                            <Setter Property="Foreground" Value="@ONACCENT@"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{StaticResource PanelHiBrush}"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style x:Key="FlatButton" TargetType="Button">
        <Setter Property="Background" Value="@BUTTONBG@"/>
        <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="14,8"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"
                            Padding="{TemplateBinding Padding}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                          TextElement.Foreground="{TemplateBinding Foreground}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="@BUTTONHOV@"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.45"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style x:Key="MiniButton" TargetType="Button" BasedOn="{StaticResource FlatButton}">
        <Setter Property="Padding" Value="9,5"/>
        <Setter Property="FontSize" Value="11"/>
        <Setter Property="Margin" Value="0,0,6,0"/>
    </Style>

    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource FlatButton}">
        <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
        <Setter Property="Foreground" Value="@ONACCENT@"/>
        <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
        <Setter Property="FontWeight" Value="SemiBold"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"
                            Padding="{TemplateBinding Padding}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                          TextElement.Foreground="{TemplateBinding Foreground}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="@ACCENTHOV@"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.45"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style x:Key="DarkCombo" TargetType="ComboBox">
        <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        <Setter Property="Background" Value="{StaticResource PanelAltBrush}"/>
        <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
        <Setter Property="Height" Value="30"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ComboBox">
                    <Grid>
                        <ToggleButton x:Name="Tb" Focusable="False" ClickMode="Press"
                                      IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                            <ToggleButton.Template>
                                <ControlTemplate TargetType="ToggleButton">
                                    <Border Background="{StaticResource PanelAltBrush}" BorderBrush="{StaticResource BorderBrush2}"
                                            BorderThickness="1" CornerRadius="6">
                                        <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"
                                              Data="M 0,0 L 9,0 L 4.5,5 Z" Fill="{StaticResource MutedBrush}"/>
                                    </Border>
                                </ControlTemplate>
                            </ToggleButton.Template>
                        </ToggleButton>
                        <ContentPresenter IsHitTestVisible="False" Margin="12,0,28,0" VerticalAlignment="Center"
                                          Content="{TemplateBinding SelectionBoxItem}"
                                          ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                          TextElement.Foreground="{StaticResource TextBrush}"/>
                        <Popup x:Name="Pop" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                               AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                            <Border MinWidth="{TemplateBinding ActualWidth}" MaxHeight="340"
                                    Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush2}"
                                    BorderThickness="1" CornerRadius="6" Margin="0,2,0,0">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <StackPanel IsItemsHost="True" Margin="4"/>
                                </ScrollViewer>
                            </Border>
                        </Popup>
                    </Grid>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
        <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        <Setter Property="Padding" Value="10,7"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ComboBoxItem">
                    <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
                        <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsHighlighted" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{StaticResource PanelHiBrush}"/>
                        </Trigger>
                        <Trigger Property="IsSelected" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                            <Setter Property="Foreground" Value="@ONACCENT@"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
</ResourceDictionary>
'@

    $map = @{
        "@ACCENT@"       = $t.Accent
        "@ACCENTPANEL@"  = $t.AccentOnPanel
        "@ACCENTHOV@"    = $t.AccentHov
        "@CHROME@"       = $t.Chrome
        "@PANEL@"        = $t.Panel
        "@PANELALT@"     = $t.PanelAlt
        "@PANELHI@"      = $t.PanelHi
        "@BORDER@"       = $t.Border
        "@TEXT@"         = $t.Text
        "@MUTED@"        = $t.Muted
        "@GOOD@"         = $t.GoodOnPanel
        "@WARN@"         = $t.WarnOnPanel
        "@BAD@"          = $t.BadOnPanel
        "@LOGBG@"        = $t.LogBg
        "@ONACCENT@"     = $t.OnAccent
        "@BUTTONBG@"     = $t.ButtonBg
        "@BUTTONHOV@"    = $t.ButtonHov
        "@CS2@"          = $t.Cs2OnPanel
        "@BGC@"          = $t.BgOnPanel
        "@ONCS2@"        = $onCs2
        "@ONBG@"         = $onBg
        "@TEXTCHROME@"   = $t.TextOnChrome
        "@MUTEDCHROME@"  = $t.MutedOnChrome
    }
    foreach ($k in $map.Keys) { $tpl = $tpl.Replace($k, $map[$k]) }
    return $tpl
}

# Rainbow title runs, contrast-corrected for whichever surface they sit on.
function Get-RainbowRuns([string]$text, $palette) {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = [System.Security.SecurityElement]::Escape([string]$text[$i])
        if ($text[$i] -eq ' ') {
            [void]$sb.Append("<Run Text=`" `"/>")
        } else {
            $color = $palette[$i % $palette.Count]
            [void]$sb.Append("<Run Foreground=`"$color`">$ch</Run>")
        }
    }
    return $sb.ToString()
}

# ============================================================
# CONFIG DIALOG -- SHARED MUTABLE STATE
# ------------------------------------------------------------
# These live at script scope rather than inside Show-ConfigDialog because
# WPF event handlers fire long after the defining function has returned.
# Script scope is the one place both the builder and the handlers can
# reliably reach. (Same class of problem as the [scriptblock]::Create()
# binding trap -- worth not re-learning.)
# ============================================================
$script:mCs2      = @{}    # thread index -> ToggleButton
$script:mBg       = @{}
$script:mSuppress = $false
$script:mRadios   = @{}
$script:mTiers    = $null
$script:mTopo     = $null
$script:mSummary  = $null
$script:mWarn     = $null

function Get-MatrixCs2 { return @($script:mCs2.Keys | Where-Object { $script:mCs2[$_].IsChecked } | Sort-Object) }
function Get-MatrixBg  { return @($script:mBg.Keys  | Where-Object { $script:mBg[$_].IsChecked }  | Sort-Object) }

function Set-MatrixFromLists($cs2, $bg) {
    $script:mSuppress = $true
    try {
        foreach ($i in $script:mCs2.Keys) { $script:mCs2[$i].IsChecked = ($cs2 -contains $i) }
        foreach ($i in $script:mBg.Keys)  { $script:mBg[$i].IsChecked  = ($bg  -contains $i) }
    } finally { $script:mSuppress = $false }
    Update-MatrixSummary
}

function Update-MatrixSummary {
    if (-not $script:mSummary) { return }
    $cs2 = Get-MatrixCs2
    $bg  = Get-MatrixBg
    $overlap = @($cs2 | Where-Object { $bg -contains $_ }).Count
    $script:mSummary.Text = "CS2: $($cs2.Count) threads  ·  Background: $($bg.Count) threads  ·  Shared: $overlap  ·  Idle: $($script:mTopo.Threads - (@($cs2 + $bg) | Sort-Object -Unique).Count)"

    if ($script:mWarn) {
        $issues = @()
        if ($cs2.Count -eq 0)   { $issues += "CS2 has no threads assigned -- it will fall back to every thread." }
        elseif ($cs2.Count -lt 2) { $issues += "CS2 is pinned to a single thread. That will hurt far more than it helps." }
        if ($bg.Count -eq 0)    { $issues += "No background threads assigned -- background processes are left unmanaged." }
        if (Test-MaskTruncation $cs2) { $issues += "Threads above 63 cannot be addressed by a single affinity mask and will be ignored." }
        if ($issues.Count -gt 0) {
            $script:mWarn.Text = ($issues -join "  ")
            $script:mWarn.Visibility = "Visible"
        } else {
            $script:mWarn.Visibility = "Collapsed"
        }
    }
}

# Any manual toggle means the user has departed from the named plan, so the
# plan selection follows them to Custom instead of silently lying about what
# is actually applied.
function Switch-ToCustomPlan {
    if ($script:mSuppress) { return }
    if ($script:mRadios.ContainsKey("Custom") -and -not $script:mRadios["Custom"].IsChecked) {
        $script:mSuppress = $true
        try { $script:mRadios["Custom"].IsChecked = $true } finally { $script:mSuppress = $false }
    }
    Update-MatrixSummary
}

# ============================================================
# RISK WARNING
# ============================================================
function Confirm-RiskyPinning {
    param([int]$Cs2Count = -1, [int]$BgCount = -1, [bool]$Truncated = $false)
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $reasons = @()
    if ($Cs2Count -ge 0 -and $Cs2Count -lt 2) { $reasons += "CS2 is pinned to $Cs2Count thread(s). Too few threads hurts its performance more than isolation helps." }
    if ($BgCount -eq 0) { $reasons += "No threads are assigned to background processes, so they'll roam freely across every core instead of being corralled. That can cause stutter." }
    if ($Truncated)     { $reasons += "Some selected threads are above index 63. Windows affinity masks cover one 64-thread processor group only, so those threads will be silently dropped." }
    if (-not $reasons)  { $reasons += "You're using a fully Custom plan." }
    $msg = ($reasons -join "`n`n") + "`n`nSave this configuration anyway?"
    $res = [System.Windows.Forms.MessageBox]::Show($msg, "CS2 Affinity Manager - Review Configuration",
             [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    return ($res -eq [System.Windows.Forms.DialogResult]::Yes)
}

# ============================================================
# CONFIGURATION DIALOG
# ============================================================
function Show-ConfigDialog {
    param($Owner, $topo, $tiers, $recommendedTier, $config, $theme, [switch]$LockedToCustom)

    $t          = $theme
    $styleXaml  = Build-StyleXaml $t
    $titleRuns  = Get-RainbowRuns "CS2 Affinity Manager" $t.RainbowOnPanel
    $simVis     = if ($script:SimMode) { "Visible" } else { "Collapsed" }

    $mainXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CS2 Affinity Manager - Configure"
        Width="1040" Height="880" MinWidth="900" MinHeight="620"
        WindowStartupLocation="CenterScreen"
        Background="$($t.Chrome)" FontFamily="Segoe UI" ResizeMode="CanResize"
        TextOptions.TextRenderingMode="ClearType">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                $styleXaml
            </ResourceDictionary.MergedDictionaries>
        </ResourceDictionary>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- ============ HEADER (fixed) ============ -->
        <Border Grid.Row="0" Style="{StaticResource Card}" Margin="16,16,16,0" Padding="18,16">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                    <TextBlock FontSize="20" FontWeight="Bold">$titleRuns</TextBlock>
                    <TextBlock x:Name="CpuInfoText" Foreground="{StaticResource MutedBrush}" Margin="0,5,0,0"
                               TextWrapping="Wrap" FontSize="12"/>
                    <TextBlock x:Name="UnsupportedNote" Foreground="{StaticResource WarnBrush}" Margin="0,6,0,0"
                               TextWrapping="Wrap" FontSize="12" Visibility="Collapsed"/>
                </StackPanel>
                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="20,0,0,0">
                    <TextBlock Text="COLOR SCHEME" Style="{StaticResource CardHeader}" Margin="0,0,0,7"
                               HorizontalAlignment="Right"/>
                    <WrapPanel x:Name="ThemeSwatches" MaxWidth="290" HorizontalAlignment="Right"/>
                    <TextBlock x:Name="ThemeName" Foreground="{StaticResource MutedBrush}" FontSize="11"
                               Margin="0,7,0,0" HorizontalAlignment="Right" TextAlignment="Right" TextWrapping="Wrap"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ============ SIMULATOR BAR (test build only) ============ -->
        <Border Grid.Row="1" Style="{StaticResource Card}" Margin="16,12,16,0" Padding="18,14"
                Visibility="$simVis" BorderBrush="{StaticResource WarnBrush}" BorderThickness="1">
            <StackPanel>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="SIMULATED CPU" Style="{StaticResource CardHeader}"
                               Margin="0,0,14,0" VerticalAlignment="Center"/>
                    <ComboBox Grid.Column="1" x:Name="SimCombo" Style="{StaticResource DarkCombo}"/>
                    <Button Grid.Column="2" x:Name="BtnSimNext" Content="Next &#x2192;" Style="{StaticResource MiniButton}"
                            Margin="10,0,0,0"/>
                </Grid>
                <TextBlock x:Name="SimDetail" Foreground="{StaticResource MutedBrush}" FontSize="11"
                           Margin="0,10,0,0" TextWrapping="Wrap"/>
                <TextBlock Text="Simulation build. No process affinity is applied and no configuration is written to disk."
                           Foreground="{StaticResource WarnBrush}" FontSize="11" Margin="0,6,0,0" TextWrapping="Wrap"/>
            </StackPanel>
        </Border>

        <!-- ============ SCROLLING CONTENT ============ -->
        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                      Margin="16,12,16,0" Padding="0,0,6,0">
            <StackPanel>

                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Text="PERFORMANCE PROFILE" Style="{StaticResource CardHeader}"/>
                        <TextBlock Text="Picking a profile rewrites the thread assignment below. Editing any thread by hand switches you to Custom."
                                   Foreground="{StaticResource MutedBrush}" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,8"/>
                        <StackPanel x:Name="PlanPanel"/>
                    </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Text="PINNING MODE" Style="{StaticResource CardHeader}"/>
                        <RadioButton x:Name="RbAffinityOnly" GroupName="PinMode"/>
                        <RadioButton x:Name="RbPriorityOnly" GroupName="PinMode"/>
                        <RadioButton x:Name="RbBoth"         GroupName="PinMode"/>
                    </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Text="THREAD ASSIGNMENT" Style="{StaticResource CardHeader}"/>
                        <TextBlock Foreground="{StaticResource MutedBrush}" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,10">
                            <Run Text="Threads are grouped by the physical core that owns them. "/>
                            <Run Text="C" FontWeight="Bold" Foreground="{StaticResource GoodBrush}"/>
                            <Run Text=" assigns the thread to CS2, "/>
                            <Run Text="B" FontWeight="Bold" Foreground="{StaticResource BadBrush}"/>
                            <Run Text=" assigns it to background processes. A thread can carry both."/>
                        </TextBlock>

                        <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                            <Button x:Name="BtnResetPlan"  Content="Reset to profile" Style="{StaticResource MiniButton}"/>
                            <Button x:Name="BtnAllCs2"     Content="All to CS2"       Style="{StaticResource MiniButton}"/>
                            <Button x:Name="BtnOnePerCore" Content="One per core"     Style="{StaticResource MiniButton}"/>
                            <Button x:Name="BtnInvertBg"   Content="Invert background" Style="{StaticResource MiniButton}"/>
                            <Button x:Name="BtnClearBg"    Content="Clear background" Style="{StaticResource MiniButton}"/>
                        </StackPanel>

                        <Border Background="{StaticResource PanelAltBrush}" BorderBrush="{StaticResource BorderBrush2}"
                                BorderThickness="1" CornerRadius="6" Padding="8,7" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock x:Name="MatrixSummary" FontSize="12" FontWeight="SemiBold"/>
                                <TextBlock x:Name="MatrixWarn" FontSize="11" Foreground="{StaticResource WarnBrush}"
                                           TextWrapping="Wrap" Margin="0,5,0,0" Visibility="Collapsed"/>
                            </StackPanel>
                        </Border>

                        <Border BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1" CornerRadius="6"
                                Background="{StaticResource PanelAltBrush}">
                            <ScrollViewer x:Name="MatrixScroll" MaxHeight="330" VerticalScrollBarVisibility="Auto" Padding="8">
                                <WrapPanel x:Name="ThreadMatrix" Orientation="Horizontal"/>
                            </ScrollViewer>
                        </Border>
                    </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Text="PROCESS EXCEPTIONS" Style="{StaticResource CardHeader}"/>
                        <TextBlock x:Name="BuiltInCountText" Foreground="{StaticResource MutedBrush}" FontSize="11"
                                   Margin="0,0,0,10" TextWrapping="Wrap"/>
                        <DockPanel Margin="0,0,0,10">
                            <Button x:Name="BtnAddException" Content="Add" Width="76" Style="{StaticResource FlatButton}"
                                    DockPanel.Dock="Right" Margin="8,0,0,0"/>
                            <TextBox x:Name="TxtNewException" ToolTip="Process name, with or without .exe -- e.g. discord"/>
                        </DockPanel>
                        <ListBox x:Name="ExceptionsList" MinHeight="86" MaxHeight="180"/>
                        <TextBlock Text="Select an entry and press Delete to remove it."
                                   Foreground="{StaticResource MutedBrush}" FontSize="10" Margin="0,7,0,0"/>
                    </StackPanel>
                </Border>

                <Border Height="4" Background="Transparent" BorderThickness="0"/>
            </StackPanel>
        </ScrollViewer>

        <!-- ============ FOOTER (pinned; v1 scrolled these off the bottom) ============ -->
        <Border Grid.Row="3" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush2}"
                BorderThickness="0,1,0,0" Padding="18,14" Margin="0,14,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button Grid.Column="0" x:Name="BtnCancel" Content="Cancel" Style="{StaticResource FlatButton}" Width="104"/>
                <TextBlock Grid.Column="1" x:Name="FooterHint" Foreground="{StaticResource MutedBrush}" FontSize="11"
                           VerticalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="16,0"/>
                <Button Grid.Column="2" x:Name="BtnSave" Content="Save" Style="{StaticResource AccentButton}" Width="140"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

    $window = New-WpfWindow $mainXaml
    if ($Owner) { try { $window.Owner = $Owner } catch {} }

    $script:mTopo    = $topo
    $script:mTiers   = $tiers
    $script:mCs2     = @{}
    $script:mBg      = @{}
    $script:mRadios  = @{}
    $script:mSummary = $window.FindName("MatrixSummary")
    $script:mWarn    = $window.FindName("MatrixWarn")

    $cpuInfoText     = $window.FindName("CpuInfoText")
    $unsupportedNote = $window.FindName("UnsupportedNote")
    $planPanel       = $window.FindName("PlanPanel")
    $rbAffinityOnly  = $window.FindName("RbAffinityOnly")
    $rbPriorityOnly  = $window.FindName("RbPriorityOnly")
    $rbBoth          = $window.FindName("RbBoth")
    $threadMatrix    = $window.FindName("ThreadMatrix")
    $builtInCount    = $window.FindName("BuiltInCountText")
    $exceptionsList  = $window.FindName("ExceptionsList")
    $txtNewException = $window.FindName("TxtNewException")
    $btnAddException = $window.FindName("BtnAddException")
    $btnCancel       = $window.FindName("BtnCancel")
    $btnSave         = $window.FindName("BtnSave")
    $themeSwatches   = $window.FindName("ThemeSwatches")
    $themeNameLbl    = $window.FindName("ThemeName")
    $footerHint      = $window.FindName("FooterHint")

    # ---- Header info ----
    $bits = @("$($topo.Cores) cores", "$($topo.Threads) threads")
    if ($topo.IsHybrid)     { $bits += "$($topo.PCores)P + $($topo.ECores)E hybrid" }
    if ($topo.IsMultiCcd)   { $bits += "$($topo.CcdCount) CCDs" }
    if ($topo.ThreadsPerCore -eq 1) { $bits += "no SMT" }
    $cpuInfoText.Text = "$($topo.Name)   ·   " + ($bits -join "   ·   ")
    $builtInCount.Text = "$($safeExceptions.Count) built-in exclusions (system, anti-cheat, GPU drivers, audio, security) are always protected. Add your own below:"

    # ---- Pinning mode: two-line labels ----
    function New-TwoLineContent($title, $sub, $titleColor, $subColor) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $tb1 = New-Object System.Windows.Controls.TextBlock
        $tb1.Text = $title; $tb1.FontWeight = "SemiBold"; $tb1.FontSize = 13
        $tb1.Foreground = New-Brush $titleColor
        $tb1.TextWrapping = "Wrap"
        $sp.Children.Add($tb1) | Out-Null
        if ($sub) {
            $tb2 = New-Object System.Windows.Controls.TextBlock
            $tb2.Text = $sub; $tb2.FontSize = 11; $tb2.Margin = "0,3,0,0"
            $tb2.Foreground = New-Brush $subColor
            $tb2.TextWrapping = "Wrap"
            $sp.Children.Add($tb2) | Out-Null
        }
        return $sp
    }

    $rbAffinityOnly.Content = New-TwoLineContent "Affinity only" "Assigns CPU cores. Leaves process priority untouched." $t.Text $t.Muted
    $rbPriorityOnly.Content = New-TwoLineContent "Priority only" "Raises CS2 and lowers background priority. No core assignment." $t.Text $t.Muted
    $rbBoth.Content         = New-TwoLineContent "Affinity + Priority" "Recommended. Both core assignment and priority class." $t.Text $t.Muted

    # ---- Theme swatches ----
    $script:themeChange = $null
    foreach ($tn in $script:ThemeCatalog.Keys) {
        $def = $script:ThemeCatalog[$tn]
        $tg  = New-Object System.Windows.Controls.Primitives.ToggleButton
        $tg.Style = $window.FindResource("SwatchToggle")
        $tg.Tag   = $tn
        $tg.ToolTip = "$tn -- $($def.Blurb)"

        $sw = New-Object System.Windows.Controls.Border
        $sw.Background   = New-Brush $def.Chrome
        $sw.CornerRadius = New-Object System.Windows.CornerRadius(4)
        $sw.BorderBrush  = New-Brush $def.Border
        $sw.BorderThickness = New-Object System.Windows.Thickness(1)
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 10; $dot.Height = 10
        $dot.Fill = New-Brush $def.Accent
        $dot.HorizontalAlignment = "Center"; $dot.VerticalAlignment = "Center"
        $sw.Child = $dot
        $tg.Content = $sw

        if ($tn -eq $t.Name) { $tg.IsChecked = $true }
        $tg.Add_Click({
            param($s, $e)
            $picked = [string]$s.Tag
            $script:themeChange = $picked
            # ToggleButtons aren't mutually exclusive like RadioButtons, so
            # enforce single-selection by hand instead of giving them a
            # GroupName -- a WPF ToggleButton GroupName forces one to stay
            # checked, which fights the "preview a pick, still Cancel-able"
            # behaviour this dialog wants.
            foreach ($sib in $themeSwatches.Children) { $sib.IsChecked = ($sib -eq $s) }
            $themeNameLbl.Text = "$picked -- $($script:ThemeCatalog[$picked].Blurb)  (applies on Save)"
        })
        $themeSwatches.Children.Add($tg) | Out-Null
    }
    $themeNameLbl.Text = "$($t.Name) -- $($script:ThemeCatalog[$t.Name].Blurb)"

    # ---- Profile radios ----
    if ($LockedToCustom) {
        $unsupportedNote.Text = "This CPU is outside the tool's profile range, so thread assignment has to be done by hand below."
        $unsupportedNote.Visibility = "Visible"
    } else {
        foreach ($key in $tiers.Keys) {
            $rb = New-Object System.Windows.Controls.RadioButton
            $rb.GroupName = "PlanTier"
            $rb.Tag = $key
            $label = $tiers[$key].Label
            if ($key -eq $recommendedTier) { $label += "   ·   Recommended for this CPU" }
            $rb.Content = New-TwoLineContent $label $tiers[$key].Desc $t.Text $t.Muted
            if (($config.planTier -eq "Auto" -and $key -eq $recommendedTier) -or $config.planTier -eq $key) { $rb.IsChecked = $true }
            $rb.Add_Checked({
                param($s, $e)
                if ($script:mSuppress) { return }
                $k = [string]$s.Tag
                if ($k -ne "Custom" -and $script:mTiers.Contains($k)) {
                    Set-MatrixFromLists @($script:mTiers[$k].CS2) @($script:mTiers[$k].BG)
                }
            })
            $planPanel.Children.Add($rb) | Out-Null
            $script:mRadios[$key] = $rb
        }
    }
    $rbCustom = New-Object System.Windows.Controls.RadioButton
    $rbCustom.GroupName = "PlanTier"; $rbCustom.Tag = "Custom"
    $rbCustom.Content = New-TwoLineContent "Custom" "Whatever you've set in the thread assignment grid below." $t.Text $t.Muted
    if ($config.planTier -eq "Custom" -or $LockedToCustom) { $rbCustom.IsChecked = $true }
    $planPanel.Children.Add($rbCustom) | Out-Null
    $script:mRadios["Custom"] = $rbCustom

    # ---- Thread matrix, grouped by physical core ----
    $coreMap  = Get-ThreadCoreMap $topo
    $byCore   = @{}
    foreach ($ti in 0..($topo.Threads - 1)) {
        $c = $coreMap[$ti].Core
        if (-not $byCore.ContainsKey($c)) { $byCore[$c] = @() }
        $byCore[$c] += $ti
    }

    # Walk core indices directly rather than enumerating hashtable keys. Even
    # with the casts above, key-order enumeration is one more thing that can
    # silently reorder the grid; a plain counter cannot.
    $coreIds = @($byCore.Keys | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    foreach ($c in $coreIds) {
        $threadsOfCore = @($byCore[$c] | Sort-Object)
        $info = $coreMap[$threadsOfCore[0]]

        $grp = New-Object System.Windows.Controls.Border
        $grp.Background      = New-Brush $t.Panel
        $grp.BorderBrush     = New-Brush $t.Border
        $grp.BorderThickness = New-Object System.Windows.Thickness(1)
        $grp.CornerRadius    = New-Object System.Windows.CornerRadius(6)
        $grp.Padding         = New-Object System.Windows.Thickness(7, 5, 7, 6)
        $grp.Margin          = New-Object System.Windows.Thickness(0, 0, 6, 6)

        $gs = New-Object System.Windows.Controls.StackPanel

        $hdr = New-Object System.Windows.Controls.TextBlock
        $hdrText = switch ($info.Kind) {
            "P"     { "P-Core $c" }
            "E"     { "E-Core $c" }
            default { $(if ($topo.IsMultiCcd) { "CCD$($info.Ccd) · Core $c" } else { "Core $c" }) }
        }
        $hdr.Text = $hdrText
        $hdr.FontSize = 10
        $hdr.FontWeight = "SemiBold"
        $hdr.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
        $hdr.Foreground = New-Brush $(switch ($info.Kind) { "P" { $t.AccentOnPanel } "E" { $t.Muted } default { $t.Muted } })
        $gs.Children.Add($hdr) | Out-Null

        # ---- system-core marking ----
        # Wording matters here. Windows does not reserve a core; there is no
        # such OS concept. CPU 0 is the boot processor and tends to collect
        # more interrupt and DPC work than the rest, so this tool holds it
        # back by choice. Saying "reserved" implied the whole core was off
        # limits, which is false whenever its sibling is still handed to CS2 --
        # on an SMT core they share L1, L2 and execution ports, so the core is
        # shared with Windows rather than surrendered to it.
        $coreThreadsReserved = @($threadsOfCore | Where-Object { $_ -lt $script:ReservedCount }).Count
        if ($coreThreadsReserved -gt 0) {
            $wholeCore = ($coreThreadsReserved -eq $threadsOfCore.Count)
            $sub = New-Object System.Windows.Controls.TextBlock
            $sub.Text       = $(if ($wholeCore) { "Windows only" } else { "Used by Windows" })
            $sub.FontSize   = 8
            $sub.FontStyle  = "Italic"
            $sub.Foreground = New-Brush $t.Muted
            $sub.Margin     = New-Object System.Windows.Thickness(0, -3, 0, 5)
            $sub.TextWrapping = "Wrap"

            $kindWord = switch ($info.Kind) { "P" { "P-core" } "E" { "E-core" } default { "core" } }
            $where    = $(if ($topo.IsMultiCcd) { " on CCD$($info.Ccd)" } else { "" })
            $tipLines = @(
                "CPU 0 is the boot processor and takes a larger share of interrupt and DPC work than any other logical CPU. Windows does not reserve it -- this tool holds it back on purpose."
                ""
                "This is $kindWord $c$where."
            )
            if (-not $wholeCore) {
                $tipLines += ""
                $tipLines += "Thread $($threadsOfCore[0]) is held back, but thread $($threadsOfCore[-1]) on the same physical core is still available. They share L1, L2 and execution ports, so anything CS2 runs here competes with that system work."
            }
            $sub.ToolTip = ($tipLines -join [Environment]::NewLine)
            $grp.ToolTip = $sub.ToolTip
            $gs.Children.Add($sub) | Out-Null

            # Mark the card itself so it reads as different before you hover.
            $grp.BorderBrush = New-Brush $t.Muted
            $hdr.Foreground  = New-Brush $t.Muted
        }

        # Sort explicitly. Without this the threads came out of the grouping in
        # an order that put T1 ahead of T0 on some cores, which made the
        # reserved thread look like the enabled one.
        foreach ($ti in $threadsOfCore) {
            $isReserved = ($ti -lt $script:ReservedCount)
            $isPastMask = ($ti -gt $script:MaxAffinityBit)

            $row = New-Object System.Windows.Controls.StackPanel
            $row.Orientation = "Horizontal"
            $row.Margin = New-Object System.Windows.Thickness(0, 1, 0, 1)

            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = "T$ti"
            $lbl.FontSize = 10
            $lbl.Width = 30
            $lbl.VerticalAlignment = "Center"
            $lbl.Foreground = New-Brush $(if ($isReserved -or $isPastMask) { $t.Muted } else { $t.Text })
            if ($isReserved) { $lbl.ToolTip = "Thread 0 -- Windows leans on this one hardest. Recommended to leave for the OS." }
            if ($isPastMask) { $lbl.ToolTip = "Beyond the 64-thread affinity mask limit. Cannot be pinned." }
            $row.Children.Add($lbl) | Out-Null

            $cCb = New-Object System.Windows.Controls.Primitives.ToggleButton
            $cCb.Style = $window.FindResource("Cs2Toggle")
            $cCb.Content = "C"; $cCb.Tag = $ti
            $cCb.Margin = New-Object System.Windows.Thickness(0, 0, 3, 0)
            $cCb.ToolTip = "Assign thread $ti to CS2"
            $cCb.IsEnabled = (-not $isPastMask)

            $bCb = New-Object System.Windows.Controls.Primitives.ToggleButton
            $bCb.Style = $window.FindResource("BgToggle")
            $bCb.Content = "B"; $bCb.Tag = $ti
            $bCb.ToolTip = "Assign thread $ti to background processes"
            $bCb.IsEnabled = (-not $isPastMask)

            $cCb.Add_Click({ Switch-ToCustomPlan })
            $bCb.Add_Click({ Switch-ToCustomPlan })

            $row.Children.Add($cCb) | Out-Null
            $row.Children.Add($bCb) | Out-Null
            $gs.Children.Add($row) | Out-Null

            # Dim the held-back thread. Opacity only -- it stays clickable.
            if ($isReserved) { $row.Opacity = 0.5 }

            $script:mCs2[$ti] = $cCb
            $script:mBg[$ti]  = $bCb
        }

        $grp.Child = $gs
        $threadMatrix.Children.Add($grp) | Out-Null
    }

    # ---- Seed matrix state ----
    $seedTier = if ($LockedToCustom) { $null } elseif ($tiers.Contains($recommendedTier)) { $recommendedTier } else { $null }
    if (@($config.customCs2Threads).Count -gt 0 -or @($config.customBgThreads).Count -gt 0) {
        Set-MatrixFromLists @($config.customCs2Threads) @($config.customBgThreads)
    } elseif ($seedTier) {
        Set-MatrixFromLists @($tiers[$seedTier].CS2) @($tiers[$seedTier].BG)
    } else {
        Set-MatrixFromLists @(0..($topo.Threads - 1)) @()
    }

    # ---- Matrix toolbar ----
    $window.FindName("BtnResetPlan").Add_Click({
        $sel = ($script:mRadios.GetEnumerator() | Where-Object { $_.Value.IsChecked -eq $true } | Select-Object -First 1).Key
        if ($sel -and $sel -ne "Custom" -and $script:mTiers.Contains($sel)) {
            Set-MatrixFromLists @($script:mTiers[$sel].CS2) @($script:mTiers[$sel].BG)
        }
    })
    $window.FindName("BtnAllCs2").Add_Click({
        Set-MatrixFromLists @(0..($script:mTopo.Threads - 1)) (Get-MatrixBg)
        Switch-ToCustomPlan
    })
    $window.FindName("BtnOnePerCore").Add_Click({
        $stride = [math]::Max(1, $script:mTopo.ThreadsPerCore)
        $cs2 = Get-StridedList 1 $script:mTopo.Threads $stride
        $bg  = @(0..($script:mTopo.Threads - 1) | Where-Object { $cs2 -notcontains $_ -and $_ -ne 0 })
        Set-MatrixFromLists $cs2 $bg
        Switch-ToCustomPlan
    })
    $window.FindName("BtnInvertBg").Add_Click({
        $bg = Get-MatrixBg
        Set-MatrixFromLists (Get-MatrixCs2) @(0..($script:mTopo.Threads - 1) | Where-Object { $bg -notcontains $_ })
        Switch-ToCustomPlan
    })
    $window.FindName("BtnClearBg").Add_Click({
        Set-MatrixFromLists (Get-MatrixCs2) @()
        Switch-ToCustomPlan
    })

    # ---- Pinning mode ----
    switch ($config.pinningMode) {
        "AffinityOnly" { $rbAffinityOnly.IsChecked = $true }
        "PriorityOnly" { $rbPriorityOnly.IsChecked = $true }
        default        { $rbBoth.IsChecked = $true }
    }

    # ---- Exceptions ----
    foreach ($e in $config.userExceptions) { $exceptionsList.Items.Add($e) | Out-Null }
    $addException = {
        $val = $txtNewException.Text.Trim() -replace '\.exe$', ''
        if ($val -and ($exceptionsList.Items -notcontains $val)) {
            $exceptionsList.Items.Add($val) | Out-Null
            $txtNewException.Text = ""
        }
    }
    $btnAddException.Add_Click($addException)
    $txtNewException.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { & $addException } })
    $exceptionsList.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Delete' -and $exceptionsList.SelectedItem) { $exceptionsList.Items.Remove($exceptionsList.SelectedItem) }
    })

    # ---- Simulator wiring ----
    $script:simSwitchTo = $null
    if ($script:SimMode) {
        $simCombo  = $window.FindName("SimCombo")
        $simDetail = $window.FindName("SimDetail")
        for ($i = 0; $i -lt $script:SimulatedCpus.Count; $i++) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $script:SimulatedCpus[$i].Name
            $item.Tag = $i
            $simCombo.Items.Add($item) | Out-Null
        }
        $script:simCurIdx = if ($topo.PSObject.Properties.Name -contains "SimIndex") { [int]$topo.SimIndex } else { 0 }
        $simCombo.SelectedIndex = $script:simCurIdx

        $tierNames = if ($tiers.Count -gt 0) { (@($tiers.Keys) -join ", ") } else { "none -- Custom only" }
        $simDetail.Text = "Profiles offered: $tierNames" +
                          "`nRecommended: $recommendedTier" +
                          "`nThreads/core: $($topo.ThreadsPerCore)   Hybrid: $($topo.IsHybrid)   Multi-CCD: $($topo.IsMultiCcd)   Supported: $(-not $LockedToCustom)"

        $simCombo.Add_SelectionChanged({
            param($s, $e)
            if ($s.SelectedItem -and ([int]$s.SelectedItem.Tag) -ne $script:simCurIdx) {
                $script:simSwitchTo = [int]$s.SelectedItem.Tag
                $script:saveClicked = $false
                [System.Windows.Window]::GetWindow($s).Close()
            }
        })
        $window.FindName("BtnSimNext").Add_Click({
            param($s, $e)
            $script:simSwitchTo = ($script:simCurIdx + 1) % $script:SimulatedCpus.Count
            $script:saveClicked = $false
            [System.Windows.Window]::GetWindow($s).Close()
        })
    }

    $footerHint.Text = "Changes take effect the next time CS2 Affinity Manager starts."

    # ---- Save / Cancel ----
    $script:saveClicked = $false
    $btnSave.Add_Click({
        $tierNow  = ($script:mRadios.GetEnumerator() | Where-Object { $_.Value.IsChecked -eq $true } | Select-Object -First 1).Key
        $cs2      = Get-MatrixCs2
        $bg       = Get-MatrixBg
        $trunc    = Test-MaskTruncation $cs2
        $isRisky  = ($cs2.Count -lt 2) -or ($bg.Count -eq 0) -or $trunc
        if ($isRisky -and -not (Confirm-RiskyPinning -Cs2Count $cs2.Count -BgCount $bg.Count -Truncated $trunc)) { return }
        $script:saveClicked = $true
        $window.Close()
    })
    $btnCancel.Add_Click({ $script:saveClicked = $false; $window.Close() })

    Update-MatrixSummary
    $null = $window.ShowDialog()

    # CPU switch closes the window and is reported back to the caller, which
    # reopens the dialog rebuilt from scratch -- a new simulated CPU changes
    # the whole topology, so there's no cheaper way to do it. A theme swatch
    # pick, by contrast, is just recorded in $script:themeChange and only
    # takes effect when Save is clicked (below), so picking colors never
    # closes anything on its own.
    if ($null -ne $script:simSwitchTo) { return @{ __action = "sim"; index = $script:simSwitchTo } }
    if (-not $script:saveClicked) { return $null }

    $selectedTier = ($script:mRadios.GetEnumerator() | Where-Object { $_.Value.IsChecked -eq $true } | Select-Object -First 1).Key
    if (-not $selectedTier) { $selectedTier = if ($LockedToCustom) { "Custom" } else { $recommendedTier } }
    $selectedPinMode = if ($rbAffinityOnly.IsChecked) { "AffinityOnly" } elseif ($rbPriorityOnly.IsChecked) { "PriorityOnly" } else { "Both" }

    return [ordered]@{
        planTier           = $selectedTier
        pinningMode        = $selectedPinMode
        theme              = $(if ($script:themeChange) { $script:themeChange } else { $t.Name })
        userExceptions     = @($exceptionsList.Items)
        customCs2Threads   = @(Get-MatrixCs2)
        customBgThreads    = @(Get-MatrixBg)
        needsConfiguration = $false
        configPending      = $false
        savedCpuCores      = $topo.Cores
        savedCpuThreads    = $topo.Threads
    }
}

# ============================================================
# CONFIG DIALOG DRIVER
# ------------------------------------------------------------
# Wraps Show-ConfigDialog in a loop so a simulated-CPU change (test build
# only) can rebuild the window from scratch rather than trying to mutate a
# live visual tree. Theme picks don't need this: they're just a value
# carried on the normal Save return, applied by the caller in one shot.
# ============================================================
function Invoke-ConfigDialog {
    param($Owner, [ref]$TopoRef, $config)

    $cfg = $config
    while ($true) {
        $topo      = $TopoRef.Value
        $supported = Test-CpuSupported $topo
        $tiers     = if ($supported) { Get-TierDefinitions $topo } else { [ordered]@{} }
        $recTier   = if ($supported -and $tiers.Count -gt 0) { Get-RecommendedTierName $topo $tiers } else { "Custom" }
        $theme     = Resolve-Theme ([string]$cfg.theme)

        $res = Show-ConfigDialog -Owner $Owner -topo $topo -tiers $tiers -recommendedTier $recTier `
                                 -config $cfg -theme $theme -LockedToCustom:(-not $supported)

        if ($null -eq $res) { return $null }

        if ($res -is [hashtable] -and $res.ContainsKey("__action")) {
            switch ($res.__action) {
                "sim" {
                    $TopoRef.Value = Get-SimulatedTopology $res.index
                    # New silicon, new plan -- drop the old thread selection so the
                    # simulated CPU gets a genuine first-run default, which is the
                    # whole thing being tested.
                    $cfg = Get-DefaultConfig
                    $cfg.theme = $theme.Name
                    continue
                }
            }
        }
        return $res
    }
}

# ============================================================
# SINGLE-INSTANCE GUARD
# ============================================================
$script:ShowEventName = "Global\CS2AffinityManager_ShowRequest"

function Get-RunningInstance {
    $procName = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName
    try {
        Get-CimInstance Win32_Process -Filter "Name='$procName.exe'" -ErrorAction Stop |
            Where-Object { $_.ProcessId -ne $PID }
    } catch { $null }
}

# The simulator is explicitly allowed to run alongside the real app -- that's
# the point of it. Only the release path enforces one instance.
if (-not $script:SimMode) {
    # A self-restart (Save -> "Restart now?") hands us the PID of the instance
    # that spawned us. That instance is deliberately still alive right now --
    # it has to start us before it can shut itself down -- so wait for it to
    # actually exit before the duplicate check below. Without this the check
    # sees the outgoing process, assumes a second launch, and exits, which
    # leaves NO instance running at all.
    if ($awaitPid -gt 0) {
        try {
            $outgoing = Get-Process -Id $awaitPid -ErrorAction SilentlyContinue
            if ($outgoing) { $outgoing.WaitForExit(10000) | Out-Null }
        } catch {}
    }

    $existing = Get-RunningInstance
    if ($existing) {
        try {
            $signalEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $script:ShowEventName)
            $signalEvent.Set() | Out-Null
        } catch {}
        exit
    }
}

# ============================================================
# MAIN WINDOW
# ============================================================
function Show-LogWindow {
    param($topo, $activeTierName, $pinningMode, $cs2Range, $bgRange, $theme)

    $t         = $theme
    $styleXaml = Build-StyleXaml $t
    $titleRuns = Get-RainbowRuns "CS2 Affinity Manager" $t.RainbowOnPanel
    $simVis    = if ($script:SimMode) { "Visible" } else { "Collapsed" }
    $simTitle  = if ($script:SimMode) { "CS2 Affinity Manager  --  SIMULATION BUILD" } else { "CS2 Affinity Manager" }

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$simTitle" Width="1000" Height="640" MinWidth="820" MinHeight="480"
        ShowInTaskbar="True"
        WindowStartupLocation="CenterScreen" Background="$($t.Chrome)" FontFamily="Segoe UI" ResizeMode="CanResize">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                $styleXaml
            </ResourceDictionary.MergedDictionaries>
        </ResourceDictionary>
    </Window.Resources>
    <Grid Margin="16">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="272"/>
            <ColumnDefinition Width="14"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0" Padding="18">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
                <TextBlock FontSize="17" FontWeight="Bold" Margin="0,0,0,4" TextWrapping="Wrap">$titleRuns</TextBlock>
                <TextBlock Text="SIMULATION BUILD" Foreground="{StaticResource WarnBrush}" FontSize="10"
                           FontWeight="Bold" Margin="0,0,0,12" Visibility="$simVis"/>
                <Border Height="1" Background="{StaticResource BorderBrush2}" Margin="0,0,0,14"/>

                <TextBlock Text="CPU" Style="{StaticResource CardHeader}" Margin="0,0,0,2"/>
                <TextBlock x:Name="InfoCpu" Margin="0,0,0,12" TextWrapping="Wrap" FontSize="12"/>
                <TextBlock Text="TOPOLOGY" Style="{StaticResource CardHeader}" Margin="0,0,0,2"/>
                <TextBlock x:Name="InfoTopology" Margin="0,0,0,12" FontSize="12" TextWrapping="Wrap"/>
                <TextBlock Text="ACTIVE PROFILE" Style="{StaticResource CardHeader}" Margin="0,0,0,2"/>
                <TextBlock x:Name="InfoPlan" Margin="0,0,0,12" FontSize="12" TextWrapping="Wrap"/>
                <TextBlock Text="PINNING MODE" Style="{StaticResource CardHeader}" Margin="0,0,0,2"/>
                <TextBlock x:Name="InfoPinMode" Margin="0,0,0,12" FontSize="12"/>
                <TextBlock Text="CS2 THREADS" Style="{StaticResource CardHeader}" Margin="0,0,0,2"/>
                <TextBlock x:Name="InfoCs2Threads" Margin="0,0,0,12" FontSize="12" TextWrapping="Wrap"/>
                <TextBlock Text="BACKGROUND THREADS" Style="{StaticResource CardHeader}" Margin="0,0,0,2"/>
                <TextBlock x:Name="InfoBgThreads" Margin="0,0,0,14" FontSize="12" TextWrapping="Wrap"/>

                <Border Background="{StaticResource PanelAltBrush}" CornerRadius="6" Padding="10,8" Margin="0,0,0,14">
                    <TextBlock x:Name="InfoStatus" FontSize="12" Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap"/>
                </Border>

                <Button x:Name="BtnConfigure"  Content="Configure..."             Style="{StaticResource FlatButton}" Margin="0,0,0,8"/>
                <Button x:Name="BtnRepairTask" Content="Repair Auto-Start Trigger" Style="{StaticResource FlatButton}" Margin="0,0,0,8"/>
                <Button x:Name="BtnOpenLog"    Content="Open Log File"            Style="{StaticResource FlatButton}"/>
            </StackPanel>
            </ScrollViewer>
        </Border>

        <Border Grid.Column="2" Background="{StaticResource LogBgBrush}" BorderBrush="{StaticResource BorderBrush2}"
                BorderThickness="1" CornerRadius="8" Padding="12">
            <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="LogText" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"
                           Foreground="$($t.LogText)"/>
            </ScrollViewer>
        </Border>
    </Grid>
</Window>
"@

    $win = New-WpfWindow $xaml

    # Minimize and close both hide to tray; the tray menu's Exit is the only
    # real way out. (Simulation build skips this -- closing it should just close.)
    if (-not $script:SimMode) {
        $script:hideToTray = {
            param($s)
            try {
                if ($s.WindowState -eq [System.Windows.WindowState]::Minimized) { $s.WindowState = [System.Windows.WindowState]::Normal }
                $s.Hide()
            } catch {}
        }
        # Closing normally means "hide to tray", not "quit" -- but the theme
        # rebuild and the self-restart genuinely do want the window gone.
        # Without this flag their Close() call was silently cancelled, so a
        # theme switch left the old window hidden and orphaned (with its
        # handlers still attached) and built a fresh one on top of it.
        $win.Add_Closing({
            param($s, $e)
            if ($script:allowRealClose) { return }
            $e.Cancel = $true
            & $script:hideToTray $s
        })
        $win.Add_StateChanged({ param($s, $e) if ($s.WindowState -eq [System.Windows.WindowState]::Minimized) { & $script:hideToTray $s } })
    } else {
        $win.Add_Closing({ try { [System.Windows.Application]::Current.Shutdown() } catch {} })
    }

    $refs = [pscustomobject]@{
        Window        = $win
        Theme         = $t
        InfoCpu       = $win.FindName("InfoCpu")
        InfoTopology  = $win.FindName("InfoTopology")
        InfoPlan      = $win.FindName("InfoPlan")
        InfoPinMode   = $win.FindName("InfoPinMode")
        InfoCs2       = $win.FindName("InfoCs2Threads")
        InfoBg        = $win.FindName("InfoBgThreads")
        InfoStatus    = $win.FindName("InfoStatus")
        BtnConfigure  = $win.FindName("BtnConfigure")
        BtnRepairTask = $win.FindName("BtnRepairTask")
        BtnOpenLog    = $win.FindName("BtnOpenLog")
        LogText       = $win.FindName("LogText")
        LogScroll     = $win.FindName("LogScroll")
    }

    $topoBits = @("$($topo.Cores) cores / $($topo.Threads) threads")
    if ($topo.IsHybrid)   { $topoBits += "$($topo.PCores)P + $($topo.ECores)E" }
    if ($topo.IsMultiCcd) { $topoBits += "$($topo.CcdCount) CCDs" }
    if ($topo.ThreadsPerCore -eq 1) { $topoBits += "no SMT" }

    $refs.InfoCpu.Text      = $topo.Name
    $refs.InfoTopology.Text = ($topoBits -join "`n")
    $refs.InfoPlan.Text     = $activeTierName
    $refs.InfoPinMode.Text  = $pinningMode
    $refs.InfoCs2.Text      = $cs2Range
    $refs.InfoBg.Text       = $bgRange
    $refs.InfoStatus.Text   = $(if ($script:SimMode) { "Simulation -- nothing is applied to real processes." } else { "Waiting for $gameProcess.exe..." })
    $refs.BtnOpenLog.Add_Click({ if (Test-Path $logPath) { Start-Process notepad.exe $logPath } })
    if ($script:SimMode) { $refs.BtnRepairTask.IsEnabled = $false; $refs.BtnOpenLog.IsEnabled = $false }

    return $refs
}

# ============================================================
# LOGGING
# ============================================================
function Write-Log {
    param($refs, [string]$msg, [string]$colorKey = "")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $msg"
    if (-not $script:SimMode) { try { $line | Out-File -FilePath $logPath -Append -Encoding utf8 } catch {} }
    if ($refs) {
        $hex = if ($colorKey) {
            switch ($colorKey) {
                "good"   { $refs.Theme.GoodOnLog }
                "warn"   { $refs.Theme.WarnOnLog }
                "bad"    { $refs.Theme.BadOnLog }
                "info"   { $refs.Theme.InfoOnLog }
                "muted"  { $refs.Theme.Muted }
                "accent" { Get-ReadableColor $refs.Theme.Accent $refs.Theme.LogBg 4.5 }
                default  { $refs.Theme.LogText }
            }
        } else { $refs.Theme.LogText }
        $refs.Window.Dispatcher.Invoke([action]{
            $run = New-Object System.Windows.Documents.Run("$line`n")
            $run.Foreground = New-Brush $hex
            $refs.LogText.Inlines.Add($run)
            $refs.LogScroll.ScrollToBottom()
        })
    }
}

function Write-RainbowLog {
    param($refs, [string]$msg)
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $msg"
    if (-not $script:SimMode) { try { $line | Out-File -FilePath $logPath -Append -Encoding utf8 } catch {} }
    if ($refs) {
        $palette = $refs.Theme.RainbowOnLog
        $refs.Window.Dispatcher.Invoke([action]{
            $prefixRun = New-Object System.Windows.Documents.Run("[$ts] ")
            $prefixRun.Foreground = New-Brush $refs.Theme.Muted
            $refs.LogText.Inlines.Add($prefixRun)
            for ($i = 0; $i -lt $msg.Length; $i++) {
                $run = New-Object System.Windows.Documents.Run([string]$msg[$i])
                $run.Foreground = New-Brush $palette[$i % $palette.Count]
                $refs.LogText.Inlines.Add($run)
            }
            $refs.LogText.Inlines.Add((New-Object System.Windows.Documents.Run("`n")))
            $refs.LogScroll.ScrollToBottom()
        })
    }
}

# ============================================================
# TASK SCHEDULER TRIGGER
# ============================================================
$script:TaskName = "CS2 Affinity Manager Trigger"

function Find-Cs2ExePath {
    $libraries = @()
    $steamPath = $null
    try { $steamPath = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -Name SteamPath -ErrorAction Stop).SteamPath -replace '/', '\' } catch {}
    if (-not $steamPath) { try { $steamPath = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -Name InstallPath -ErrorAction Stop).InstallPath } catch {} }
    if (-not $steamPath) { try { $steamPath = (Get-ItemProperty "HKLM:\SOFTWARE\Valve\Steam" -Name InstallPath -ErrorAction Stop).InstallPath } catch {} }
    if (-not $steamPath) { return $null }
    $libraries += $steamPath

    $vdfPath = Join-Path $steamPath "steamapps\libraryfolders.vdf"
    if (Test-Path $vdfPath) {
        $vdfMatches = [regex]::Matches((Get-Content $vdfPath -Raw), '"path"\s*"([^"]+)"')
        foreach ($m in $vdfMatches) {
            $lib = $m.Groups[1].Value -replace '\\\\', '\'
            if ($libraries -notcontains $lib) { $libraries += $lib }
        }
    }
    foreach ($lib in $libraries) {
        $dir = Join-Path $lib "steamapps\common\Counter-Strike Global Offensive\game\bin\win64"
        if (Test-Path $dir) {
            $exe = Get-ChildItem -Path $dir -Filter "cs2.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    return $null
}

function Install-CS2Trigger {
    param($refs)
    if ($script:SimMode) { return $false }
    $log = { param($m, $c = "") if ($refs) { Write-Log $refs $m $c } else { Write-Output $m } }
    try {
        & $log "Enabling process-creation auditing..."
        Start-Process -FilePath "$env:SystemRoot\System32\auditpol.exe" `
            -ArgumentList '/set','/subcategory:"Process Creation"','/success:enable' `
            -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null

        & $log "Removing any conflicting/stale Task Scheduler entry..."
        schtasks /Delete /TN $script:TaskName /F 2>$null | Out-Null
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue

        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $action  = New-ScheduledTaskAction -Execute $exePath -Argument "-background"

        $cs2Path = Find-Cs2ExePath
        if ($cs2Path) {
            & $log "Found cs2.exe at: $cs2Path" "muted"
            $safePath = $cs2Path -replace "'", ""
            $eventXml = "<QueryList><Query Id='0' Path='Security'><Select Path='Security'>*[System[(EventID=4688)]] and *[EventData[Data[@Name='NewProcessName']='$safePath']]</Select></Query></QueryList>"
            $cimClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
            $trigger  = New-CimInstance -CimClass $cimClass -ClientOnly
            $trigger.Subscription = $eventXml
            $trigger.Enabled = $true
        } else {
            & $log "Could not locate cs2.exe automatically - falling back to a 1-minute polling trigger." "warn"
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration ([TimeSpan]::MaxValue)
        }

        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

        & $log "Task Scheduler trigger installed/repaired successfully." "good"
        return $true
    } catch {
        & $log "Failed to install Task Scheduler trigger: $($_.Exception.Message)" "bad"
        return $false
    }
}

if ($installtask) { Install-CS2Trigger -refs $null | Out-Null; exit }

# ============================================================
# TRAY ICON
# ============================================================
function New-TrayIcon {
    param($refs)
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    try { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath) } catch { $icon = [System.Drawing.SystemIcons]::Application }

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = $icon
    $notify.Text = "CS2 Affinity Manager"
    $notify.Visible = $true

    $script:showAction = {
        # $script:refs, not the $refs parameter -- a theme change replaces
        # $script:refs with a new window. Reading the parameter here would
        # keep pointing at whatever window existed when the tray icon was
        # first built, i.e. a closed one after any rebuild.
        if ($script:refs) { $script:refs.Window.Show(); $script:refs.Window.WindowState = 'Normal'; $script:refs.Window.Activate() }
    }
    $notify.Add_DoubleClick($script:showAction)
    $notify.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $script:showAction } })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $show = $menu.Items.Add("Show Window"); $show.Add_Click($script:showAction)
    $menu.Items.Add("-") | Out-Null
    $openLog = $menu.Items.Add("Open Log File")
    $openLog.Add_Click({ if (Test-Path $logPath) { Start-Process notepad.exe $logPath } })
    $menu.Items.Add("-") | Out-Null
    $exit = $menu.Items.Add("Exit")
    $exit.Add_Click({ $script:trayNotify.Visible = $false; $script:trayNotify.Dispose(); $script:allowRealClose = $true; [System.Windows.Application]::Current.Shutdown() })
    $notify.ContextMenuStrip = $menu
    return $notify
}

# ============================================================
# THREAD RESOLUTION
# ------------------------------------------------------------
# Turns a saved config plus a live topology into the thread lists actually
# applied. Split out of the main flow so the simulator can call it and show
# exactly what the release build would do, without duplicating the logic.
# ============================================================
function Resolve-ActivePlan($topo, $config, $tiers, $recommendedTier, $supported) {
    $validCustom = {
        param($list)
        (@($list).Count -gt 0) -and (@($list | Where-Object { $_ -lt 0 -or $_ -ge $topo.Threads }).Count -eq 0)
    }

    if ($config.planTier -eq "Custom" -and (& $validCustom $config.customCs2Threads)) {
        $cs2 = @($config.customCs2Threads)
        $bg  = if (& $validCustom $config.customBgThreads) { @($config.customBgThreads) }
               else { @(0..($topo.Threads - 1) | Where-Object { $cs2 -notcontains $_ }) }
        return @{ CS2 = $cs2; BG = $bg; Name = "Custom" }
    }
    if ($supported -and $tiers.Contains([string]$config.planTier)) {
        $k = [string]$config.planTier
        return @{ CS2 = @($tiers[$k].CS2); BG = @($tiers[$k].BG); Name = $tiers[$k].Label }
    }
    if ($supported -and $tiers.Contains($recommendedTier)) {
        return @{ CS2 = @($tiers[$recommendedTier].CS2); BG = @($tiers[$recommendedTier].BG); Name = $tiers[$recommendedTier].Label }
    }
    return @{ CS2 = @(0..($topo.Threads - 1)); BG = @(); Name = "Balanced (fallback)" }
}

# Reduces a config to the only things the affinity engine actually acts on:
# the threads that end up pinned, the pinning mode, and the exception list.
#
# Compare THIS, not the raw config fields. A first-run config stores
# planTier "Auto" with empty thread lists, while the dialog always returns a
# resolved tier name and an explicit grid selection -- so a field-by-field
# comparison reported "settings changed, restart required" on the very first
# Save even when nothing was touched, and only that once, because the save
# rewrote the config into the resolved form the dialog returns.
#
# Resolving both sides through Resolve-ActivePlan makes the two spellings of
# the same plan compare equal, and still catches every change that genuinely
# alters what gets pinned.
function Get-PlanSignature($cfg, $topo) {
    $sup = Test-CpuSupported $topo
    $trs = if ($sup) { Get-TierDefinitions $topo } else { [ordered]@{} }
    $rec = if ($sup -and $trs.Count -gt 0) { Get-RecommendedTierName $topo $trs } else { "Custom" }
    $pl  = Resolve-ActivePlan $topo $cfg $trs $rec $sup
    $pin = if ([string]$cfg.pinningMode -in @("AffinityOnly", "PriorityOnly", "Both")) { [string]$cfg.pinningMode } else { "Both" }
    $exc = (@($cfg.userExceptions) | Sort-Object -Unique) -join ","
    return "$(@($pl.CS2) -join ',')|$(@($pl.BG) -join ',')|$pin|$exc"
}

# ============================================================
# MAIN STARTUP FLOW
# ============================================================
$script:topo = if ($script:SimMode) { Get-SimulatedTopology 0 } else { Get-CpuTopology }
$config      = Load-Config
$theme       = Resolve-Theme ([string]$config.theme)

if (-not $script:SimMode) {
    $hardwareChanged = ($config.savedCpuCores -gt 0 -and ($config.savedCpuCores -ne $script:topo.Cores -or $config.savedCpuThreads -ne $script:topo.Threads))
    if ($hardwareChanged) {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $msg = @"
CPU Hardware Change Detected

Previous: $($config.savedCpuCores) cores / $($config.savedCpuThreads) threads
Current:  $($script:topo.Cores) cores / $($script:topo.Threads) threads

Affinity settings need to be reconfigured for the new hardware.
"@
        [System.Windows.Forms.MessageBox]::Show($msg, "CS2 Affinity Manager - Hardware Change", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        $config.needsConfiguration = $true
        $config.planTier = "Auto"
        $config.customCs2Threads = @()
        $config.customBgThreads  = @()
    }
}

$supported = Test-CpuSupported $script:topo
$needsConfigNow = $script:SimMode -or $config.needsConfiguration -or $config.configPending -or $configureNow

if ($needsConfigNow) {
    try {
        $topoRef = [ref]$script:topo
        $result = Invoke-ConfigDialog -Owner $null -TopoRef $topoRef -config $config
        $script:topo = $topoRef.Value
        if (-not $result) {
            if (-not $script:SimMode) { $config.configPending = $true; Save-Config $config }
            exit
        }
        Save-Config $result
        $config = $result
        $theme  = Resolve-Theme ([string]$config.theme)
    } catch {
        if (-not $script:SimMode) { $config.configPending = $true; Save-Config $config }
        exit
    }
}

if (-not $script:SimMode -and $config.savedCpuCores -eq 0) {
    $config.savedCpuCores   = $script:topo.Cores
    $config.savedCpuThreads = $script:topo.Threads
    Save-Config $config
}

if ($quick) { exit }

# ---- Resolve the plan that will actually be applied ----
$topo      = $script:topo
$supported = Test-CpuSupported $topo
$tiers     = if ($supported) { Get-TierDefinitions $topo } else { [ordered]@{} }
$recTier   = if ($supported -and $tiers.Count -gt 0) { Get-RecommendedTierName $topo $tiers } else { "Custom" }
$plan      = Resolve-ActivePlan $topo $config $tiers $recTier $supported

$cs2ThreadList  = @($plan.CS2)
$bgThreadList   = @($plan.BG)
$activeTierName = $plan.Name

$pinningMode = $config.pinningMode
if ($pinningMode -notin @("AffinityOnly", "PriorityOnly", "Both")) { $pinningMode = "Both" }

$allExceptions = @($safeExceptions) + @($config.userExceptions) | Select-Object -Unique
$cs2Mask   = Build-MaskFromList $cs2ThreadList
$bgMask    = Build-MaskFromList $bgThreadList
$hasBgMask = (@($bgThreadList | Where-Object { $_ -le $script:MaxAffinityBit }).Count -gt 0)
$cs2Range  = "threads " + (Format-ThreadRanges $cs2ThreadList)
$bgRange   = if ($hasBgMask) { "threads " + (Format-ThreadRanges $bgThreadList) } else { "none" }

function Get-PinModeLabel($p, $a, $b) {
    switch ($p) { "AffinityOnly" { $a }; "PriorityOnly" { $b }; default { "$a  $b" } }
}

$script:refs = Show-LogWindow -topo $topo -activeTierName $activeTierName -pinningMode $pinningMode `
                              -cs2Range $cs2Range -bgRange $bgRange -theme $theme

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

# BtnConfigure and BtnRepairTask get re-wired here so the same function works
# right after startup and again after a theme-only rebuild replaces the
# window (a fresh window means fresh buttons with no handlers yet).
function Wire-LogWindowHandlers {
    $script:refs.BtnConfigure.Add_Click({
        $liveConfig = $(if ($script:SimMode) { $config } else { Load-Config })
        $topoRef = [ref]$script:topo
        $result = Invoke-ConfigDialog -Owner $script:refs.Window -TopoRef $topoRef -config $liveConfig
        $script:topo = $topoRef.Value
        if ($result) {
            Save-Config $result

            # Affinity/tier/pinning changes affect threads that may already be
            # pinned for a running game, so those still need a restart --
            # unchanged, deliberate behaviour. Theme is purely cosmetic, so if
            # it's the ONLY thing that changed, just repaint instead of making
            # the person close and relaunch for a colour swap.
            $themeChanged = ($result.theme -ne $liveConfig.theme)
            $otherChanged = (Get-PlanSignature $result $script:topo) -ne (Get-PlanSignature $liveConfig $script:topo)

            if ($themeChanged -and -not $otherChanged) {
                $newTheme = Resolve-Theme ([string]$result.theme)
                $script:allowRealClose = $true
                $script:refs.Window.Close()
                $script:allowRealClose = $false
                $script:refs = Show-LogWindow -topo $script:topo -activeTierName $activeTierName -pinningMode $pinningMode `
                                              -cs2Range $cs2Range -bgRange $bgRange -theme $newTheme
                Wire-LogWindowHandlers
                $script:refs.Window.Show()
                Write-Log $script:refs "Theme changed to $($newTheme.Name)." "accent"
                if ($script:waitingForCs2 -eq $false) {
                    $script:refs.InfoStatus.Text = "Running"
                    $script:refs.InfoStatus.Foreground = New-Brush $script:refs.Theme.GoodOnPanel
                }
            } elseif ($otherChanged) {
                # Affinity/priority changes can't be repainted in place like a
                # theme can -- they only take effect from a fresh start. Ask
                # before doing it anyway, since it interrupts whatever the
                # tray icon was quietly doing in the background.
                if ($script:SimMode) {
                    $script:configPending = $true
                    Write-Log $script:refs "Configuration saved. Restart CS2 Affinity Manager for it to take effect." "accent"
                } else {
                    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
                    $go = [System.Windows.Forms.MessageBox]::Show(
                        "Affinity and priority settings changed. CS2 Affinity Manager needs to restart for them to take effect.`n`nRestart now?",
                        "CS2 Affinity Manager - Restart Required", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                    if ($go -eq [System.Windows.Forms.DialogResult]::Yes) {
                        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                        try {
                            # -awaitPid: tell the new instance to wait for this
                            # one to die before it runs its single-instance
                            # check, or it will mistake us for a duplicate.
                            Start-Process -FilePath $exePath -ArgumentList "-awaitPid", $PID
                            if ($script:trayNotify) { $script:trayNotify.Visible = $false; $script:trayNotify.Dispose() }
                            $script:allowRealClose = $true
                            [System.Windows.Application]::Current.Shutdown()
                            return
                        } catch {
                            Write-Log $script:refs "Couldn't relaunch automatically ($($_.Exception.Message)) -- restart manually." "bad"
                        }
                    }
                    $script:configPending = $true
                    Write-Log $script:refs "Configuration saved. Restart CS2 Affinity Manager for it to take effect." "accent"
                }
            } else {
                Write-Log $script:refs "No changes to save." "muted"
            }
            if ($script:SimMode) {
                Write-Log $script:refs "(Simulation -- nothing was written to disk.)" "muted"
                Show-SimReport $result
            }
        }
    })

    $script:refs.BtnRepairTask.Add_Click({
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $go = [System.Windows.Forms.MessageBox]::Show(
            "This removes any existing '$($script:TaskName)' scheduled task and recreates it so CS2 Affinity Manager auto-launches when cs2.exe starts. Continue?",
            "Repair Auto-Start Trigger", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($go -eq [System.Windows.Forms.DialogResult]::Yes) { Install-CS2Trigger -refs $script:refs | Out-Null }
    })
}
Wire-LogWindowHandlers

# ============================================================
# SIMULATION REPORT
# ------------------------------------------------------------
# Prints exactly what the release build would compute for the currently
# simulated CPU: chosen profile, thread ranges, the raw 64-bit affinity
# masks, and any gating that kicked in. This is the thing to eyeball when
# checking whether a given CPU shape produces a sane default.
# ============================================================
function Show-SimReport($cfg) {
    $tp  = $script:topo
    $sup = Test-CpuSupported $tp
    $tr  = if ($sup) { Get-TierDefinitions $tp } else { [ordered]@{} }
    $rec = if ($sup -and $tr.Count -gt 0) { Get-RecommendedTierName $tp $tr } else { "Custom" }
    $pl  = Resolve-ActivePlan $tp $cfg $tr $rec $sup

    Write-RainbowLog $script:refs "--- Simulated: $($tp.Name) ---"
    Write-Log $script:refs "  Topology       : $($tp.Cores)c / $($tp.Threads)t   SMT=$($tp.ThreadsPerCore)   Hybrid=$($tp.IsHybrid)   MultiCCD=$($tp.IsMultiCcd)"
    if ($tp.IsHybrid)   { Write-Log $script:refs "  Hybrid split   : $($tp.PCores) P-cores ($($tp.PThreads) threads) + $($tp.ECores) E-cores" }
    if ($tp.IsMultiCcd) { Write-Log $script:refs "  Chiplets       : $($tp.CcdCount) CCDs x $($tp.CcdSize) cores  ->  CCD0 is threads 0-$(($tp.CcdSize * $tp.ThreadsPerCore) - 1)" }
    Write-Log $script:refs "  Reserved       : thread 0 (core 0)"
    if ($tp.IsHybrid)   { Write-Log $script:refs "  Hybrid layout  : $($tp.PCores) P-cores ($($tp.PThreads) threads) + $($tp.ECores) E-cores" }
    if ($tp.IsMultiCcd) { Write-Log $script:refs "  Chiplets       : $($tp.CcdCount) x $($tp.CcdSize)-core CCD" }
    Write-Log $script:refs "  Supported      : $sup" $(if ($sup) { "good" } else { "warn" })
    Write-Log $script:refs "  Profiles       : $(if ($tr.Count) { (@($tr.Keys) -join ', ') } else { 'none (Custom only)' })"
    Write-Log $script:refs "  Recommended    : $rec" "accent"
    Write-Log $script:refs "  Active profile : $($pl.Name)"
    Write-Log $script:refs "  CS2 threads    : $(Format-ThreadRanges $pl.CS2)   [$(@($pl.CS2).Count) threads]" "good"
    Write-Log $script:refs "  BG threads     : $(Format-ThreadRanges $pl.BG)   [$(@($pl.BG).Count) threads]" "bad"
    $m1 = Build-MaskFromList $pl.CS2
    $m2 = Build-MaskFromList $pl.BG
    Write-Log $script:refs ("  CS2 mask       : 0x{0:X}" -f [int64]$m1) "muted"
    Write-Log $script:refs ("  BG mask        : 0x{0:X}" -f [int64]$m2) "muted"
    if (Test-MaskTruncation $pl.CS2) {
        Write-Log $script:refs "  WARNING: CS2 selection includes threads above 63. Windows affinity masks address one 64-thread processor group only; those threads are dropped." "warn"
    }
    Write-Log $script:refs ""
}

if ($script:SimMode) {
    # ---- SIMULATION: report only, never touch a real process ----
    Write-RainbowLog $script:refs "CS2 Affinity Manager -- SIMULATION BUILD"
    Write-Log $script:refs "No affinity is applied, no config is written, no scheduled task is touched." "warn"
    Write-Log $script:refs "Use Configure... to cycle simulated CPUs and inspect what each one would get." "muted"
    Write-Log $script:refs ""
    Show-SimReport $config
    $script:refs.Window.Show()
    $app.Run() | Out-Null
    exit
}

# ============================================================
# LIVE AFFINITY ENGINE
# ============================================================
$script:trayNotify    = New-TrayIcon -refs $script:refs
$script:configPending = $false
try { $script:showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $script:ShowEventName) } catch { $script:showEvent = $null }

Write-RainbowLog $script:refs "CS2 Affinity Manager started."
# Print the detected layout and, critically, WHERE it came from. If a CPU is
# ever mis-detected this line says whether the curated table, Windows, or the
# fallback heuristic produced the answer -- which is the difference between a
# missing table entry and an actual logic bug.
$layoutBits = @("$($topo.Cores)c/$($topo.Threads)t", "SMT x$($topo.ThreadsPerCore)")
if ($topo.IsHybrid)   { $layoutBits += "$($topo.PCores)P+$($topo.ECores)E" }
if ($topo.IsMultiCcd) { $layoutBits += "$($topo.CcdCount) CCDs x $($topo.CcdSize) cores" }
$srcLabel = switch ([string]$topo.LayoutSource) {
    "database" { "CPU table" }
    "windows"  { "Windows topology API" }
    "supplied" { "simulated" }
    default    { "heuristic (CPU not in table)" }
}
Write-Log $script:refs "CPU: $($topo.Name)"
Write-Log $script:refs "Layout: $($layoutBits -join '  |  ')   (source: $srcLabel)" "muted"
Write-Log $script:refs "Reserved for Windows: thread 0" "muted"
Write-Log $script:refs "Profile: $activeTierName | Pinning: $pinningMode | Theme: $($theme.Name)"
if (Test-MaskTruncation $cs2ThreadList) {
    Write-Log $script:refs "Note: threads above index 63 were dropped -- a Windows affinity mask covers one 64-thread processor group." "warn"
}

function Apply-AffinitySnapshot {
    param($bgMask, $hasBgMask, $allExceptions, $pinningMode, $bgRange)
    if (-not $hasBgMask) { return }
    $allProcesses = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $allExceptions -and $_.Path -and ($_.Path -notlike "$([regex]::Escape($env:SystemRoot))\*") } |
        Select-Object Name, Id, @{ Name = "CpuRate"; Expression = {
            # Accumulated CPU seconds divided by wall-clock seconds since the
            # process started -- i.e. average cores consumed over its lifetime.
            $age = (New-TimeSpan -Start $_.StartTime).TotalSeconds
            if ($age -gt 0) { $_.CPU / $age } else { 0 }
        }}

    if (-not $allProcesses) {
        Write-Log $script:refs "  (no background processes to isolate)" "muted"
        return
    }

    $topGroups = $allProcesses | Group-Object -Property Name |
        Select-Object Name, @{ N = "TotalCpuRate"; E = { ($_.Group | Measure-Object -Property CpuRate -Sum).Sum } }, Group |
        Sort-Object TotalCpuRate -Descending | Select-Object -First 10

    foreach ($group in $topGroups) {
        $displayName = if ($group.Group.Count -gt 1) { "$($group.Name) ($($group.Group.Count))" } else { $group.Name }
        foreach ($item in $group.Group) {
            $p = Get-Process -Id $item.Id -ErrorAction SilentlyContinue
            if ($p) {
                try {
                    if ($pinningMode -ne "PriorityOnly") { $p.ProcessorAffinity = $bgMask }
                    if ($pinningMode -ne "AffinityOnly") { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
                } catch {}
            }
        }
        Write-Log $script:refs ("  {0,-28} {1}" -f $displayName, (Get-PinModeLabel $pinningMode "affinity=$bgRange" "priority=BelowNormal"))
    }
}

$dispatcherTimer = New-Object System.Windows.Threading.DispatcherTimer
$dispatcherTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
$script:passNum = 1
$script:waitingForCs2 = $true
$script:secondsUntilNextPass = 0

function Invoke-AffinityPass($cs2Procs) {
    Write-RainbowLog $script:refs "--- Pass $($script:passNum) ---"
    foreach ($p in $cs2Procs) {
        try {
            if ($pinningMode -ne "PriorityOnly") { $p.ProcessorAffinity = $cs2Mask }
            if ($pinningMode -ne "AffinityOnly") { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High }
            Write-Log $script:refs "  $gameProcess.exe (PID $($p.Id))  $(Get-PinModeLabel $pinningMode "affinity=$cs2Range" "priority=High")"
        } catch {}
    }
    Apply-AffinitySnapshot -bgMask $bgMask -hasBgMask $hasBgMask -allExceptions $allExceptions -pinningMode $pinningMode -bgRange $bgRange
    $script:secondsUntilNextPass = 300
    $script:passNum++
}

$dispatcherTimer.Add_Tick({
    if ($script:showEvent -and $script:showEvent.WaitOne(0)) { & $script:showAction }

    if ($script:configPending) {
        Write-Log $script:refs "Configuration changed -- please restart CS2 Affinity Manager." "warn"
        $dispatcherTimer.Stop()
        return
    }

    if ($script:waitingForCs2) {
        $cs2 = Get-Process -Name $gameProcess -ErrorAction SilentlyContinue
        if ($cs2) {
            $script:waitingForCs2 = $false
            $script:refs.InfoStatus.Text = "Running"
            $script:refs.InfoStatus.Foreground = New-Brush $script:refs.Theme.GoodOnPanel
            Write-Log $script:refs "$gameProcess.exe detected." "good"
            Invoke-AffinityPass $cs2
        }
        return
    }

    $cs2 = Get-Process -Name $gameProcess -ErrorAction SilentlyContinue
    if (-not $cs2) {
        Write-Log $script:refs "$gameProcess.exe closed. Exiting."
        $dispatcherTimer.Stop()
        if ($script:trayNotify) { $script:trayNotify.Visible = $false; $script:trayNotify.Dispose() }
        $script:allowRealClose = $true
        [System.Windows.Application]::Current.Shutdown()
        return
    }

    $script:secondsUntilNextPass--
    if ($script:secondsUntilNextPass -le 0) { Invoke-AffinityPass $cs2 }
})

$dispatcherTimer.Start()
# -background is what the Task Scheduler trigger passes when it fires on
# cs2.exe starting. Start in the tray instead of throwing a window over the
# game that just launched; the tray icon (or launching the app again) brings
# it up. The switch was previously accepted and then ignored, so the window
# appeared mid-game every single time the trigger fired.
if (-not $background) { $script:refs.Window.Show() }
$app.Run() | Out-Null
