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
[CmdletBinding()]
param(
    [string] $Fpc,
    [string] $Lazarus = 'C:\lazarus'
)

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

& $fpcExe -Mobjfpc -Scghi -O2 -vewn "-TWin64" -dLCL -dLCLwin32 `
    "-Fu$(Join-Path $lcl 'win32')" "-Fu$lcl" `
    "-Fu$(Join-Path $Lazarus 'components\lazutils\lib\x86_64-win64')" `
    "-Fu$(Join-Path $Lazarus 'packager\units\x86_64-win64')" `
    "-Fu$(Join-Path $root 'engine')" "-Fu$(Join-Path $root 'engine\libs')" `
    "-Fu$(Join-Path $root 'tests')" "-Fu$(Join-Path $root 'host\gui\libs')" `
    "-FU$unitsDir" "-FE$binDir" "-o$exe" `
    (Join-Path $root 'host\gui\phosphorguitest.lpr') | Out-Null
if (-not (Test-Path $exe)) { throw "phosphorguitest did not build (fpc exit $LASTEXITCODE)" }
Write-Host "gui runner built: $exe" -ForegroundColor DarkGray
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
    $cage = Join-Path $tmp 'phosphor-hostmode-cage'
    New-Item -ItemType Directory -Force $cage | Out-Null
    if (-not (Host-Case 'the sandbox root reaches a GUI program' @('--sandbox', $cage, 'run', (Join-Path $hm 'gui.bas')) 0 'gui ok')) { $allOk = $false }
}

Write-Host ''
if ($allOk) { Write-Host 'GUI SUITE OK' -ForegroundColor Green; exit 0 }
else { Write-Host 'GUI SUITE FAILED' -ForegroundColor Red; exit 1 }
