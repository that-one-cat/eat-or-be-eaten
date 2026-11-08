@echo off
rem run_benchmarks.bat - Fish Game benchmarks on a Windows machine with the exported build (no Godot editor needed).
rem
rem Usage:  run_benchmarks.bat [path\to\FishGame.exe]
rem         (default: FishGame.exe next to this script; copy the script into the export folder and double-click it)
rem Env:    SIM_TICKS=<n> (default 1800), CROWD_FRAMES=<n> (default 3600), RESOLUTION=<WxH> (default 1920x1080)
rem
rem Runs four benches one after another (about 5-8 minutes; keep the laptop on mains power, the screen awake and
rem the game window in front, do not touch the mouse while the crowd benches run):
rem   1. sim             headless sim tick bench          -- --bench=sim --frames=%SIM_TICKS%
rem   2. crowd_high      windowed crowd bench, high tier  -- --bench=crowd --frames=%CROWD_FRAMES% --quality=high
rem   3. crowd_low       windowed crowd bench, low tier   -- --bench=crowd --frames=%CROWD_FRAMES% --quality=low
rem   4. crowd_low_compat  low tier on the Compatibility renderer (--rendering-method gl_compatibility)
rem Windowed runs use --resolution %RESOLUTION% --disable-vsync --fixed-fps 60 (same as tools/bench.sh).
rem The bench scenes are reached through main.tscn's `--bench=<name>` user arg (release templates cannot run another
rem scene). Output: bench_results\<yyyyMMdd-HHmmss>\<name>.json (the scene's BENCH_JSON line), <name>.log (full
rem engine output) and machine.txt (CPU, GPU, driver, RAM, Windows version), next to the exe.
rem Exit code per bench (printed): 0 pass, 2 tripwire failed, 3 invalid run (busy machine, window not drawn, too
rem short), anything else = crash. The script itself exits 1 when any bench produced no JSON.

setlocal EnableExtensions EnableDelayedExpansion

set "EXE=%~1"
if "%EXE%"=="" set "EXE=%~dp0FishGame.exe"
if not exist "%EXE%" (
	echo run_benchmarks: "%EXE%" not found. Pass the path of the exported FishGame.exe.
	exit /b 1
)
if "%SIM_TICKS%"=="" set "SIM_TICKS=1800"
if "%CROWD_FRAMES%"=="" set "CROWD_FRAMES=3600"
if "%RESOLUTION%"=="" set "RESOLUTION=1920x1080"

for %%I in ("%EXE%") do (
	set "EXE_DIR=%%~dpI"
	set "EXE_NAME=%%~nI"
)
rem The console wrapper (debug/export_console_wrapper in the preset) forwards stdout and the exit code; without it
rem the engine writes its output with --log-file.
set "CONSOLE=%EXE_DIR%%EXE_NAME%.console.exe"
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"`) do set "STAMP=%%T"
set "OUT=%EXE_DIR%bench_results\%STAMP%"
mkdir "%OUT%" 2>nul
echo run_benchmarks: results go to %OUT%

powershell -NoProfile -Command "$c = Get-CimInstance Win32_Processor | Select-Object -First 1; $o = Get-CimInstance Win32_OperatingSystem; $g = Get-CimInstance Win32_VideoController | ForEach-Object { '  ' + $_.Name + ' (driver ' + $_.DriverVersion + ', ' + $_.CurrentHorizontalResolution + 'x' + $_.CurrentVerticalResolution + ')' }; @('CPU: ' + $c.Name + ' (' + $c.NumberOfLogicalProcessors + ' threads)', ('RAM: {0:N1} GB' -f ($o.TotalVisibleMemorySize / 1MB)), ('OS: ' + $o.Caption + ' ' + $o.Version), 'GPU:') + $g + @(('Power: ' + ((Get-CimInstance -Namespace root/cimv2 Win32_Battery | Select-Object -First 1 -ExpandProperty BatteryStatus) -as [string]) + ' (2 = on mains, empty = no battery)')) | Set-Content -LiteralPath (Join-Path $env:OUT 'machine.txt')"
type "%OUT%\machine.txt"

set "FAILED=0"
call :bench sim "--headless" "--bench=sim --frames=%SIM_TICKS%"
call :bench crowd_high "--resolution %RESOLUTION% --disable-vsync --fixed-fps 60" "--bench=crowd --frames=%CROWD_FRAMES% --quality=high"
call :bench crowd_low "--resolution %RESOLUTION% --disable-vsync --fixed-fps 60" "--bench=crowd --frames=%CROWD_FRAMES% --quality=low"
call :bench crowd_low_compat "--rendering-method gl_compatibility --resolution %RESOLUTION% --disable-vsync --fixed-fps 60" "--bench=crowd --frames=%CROWD_FRAMES% --quality=low"

echo.
echo run_benchmarks: done, results in %OUT%
if "%FAILED%"=="1" exit /b 1
exit /b 0

rem :bench <name> "<engine args>" "<user args>"
:bench
set "NAME=%~1"
set "LOG=%OUT%\%NAME%.log"
set "JSON=%OUT%\%NAME%.json"
echo.
echo run_benchmarks: %NAME% ...
if exist "%CONSOLE%" (
	"%CONSOLE%" %~2 -- %~3 > "%LOG%" 2>&1
) else (
	"%EXE%" --log-file "%LOG%" %~2 -- %~3
)
set "CODE=!ERRORLEVEL!"
powershell -NoProfile -Command "$l = Select-String -LiteralPath $env:LOG -Pattern '^BENCH_JSON:' | Select-Object -First 1; if ($l) { [IO.File]::WriteAllText($env:JSON, $l.Line.Substring(11)); exit 0 } else { exit 1 }"
if errorlevel 1 (
	echo run_benchmarks: %NAME% exit !CODE!, NO BENCH_JSON line - see %LOG%
	set "FAILED=1"
	exit /b 0
)
for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "(Select-String -LiteralPath $env:LOG -Pattern '^BENCH [a-z_]+:' | Select-Object -First 1).Line"`) do echo   %%V
echo run_benchmarks: %NAME% exit !CODE! ^(0 pass, 2 tripwire, 3 invalid^) -^> %JSON%
exit /b 0
