<#
.SYNOPSIS
  Builds the headless GUI suite runner (phosphorguitest) against the LCL win32
  widgetset and runs it over the phase-2 GUI oracle files, byte-comparing each
  summary to its golden.

.DESCRIPTION
  The GUI counterpart of test-suite.ps1. phosphorguitest links the LCL (which the
  engine may not) and registers the GUI packages under host/gui/libs; the tests
  build controls and fire events entirely headless -- no window is shown and the
  message loop is never entered -- so the run is byte-exact just like phase 1.
  On Windows the win32 widgetset needs no display at all.
#>
# [CmdletBinding()] WAS HERE AND IS DELIBERATELY GONE. It does refuse an unknown
# named parameter, but with PowerShell's own wording and EXIT 1 -- the same code a
# genuinely failed suite uses, so a caller cannot tell "you typed the flag wrong"
# from "the tests failed". Without it the stragglers land in $args and the shared
# helper answers exit 2 with the same sentence its bash twin says. Measured
# 2026-09-15; see scripts/lib/runner.sh for the defect this pair exists to stop.
param(
    [string] $Fpc,
    [string] $Lazarus = 'C:\lazarus'
)

. (Join-Path $PSScriptRoot 'lib/runner.ps1')
Assert-RunnerArgs 'test-gui.ps1' noprove $args


$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

function Resolve-Fpc {
    if ($Fpc) { return $Fpc }
    $c = 'C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
    if (Test-Path $c) { return $c }
    (Get-Command fpc -ErrorAction Stop).Source
}

$fpcExe = Resolve-Fpc
$lcl = Join-Path $Lazarus 'lcl\units\x86_64-win64'
if (-not (Test-Path (Join-Path $lcl 'win32'))) {
    throw "LCL win32 units not found under $lcl -- pass -Lazarus <dir>"
}

# --- build the GUI runner (win32 widgetset, headless) ------------------------
$binDir   = Join-Path $root 'bin'
$unitsDir = Join-Path $binDir 'gui-units\x86_64-win64'
$exe      = Join-Path $binDir 'phosphorguitest.exe'
New-Item -ItemType Directory -Force $unitsDir | Out-Null
if (Test-Path $exe) { Remove-Item $exe -Force }

$glog = & $fpcExe -Mobjfpc -Scghi -O2 -vewn "-TWin64" -dLCL -dLCLwin32 `
    "-Fu$(Join-Path $lcl 'win32')" "-Fu$lcl" `
    "-Fu$(Join-Path $Lazarus 'components\lazutils\lib\x86_64-win64')" `
    "-Fu$(Join-Path $Lazarus 'packager\units\x86_64-win64')" `
    "-Fu$(Join-Path $root 'engine')" "-Fu$(Join-Path $root 'engine\libs')" `
    "-Fu$(Join-Path $root 'tests')" "-Fu$(Join-Path $root 'host\gui\libs')" `
    "-FU$unitsDir" "-FE$binDir" "-o$exe" `
    (Join-Path $root 'host\gui\phosphorguitest.lpr')
Assert-CleanBuild $glog 'phosphorguitest'
if (-not (Test-Path $exe)) { throw "phosphorguitest did not build (fpc exit $LASTEXITCODE)" }
Write-Host "gui runner built: $exe" -ForegroundColor DarkGray

# --- and the Lazarus DEMO, which is an LCL application like any embedder's ----
# What runs the demo's LOGIC is probe_demo in the main suite -- the demo's
# decisions live in a unit with no LCL in it for exactly that reason. What
# nothing ran until this line is the WINDOW: the unit that wires six controls,
# and the program that installs the application's own crash guard before
# anything can raise. Neither is reached by probe_demo, so without this a demo
# that stopped compiling would be found by a person opening it -- the defect
# this project has already paid for twice.
$demoExe = Join-Path $binDir 'phosphor_demo.exe'
if (Test-Path $demoExe) { Remove-Item $demoExe -Force }
$dlog = & $fpcExe -Mobjfpc -Scghi -O2 -vewn "-TWin64" -dLCL -dLCLwin32 `
    "-Fu$(Join-Path $lcl 'win32')" "-Fu$lcl" `
    "-Fu$(Join-Path $Lazarus 'components\lazutils\lib\x86_64-win64')" `
    "-Fu$(Join-Path $Lazarus 'packager\units\x86_64-win64')" `
    "-Fu$(Join-Path $root 'engine')" "-Fu$(Join-Path $root 'engine\libs')" `
    "-Fu$(Join-Path $root 'lazarus\demo')" `
    "-FU$unitsDir" "-FE$binDir" "-o$demoExe" `
    (Join-Path $root 'lazarus\demo\phosphor_demo.lpr')
