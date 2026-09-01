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
    $exp = [System.IO.File]::ReadAllBytes((Join-Path $gui "$name.expected"))
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
foreach ($name in $manifest) {
    if (-not (Run-One $name)) { $allOk = $false }
}

Write-Host ''
if ($allOk) { Write-Host 'GUI SUITE OK' -ForegroundColor Green; exit 0 }
else { Write-Host 'GUI SUITE FAILED' -ForegroundColor Red; exit 1 }
