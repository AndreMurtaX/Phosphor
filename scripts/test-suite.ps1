<#
.SYNOPSIS
  Builds the headless suite runner (phosphortest) and runs it over the phase-1
  oracle files, byte-comparing each summary to its golden and checking exit code.

.DESCRIPTION
  The engine's real acceptance test. For each .bas file the runner prints a
  byte-exact summary (passed:/failed:) to stdout; this script captures it with
  cmd redirection (so bytes are not re-encoded) and compares to <file>.expected.

  Discipline: -ProveFailure corrupts one expected value in 00_harness and
  confirms the runner reports a failure and exits non-zero -- the check is seen
  failing before it is trusted.
#>
[CmdletBinding()]
param(
    [switch] $ProveFailure,
    [string] $Fpc
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

# --- boundary check: the engine must not reach a host/GUI unit ---------------
$forbidden = @('crt','video','keyboard','lcl','lclintf','lcltype','forms','controls',
               'dialogs','graphics','interfaces','windows','unix','baseunix')
foreach ($src in Get-ChildItem (Join-Path $root 'engine') -Filter *.pas -Recurse) {
    $text = Get-Content -Raw -LiteralPath $src.FullName
    # Strip Pascal comments first: a unit name mentioned in prose (e.g. an engine
    # comment that names the LCL host it must NOT reach) is documentation, not a
    # dependency, and must not trip the check.
    $text = [regex]::Replace($text, '(?m)//.*?$', ' ')
    $text = [regex]::Replace($text, '(?s)\{.*?\}', ' ')
    $text = [regex]::Replace($text, '(?s)\(\*.*?\*\)', ' ')
    foreach ($m in [regex]::Matches($text, '(?is)\buses\b(.*?);')) {
        foreach ($u in $forbidden) {
            if ($m.Groups[1].Value.ToLowerInvariant() -match "(^|[\s,])$([regex]::Escape($u))([\s,]|$)") {
                throw "boundary violation: $($src.Name) uses '$u'"
            }
        }
    }
}
Write-Host 'boundary check: engine stays host-agnostic' -ForegroundColor DarkGray

# --- build the runner --------------------------------------------------------
$fpcExe   = Resolve-Fpc
$binDir   = Join-Path $root 'bin'
$unitsDir = Join-Path $binDir 'units\x86_64-win64'
$exe      = Join-Path $binDir 'phosphortest.exe'
New-Item -ItemType Directory -Force $unitsDir | Out-Null
if (Test-Path $exe) { Remove-Item $exe -Force }

& $fpcExe -Mobjfpc -Scghi -O2 -vewn "-TWin64" `
    "-Fu$(Join-Path $root 'engine')" "-Fu$(Join-Path $root 'engine\libs')" "-Fu$(Join-Path $root 'tests')" `
    "-FU$unitsDir" "-FE$binDir" "-o$exe" `
    (Join-Path $root 'host\console\phosphortest.lpr') | Out-Null
if (-not (Test-Path $exe)) { throw "phosphortest did not build (fpc exit $LASTEXITCODE)" }
Write-Host "runner built: $exe" -ForegroundColor DarkGray
Write-Host ''

# --- run the manifest --------------------------------------------------------
$suite = Join-Path $root 'tests\suite'
$negDir = Join-Path $root 'tests\negative'
# Single-source manifest, shared with test-suite.sh so Windows/Linux never drift.
$manifest = Get-Content (Join-Path $suite 'manifest.txt') |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
$tmp = [System.IO.Path]::GetTempPath()

function Run-One([string] $basPath, [byte[]] $expected, [int] $wantExit, [string] $label) {
    $out = Join-Path $tmp 'phosphortest.out'
    $err = Join-Path $tmp 'phosphortest.err'
    # Redirect BOTH streams inside cmd: the runner writes failure detail to
    # stderr, and PowerShell's Stop preference would treat that as terminating.
    cmd /c "`"$exe`" `"$basPath`" > `"$out`" 2> `"$err`""
    $code = $LASTEXITCODE
    $act = [System.IO.File]::ReadAllBytes($out)
    $same = ($act.Length -eq $expected.Length)
    if ($same) { for ($i=0; $i -lt $act.Length; $i++) { if ($act[$i] -ne $expected[$i]) { $same=$false; break } } }
    $okExit = ($code -eq $wantExit)
    if ($same -and $okExit) {
        Write-Host ("PASS  {0}  ({1} B, exit {2})" -f $label, $act.Length, $code) -ForegroundColor Green
        return $true
    }
    Write-Host ("FAIL  {0}" -f $label) -ForegroundColor Red
    if (-not $same) {
        Write-Host ("  expected: {0}" -f ([Text.Encoding]::ASCII.GetString($expected) -replace "`n","\n"))
        Write-Host ("  actual:   {0}" -f ([Text.Encoding]::ASCII.GetString($act) -replace "`n","\n"))
    }
    if (-not $okExit) { Write-Host ("  exit {0}, wanted {1}" -f $code, $wantExit) }
    return $false
}

