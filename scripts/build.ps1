<#
.SYNOPSIS
  Builds the Phosphor console host from source with FPC.

.DESCRIPTION
  The authoritative build. Drives fpc.exe directly (the IDE is optional; see
  host/console/phosphor.lpi for opening it in Lazarus). Three things it does
  that a bare "fpc" call does not:

    1. Boundary check. Scans engine/*.pas for any host- or GUI-facing unit. The
       engine is a library and must stay one; if it ever reaches for crt, the
       LCL, Windows, etc. the build fails here, before the compiler is even
       called. This is the Phosphor equivalent of Plan9Basic's FMX boundary
       check.

    2. It does not trust the exit code. A step can "succeed" having done
       nothing, so after compiling it checks the binary exists and actually
       runs (--version), and only then reports success.

    3. Clean unit output. Compiled units go to bin/units/<cpu>-<os> so the
       source tree and bin/ stay tidy.

.PARAMETER Fpc
  Path to fpc.exe. Defaults to the Lazarus FPC on this machine, then PATH.

.PARAMETER Lazarus
  Where Lazarus is installed. Defaults to C:\lazarus, which is where the
  installer puts it. `phosphor` is one binary that is also the GUI host, so the
  build LINKS THE LCL and needs the win32 LCL units under
  <Lazarus>\lcl\units\x86_64-win64. Installed somewhere else, pass it here.

  This block is the only documentation this parameter has ever had. It was
  discoverable solely by triggering the error message that suggests it, which is
  no use to anyone who installed Lazarus elsewhere and read the help first.

.PARAMETER TargetOS
  win64 (default) or linux. linux cross-builds are not yet possible on this
  machine -- see docs/architecture.md, "Linux". The script says so and stops.
#>
[CmdletBinding()]
param(
    [string] $Fpc,
    [string] $Lazarus = 'C:\lazarus',
    [ValidateSet('win64','linux')]
    [string] $TargetOS = 'win64'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

function Resolve-Fpc {
    if ($Fpc) {
        if (-not (Test-Path $Fpc)) { throw "fpc not found at $Fpc" }
        return $Fpc
    }
    $candidate = 'C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
    if (Test-Path $candidate) { return $candidate }
    $onPath = Get-Command fpc -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    throw 'fpc.exe not found. Install FPC/Lazarus or pass -Fpc <path>.'
}

# --- 1. Boundary check: the engine must not reach for a host or GUI unit ------
# ONE COPY, in scripts/lib/boundary.ps1, with its bash twin beside it. There were
# four, they disagreed, and on 2026-09-15 they were scored for the first time
# against tests/boundary: the PowerShell halves 10/11, the bash halves 8/11. Both
# stripped // before the block forms, which lets a brace comment lose its
# terminator to a // on the same line and then swallow a real uses clause.
# scripts/check-boundary.py now runs both halves over those fixtures.
$engineDir = Join-Path $root 'engine'
. (Join-Path $PSScriptRoot 'lib/boundary.ps1')
Assert-EngineBoundary $engineDir

# --- Linux gate ---------------------------------------------------------------
if ($TargetOS -eq 'linux') {
    Write-Host ''
    Write-Host 'Linux cross-build is not available on this machine.' -ForegroundColor Yellow
    Write-Host 'Missing: FPC RTL units for x86_64-linux and cross binutils (ld/as).'
    Write-Host 'See docs/architecture.md, section "Linux", for the two supported paths.'
    exit 3
}

# --- 2. Compile ---------------------------------------------------------------
$fpcExe   = Resolve-Fpc
$binDir   = Join-Path $root 'bin'
$unitsDir = Join-Path $binDir "units\x86_64-$TargetOS"
$exe      = Join-Path $binDir 'phosphor.exe'
$lpr      = Join-Path $root 'host\console\phosphor.lpr'

# EVERY PREREQUISITE IS CHECKED BEFORE ANYTHING IS DESTROYED. This probe used to
# sit AFTER the Remove-Item below, so someone who mistyped -Lazarus, or who simply
# did not have Lazarus, was left with no binary at all and an error about units --
# their working phosphor.exe deleted to build a replacement that was never going
# to be attempted. Nothing announced that; it just was not there afterwards.
#
# The LCL comes in because phosphor IS the GUI host now -- one binary that brings
# the widgetset up when there is a session and stays a console interpreter when
# there is not. The engine still never sees any of it: the boundary check above
# scans engine/ and fails the build if a unit there reaches for the LCL.
Write-Host "compiler: $fpcExe"
$lcl = Join-Path $Lazarus 'lcl\units\x86_64-win64'
if (-not (Test-Path (Join-Path $lcl 'win32'))) {
    throw "LCL win32 units not found under $lcl -- install Lazarus, or pass -Lazarus <dir>"
}

New-Item -ItemType Directory -Force $unitsDir | Out-Null
if (Test-Path $exe) { Remove-Item $exe -Force }
$args = @(
    '-Mobjfpc', '-Scghi', '-O2', '-vewn',
    "-T$TargetOS", '-dLCL', '-dLCLwin32',
    "-Fu$(Join-Path $lcl 'win32')",
    "-Fu$lcl",
    "-Fu$(Join-Path $Lazarus 'components\lazutils\lib\x86_64-win64')",
    "-Fu$(Join-Path $Lazarus 'packager\units\x86_64-win64')",
    "-Fu$engineDir",
    "-Fu$(Join-Path $engineDir 'libs')",
    "-Fu$(Join-Path $root 'host\gui\libs')",
    "-Fu$(Join-Path $root 'host\packages')",
    "-FU$unitsDir",
    "-FE$binDir",
    "-o$exe",
    $lpr
)
$blog = & $fpcExe @args 2>&1
$compileExit = $LASTEXITCODE
$blog | ForEach-Object { Write-Host $_ }

# A -vewn build must be clean: FAIL on any warning/note (host packages included), not
# just a missing binary. A note can hide in a package the engine suite never compiles.
$issues = $blog | Where-Object { "$_" -match '(?i)warning|note:|error|fatal' -and "$_" -notmatch 'Compiling|Linking' }
if ($issues) {
    Write-Error "build NOT clean -- warnings/notes above; the zero-note bar is not met"
    exit 1
}

# --- 3. Trust nothing: verify the artifact, do not believe the exit code ------
if (-not (Test-Path $exe)) {
    Write-Error "no binary produced (fpc exit $compileExit); build failed"
    exit 1
}
$verOut = & $exe '--version'
if ($LASTEXITCODE -ne 0 -or $verOut -notmatch 'Phosphor BASIC') {
    Write-Error "binary exists but does not run as expected: '$verOut'"
    exit 1
}
Write-Host ''
Write-Host "built:  $exe" -ForegroundColor Green
Write-Host "verify: $verOut" -ForegroundColor Green
exit 0