Assert-CleanBuild $dlog 'the Lazarus demo'
if (-not (Test-Path $demoExe)) { throw "the Lazarus demo did not build (fpc exit $LASTEXITCODE)" }
Write-Host "lazarus demo built: $demoExe" -ForegroundColor DarkGray
Write-Host ''

# --- run the manifest --------------------------------------------------------
$gui = Join-Path $root 'tests\gui'
$manifest = Get-Content (Join-Path $gui 'manifest.txt') |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
$tmp = [System.IO.Path]::GetTempPath()

function Run-One([string] $name) {
    $bas = Join-Path $gui "$name.bas"
    $expPath = Join-Path $gui "$name.expected"
    # A missing golden is a FAILURE to report, not an exception that kills the run
    # before its summary. Under ErrorActionPreference=Stop, ReadAllBytes on an absent
    # file ended the script mid-list -- the operator saw a stack trace and never saw
    # which files had passed, nor GUI SUITE FAILED.
    if ((-not (Test-Path $bas)) -or (-not (Test-Path $expPath))) {
        Write-Host ("FAIL  {0}  (missing .bas or .expected)" -f $name) -ForegroundColor Red
        return $false
    }
    $exp = [System.IO.File]::ReadAllBytes($expPath)
    $out = Join-Path $tmp 'phosphorguitest.out'
    $err = Join-Path $tmp 'phosphorguitest.err'
    cmd /c "`"$exe`" `"$bas`" > `"$out`" 2> `"$err`""
    $code = $LASTEXITCODE
    $act = [System.IO.File]::ReadAllBytes($out)
    $same = ($act.Length -eq $exp.Length)
    if ($same) { for ($i=0; $i -lt $act.Length; $i++) { if ($act[$i] -ne $exp[$i]) { $same=$false; break } } }
    if ($same -and ($code -eq 0)) {
        Write-Host ("PASS  {0}  ({1} B, exit {2})" -f $name, $act.Length, $code) -ForegroundColor Green
        return $true
    }
    Write-Host ("FAIL  {0}" -f $name) -ForegroundColor Red
    if (-not $same) {
        Write-Host ("  expected: {0}" -f ([Text.Encoding]::ASCII.GetString($exp) -replace "`n","\n"))
        Write-Host ("  actual:   {0}" -f ([Text.Encoding]::ASCII.GetString($act) -replace "`n","\n"))
    }
    if ($code -ne 0) { Write-Host ("  exit {0}; stderr:" -f $code); Get-Content $err | ForEach-Object { Write-Host "    $_" } }
    return $false
}

$allOk = $true
# The manifest must COVER the directory, the same invariant test-suite.ps1 enforces:
# a .bas dropped into tests\gui and never listed simply does not run.
$onDisk = @(Get-ChildItem $gui -Filter *.bas | ForEach-Object { $_.BaseName })
foreach ($b in $onDisk) {
    if ($manifest -notcontains $b) {
        Write-Host ("FAIL  manifest: {0}.bas is in tests\gui but not in manifest.txt -- it never runs" -f $b) -ForegroundColor Red
        $allOk = $false
    }
}

foreach ($name in $manifest) {
    if (-not (Run-One $name)) { $allOk = $false }
}

# --- the watchdog: a hang ends the run, and says so (ledger d56) --------------
# tests/gui/watchdog/hang.bas enters the message loop and never leaves it. The
# runner's watchdog, shortened to 2 s here, must end the run AT the hang: the one
# case before it counted, the hang counted as a failure, exit 4, nothing after it.
# It used to call Application.Terminate, the file ran on, and `passed: 2` came out
# of a file that hung. The run is BOUNDED at 60 s and killed past it, because the
# risk the plan named is that ending a process from inside a timer blocks -- and a
# watchdog that hangs must be reported, not joined.
Write-Host ''
$hang = Join-Path $gui 'watchdog\hang.bas'
$hOut = Join-Path $tmp 'watchdog.out'
$hErr = Join-Path $tmp 'watchdog.err'
$sw = [Diagnostics.Stopwatch]::StartNew()
$hp = Start-Process -FilePath $exe -ArgumentList "`"$hang`" --watchdog-ms 2000" -PassThru -NoNewWindow `
        -RedirectStandardOutput $hOut -RedirectStandardError $hErr