$allOk = $true

if ($ProveFailure) {
    # Corrupt one expected value so an assertion fails; the summary must change
    # (failed:1) and the exit code become 1.
    $bad = Join-Path $tmp 'harness_broken.bas'
    (Get-Content -Raw (Join-Path $suite '00_harness.bas')) -replace 'assert_eq\(2 \+ 3, 5\)', 'assert_eq(2 + 3, 6)' |
        Set-Content -LiteralPath $bad -NoNewline -Encoding utf8
    $goodGolden = [System.IO.File]::ReadAllBytes((Join-Path $suite '00_harness.expected'))
    Write-Host 'ProveFailure: one expected value corrupted' -ForegroundColor Yellow
    # Against the GOOD golden this must FAIL (bytes differ) and exit 1, so a PASS
    # here would itself be the bug. We assert the run FAILs the comparison.
    $detected = -not (Run-One $bad $goodGolden 0 '00_harness (corrupted, expect mismatch)')
    if ($detected) { Write-Host 'ProveFailure: mismatch correctly detected' -ForegroundColor Green }
    else { Write-Host 'ProveFailure: NOT detected -- the check is broken' -ForegroundColor Red; $allOk = $false }
}
else {
    # THE MANIFEST MUST COVER THE DIRECTORY, BOTH WAYS. Nothing used to check this. A
    # .bas dropped into tests\suite and never listed simply did not run -- on either
    # OS -- while scripts\coverage.py still counted it as "exercised by a test",
    # because that gate globs tests\**\*.bas rather than reading the manifest. The
    # two checks then agreed on a green nobody had earned.
    $onDisk = @(Get-ChildItem $suite -Filter *.bas | ForEach-Object { $_.BaseName })
    if ($onDisk.Count -eq 0) {
        Write-Host 'FAIL  manifest: tests\suite holds no .bas files at all' -ForegroundColor Red
        $allOk = $false
    }
    foreach ($b in $onDisk) {
        if ($manifest -notcontains $b) {
            Write-Host ("FAIL  manifest: {0}.bas is in tests\suite but not in manifest.txt -- it never runs" -f $b) -ForegroundColor Red
            $allOk = $false
        }
    }
    foreach ($name in $manifest) {
        if (-not (Test-Path (Join-Path $suite "$name.bas"))) {
            Write-Host ("FAIL  manifest: {0} is listed but {0}.bas is missing" -f $name) -ForegroundColor Red
            $allOk = $false
        }
        if (-not (Test-Path (Join-Path $suite "$name.expected"))) {
            Write-Host ("FAIL  manifest: {0} is listed but {0}.expected is missing" -f $name) -ForegroundColor Red
            $allOk = $false
        }
    }

    foreach ($name in $manifest) {
        $bas = Join-Path $suite "$name.bas"
        $expPath = Join-Path $suite "$name.expected"
        # A manifest entry with no file was already reported above. Skipping it here
        # is what lets the run reach its SUMMARY: ReadAllBytes on a missing golden
        # throws under ErrorActionPreference=Stop, and the script died mid-run --
        # printing the diagnosis and then never printing SUITE FAILED.
        if (-not (Test-Path $bas) -or -not (Test-Path $expPath)) { continue }
        $exp = [System.IO.File]::ReadAllBytes($expPath)
        if (-not (Run-One $bas $exp 0 $name)) { $allOk = $false }
    }

    # Negatives: each MUST be rejected (non-zero exit). A negative that RUNS is
    # a failure of the language, so this is a real gate, not decoration.
    # A missing directory used to be skipped in silence and an empty one produced an
    # empty loop -- either way the suite stayed green while proving nothing about
    # rejection. (On Linux the same emptiness printed "PASS  reject: *.bas", the
    # unexpanded glob reading as a correct rejection.) Both are failures now.
    $negFiles = @()
    if (Test-Path $negDir) { $negFiles = @(Get-ChildItem $negDir -Filter *.bas | Sort-Object Name) }
    if ($negFiles.Count -eq 0) {
        Write-Host ''
        Write-Host 'FAIL  negatives: no .bas files found in tests\negative -- the suite proves nothing about rejection' -ForegroundColor Red
        $allOk = $false
    }
    if ($negFiles.Count -gt 0) {
        Write-Host ''
        foreach ($neg in $negFiles) {
            $out = Join-Path $tmp 'phosphortest.out'
            $err = Join-Path $tmp 'phosphortest.err'
            cmd /c "`"$exe`" `"$($neg.FullName)`" > `"$out`" 2> `"$err`""
            $code = $LASTEXITCODE
            if ($code -ne 0) {
                $why = (Get-Content -Raw $err).Trim()
                Write-Host ("PASS  reject: {0}  (exit {1})" -f $neg.Name, $code) -ForegroundColor Green
                if ($why) { Write-Host ("         {0}" -f $why) -ForegroundColor DarkGray }
            } else {
                Write-Host ("FAIL  reject: {0}  ran instead of being rejected" -f $neg.Name) -ForegroundColor Red
                $allOk = $false
            }
        }
    }

    # Pascal probes + the embed host: host-facing programs a .bas file cannot
    # express (the value kernel, the execution limits, the embedding API). Each
    # prints ok:/fail: and exits non-zero on a failure.
    Write-Host ''
    $hostProbes = @(
        @{ name='probe_value';    src='tests\probe_value.lpr' },
        @{ name='probe_limits';   src='tests\probe_limits.lpr' },
        @{ name='probe_bytecode'; src='tests\probe_bytecode.lpr' },
        @{ name='probe_sandbox';  src='tests\probe_sandbox.lpr' },
        @{ name='phosphorembed';  src='host\embed\phosphorembed.lpr' }
    )
    foreach ($hp in $hostProbes) {
        $psrc = Join-Path $root $hp.src
        # A probe whose SOURCE has gone missing used to be skipped in silence, so
        # deleting tests\probe_bytecode.lpr or host\embed\phosphorembed.lpr still
        # printed SUITE OK. Not running is not passing.
        if (-not (Test-Path $psrc)) {
            Write-Host ("FAIL  probe: {0}  source {1} is missing" -f $hp.name, $hp.src) -ForegroundColor Red
            $allOk = $false
            continue
        }
        $pexe = Join-Path $binDir ($hp.name + '.exe')
        if (Test-Path $pexe) { Remove-Item $pexe -Force }
        & $fpcExe -Mobjfpc -Scghi -O2 -vewn "-TWin64" `
            "-Fu$(Join-Path $root 'engine')" "-Fu$(Join-Path $root 'engine\libs')" `
            "-FU$unitsDir" "-FE$binDir" "-o$pexe" $psrc | Out-Null
        if (-not (Test-Path $pexe)) { Write-Host ("FAIL  probe: {0}  did not build" -f $hp.name) -ForegroundColor Red; $allOk = $false; continue }
        $pout = Join-Path $tmp 'probe.out'
        $perr = Join-Path $tmp 'probe.err'
        cmd /c "`"$pexe`" > `"$pout`" 2> `"$perr`""
        $pcode = $LASTEXITCODE
        $psum = (((Get-Content -Raw $pout) -split "`r?`n" | Where-Object { $_ -match '^(ok|fail):' }) -join ' ').Trim()
        if ($pcode -eq 0) { Write-Host ("PASS  probe: {0}  ({1})" -f $hp.name, $psum) -ForegroundColor Green }
        else {
            Write-Host ("FAIL  probe: {0}  ({1})" -f $hp.name, $psum) -ForegroundColor Red
            $why = (Get-Content -Raw $perr).Trim(); if ($why) { Write-Host ("         {0}" -f $why) -ForegroundColor DarkGray }
            $allOk = $false
        }
    }
}

# --- source-level gates -------------------------------------------------------
# Two invariants no compiler can check and no golden happens to cover:
#   check-codepage.py  no Char is concatenated into a code-page string (bytes >= 128
#                      are silently destroyed; the class has been swept three times)
#   coverage.py        every registered built-in is exercised by a test AND listed in
#                      the function reference
#   check-sandbox.py   every routine a script can reach that touches the filesystem
#                      asks the sandbox gate first (or is exempt, by name, with a
#                      reason) -- the rule that would otherwise rot one new function
#                      at a time
# They are run HERE, in the acceptance gate, rather than in the build: building
# should not need Python, but passing the suite should mean the invariants hold.
# A missing interpreter is a FAILURE, not a skip -- a gate that quietly does not run
# is worse than no gate, because it reads as a pass.
Write-Host ''
$py = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $py) { $py = (Get-Command python3 -ErrorAction SilentlyContinue) }
if (-not $py) {
    Write-Host 'FAIL  gates: no python interpreter found (needed by the source checks)' -ForegroundColor Red
    $allOk = $false
} else {
    foreach ($gate in @('check-codepage.py', 'coverage.py', 'check-sandbox.py')) {
        $gp = Join-Path $here $gate
        # The comment above says a gate that quietly does not run is worse than no
        # gate, and then this line skipped a gate whose FILE was missing -- exactly
        # the case that sentence was written about.
        if (-not (Test-Path $gp)) {
            Write-Host ("FAIL  gate: {0} is missing from scripts/" -f $gate) -ForegroundColor Red
            $allOk = $false
            continue
        }
        $gout = & $py.Source $gp 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("PASS  gate: {0}" -f $gate) -ForegroundColor Green
        } else {
            Write-Host ("FAIL  gate: {0}" -f $gate) -ForegroundColor Red
            $gout | ForEach-Object { Write-Host ("         {0}" -f $_) -ForegroundColor DarkGray }
            $allOk = $false
        }
    }
}

Write-Host ''
if ($allOk) { Write-Host 'SUITE OK' -ForegroundColor Green; exit 0 }
else { Write-Host 'SUITE FAILED' -ForegroundColor Red; exit 1 }
