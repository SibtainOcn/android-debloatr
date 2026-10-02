<#
=====================================================================
 ANDROID PACKAGE REMOVER v2  -  no root, Android 9 - 16
=====================================================================
 Removes / disables / restores ANY packages you give it. Nothing is
 blocked; core-OS packages, your current launcher and keyboard only
 trigger a warning.

 Uninstall strategy (decided per package from live device state):
   user app (/data)          pm uninstall <pkg>            -> PERMANENT
   updated system app        pm uninstall <pkg>            (strip updates)
                             pm uninstall --user 0 <pkg>   -> removed for you
   system app                pm uninstall --user 0 <pkg>   -> removed for you
 System APKs live on read-only /system; deleting the file itself needs
 root. "Removed for you" = gone from the phone, no RAM/CPU/battery use,
 restorable with -Mode Restore (or a factory reset).

 All commands run on the device in ONE batch (push + sh) and the result
 is verified afterwards against a fresh package list.

 Usage
   .\remover.ps1 -Packages com.a,com.b            uninstall
   .\remover.ps1 -ListFile list.txt               one package per line, # = comment
   .\remover.ps1 -Packages com.a -DryRun          show the plan only
   .\remover.ps1 -Packages com.a -Mode Disable    pm disable-user (keeps APK + data)
   .\remover.ps1 -Packages com.a -Mode Restore    bring back removed/disabled apps
   .\remover.ps1 ... -KeepData                    uninstall with -k (faster restore)
   .\remover.ps1 ... -Serial <id>                 choose device
   .\remover.ps1 ... -LogDir <dir>                where logs go (default output\logs)
   .\remover.ps1 -h                               this help
=====================================================================
#>
param(
    [Alias('h')][switch]$Help,
    [string[]]$Packages,
    [string]$ListFile,
    [ValidateSet('Uninstall', 'Disable', 'Restore')][string]$Mode = 'Uninstall',
    [string]$Serial,
    [switch]$DryRun,
    [switch]$KeepData,
    [string]$LogDir = (Join-Path $PSScriptRoot '..\output\logs')
)

if ($Help) {
    if ((Get-Content -Raw $PSCommandPath) -match '(?s)<#(.*?)#>') { Write-Host $Matches[1].Trim() }
    exit 0
}

$ErrorActionPreference = 'Continue'

# Core packages: removing these can break boot/UI. Warning only.
$Critical = @(
    'android', 'com.android.systemui', 'com.android.settings', 'com.android.phone', 'com.android.shell',
    'com.android.packageinstaller', 'com.google.android.packageinstaller',
    'com.android.permissioncontroller', 'com.google.android.permissioncontroller',
    'com.google.android.gms', 'com.google.android.gsf', 'com.android.server.telecom',
    'com.android.bluetooth', 'com.google.android.bluetooth', 'com.android.inputdevices', 'com.android.keychain',
    'com.android.externalstorage', 'com.android.location.fused', 'com.google.android.webview',
    'com.google.android.ext.services', 'com.google.android.ext.shared', 'com.android.se',
    'com.android.networkstack', 'com.google.android.networkstack', 'com.android.providers.settings',
    'com.android.providers.media', 'com.google.android.providers.media.module', 'com.android.providers.telephony'
)

function Write-Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }

function Get-AdbDevices {
    $list = @()
    foreach ($line in (& adb devices -l 2>$null)) {
        if ($line -match '^(\S+)\s+(device|unauthorized|offline|recovery|sideload|bootloader|no permissions)\b') {
            $list += [pscustomobject]@{ serial = $Matches[1]; state = $Matches[2] }
        }
    }
    return , $list
}

