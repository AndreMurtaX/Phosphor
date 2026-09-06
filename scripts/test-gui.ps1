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


# --- the --gui handoff --------------------------------------------------------
# `phosphor --gui <file>` is what a person types to run a GUI program, and until
# now nothing ran it. It makes four decisions -- is there a graphical session, is
# phosphorgui beside me, spawn it, hand back its exit code -- and each is checked
# here. The fixtures open no window: the handoff is the subject, and a window
# would only hide it.
Write-Host ''
$console = Join-Path $binDir 'phosphor.exe'
$guiExe  = Join-Path $binDir 'phosphorgui.exe'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'build.ps1') | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL  handoff: phosphor did not build' -ForegroundColor Red; $allOk = $false }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'build-gui.ps1') | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL  handoff: phosphorgui did not build' -ForegroundColor Red; $allOk = $false }

function Handoff-Case {
    # NOT $Args: that is a PowerShell automatic variable, and a param by that
    # name is silently ignored -- the first version of this ran phosphor with no
    # arguments at all and got the REPL, four times over.
    param([string] $Name, [string[]] $CliArgs, [int] $WantExit, [string] $WantText)
    $o = Join-Path $tmp 'handoff.out'
    $quoted = ($CliArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
    cmd /c "`"$console`" $quoted > `"$o`" 2>&1"
    $code = $LASTEXITCODE
    $text = Get-Content -Raw $o -ErrorAction SilentlyContinue
    if ($null -eq $text) { $text = '' }
    $okCode = ($code -eq $WantExit)
    $okText = ($WantText -eq '') -or ($text -like "*$WantText*")
    if ($okCode -and $okText) {
        Write-Host ("PASS  handoff: {0}  (exit {1})" -f $Name, $code) -ForegroundColor Green
        return $true
    }
    Write-Host ("FAIL  handoff: {0}" -f $Name) -ForegroundColor Red
    if (-not $okCode) { Write-Host ("        wanted exit {0}, got {1}" -f $WantExit, $code) -ForegroundColor DarkGray }
    if (-not $okText) { Write-Host ("        wanted text containing '{0}', got: {1}" -f $WantText, ($text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray }
    return $false
}

$hoDir = Join-Path $gui 'handoff'
if (Test-Path $guiExe) {
    # 1. It really hands over: the child's stdout comes back unchanged, exit 0.
    if (-not (Handoff-Case 'runs the program through phosphorgui' @('--gui', (Join-Path $hoDir 'hello.bas')) 0 'handoff ok')) { $allOk = $false }

    # 2. And it hands back the child's FAILURE. A wrapper that swallows the
    #    child's status reports every run as a success.
    if (-not (Handoff-Case 'gives back the failing exit code' @('--gui', (Join-Path $hoDir 'fails.bas')) 1 'about to fail')) { $allOk = $false }

    # 3. Usage: --gui with nothing to run.
    if (-not (Handoff-Case 'refuses --gui with no file' @('--gui') 2 'needs a file to run')) { $allOk = $false }

    # 4. The message when phosphorgui is not beside it. Hidden and put straight
    #    back, so a failure here cannot leave the tree without its binary.
    $hidden = Join-Path $binDir 'phosphorgui.hidden'
    Rename-Item -Path $guiExe -NewName 'phosphorgui.hidden' -Force
    try {
        if (-not (Handoff-Case 'says what is missing when phosphorgui is not there' @('--gui', (Join-Path $hoDir 'hello.bas')) 2 'needs phosphorgui beside this binary')) { $allOk = $false }
    } finally {
        Rename-Item -Path $hidden -NewName 'phosphorgui.exe' -Force
    }
} else {
    Write-Host 'FAIL  handoff: phosphorgui.exe is not present, so the handoff was not tested' -ForegroundColor Red
    $allOk = $false
}

Write-Host ''
if ($allOk) { Write-Host 'GUI SUITE OK' -ForegroundColor Green; exit 0 }
else { Write-Host 'GUI SUITE FAILED' -ForegroundColor Red; exit 1 }
