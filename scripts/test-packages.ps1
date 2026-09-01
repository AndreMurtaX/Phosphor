<#
.SYNOPSIS
  Builds the opt-in-package test runner (phosphorpkgtest) and runs it over the
  package suite (base64, zip, ...), byte-comparing each summary to its golden.

.DESCRIPTION
  These packages are NOT part of the engine -- they live under host/packages/ and a
  host registers the ones it wants. This runner links them and runs the .bas files
  that exercise them, exactly the byte-exact way the engine suite is checked. The
  packages used here (base64 from fcl-base, zip from paszlib) ship with FPC, so no
  external runtime library is needed.
#>
[CmdletBinding()]
param([string] $Fpc)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

function Resolve-Fpc {
    if ($Fpc) { return $Fpc }
    $c = 'C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
    if (Test-Path $c) { return $c }
    (Get-Command fpc -ErrorAction Stop).Source
}

$fpcExe   = Resolve-Fpc
$binDir   = Join-Path $root 'bin'
$unitsDir = Join-Path $binDir 'pkg-units\x86_64-win64'
$exe      = Join-Path $binDir 'phosphorpkgtest.exe'
New-Item -ItemType Directory -Force $unitsDir | Out-Null
if (Test-Path $exe) { Remove-Item $exe -Force }

& $fpcExe -Mobjfpc -Scghi -O2 -vewn "-TWin64" `
    "-Fu$(Join-Path $root 'engine')" "-Fu$(Join-Path $root 'engine\libs')" `
    "-Fu$(Join-Path $root 'tests')" "-Fu$(Join-Path $root 'host\packages')" `
    "-FU$unitsDir" "-FE$binDir" "-o$exe" `
    (Join-Path $root 'host\packages\phosphorpkgtest.lpr') | Out-Null
if (-not (Test-Path $exe)) { throw "phosphorpkgtest did not build (fpc exit $LASTEXITCODE)" }
Write-Host "package runner built: $exe" -ForegroundColor DarkGray
Write-Host ''

$pkg = Join-Path $root 'tests\packages'
$manifest = Get-Content (Join-Path $pkg 'manifest.txt') |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
$tmp = [System.IO.Path]::GetTempPath()

# A package needing an external runtime library is skipped where it is absent.
$sqliteAvail = (Test-Path (Join-Path $binDir 'sqlite3.dll')) -or
               (Test-Path (Join-Path $env:SystemRoot 'System32\sqlite3.dll'))

$allOk = $true
foreach ($name in $manifest) {
    if (($name -like '*sqlite*') -and (-not $sqliteAvail)) {
        Write-Host ("SKIP  {0}  (SQLite runtime library not found)" -f $name) -ForegroundColor Yellow
        continue
    }
    $bas = Join-Path $pkg "$name.bas"
    $exp = [System.IO.File]::ReadAllBytes((Join-Path $pkg "$name.expected"))
    $out = Join-Path $tmp 'phosphorpkgtest.out'
    $err = Join-Path $tmp 'phosphorpkgtest.err'
    cmd /c "`"$exe`" `"$bas`" > `"$out`" 2> `"$err`""
    $code = $LASTEXITCODE
    $act = [System.IO.File]::ReadAllBytes($out)
    $same = ($act.Length -eq $exp.Length)
    if ($same) { for ($i=0; $i -lt $act.Length; $i++) { if ($act[$i] -ne $exp[$i]) { $same=$false; break } } }
    if ($same -and ($code -eq 0)) {
        Write-Host ("PASS  {0}  ({1} B, exit {2})" -f $name, $act.Length, $code) -ForegroundColor Green
    } else {
        Write-Host ("FAIL  {0}" -f $name) -ForegroundColor Red
        if (-not $same) {
            Write-Host ("  expected: {0}" -f ([Text.Encoding]::ASCII.GetString($exp) -replace "`n","\n"))
            Write-Host ("  actual:   {0}" -f ([Text.Encoding]::ASCII.GetString($act) -replace "`n","\n"))
        }
        if ($code -ne 0) { Write-Host ("  exit {0}; stderr:" -f $code); Get-Content $err | ForEach-Object { Write-Host "    $_" } }
        $allOk = $false
    }
}

Write-Host ''
if ($allOk) { Write-Host 'PACKAGES OK' -ForegroundColor Green; exit 0 }
else { Write-Host 'PACKAGES FAILED' -ForegroundColor Red; exit 1 }
