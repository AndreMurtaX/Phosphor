<#
.SYNOPSIS
  Runs the classic-BASIC feature tests through the real `phosphor` console host,
  byte-comparing each program's output to its golden.

.DESCRIPTION
  These exercise the standard-BASIC commands the founding brief requires -- INPUT /
  LINE INPUT / INPUT$, classic #-numbered file I/O (OPEN/CLOSE/PRINT#/INPUT#/LINE
  INPUT#/EOF/LOF/LOC/SEEK), PRINT USING, SWAP, the byte primitives -- plus that every
  function package is reachable through the host.

  Two kinds of test live in tests/classic:
    <name>.bas   run with `phosphor run <name>.bas --out <actual>`; a <name>.in file,
                 when present, is fed on stdin (the console INPUT tests).
    <name>.repl  typed into the interactive REPL on stdin; stdout is the transcript,
                 which pins that state persists across lines.
  Either way the output is byte-compared to <name>.expected.

  Discipline: -ProveFailure corrupts one golden byte and confirms the comparison
  reports a mismatch -- the check is seen failing before it is trusted.
#>
[CmdletBinding()]
param([switch] $ProveFailure)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$exe  = Join-Path $root 'bin\phosphor.exe'
if (-not (Test-Path $exe)) { throw "phosphor.exe not built -- run scripts\build.ps1 first" }
$dir  = Join-Path $root 'tests\classic'
$tmp  = [System.IO.Path]::GetTempPath()
$tests = @(Get-ChildItem $dir -Filter *.bas) + @(Get-ChildItem $dir -Filter *.repl) |
         Sort-Object Name

function Run-One([System.IO.FileInfo] $t, [byte[]] $expected, [string] $label) {
    $out = Join-Path $tmp 'classic.out'
    if (Test-Path $out) { Remove-Item $out -Force }
    if ($t.Extension -eq '.repl') {
        # A REPL session: the file is what the user types; stdout is the transcript.
        cmd /c "`"$exe`" < `"$($t.FullName)`" > `"$out`" 2> NUL"
    }
    else {
        $inP = Join-Path $dir ($t.BaseName + '.in')
        if (-not (Test-Path $inP)) { $inP = $null }
        $line = "`"$exe`" run `"$($t.FullName)`" --out `"$out`" "
        if ($inP) { $line += "< `"$inP`" " } else { $line += "< NUL " }
        $line += "2> NUL"
        cmd /c $line
    }
    $code = $LASTEXITCODE
    $act = if (Test-Path $out) { [System.IO.File]::ReadAllBytes($out) } else { @() }
    $same = ($act.Length -eq $expected.Length)
    if ($same) { for ($i=0; $i -lt $act.Length; $i++) { if ($act[$i] -ne $expected[$i]) { $same=$false; break } } }
    if ($same -and ($code -eq 0)) {
        Write-Host ("PASS  {0}  ({1} B)" -f $label, $act.Length) -ForegroundColor Green
        return $true
    }
    Write-Host ("FAIL  {0}" -f $label) -ForegroundColor Red
    if (-not $same) {
        Write-Host ("  expected: {0}" -f (([Text.Encoding]::UTF8.GetString($expected)) -replace "`n","\n"))
        Write-Host ("  actual:   {0}" -f (([Text.Encoding]::UTF8.GetString($act)) -replace "`n","\n"))
    }
    if ($code -ne 0) { Write-Host ("  exit {0}" -f $code) }
    return $false
}

$allOk = $true

if ($ProveFailure) {
    $t   = $tests | Select-Object -First 1
    $exp = [System.IO.File]::ReadAllBytes((Join-Path $dir ($t.BaseName + '.expected')))
    $bad = $exp.Clone(); $bad[0] = $bad[0] -bxor 0xFF     # flip one golden byte
    Write-Host 'ProveFailure: one golden byte corrupted' -ForegroundColor Yellow
    $detected = -not (Run-One $t $bad ($t.BaseName + ' (corrupted, expect mismatch)'))
    if ($detected) { Write-Host 'ProveFailure: mismatch correctly detected' -ForegroundColor Green }
    else { Write-Host 'ProveFailure: NOT detected -- the check is broken' -ForegroundColor Red; $allOk = $false }
}
else {
    foreach ($t in $tests) {
        $exp = [System.IO.File]::ReadAllBytes((Join-Path $dir ($t.BaseName + '.expected')))
        if (-not (Run-One $t $exp $t.BaseName)) { $allOk = $false }
    }
}

Write-Host ''
if ($allOk) { Write-Host 'CLASSIC OK' -ForegroundColor Green; exit 0 }
else { Write-Host 'CLASSIC FAILED' -ForegroundColor Red; exit 1 }
