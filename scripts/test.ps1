<#
.SYNOPSIS
  Builds Phosphor, runs the skeleton smoke test, and byte-compares the output
  against the golden file.

.DESCRIPTION
  The runner writes its output to a file (--out) rather than to the console, and
  we compare raw bytes. That sidesteps PowerShell re-encoding native stdout and
  makes the UTF-8 assertion exact: the bytes of the source literal must arrive
  in the golden file unchanged.

  Discipline: a check is only trustworthy once it has been seen to fail. Pass
  -ProveFailure to corrupt the expected bytes in a temp copy and confirm the
  comparison reports FAIL -- then run again without it to see PASS.
#>
[CmdletBinding()]
param(
    [switch] $ProveFailure
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

# Build first (build.ps1 verifies the binary itself).
& (Join-Path $here 'build.ps1')
if ($LASTEXITCODE -ne 0) { throw "build failed (exit $LASTEXITCODE)" }

$exe      = Join-Path $root 'bin\phosphor.exe'
$bas      = Join-Path $root 'tests\skeleton\hello.bas'
$expected = Join-Path $root 'tests\skeleton\hello.expected'
$actual   = Join-Path ([System.IO.Path]::GetTempPath()) 'phosphor_hello.actual'

Write-Host ''
Write-Host "run: $exe run $bas --out $actual"
& $exe 'run' $bas '--out' $actual
if ($LASTEXITCODE -ne 0) { throw "runner exited $LASTEXITCODE" }

$expectedBytes = [System.IO.File]::ReadAllBytes($expected)
if ($ProveFailure) {
    # Deliberately break the check to watch it fail, per the "see it fail first"
    # rule. This flips one byte of the expectation only in memory.
    $expectedBytes = $expectedBytes.Clone()
    $expectedBytes[0] = $expectedBytes[0] -bxor 0x20
    Write-Host 'ProveFailure: expectation corrupted on purpose' -ForegroundColor Yellow
}
$actualBytes = [System.IO.File]::ReadAllBytes($actual)

function Format-Hex([byte[]] $b, [int] $max = 64) {
    ($b | Select-Object -First $max | ForEach-Object { $_.ToString('x2') }) -join ' '
}

$same = $actualBytes.Length -eq $expectedBytes.Length
if ($same) {
    for ($i = 0; $i -lt $actualBytes.Length; $i++) {
        if ($actualBytes[$i] -ne $expectedBytes[$i]) { $same = $false; break }
    }
}

Write-Host ''
if ($same) {
    Write-Host "PASS  ($($actualBytes.Length) bytes match golden)" -ForegroundColor Green
    exit 0
} else {
    Write-Host 'FAIL  output does not match golden' -ForegroundColor Red
    Write-Host "  expected ($($expectedBytes.Length) B): $(Format-Hex $expectedBytes)"
    Write-Host "  actual   ($($actualBytes.Length) B): $(Format-Hex $actualBytes)"
    exit 1
}