function Resolve-Device([string]$Wanted) {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { Write-Fail 'adb not found in PATH. Install Android platform-tools.'; exit 2 }
    $devs = Get-AdbDevices
    for ($try = 0; $try -lt 5 -and -not ($devs | Where-Object state -eq 'device'); $try++) {
        & adb start-server 2>$null | Out-Null
        Start-Sleep -Seconds 2
        $devs = Get-AdbDevices
    }
    if ($Wanted) { $d = $devs | Where-Object serial -eq $Wanted | Select-Object -First 1 }
    else {
        $ready = @($devs | Where-Object state -eq 'device')
        if ($ready.Count -gt 1) { Write-Fail "Several devices connected - pass -Serial: $(($ready.serial) -join ', ')"; exit 2 }
        $d = if ($ready.Count -eq 1) { $ready[0] } else { $devs | Select-Object -First 1 }
    }
    if (-not $d) { Write-Fail 'No device found. Enable USB debugging and connect the device.'; exit 2 }
    if ($d.state -ne 'device') { Write-Fail "Device state is '$($d.state)' (accept the USB debugging prompt / boot into Android)."; exit 2 }
    return $d.serial
}

function Get-State {
    $remote = 'echo @@USER; pm list packages --user 0 -f; echo @@ALL; pm list packages -u; echo @@SYS; pm list packages -s -u; ' +
              'echo @@DIS; pm list packages -d --user 0; ' +
              'echo @@HOME; cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME; ' +
              'echo @@IME; settings get secure default_input_method; echo @@END'
    $s = @{ User = @{}; All = @{}; Sys = @{}; Dis = @{}; Home = ''; Ime = '' }
    $section = ''
    foreach ($line in (& adb @AdbArgs shell $remote 2>&1)) {
        $l = "$line".Trim()
        if ($l -like '@@*') { $section = $l.Substring(2); continue }
        if (-not $l) { continue }
        switch ($section) {
            'USER' { if ($l -match '^package:(.*)=([^=\s]+)$') { $s.User[$Matches[2]] = $Matches[1] } elseif ($l -match '^package:(\S+)$') { $s.User[$Matches[1]] = '' } }
            'ALL'  { if ($l -match '^package:(\S+)') { $s.All[$Matches[1]] = $true } }
            'SYS'  { if ($l -match '^package:(\S+)') { $s.Sys[$Matches[1]] = $true } }
            'DIS'  { if ($l -match '^package:(\S+)') { $s.Dis[$Matches[1]] = $true } }
            'HOME' { if ($l -match '^([\w.]+)/') { $s.Home = $Matches[1] } }
            'IME'  { if ($l -match '^([\w.]+)/') { $s.Ime = $Matches[1] } }
        }
    }
    return $s
}

# ---------------------------------------------------------------------
# Collect package names (args, comma/space separated strings, list file)
# ---------------------------------------------------------------------
$names = New-Object System.Collections.Generic.List[string]
foreach ($p in $Packages) { foreach ($x in ("$p" -split '[,;\s]+')) { if ($x) { $names.Add($x) } } }
if ($ListFile) {
    if (-not (Test-Path $ListFile)) { Write-Fail "List file not found: $ListFile"; exit 2 }
    foreach ($line in (Get-Content $ListFile)) {
        $t = ($line -replace '#.*$', '').Trim().Trim("'", '"', ',')
        if ($t) { $names.Add($t) }
    }
}
$names = @($names | Select-Object -Unique)
$bad = @($names | Where-Object { $_ -notmatch '^[A-Za-z][\w]*(\.[\w]+)*$' })
if ($bad.Count) { Write-Warn "Ignoring invalid package names: $($bad -join ', ')" }
$names = @($names | Where-Object { $_ -match '^[A-Za-z][\w]*(\.[\w]+)*$' })
if ($names.Count -eq 0) { Write-Fail 'No packages given. Use -Packages or -ListFile.'; exit 2 }

Write-Host ''
Write-Host "=== $($Mode.ToUpper())$(if ($DryRun) { ' (DRY RUN)' }) - $($names.Count) package(s) ===" -ForegroundColor Yellow

$Serial = Resolve-Device $Serial
$AdbArgs = @('-s', $Serial)
$before = Get-State
Write-Host "  Device $Serial | $($before.User.Count) packages installed for user 0" -ForegroundColor Gray