# READ THE HANDLE BEFORE THE PROCESS ENDS, or ExitCode comes back EMPTY: a
# Process object from Start-Process -PassThru keeps the exit code only if its
# handle was opened while the process lived. The first run of this case reported
# a correct 2-second hang as a failure with `exit=` blank, for exactly this.
$null = $hp.Handle
$ended = $hp.WaitForExit(60000)
if (-not $ended) { $hp.Kill() }
$hp.WaitForExit()
$secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
$hText = [IO.File]::ReadAllText($hOut)
$hWhy = [IO.File]::ReadAllText($hErr)
$okW = $ended -and ($hp.ExitCode -eq 4) -and ($hText -eq "passed: 1`nfailed: 1`n") -and
       ($hWhy -like '*did not end within 2000 ms*')
if ($okW) {
    Write-Host ("PASS  watchdog: a hang ends the run at the hang  (exit 4, {0} s)" -f $secs) -ForegroundColor Green
} else {
    Write-Host 'FAIL  watchdog: a hang did not end the run cleanly' -ForegroundColor Red
    Write-Host ("        ended={0} exit={1} secs={2}" -f $ended, $hp.ExitCode, $secs) -ForegroundColor DarkGray
    Write-Host ("        stdout: {0}" -f ($hText -replace "`n", '\n')) -ForegroundColor DarkGray
    Write-Host ("        stderr: {0}" -f ($hWhy -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
    $allOk = $false
}
[IO.File]::Delete($hOut); [IO.File]::Delete($hErr)

# --- the ledger: a forgotten modal answer or a handler fault fails the run -----
# tests/gui/ledger/forgot.bas provokes each way the modal answer queue can be
# wrong -- asked with nothing queued, taken by the wrong kind, never used -- and
# MUST fail on all three. The runner said a forgotten answer "fails on the
# count" while nothing read the count (2026-10-08); this is the run that shows
# it is read. A handler fault no test acknowledged fails it too: GuiCallBack
# swallows a fault by design, which skipped every assertion after it in silence.
# Bounded like everything else here.
$lb = Join-Path $gui 'ledger\forgot.bas'
$lOut = Join-Path $tmp 'ledger.out'
$lErr = Join-Path $tmp 'ledger.err'
$lp = Start-Process -FilePath $exe -ArgumentList "`"$lb`"" -PassThru -NoNewWindow `
        -RedirectStandardOutput $lOut -RedirectStandardError $lErr
$null = $lp.Handle
$lEnded = $lp.WaitForExit(60000)
if (-not $lEnded) { $lp.Kill() }
$lp.WaitForExit()
$lText = [IO.File]::ReadAllText($lOut)
$lWhy = [IO.File]::ReadAllText($lErr)
$okL = $lEnded -and ($lp.ExitCode -eq 1) -and ($lText -eq "passed: 1`nfailed: 4`n") -and
       ($lWhy -like '*asked with no answer queued*') -and ($lWhy -like '*never used*') -and
       ($lWhy -like '*taken by a different kind*') -and
       ($lWhy -like '*event handler fault(s) no test acknowledged*on_fault*')
if ($okL) {
    Write-Host 'PASS  ledger: a forgotten modal answer or an unacknowledged handler fault fails the run  (exit 1)' -ForegroundColor Green
} else {
    Write-Host 'FAIL  ledger: the modal answer ledger did not fail the run' -ForegroundColor Red
    Write-Host ("        ended={0} exit={1}" -f $lEnded, $lp.ExitCode) -ForegroundColor DarkGray
    Write-Host ("        stdout: {0}" -f ($lText -replace "`n", '\n')) -ForegroundColor DarkGray
    Write-Host ("        stderr: {0}" -f ($lWhy -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
    $allOk = $false
}
[IO.File]::Delete($lOut); [IO.File]::Delete($lErr)


# --- host mode: one binary that decides ---------------------------------------
# phosphor links the LCL and brings the widgetset up only when a graphical
# session is reachable, registering the GUI functions with it. On Windows that is
# always -- the win32 widgetset needs no display -- so what is checked here is
# that a GUI program runs through the ONE binary with no flag, that a console
# program still does, and that the exit code is the program's own. The
# no-session half of the decision can only be produced on Unix and is checked in
# test-gui.sh, which takes the session away for one command.
Write-Host ''
$console = Join-Path $binDir 'phosphor.exe'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'build.ps1') | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $console)) {
    Write-Host 'FAIL  hostmode: phosphor did not build' -ForegroundColor Red
    $allOk = $false
} else {
    function Host-Case {
        # NOT $Args: that is a PowerShell automatic variable and a param by that
        # name is silently ignored, which once ran phosphor with no arguments at
        # all and got the REPL back, four times over.
        param([string] $Name, [string[]] $CliArgs, [int] $WantExit, [string] $WantText)
        $o = Join-Path $tmp 'hostmode.out'
        $quoted = ($CliArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
        cmd /c "`"$console`" $quoted > `"$o`" 2>&1"
        $code = $LASTEXITCODE
        $text = Get-Content -Raw $o -ErrorAction SilentlyContinue
        if ($null -eq $text) { $text = '' }
        $okCode = ($code -eq $WantExit)
        $okText = ($WantText -eq '') -or ($text -like "*$WantText*")
        if ($okCode -and $okText) {
            Write-Host ("PASS  hostmode: {0}  (exit {1})" -f $Name, $code) -ForegroundColor Green
            return $true
        }
        Write-Host ("FAIL  hostmode: {0}" -f $Name) -ForegroundColor Red
        if (-not $okCode) { Write-Host ("        wanted exit {0}, got {1}" -f $WantExit, $code) -ForegroundColor DarkGray }
        if (-not $okText) { Write-Host ("        wanted text containing '{0}', got: {1}" -f $WantText, ($text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray }
        return $false
    }

    $hm = Join-Path $gui 'hostmode'
    # 1. A GUI program, with no flag and no second binary.
    if (-not (Host-Case 'a GUI program runs with no flag' @('run', (Join-Path $hm 'gui.bas')) 0 'gui ok: registrado')) { $allOk = $false }
    # 2. A console program through the same binary, unchanged.
    if (-not (Host-Case 'and a console program still does' @('run', (Join-Path $hm 'hello.bas')) 0 'console ok')) { $allOk = $false }
    # 3. The exit code is the program's.
    if (-not (Host-Case 'a failing program fails the run' @('run', (Join-Path $hm 'fails.bas')) 1 'about to fail')) { $allOk = $false }
    # 4. --gui is accepted and says it is not needed, rather than being ignored.
    if (-not (Host-Case '--gui is accepted and answered' @('--gui', 'run', (Join-Path $hm 'gui.bas')) 0 'no longer needed')) { $allOk = $false }
    # 5. THE SANDBOX REACHES A GUI RUN. It could not before: the console host
    #    spawned a second binary and passed it only the file name, so --sandbox
    #    was accepted and silently dropped on exactly the path a GUI program took.
    # 6. --no-console must be a NO-OP on a console shared with this terminal: it
    #    is the shell's window, not the program's. The run still prints and still
    #    succeeds -- an early version released the console and then died on its
    #    next println with EInOutError, exit 217.
    if (-not (Host-Case '--no-console leaves a terminal console alone' @('--no-console', 'run', (Join-Path $hm 'hello.bas')) 0 'console ok')) { $allOk = $false }
    #    AND IT HAS TO BE ABLE TO FAIL (ledger d51). This case used to run
    #    gui.bas, which touches no path, so it passed with the right root, a
    #    bogus one, or no --sandbox at all. gui_sandbox.bas asks the sandbox two
    #    things -- which root is bound, and whether ".." is visible -- and the
    #    unconfined run beside it shows that the probe CAN answer 1, so a 0 under
    #    the cage is the sandbox and not a broken dir_exists.
    $cage = Join-Path $tmp 'phosphor-hostmode-cage'
    New-Item -ItemType Directory -Force $cage | Out-Null
    $gsb = Join-Path $hm 'gui_sandbox.bas'
    if (-not (Host-Case 'the sandbox root reaches a GUI program' @('--sandbox', $cage, 'run', $gsb) 0 ("root=" + $cage + "|"))) { $allOk = $false }
    if (-not (Host-Case 'and confines it: ".." is outside the cage' @('--sandbox', $cage, 'run', $gsb) 0 'parent visible: 0')) { $allOk = $false }
    if (-not (Host-Case 'unconfined, the same program sees ".."' @('run', $gsb) 0 'parent visible: 1')) { $allOk = $false }
}

Write-Host ''
if ($allOk) { Write-Host 'GUI SUITE OK' -ForegroundColor Green; exit 0 }
else { Write-Host 'GUI SUITE FAILED' -ForegroundColor Red; exit 1 }
