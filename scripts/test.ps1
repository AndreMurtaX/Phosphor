<#
.SYNOPSIS
  Builds Phosphor, runs the skeleton smoke test, and byte-compares the output
  against the golden file -- through BOTH non-console output paths.

.DESCRIPTION
  The host has two byte-exact output paths and one console path:
    A. --out <file>       -> TFileStream (used by tools/tests)
    B. redirected stdout  -> raw bytes to the stdout handle (pipe/file)
    (console stdout       -> WriteConsoleW; can only be checked on a real
                             terminal, so it is verified by hand with --diag.)
  This script checks A and B. B is captured with cmd redirection, not
  PowerShell's, because PowerShell re-encodes a native program's stdout and
  would defeat a byte comparison.

  Discipline: a check is only trustworthy once seen to fail. Pass -ProveFailure
  to corrupt the expectation and confirm both comparisons report FAIL.
#>
[CmdletBinding()]
param(
    [switch] $ProveFailure
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

& (Join-Path $here 'build.ps1')
if ($LASTEXITCODE -ne 0) { throw "build failed (exit $LASTEXITCODE)" }

$exe      = Join-Path $root 'bin\phosphor.exe'
$bas      = Join-Path $root 'tests\skeleton\hello.bas'
$expected = Join-Path $root 'tests\skeleton\hello.expected'
$tmp      = [System.IO.Path]::GetTempPath()
$outA     = Join-Path $tmp 'phosphor_hello.A.actual'
$outB     = Join-Path $tmp 'phosphor_hello.B.actual'

$expectedBytes = [System.IO.File]::ReadAllBytes($expected)
if ($ProveFailure) {
    $expectedBytes = $expectedBytes.Clone()
    $expectedBytes[0] = $expectedBytes[0] -bxor 0x20
    Write-Host 'ProveFailure: expectation corrupted on purpose' -ForegroundColor Yellow
}

function Format-Hex([byte[]] $b, [int] $max = 48) {
    ($b | Select-Object -First $max | ForEach-Object { $_.ToString('x2') }) -join ' '
}
function Test-Golden([string] $label, [string] $actualPath, [byte[]] $exp) {
    $act = [System.IO.File]::ReadAllBytes($actualPath)
    $same = $act.Length -eq $exp.Length
    if ($same) {
        for ($i = 0; $i -lt $act.Length; $i++) {
            if ($act[$i] -ne $exp[$i]) { $same = $false; break }
        }
    }
    if ($same) {
        Write-Host ("PASS  {0}  ({1} bytes match golden)" -f $label, $act.Length) -ForegroundColor Green
    } else {
        Write-Host ("FAIL  {0}  output does not match golden" -f $label) -ForegroundColor Red
        Write-Host ("  expected ({0} B): {1}" -f $exp.Length, (Format-Hex $exp))
        Write-Host ("  actual   ({0} B): {1}" -f $act.Length, (Format-Hex $act))
    }
    return $same
}

# A. --out file path
& $exe 'run' $bas '--out' $outA
if ($LASTEXITCODE -ne 0) { throw "runner (--out) exited $LASTEXITCODE" }

# B. redirected stdout path, captured with cmd so bytes are not re-encoded.
cmd /c "`"$exe`" run `"$bas`" > `"$outB`""
if ($LASTEXITCODE -ne 0) { throw "runner (stdout redirect) exited $LASTEXITCODE" }

# C. packed standalone executable: pack hello.bas into a self-extracting exe, run
#    it with no arguments, and compare -- proves the .pbc rides in the binary.
$packExe = Join-Path $tmp 'phosphor_hello_packed.exe'
$outC    = Join-Path $tmp 'phosphor_hello.C.actual'
& $exe 'pack' $bas $packExe
if ($LASTEXITCODE -ne 0) { throw "pack exited $LASTEXITCODE" }
cmd /c "`"$packExe`" > `"$outC`""
if ($LASTEXITCODE -ne 0) { throw "packed exe exited $LASTEXITCODE" }

Write-Host ''
$okA = Test-Golden 'A:--out        ' $outA $expectedBytes
$okB = Test-Golden 'B:stdout-redir ' $outB $expectedBytes
$okC = Test-Golden 'C:packed       ' $outC $expectedBytes

if ($okA -and $okB -and $okC) { exit 0 } else { exit 1 }
