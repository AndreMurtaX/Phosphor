<#
.SYNOPSIS
  Runs every program in examples/ and byte-compares it to a golden.

.DESCRIPTION
  WHY THIS EXISTS. examples/ is the face of the project -- the README points at
  it, and it is the first code anyone runs. Nothing executed it. Every other
  corpus in tests/ has a runner; the one directory a person actually opens had
  none, so `examples/interactive.bas` shipped answering every INPUT with an empty
  string (the GUI host assigned no input seam) and `examples/crt_keys.bas` shipped
  unable to reach its own last line (`x$ = crt_done()`, a number into a string).
  Both were found by a human typing the command. That is not a test strategy.

  Three modes, because the examples are not all the same kind of program:

    run      -- run it with stdin closed, compare stdout+stderr to <name>.expected
    input    -- the same, with <name>.in piped in (a recorded session)
    compile  -- compile only. For a program that opens a window and waits: the
                compiler is host-agnostic and needs no display, so "it still
                compiles" is what CAN be checked, and it is checked rather than
                skipped in silence.

  Every run is SANDBOXED to the checkout (--sandbox), so an example that writes
  files cannot write them anywhere else.

  The manifest covers the directory in both directions: a .bas with no manifest
  entry fails, and an entry with no .bas fails. A new example cannot be added
  without saying how it is verified.

.PARAMETER ProveFailure
  Corrupt one golden and confirm the comparison reports it.
#>
[CmdletBinding()]
param(
    [switch] $ProveFailure,
    [string] $Fpc
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$examples = Join-Path $root 'examples'
$exe = Join-Path $root 'bin\phosphor.exe'

# --- the binary this suite needs must be the CURRENT one ----------------------
# Running a stale binary is running old code; on 2026-09-05 that cost thirteen
# projects. Build first, always.
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'build.ps1') @(
    if ($Fpc) { '-Fpc'; $Fpc }) | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL  build: phosphor did not build' -ForegroundColor Red; exit 1 }
if (-not (Test-Path $exe)) { Write-Host 'FAIL  build: no phosphor.exe' -ForegroundColor Red; exit 1 }

# --- manifest, both directions ------------------------------------------------
$manifestPath = Join-Path $examples 'manifest.txt'
if (-not (Test-Path $manifestPath)) {
    Write-Host 'FAIL  manifest: examples/manifest.txt is missing' -ForegroundColor Red; exit 1
}
$entries = @()
foreach ($line in Get-Content $manifestPath) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $parts = $t.Split('|')
    if ($parts.Count -ne 2) {
        Write-Host ("FAIL  manifest: '{0}' is not '<name>|<mode>'" -f $t) -ForegroundColor Red; exit 1
    }
    $entries += @{ name = $parts[0].Trim(); mode = $parts[1].Trim() }
}

$allOk = $true
$onDisk = Get-ChildItem $examples -Filter *.bas | ForEach-Object { $_.BaseName }
foreach ($b in $onDisk) {
    if ($entries.name -notcontains $b) {
        Write-Host ("FAIL  manifest: {0}.bas is in examples/ but not in manifest.txt -- it never runs" -f $b) -ForegroundColor Red
        $allOk = $false
    }
}
foreach ($e in $entries) {
    if ($onDisk -notcontains $e.name) {
        Write-Host ("FAIL  manifest: {0} is listed but {0}.bas is missing" -f $e.name) -ForegroundColor Red
        $allOk = $false
    }
}
if (-not $allOk) { Write-Host ''; Write-Host 'EXAMPLES FAILED' -ForegroundColor Red; exit 1 }

$tmp = Join-Path $env:TEMP ('phosphor-examples-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null

foreach ($e in $entries) {
    $bas = Join-Path $examples ($e.name + '.bas')
    $gold = Join-Path $examples ($e.name + '.expected')
    $out = Join-Path $tmp ($e.name + '.out')

    if ($e.mode -eq 'compile') {
        $pbc = Join-Path $tmp ($e.name + '.pbc')
        & $exe compile $bas $pbc 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $pbc)) {
            Write-Host ("PASS  {0}  (compiles; it opens a window, so it is not run here)" -f $e.name) -ForegroundColor Green
        } else {
            Write-Host ("FAIL  {0}  did not compile (exit {1})" -f $e.name, $LASTEXITCODE) -ForegroundColor Red
            $allOk = $false
        }
        continue
    }

    if (-not (Test-Path $gold)) {
        Write-Host ("FAIL  {0}  has no golden ({0}.expected)" -f $e.name) -ForegroundColor Red
        $allOk = $false
        continue
    }

    # cmd redirection, so the bytes are not re-encoded on the way to the file.
    if ($e.mode -eq 'input') {
        $inFile = Join-Path $examples ($e.name + '.in')
        if (-not (Test-Path $inFile)) {
            Write-Host ("FAIL  {0}  is listed as 'input' but {0}.in is missing" -f $e.name) -ForegroundColor Red
            $allOk = $false
            continue
        }
        cmd /c "`"$exe`" --sandbox `"$root`" run `"$bas`" > `"$out`" 2>&1 < `"$inFile`""
    } elseif ($e.mode -eq 'run') {
        cmd /c "`"$exe`" --sandbox `"$root`" run `"$bas`" > `"$out`" 2>&1 < NUL"
    } else {
        Write-Host ("FAIL  {0}  unknown mode '{1}'" -f $e.name, $e.mode) -ForegroundColor Red
        $allOk = $false
        continue
    }
    $code = $LASTEXITCODE

    $actual = [IO.File]::ReadAllBytes($out)
    $want = [IO.File]::ReadAllBytes($gold)
    if ($ProveFailure -and $e.name -eq $entries[0].name -and $want.Length -gt 0) {
        $want = $want.Clone(); $want[0] = [byte](($want[0] + 1) % 256)
        Write-Host 'ProveFailure: one golden byte corrupted' -ForegroundColor Yellow
    }
    $same = ($actual.Length -eq $want.Length)
    if ($same) { for ($i = 0; $i -lt $actual.Length; $i++) { if ($actual[$i] -ne $want[$i]) { $same = $false; break } } }

    if ($same -and $code -eq 0) {
        Write-Host ("PASS  {0}  ({1} B, exit 0)" -f $e.name, $actual.Length) -ForegroundColor Green
    } else {
        Write-Host ("FAIL  {0}  (exit {1})" -f $e.name, $code) -ForegroundColor Red
        if (-not $same) {
            Write-Host ("        expected {0} B, got {1} B" -f $want.Length, $actual.Length) -ForegroundColor DarkGray
            $head = [Text.Encoding]::UTF8.GetString($actual)
            if ($head.Length -gt 400) { $head = $head.Substring(0, 400) + ' ...' }
            Write-Host ("        got: {0}" -f ($head -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
        }
        $allOk = $false
    }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host ''
if ($ProveFailure) {
    if ($allOk) { Write-Host 'ProveFailure: the corruption was NOT detected' -ForegroundColor Red; exit 1 }
    Write-Host 'ProveFailure: mismatch correctly detected' -ForegroundColor Yellow
    Write-Host 'EXAMPLES OK' -ForegroundColor Green
    exit 0
}
if ($allOk) { Write-Host 'EXAMPLES OK' -ForegroundColor Green; exit 0 }
Write-Host 'EXAMPLES FAILED' -ForegroundColor Red
exit 1
