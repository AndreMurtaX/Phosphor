<#
.SYNOPSIS
  Builds phosphorgui -- the COMPLETE Phosphor runner: the engine, every function
  package, and the LCL GUI libraries.

.DESCRIPTION
  `phosphor` (scriptsuild.ps1) is the headless host: engine + every non-GUI
  package. It deliberately does NOT link the LCL: on Linux the gtk2 widgetset opens
  the X display in a unit INITIALIZATION section, so an LCL-linked binary exits 1
  with "cannot open display" wherever none is reachable -- CI, containers, headless
  servers, and a plain ssh session. (With a live display it runs fine; the point is
  that the console host must not DEPEND on one.)

  So the GUI runner is a second binary. `phosphor --gui <file.bas>` hands over to it,
  which is why the two live side by side in bin/.

  Compiling does not need either: the compiler is host-agnostic, so
  `phosphor compile <any.bas> <out.pbc>` already handles GUI programs.
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
    if ($Fpc) { if (-not (Test-Path $Fpc)) { throw "fpc not found at $Fpc" }; return $Fpc }
    $c = 'C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
    if (Test-Path $c) { return $c }
    (Get-Command fpc -ErrorAction Stop).Source
}

$fpcExe = Resolve-Fpc
$lcl = Join-Path $Lazarus 'lcl\units\x86_64-win64'
if (-not (Test-Path (Join-Path $lcl 'win32'))) {
    throw "LCL win32 units not found under $lcl -- pass -Lazarus <dir>"
}

$binDir   = Join-Path $root 'bin'
$unitsDir = Join-Path $binDir 'gui-units\x86_64-win64'
$exe      = Join-Path $binDir 'phosphorgui.exe'
New-Item -ItemType Directory -Force $unitsDir | Out-Null
if (Test-Path $exe) { Remove-Item $exe -Force }

Write-Host "compiler: $fpcExe"
$blog = & $fpcExe -Mobjfpc -Scghi -O2 -vewn "-TWin64" -dLCL -dLCLwin32 `
    "-Fu$(Join-Path $lcl 'win32')" "-Fu$lcl" `
    "-Fu$(Join-Path $Lazarus 'components\lazutils\lib\x86_64-win64')" `
    "-Fu$(Join-Path $Lazarus 'packager\units\x86_64-win64')" `
    "-Fu$(Join-Path $root 'engine')" "-Fu$(Join-Path $root 'engine\libs')" `
    "-Fu$(Join-Path $root 'host\gui\libs')" "-Fu$(Join-Path $root 'host\packages')" `
    "-FU$unitsDir" "-FE$binDir" "-o$exe" `
    (Join-Path $root 'host\gui\phosphorgui.lpr') 2>&1
$blog | ForEach-Object { Write-Host $_ }

# Same zero-note bar as the console build.
$issues = $blog | Where-Object { "$_" -match '(?i)warning|note:|error|fatal' -and "$_" -notmatch 'Compiling|Linking' }
if ($issues) { Write-Error 'build NOT clean -- warnings/notes above'; exit 1 }
if (-not (Test-Path $exe)) { Write-Error 'no binary produced'; exit 1 }

Write-Host ''
Write-Host "built:  $exe" -ForegroundColor Green
exit 0
