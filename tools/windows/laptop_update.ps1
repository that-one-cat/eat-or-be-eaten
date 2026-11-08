# Runs ON Robert's laptop (invoked over SSH by deploy_to_robert.sh): unpack the new source, import, optionally test,
# export the release build, publish it to the desktop. Windows PowerShell 5.1 compatible.
# Contract and gotchas: docs/WINDOWS_BUILD.md.
param(
    [switch]$RunTests,
    [string]$Commit = 'unknown'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PinnedGodot = '4.7.2'                                   # project pin (CLAUDE.md); must match the export templates
$Godot   = 'C:\Godot\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe'
$Root    = 'D:\Dev\Eat Or Be Eaten'
$Deploy  = 'C:\Godot\_deploy'
$Desktop = 'C:\Users\ThinkPad\Desktop\Eat Or Be Eaten'
$Zip     = Join-Path $Deploy 'fg.zip'

function Fail([string]$msg) { Write-Output "FAILED: $msg"; exit 1 }
function Tail-Log([string]$path, [int]$n = 25) { if (Test-Path $path) { Get-Content $path -Tail $n } }

# --- preflight -------------------------------------------------------------------------------------------------
if (-not (Test-Path 'D:\')) { Fail 'drive D: (Kintamania) is not mounted - see docs/WINDOWS_BUILD.md "D: missing"' }
if (-not (Test-Path $Godot)) { Fail "Godot editor not found: $Godot" }
$ver = (& $Godot --version) | Select-Object -First 1
if (-not $ver.StartsWith($PinnedGodot)) { Fail "Godot is '$ver', the project pin is $PinnedGodot" }
$tpl = Join-Path $env:APPDATA "Godot\export_templates\$PinnedGodot.stable\windows_release_x86_64.exe"
if (-not (Test-Path $tpl)) { Fail "export template missing: $tpl" }
if (-not (Test-Path $Zip)) { Fail "source archive not uploaded: $Zip" }
"godot: $ver"

# --- unpack (keep .godot: the import cache makes re-imports incremental) ------------------------------------------
New-Item -ItemType Directory -Force $Root | Out-Null
foreach ($d in 'game', 'tools') {
    $p = Join-Path $Root $d
    if (Test-Path $p) { Get-ChildItem $p -Force | Where-Object { $_.Name -ne '.godot' } | Remove-Item -Recurse -Force }
}
& tar.exe -xf $Zip -C $Root
if ($LASTEXITCODE -ne 0) { Fail 'tar failed to unpack the archive' }
Remove-Item $Zip -Force
"unpacked commit $Commit into $Root"

# --- import ------------------------------------------------------------------------------------------------------
$log = Join-Path $Root 'build_import.log'
New-Item -ItemType Directory -Force (Join-Path $Root 'build\windows') | Out-Null
& $Godot --headless --path "$Root\game" --import *> $log
& $Godot --headless --path "$Root\game" --quit *> $log
if ($LASTEXITCODE -ne 0 -or -not (Select-String -Path $log -Pattern 'boot OK' -Quiet)) { Tail-Log $log; Fail 'load check failed after import' }
"import + load check OK"

# --- tests (optional, slow on the laptop: well over 10 min) -----------------------------------------------------------------------
if ($RunTests) {
    $tlog = Join-Path $Root 'build_tests.log'
    & $Godot --headless --path "$Root\game" --script res://tests/run_tests.gd *> $tlog
    $line = Select-String -Path $tlog -Pattern '^TESTS:' | Select-Object -Last 1
    "tests: $($line.Line)"
    if (-not $line -or $line.Line -notmatch ' 0 failed') { Select-String -Path $tlog -Pattern '^FAIL' | Select-Object -First 20 | ForEach-Object { $_.Line }; Fail 'tests failed' }
}

# --- export ------------------------------------------------------------------------------------------------------
$out = Join-Path $Root 'build\windows\FishGame.exe'
$started = Get-Date
$elog = Join-Path $Root 'build_export.log'
# Playtest preset = the release preset + the `god_menu` feature tag (God menu / console for the Director's playtests).
# The shipping preset `Windows Desktop` has no tag and must stay the one used for any public build.
$Preset = 'Windows Playtest'
& $Godot --headless --path "$Root\game" --export-release $Preset '../build/windows/FishGame.exe' *> $elog
if (-not (Test-Path $out) -or (Get-Item $out).LastWriteTime -lt $started) { Tail-Log $elog; Fail 'export did not produce a fresh FishGame.exe' }
"exported: {0:N1} MB" -f ((Get-Item $out).Length / 1MB)

# --- smoke: the release build must boot headless -------------------------------------------------------------------
$boot = & (Join-Path $Root 'build\windows\FishGame.console.exe') --headless --quit 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $boot -notmatch 'boot OK') { Fail "release build did not boot: $boot" }
"release build boots OK"

# --- publish to the desktop ----------------------------------------------------------------------------------------
New-Item -ItemType Directory -Force $Desktop | Out-Null
try { Copy-Item $out (Join-Path $Desktop 'Eat Or Be Eaten.exe') -Force }
catch { Fail 'cannot overwrite the desktop exe - the game is probably running; close it and rerun' }
Set-Content (Join-Path $Desktop 'Play (weak PC mode).bat') "@echo off`r`ncd /d `"%~dp0`"`r`nstart `"`" `"Eat Or Be Eaten.exe`" --rendering-method gl_compatibility -- --quality=low" -Encoding ASCII
Set-Content (Join-Path $Desktop 'build-info.txt') ("commit: $Commit`r`nbuilt: {0:yyyy-MM-dd HH:mm}`r`ngodot: $ver`r`npreset: $Preset (god_menu)" -f (Get-Date)) -Encoding ASCII
"published to $Desktop"
"DONE commit=$Commit"