# ---------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------
$k = if ($KeepData) { '-k ' } else { '' }
$plan = @(); $results = @()
foreach ($n in $names) {
    $installed = $before.User.ContainsKey($n)
    $known = $before.All.ContainsKey($n)
    $isSys = $before.Sys.ContainsKey($n)
    $updated = $isSys -and $installed -and ($before.User[$n] -like '/data/*')
    $kind = if (-not $isSys) { 'user app' } elseif ($updated) { 'updated system' } else { 'system' }
    $cmds = @(); $skip = $null

    switch ($Mode) {
        'Uninstall' {
            if (-not $known) { $skip = 'not on device' }
            elseif (-not $installed) { $skip = 'already removed' }
            elseif (-not $isSys) {
                # full uninstall; if the ROM refuses (misreported system app) fall back to user 0
                $cmds = @("r=`$(pm uninstall $k$n 2>&1); echo `"`$r`"; case `"`$r`" in *Success*) ;; *) pm uninstall $k--user 0 $n ;; esac")
            }
            elseif ($updated) { $cmds = @("pm uninstall $n", "pm uninstall $k--user 0 $n") }
            else { $cmds = @("pm uninstall $k--user 0 $n") }
        }
        'Disable' {
            if (-not $installed) { $skip = $(if ($known) { 'removed (restore first)' } else { 'not on device' }) }
            elseif ($before.Dis.ContainsKey($n)) { $skip = 'already disabled' }
            else { $cmds = @("pm disable-user --user 0 $n") }
        }
        'Restore' {
            if (-not $known) { $skip = 'APK no longer on device - reinstall it from a store/APK' }
            else {
                if (-not $installed) { $cmds += "pm install-existing --user 0 $n" }
                if ($before.Dis.ContainsKey($n) -or -not $installed) { $cmds += "pm enable --user 0 $n" }
                if ($cmds.Count -eq 0) { $skip = 'already installed and enabled' }
            }
        }
    }

    if ($Mode -ne 'Restore' -and -not $skip) {
        if ($Critical -contains $n -or $n -like 'com.android.providers.*') { Write-Warn "$n is core OS - removal may break boot/UI (recover: factory reset)" }
        if ($n -eq $before.Home) { Write-Warn "$n is your CURRENT LAUNCHER - set another launcher first or you'll get a black home screen" }
        if ($n -eq $before.Ime) { Write-Warn "$n is your CURRENT KEYBOARD - switch keyboard first" }
    }

    if ($skip) { $results += [pscustomobject]@{ package = $n; kind = $kind; result = 'skipped'; detail = $skip } }
    else { $plan += [pscustomobject]@{ package = $n; kind = $kind; cmds = $cmds } }
}

if ($DryRun) {
    Write-Host ''
    foreach ($p in $plan) {
        $desc = ($p.cmds | ForEach-Object { if ($_ -like 'r=*') { "pm uninstall $k$($p.package) (fallback --user 0)" } else { $_ } }) -join ' ; '
        Write-Host ('  {0,-55} {1,-15} {2}' -f $p.package, $p.kind, $desc) -ForegroundColor Cyan
    }
    foreach ($r in $results) { Write-Host ('  {0,-55} {1,-15} skip: {2}' -f $r.package, $r.kind, $r.detail) -ForegroundColor DarkGray }
    Write-Host "`n  DRY RUN: $($plan.Count) to process, $($results.Count) skipped. Nothing was changed." -ForegroundColor Yellow
    $summary = [ordered]@{ mode = $Mode; dryRun = $true; planned = @($plan.package); skipped = $results }
    Write-Host ('@@SUMMARY=' + (ConvertTo-Json -InputObject $summary -Depth 4 -Compress))
    exit 0
}

# ---------------------------------------------------------------------
# Execute: one shell script pushed + run on the device
# ---------------------------------------------------------------------
if ($plan.Count -gt 0) {
    $sh = New-Object System.Collections.Generic.List[string]
    $sh.Add('#!/system/bin/sh')
    foreach ($p in $plan) {
        $sh.Add("echo '@@PKG $($p.package)'")
        foreach ($c in $p.cmds) { $sh.Add("$c 2>&1") }
    }
    $sh.Add("echo '@@DONE'")
    $local = Join-Path ([IO.Path]::GetTempPath()) "debloat_$PID.sh"
    $remoteSh = "/data/local/tmp/debloat_$PID.sh"
    [IO.File]::WriteAllText($local, (($sh -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    $pushed = & adb @AdbArgs push $local $remoteSh 2>&1
    Remove-Item $local -ErrorAction SilentlyContinue
    $i = 0; $total = $plan.Count
    Write-Host ''
    if ($LASTEXITCODE -eq 0) {
        & adb @AdbArgs shell sh $remoteSh 2>&1 | ForEach-Object {
            $l = "$_".Trim()
            if ($l -match '^@@PKG (.+)$') { $i++; Write-Host "[$i/$total] $($Matches[1])" -ForegroundColor Cyan }
            elseif ($l -and $l -ne '@@DONE') { Write-Host "    $l" -ForegroundColor DarkGray }
        }
        & adb @AdbArgs shell rm -f $remoteSh 2>&1 | Out-Null
    } else {
        # Fallback: one adb call per command
        Write-Warn "push failed ($pushed) - running commands one by one"
        foreach ($p in $plan) {
            $i++; Write-Host "[$i/$total] $($p.package)" -ForegroundColor Cyan
            foreach ($c in $p.cmds) { & adb @AdbArgs shell $c 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
        }
    }
}

# ---------------------------------------------------------------------
# Verify against a fresh package list
# ---------------------------------------------------------------------
$after = Get-State
foreach ($p in $plan) {
    $n = $p.package
    $res = 'failed'; $detail = ''
    switch ($Mode) {
        'Uninstall' {
            if (-not $after.All.ContainsKey($n)) { $res = 'permanent'; $detail = 'fully uninstalled' }
            elseif (-not $after.User.ContainsKey($n)) { $res = 'removed'; $detail = 'removed for user 0 (restorable)' }
            else { $detail = 'still installed' }
        }
        'Disable' { if ($after.Dis.ContainsKey($n)) { $res = 'disabled' } else { $detail = 'still enabled' } }
        'Restore' { if ($after.User.ContainsKey($n) -and -not $after.Dis.ContainsKey($n)) { $res = 'restored' } else { $detail = 'not restored' } }
    }
    $results += [pscustomobject]@{ package = $n; kind = $p.kind; result = $res; detail = $detail }
}

Write-Host ''
$colors = @{ permanent = 'Green'; removed = 'Green'; disabled = 'Green'; restored = 'Green'; skipped = 'DarkGray'; failed = 'Red' }
foreach ($r in $results) { Write-Host ('  {0,-10} {1,-55} {2}' -f $r.result.ToUpper(), $r.package, $r.detail) -ForegroundColor $colors[$r.result] }

$count = @{}; foreach ($r in $results) { $count[$r.result] = 1 + [int]$count[$r.result] }
$line = ($count.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  '
Write-Host "`nDONE ($Mode): $line  total=$($results.Count)" -ForegroundColor Yellow

$LogDir = (New-Item -ItemType Directory -Force $LogDir).FullName
$log =Join-Path $LogDir ("{0}_{1}_{2}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $Mode.ToLower(), ($Serial -replace '[^\w-]', '-'))
$results | ForEach-Object { $_.result, $_.package, $_.kind, $_.detail -join "`t" } | Set-Content -Encoding UTF8 $log
Write-Host "  Log: $log" -ForegroundColor Gray

$summary = [ordered]@{ mode = $Mode; dryRun = $false; counts = $count; results = $results; log = $log }
Write-Host ('@@SUMMARY=' + (ConvertTo-Json -InputObject $summary -Depth 4 -Compress))
if ($count['failed']) { exit 1 } else { exit 0 }
