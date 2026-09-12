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
# Every scratch path in this script hangs off $tmp, and $tmp is a per-PROCESS
# directory rather than the shared user TEMP. Fixed names directly under TEMP
# meant two runs at once -- two worktrees, two agents -- clobbered each other's
# output and died on a file lock, which reads exactly like a test failure. The
# bash twin has always used mktemp.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "phosphor-run-$PID"
if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp | Out-Null }

# `Get-Content -Raw` answers $null for an EMPTY file, and $null.Trim() throws a
# null-reference that $ErrorActionPreference = 'Stop' turns into a dead run. Every
# caller here reads the stderr of something that may have said nothing at all.
function Read-Text([string] $path) {
    if (-not (Test-Path $path)) { return '' }
    $raw = Get-Content -Raw $path
    if ($null -eq $raw) { return '' }
    return $raw.Trim()
}

# NOT removed at the end, and that is a decision rather than an oversight. Emptying
# it would take a recursive removal, which this tree forbids outright -- it lost
# thirteen working copies to one. Three cleanups were written and measured here on
# 2026-09-11: one sat after `exit` and was dead code; one used Remove-Item, which
# PROMPTS on a non-empty directory and hung a run for an hour with no console to
# answer it; one used Directory.Delete, which is correct rmdir and therefore
# removed nothing, because this directory always holds the run's scratch. A few
# kilobytes under TEMP is the operating system's to reclaim. The directory earns
# its keep by isolating concurrent runs, which is what it was added for.
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

# C. packed standalone executable. pack takes COMPILED bytecode, so the pipeline
#    is compile-then-pack: run the result with no arguments and compare, which
#    proves the .pbc rides in the binary.
$pbc     = Join-Path $tmp 'phosphor_hello.pbc'
$packExe = Join-Path $tmp 'phosphor_hello_packed.exe'
$outC    = Join-Path $tmp 'phosphor_hello.C.actual'
& $exe 'compile' $bas $pbc
if ($LASTEXITCODE -ne 0) { throw "compile exited $LASTEXITCODE" }
& $exe 'pack' $pbc $packExe
if ($LASTEXITCODE -ne 0) { throw "pack exited $LASTEXITCODE" }
cmd /c "`"$packExe`" > `"$outC`""
if ($LASTEXITCODE -ne 0) { throw "packed exe exited $LASTEXITCODE" }

# D. packed with --no-console: the choice is BAKED INTO THE FILE, because a packed
#    program ignores its command line. Redirected output must be untouched by it --
#    a windowed program with no console still writes its log.
$packExeD = Join-Path $tmp 'phosphor_hello_packed_noconsole.exe'
$outD     = Join-Path $tmp 'phosphor_hello.D.actual'
& $exe 'pack' '--no-console' $pbc $packExeD
if ($LASTEXITCODE -ne 0) { throw "pack --no-console exited $LASTEXITCODE" }
cmd /c "`"$packExeD`" > `"$outD`""
if ($LASTEXITCODE -ne 0) { throw "packed --no-console exe exited $LASTEXITCODE" }

Write-Host ''
$okA = Test-Golden 'A:--out        ' $outA $expectedBytes
$okB = Test-Golden 'B:stdout-redir ' $outB $expectedBytes
$okC = Test-Golden 'C:packed       ' $outC $expectedBytes
$okD = Test-Golden 'D:packed-noconsole' $outD $expectedBytes

# The trailer has to be the VERSIONED one, or there is nowhere for a flag to live
# and the stub would be reading a format it was not told about.
$okE = $true
foreach ($f in @($packExe, $packExeD)) {
    $b = [IO.File]::ReadAllBytes($f)
    $magic = [Text.Encoding]::ASCII.GetString($b, $b.Length - 8, 8)
    if ($magic -ne 'PHOSPBC2') {
        Write-Host ("FAIL  trailer: {0} ends with '{1}', wanted 'PHOSPBC2'" -f (Split-Path -Leaf $f), $magic) -ForegroundColor Red
        $okE = $false
    }
}
if ($okE) { Write-Host "PASS  E:trailer        (both packed files carry a v2 trailer)" -ForegroundColor Green }

# F. pack REFUSES source. The rule is only real if something fails when it is
#    broken, and the message has to name the two commands that were meant.
$refuseOut = Join-Path $tmp 'phosphor_pack_refuse.txt'
cmd /c "`"$exe`" pack `"$bas`" `"$(Join-Path $tmp 'never.exe')`" > `"$refuseOut`" 2>&1"
$refuseCode = $LASTEXITCODE
$refuseText = Get-Content -Raw $refuseOut
$okF = ($refuseCode -eq 2) -and ($refuseText -like '*not a .pbc*') -and ($refuseText -like '*phosphor compile*')
if ($okF) { Write-Host "PASS  F:pack refuses source (exit 2, and says how to compile)" -ForegroundColor Green }
else {
    Write-Host ("FAIL  F:pack refuses source (exit {0})" -f $refuseCode) -ForegroundColor Red
    Write-Host ("        {0}" -f ($refuseText -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
}

# G. A name no host built from this binary can provide. The COMPILER cannot judge
#    that -- it has no registry, which is what lets one .pbc run on hosts with
#    different packages -- but PACK can, because the executable it writes carries
#    this very binary as its stub.
$badBas = Join-Path $tmp 'phosphor_badname.bas'
Set-Content -LiteralPath $badBas -Encoding ascii -Value @(
    'println "before"',
    'x = no_such_function_anywhere(1)'
)
$badPbc = Join-Path $tmp 'phosphor_badname.pbc'
$checkOut = Join-Path $tmp 'phosphor_badname.check.txt'

# compile alone must NOT complain: late binding is the point.
cmd /c "`"$exe`" compile `"$badBas`" `"$badPbc`" > `"$checkOut`" 2>&1"
$okG1 = ($LASTEXITCODE -eq 0) -and ((Get-Content -Raw $checkOut) -eq $null -or (Get-Content -Raw $checkOut).Trim() -eq '')

# compile --check must WARN and still succeed, and still write the file.
cmd /c "`"$exe`" compile --check `"$badBas`" `"$badPbc`" > `"$checkOut`" 2>&1"
$checkText = Get-Content -Raw $checkOut
$okG2 = ($LASTEXITCODE -eq 0) -and (Test-Path $badPbc) -and
        ($checkText -like '*warning*') -and ($checkText -like '*no_such_function_anywhere*')

# pack must REFUSE it, name it, and write no executable.
$neverExe = Join-Path $tmp 'phosphor_never.exe'
if (Test-Path $neverExe) { Remove-Item $neverExe -Force }
cmd /c "`"$exe`" pack `"$badPbc`" `"$neverExe`" > `"$checkOut`" 2>&1"
$packCode = $LASTEXITCODE
$packText = Get-Content -Raw $checkOut
$okG3 = ($packCode -eq 1) -and ($packText -like '*no_such_function_anywhere*')

$okG = $okG1 -and $okG2 -and $okG3
if ($okG) { Write-Host "PASS  G:name check     (compile is silent, --check warns, pack refuses)" -ForegroundColor Green }
else {
    Write-Host "FAIL  G:name check" -ForegroundColor Red
    Write-Host ("        compile silent={0}  --check warned={1}  pack refused={2}" -f $okG1, $okG2, $okG3) -ForegroundColor DarkGray
    Write-Host ("        last output: {0}" -f ($packText -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
}

# H/I. A COMMAND THAT CANNOT WRITE ITS OUTPUT MUST SAY SO. `compile` and `pack`
#      used to exit 0 with zero bytes on both streams and no file produced, so a
#      build script that checked the exit code was told the artifact existed and
#      the next step packed or ran a stale one. Two shapes that fail for two
#      different OS reasons, because one of them passing is not the rule.
$hi = Join-Path $tmp 'phosphor_unwritable'
if (Test-Path $hi) { Remove-Item $hi -Recurse -Force }
New-Item -ItemType Directory -Force $hi | Out-Null
New-Item -ItemType Directory -Force (Join-Path $hi 'adir') | Out-Null
$hiOut = Join-Path $tmp 'phosphor_unwritable.txt'

function Test-Unwritable([string] $verb, [string] $inFile, [string] $shape, [string] $target) {
    cmd /c "`"$exe`" $verb `"$inFile`" `"$target`" > `"$hiOut`" 2>&1"
    $code = $LASTEXITCODE
    $text = Get-Content -Raw $hiOut
    if ($null -eq $text) { $text = '' }
    $ok = ($code -ne 0) -and ($text -like '*cannot write to*') -and (-not (Test-Path -PathType Leaf $target))
    if (-not $ok) {
        Write-Host ("        {0} / {1}: exit {2}, said '{3}'" -f $verb, $shape, $code,
                    ($text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
    }
    return $ok
}

$okH = (Test-Unwritable 'compile' $bas 'missing directory' (Join-Path $hi 'nodir\x.pbc')) -and
       (Test-Unwritable 'compile' $bas 'output is a directory' (Join-Path $hi 'adir'))
if ($okH) { Write-Host "PASS  H:compile unwritable (exit<>0, names the path, writes nothing)" -ForegroundColor Green }
else { Write-Host "FAIL  H:compile unwritable output is silent" -ForegroundColor Red }

$okI = (Test-Unwritable 'pack' $pbc 'missing directory' (Join-Path $hi 'nodir\app.exe')) -and
       (Test-Unwritable 'pack' $pbc 'output is a directory' (Join-Path $hi 'adir'))
if ($okI) { Write-Host "PASS  I:pack unwritable    (exit<>0, names the path, writes nothing)" -ForegroundColor Green }
else { Write-Host "FAIL  I:pack unwritable output is silent" -ForegroundColor Red }

# J. A PACKED EXECUTABLE WHOSE PAYLOAD WILL NOT VERIFY MUST REFUSE, NOT PROMPT.
#    It used to fall through to the CLI, and the CLI with no arguments is an
#    interactive BASIC prompt that runs whatever is typed and never ends by
#    itself: a corrupted or tampered MyApp.exe handed a user a shell, and every
#    script that shipped it saw exit 0.
#
#    The three damaged files are built by SPLICING two genuinely packed
#    executables, so no byte pattern has to be guessed: both carry an intact
#    PHOSPBC2 magic -- the file still says "I am a packed application" -- and
#    only the trailer's description of the payload is wrong.
$basB = Join-Path $tmp 'phosphor_second.bas'
Set-Content -LiteralPath $basB -Encoding ascii -Value 'println "a second program, with different bytes and a different length"'
$pbcB = Join-Path $tmp 'phosphor_second.pbc'
$exeB = Join-Path $tmp 'phosphor_second_packed.exe'
& $exe 'compile' $basB $pbcB
if ($LASTEXITCODE -ne 0) { throw "compile (second) exited $LASTEXITCODE" }
& $exe 'pack' $pbcB $exeB
if ($LASTEXITCODE -ne 0) { throw "pack (second) exited $LASTEXITCODE" }

$bytesA = [IO.File]::ReadAllBytes($packExe)
$bytesB = [IO.File]::ReadAllBytes($exeB)
function New-Damaged([string] $path, [int] $keep, [byte[]] $tail) {
    $fs = [IO.File]::Create($path)
    try { $fs.Write($bytesA, 0, $keep); $fs.Write($tail, 0, $tail.Length) } finally { $fs.Close() }
}
function Tail([byte[]] $b, [int] $n) {
    $t = New-Object byte[] $n; [Array]::Copy($b, $b.Length - $n, $t, 0, $n); return $t
}
$dmg1 = Join-Path $tmp 'phosphor_damaged_trailer.exe'   # the whole trailer from B
$dmg2 = Join-Path $tmp 'phosphor_damaged_cksum.exe'     # only the checksum from B
$dmg3 = Join-Path $tmp 'phosphor_damaged_flags.exe'     # flag bits this build has never defined
New-Damaged $dmg1 ($bytesA.Length - 32) (Tail $bytesB 32)
New-Damaged $dmg2 ($bytesA.Length - 16) ((Tail $bytesB 16)[0..3] + (Tail $bytesA 12))
New-Damaged $dmg3 ($bytesA.Length - 12) (([byte[]](0xFF,0xFF,0xFF,0xFF)) + (Tail $bytesA 8))

$okJ = $true
foreach ($d in @(@($dmg1,'trailer'), @($dmg2,'checksum'), @($dmg3,'unknown flags'))) {
    cmd /c "`"$($d[0])`" < NUL > `"$hiOut`" 2>&1"
    $code = $LASTEXITCODE
    $text = Get-Content -Raw $hiOut
    if ($null -eq $text) { $text = '' }
    # exit 2 is this host's "I will not run: what I was given is wrong", the same
    # code a missing file, an unwritable --out and an unbindable sandbox answer.
    $good = ($code -eq 2) -and ($text -like '*corrupt*') -and ($text -notlike '*REPL*')
    if (-not $good) {
        $okJ = $false
        Write-Host ("        damaged {0}: exit {1}, said '{2}'" -f $d[1], $code,
                    ($text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
    }
}
if ($okJ) { Write-Host "PASS  J:corrupt payload    (exit 2, says so, never opens a prompt)" -ForegroundColor Green }
else { Write-Host "FAIL  J:corrupt payload falls through to the CLI" -ForegroundColor Red }

# K. THE MIRROR, and it matters as much as J. A file that carries NO evidence of
#    being packed -- no mark in its middle and no magic in its tail -- is a bare
#    stub, and being the CLI is then exactly right: that is the whole reason one
#    binary can be both. A refusal that swallowed this case would have broken
#    `phosphor` itself.
#
#    THE SECOND SHAPE USED TO BE "a packed file truncated past its magic", AND
#    THAT EXPECTATION WAS THE DEFECT. A truncated application is a damaged
#    application, not a bare stub; it is refused in L below, and this letter now
#    holds two files that genuinely carry no program: the stub as built, and the
#    stub with trailing bytes that are not a trailer -- the shape a resource
#    appender or an installer footer leaves behind.
$stubBytes = [IO.File]::ReadAllBytes($exe)
$stubJunk  = Join-Path $tmp 'phosphor_stub_plus_junk.exe'
$junkTail  = [Text.Encoding]::ASCII.GetBytes('not a trailer, just some bytes riding along')
$fsK = [IO.File]::Create($stubJunk)
try { $fsK.Write($stubBytes, 0, $stubBytes.Length); $fsK.Write($junkTail, 0, $junkTail.Length) } finally { $fsK.Close() }

$okK = $true
foreach ($k in @(@($exe,'the stub itself'), @($stubJunk,'the stub with non-trailer bytes appended'))) {
    cmd /c "`"$($k[0])`" < NUL > `"$hiOut`" 2>&1"
    $code = $LASTEXITCODE
    $text = Get-Content -Raw $hiOut
    if ($null -eq $text) { $text = '' }
    $good = ($code -eq 0) -and ($text -like '*REPL*')
    if (-not $good) {
        $okK = $false
        Write-Host ("        {0}: exit {1}, said '{2}'" -f $k[1], $code,
                    ($text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
    }
}
if ($okK) { Write-Host "PASS  K:no magic is the CLI (a bare stub still opens the REPL)" -ForegroundColor Green }
else { Write-Host "FAIL  K:a file with no trailer magic no longer behaves as the CLI" -ForegroundColor Red }

# L. A TRUNCATED PACKED APPLICATION IS A DAMAGED APPLICATION, NOT A BARE STUB.
#    J covers every corruption that leaves the TAIL intact, because the tail was
#    the only place a file said "I am a packed application". Truncation -- an
#    interrupted copy or download, a partial write, an antivirus that cuts a file
#    short, and the commonest corruption there is -- removes exactly those bytes,
#    so the reader found no magic, answered "bare stub" and RunCommandLine opened
#    the REPL with exit 0: a damaged MyApp.exe handing a user a BASIC prompt that
#    runs whatever is typed into it, which is word for word what J exists to
#    refuse. The stub now carries a compiled-in mark in its MIDDLE, where
#    truncation cannot reach, holding the length the packer finished with.
#
#    Each shape asserts its own REASON, not just "corrupt": a refusal that fired
#    for the wrong branch would pass a message-blind check while proving nothing.
function New-Truncated([string] $path, [int] $drop) {
    $fs = [IO.File]::Create($path)
    try { $fs.Write($bytesA, 0, $bytesA.Length - $drop) } finally { $fs.Close() }
}
$trunc4  = Join-Path $tmp 'phosphor_trunc4.exe'
$trunc1  = Join-Path $tmp 'phosphor_trunc1.exe'
$noMagic = Join-Path $tmp 'phosphor_nomagic.exe'
New-Truncated $trunc4 4
New-Truncated $trunc1 1
# The magic overwritten IN PLACE: the same length, so only the mark can tell.
$fsL = [IO.File]::Create($noMagic)
try {
    $fsL.Write($bytesA, 0, $bytesA.Length - 8)
    $fsL.Write([Text.Encoding]::ASCII.GetBytes('XXXXXXXX'), 0, 8)
} finally { $fsL.Close() }

$okL = $true
foreach ($t in @(@($trunc4,'truncated by 4','truncated'),
                 @($trunc1,'truncated by 1','truncated'),
                 @($noMagic,'magic overwritten in place','overwritten'))) {
    cmd /c "`"$($t[0])`" < NUL > `"$hiOut`" 2>&1"
    $code = $LASTEXITCODE
    $text = Get-Content -Raw $hiOut
    if ($null -eq $text) { $text = '' }
    $good = ($code -eq 2) -and ($text -like '*corrupt*') -and
            ($text -like "*$($t[2])*") -and ($text -notlike '*REPL*')
    if (-not $good) {
        $okL = $false
        Write-Host ("        {0}: exit {1}, said '{2}'" -f $t[1], $code,
                    ($text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
    }
}
# AND THE MIRROR OF L, or the length check would be free to refuse everything: an
# intact packed application must still run after being copied somewhere else,
# byte-exact against the same golden as A-D.
$movedApp = Join-Path $tmp 'phosphor_moved_app.exe'
Copy-Item $packExe $movedApp -Force
$outL = Join-Path $tmp 'phosphor_hello.L.actual'
cmd /c "`"$movedApp`" < NUL > `"$outL`""
$movedCode = $LASTEXITCODE
if ($movedCode -ne 0) {
    $okL = $false
    Write-Host ("        an intact packed app, copied elsewhere, exited {0}" -f $movedCode) -ForegroundColor DarkGray
} elseif (-not (Test-Golden 'L:packed, moved ' $outL $expectedBytes)) { $okL = $false }
if ($okL) { Write-Host "PASS  L:truncated payload  (exit 2, says truncated, never opens a prompt)" -ForegroundColor Green }
else { Write-Host "FAIL  L:a truncated packed application falls through to the CLI" -ForegroundColor Red }

# M. `--sandbox ""` MUST REFUSE, exactly as `--sandbox "   "` already did.
#    '' is the encoding for "no sandbox was asked for" AND what an operator hands
#    over when they write `phosphor --sandbox "$RUNDIR" untrusted.bas` with RUNDIR
#    unset. BindSandbox used the VALUE to decide whether the flag had been given,
#    so the empty argument ran the script COMPLETELY UNCONFINED, silently, exit 0
#    -- the outcome that routine's own comment says it exists to prevent -- while
#    the whitespace spelling of the same intent was correctly refused.
#
#    THE EMPTY ARGUMENT HAS TO REACH THE PROGRAM, and PowerShell 5.1 DROPS an
#    empty string when it calls a native binary: `& $exe '--sandbox' '' $bas`
#    arrives as `--sandbox <bas>`, which is refused too -- for the wrong reason,
#    naming the .bas as the root. It is therefore spelled through cmd, and the
#    refusal is matched on the double space that only an EMPTY value can produce.
$sbxDir = Join-Path $tmp 'phosphor_sandbox_arg'
New-Item -ItemType Directory -Force $sbxDir | Out-Null
New-Item -ItemType Directory -Force (Join-Path $sbxDir 'cage') | Out-Null
$sbxBas = Join-Path $sbxDir 'escape.bas'
Set-Content -LiteralPath $sbxBas -Encoding ascii -Value @(
    'println "sandboxroot=[" + sandboxroot$() + "]"',
    'n = file_writealltext("escaped_outside.txt", "ESCAPED")',
    'println "write outside -> " + str$(n)'
)
$sbxEscaped = Join-Path $sbxDir 'escaped_outside.txt'
$sbxOut = Join-Path $tmp 'phosphor_sandbox_arg.txt'

function Invoke-InDir([string] $tail) {
    cmd /c "cd /d `"$sbxDir`" && `"$exe`" $tail < NUL > `"$sbxOut`" 2>&1"
    $script:sbxCode = $LASTEXITCODE
    $t = Get-Content -Raw $sbxOut
    if ($null -eq $t) { $t = '' }
    return $t
}

if (Test-Path $sbxEscaped) { Remove-Item $sbxEscaped -Force }
$mText = Invoke-InDir '--sandbox "" escape.bas'
# Two spaces before the dash: the root printed back is the empty string, which is
# the case under test. A swallowed filename would print the filename there.
$okM1 = ($sbxCode -eq 2) -and ($mText -like '*cannot establish the sandbox root  --*') -and
        ($mText -notlike '*sandboxroot=*') -and (-not (Test-Path $sbxEscaped))

# The whitespace spelling, which was right all along and must stay right.
if (Test-Path $sbxEscaped) { Remove-Item $sbxEscaped -Force }
$mText2 = Invoke-InDir '--sandbox "   " escape.bas'
$okM2 = ($sbxCode -eq 2) -and ($mText2 -like '*cannot establish the sandbox root*') -and
        (-not (Test-Path $sbxEscaped))

# AND THE DOCUMENTED DEFAULT MUST NOT MOVE. No --sandbox is no sandbox: the
# script runs unconfined and the write succeeds. A guard that refused this would
# have broken `phosphor` itself, exactly as a refusal in K would have.
if (Test-Path $sbxEscaped) { Remove-Item $sbxEscaped -Force }
$mText3 = Invoke-InDir 'escape.bas'
# .Contains, not -like: '[]' is an empty character class in the wildcard language
# and -like throws WildcardPatternException on it.
$okM3 = ($sbxCode -eq 0) -and ($mText3.Contains('sandboxroot=[]')) -and
        ($mText3 -like '*write outside -> 1*') -and (Test-Path $sbxEscaped)

# And a real root still confines rather than refuses: the run succeeds, the write
# outside it does not.
if (Test-Path $sbxEscaped) { Remove-Item $sbxEscaped -Force }
$mText4 = Invoke-InDir '--sandbox cage escape.bas'
$okM4 = ($sbxCode -eq 0) -and ($mText4 -like '*cage*') -and
        ($mText4 -like '*write outside -> 0*') -and (-not (Test-Path $sbxEscaped))

$okM = $okM1 -and $okM2 -and $okM3 -and $okM4
if ($okM) { Write-Host "PASS  M:--sandbox `"`" refused (empty argument never runs unconfined)" -ForegroundColor Green }
else {
    Write-Host "FAIL  M:--sandbox argument handling" -ForegroundColor Red
    Write-Host ("        empty={0} whitespace={1} default-unconfined={2} real-root={3}" -f $okM1, $okM2, $okM3, $okM4) -ForegroundColor DarkGray
    Write-Host ("        empty said: {0}" -f ($mText -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
}

# N. `--out ""` MUST REFUSE, for the same reason M does and one `else if` down
#    the same argument loop. TConsoleHost.Create guards with `if AOutPath <> ''`,
#    so '' encodes "no --out was asked for" as well as what `--out "$LOG"` hands
#    over with LOG unset: the flag VANISHED and the program's output went to the
#    terminal at exit 0 with nothing said -- while `--out "   "` was refused on
#    Windows and honoured on Linux. Three answers to one intent.
#    Spelled through cmd for the same reason M is: PowerShell 5.1 drops an empty
#    native argument, and a dropped one would leave `--out job.bas` and consume
#    the script name -- a refusal for the wrong reason, which is not a pass.
$outDir = Join-Path $tmp 'phosphor_out_arg'
New-Item -ItemType Directory -Force $outDir | Out-Null
New-Item -ItemType Directory -Force (Join-Path $outDir 'cage') | Out-Null
$outBas = Join-Path $outDir 'job.bas'
Set-Content -LiteralPath $outBas -Encoding ascii -Value 'println "SECRET-OUTPUT"'
$outLog = Join-Path $tmp 'phosphor_out_arg.txt'
$outReal = Join-Path $outDir 'real.txt'

function Invoke-OutDir([string] $tail) {
    cmd /c "cd /d `"$outDir`" && `"$exe`" $tail < NUL > `"$outLog`" 2>&1"
    $script:outCode = $LASTEXITCODE
    $t = Get-Content -Raw $outLog
    if ($null -eq $t) { $t = '' }
    return $t
}

if (Test-Path $outReal) { Remove-Item $outReal -Force }
$nText = Invoke-OutDir '--out "" job.bas'
$okN1 = ($outCode -eq 2) -and ($nText -like '*--out needs a path*') -and
        ($nText -notlike '*SECRET-OUTPUT*') -and (-not (Test-Path $outReal))

# ...and with a sandbox bound too, which is where it was worst: the operator had
# asked for confinement AND for a log, and got a wide-open terminal instead.
$nText2 = Invoke-OutDir '--sandbox cage --out "" job.bas'
$okN2 = ($outCode -eq 2) -and ($nText2 -like '*--out needs a path*') -and
        ($nText2 -notlike '*SECRET-OUTPUT*')

# AND THE DOCUMENTED DEFAULT MUST NOT MOVE. No --out is stdout.
$nText3 = Invoke-OutDir 'job.bas'
$okN3 = ($outCode -eq 0) -and ($nText3 -like '*SECRET-OUTPUT*')

# And a real path still redirects rather than being refused: the file is written
# and nothing reaches the terminal. A guard that refused this would have broken
# block A, which is what block A is there to catch.
if (Test-Path $outReal) { Remove-Item $outReal -Force }
$nText4 = Invoke-OutDir '--out real.txt job.bas'
$okN4 = ($outCode -eq 0) -and ($nText4 -notlike '*SECRET-OUTPUT*') -and (Test-Path $outReal) -and
        ((Get-Content -Raw $outReal) -like '*SECRET-OUTPUT*')

# The sentence the empty case now gives is the one --out-with-nothing-after-it
# already gave. Pinned so the two cannot drift apart.
$nText5 = Invoke-OutDir '--out'
$okN5 = ($outCode -eq 2) -and ($nText5 -like '*--out needs a path*')

$okN = $okN1 -and $okN2 -and $okN3 -and $okN4 -and $okN5
if ($okN) { Write-Host "PASS  N:--out `"`" refused    (empty argument never silently unredirects)" -ForegroundColor Green }
else {
    Write-Host "FAIL  N:--out argument handling" -ForegroundColor Red
    Write-Host ("        empty={0} empty-with-sandbox={1} default-stdout={2} real-path={3} no-value={4}" -f $okN1, $okN2, $okN3, $okN4, $okN5) -ForegroundColor DarkGray
    Write-Host ("        empty said: {0}" -f ($nText -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
}

# O. A SOURCE FILE IS NOT BYTECODE BECAUSE ITS FIRST THREE LETTERS ARE PBC.
#    IsBytecode read three bytes and answered on 'P','B','C' alone, so every .bas
#    whose first line begins with an uppercase identifier starting PBC -- PBCount,
#    PBCmax, PBC$ -- was handed to the bytecode reader and refused with
#    "unsupported .pbc format version 111": the code point of the fourth SOURCE
#    character reported as a format version, which says nothing about what is
#    wrong. `pack` lost its own helpful refusal at the same door, and
#    phosphortest, which never sniffs, ran the very same file -- two shipped
#    hosts disagreeing about one file.
#
#    The real header is the magic PLUS a version byte, and no text file carries a
#    control character there. "A control character" alone is not the whole rule
#    either: TAB, LF and CR are 9, 10 and 13, and `PBC<TAB>= 3` and a line that is
#    just `PBC` are both SOURCE TEXT the sniffer must not claim. Shapes 3 and 4
#    are those two, and on Windows shape 4's fourth byte is CR where on Linux it
#    is LF -- the same file asks a different half of the rule on each OS, which is
#    the honest thing about it.
#
#    Shape 4 stopped being a valid PROGRAM on 2026-09-11: a name on a line of its
#    own is a call with the parentheses left off, and the compiler refuses it
#    instead of reading a variable and discarding it. That takes nothing away
#    from the shape -- its fourth byte is still the newline, which is the whole
#    question here -- so what it asserts changed rather than what it is. A
#    diagnostic naming the line is something only the COMPILER can produce, so it
#    is proof the file went to the compiler and not to the bytecode reader,
#    exactly as `count is 3` was for shape 1.
#
#    Shapes 5 to 7 are the MIRROR and matter as much: a genuine .pbc must still be
#    recognised as one, or a sniff that answered "source" to everything would pass
#    1 to 4 and break running and packing bytecode entirely.
$sniffDir = Join-Path $tmp 'phosphor_sniff'
New-Item -ItemType Directory -Force $sniffDir | Out-Null
$sniffOut = Join-Path $tmp 'phosphor_sniff.txt'
$okO = $true

function Test-SniffRuns([string] $shape, [string] $file, [string] $want) {
    cmd /c "`"$exe`" `"$file`" < NUL > `"$sniffOut`" 2>&1"
    $code = $LASTEXITCODE
    $text = Get-Content -Raw $sniffOut
    if ($null -eq $text) { $text = '' }
    # 'format version' is the tell of the old defect, so it is asserted ABSENT:
    # a refusal for the right reason and one for this reason are not the same.
    $ok = ($code -eq 0) -and ($text -like "*$want*") -and ($text -notlike '*format version*')
    if (-not $ok) {
        Write-Host ("        {0}: exit {1}, said '{2}'" -f $shape, $code,
                    ($text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
    }
    return $ok
}

# The same question for a file the COMPILER refuses: the refusal has to be the
# compiler's, naming the source line, and never a format version.
function Test-SniffCompiled([string] $shape, [string] $file, [string] $want) {
    cmd /c "`"$exe`" `"$file`" < NUL > `"$sniffOut`" 2>&1"
    $code = $LASTEXITCODE
    $text = Get-Content -Raw $sniffOut
    if ($null -eq $text) { $text = '' }
    $ok = ($code -ne 0) -and ($text -like "*$want*") -and ($text -notlike '*format version*')
    if (-not $ok) {
        Write-Host ("        {0}: exit {1}, said '{2}'" -f $shape, $code,
                    ($text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
    }
    return $ok
}

$sniff1 = Join-Path $sniffDir 'pbcount.bas'
Set-Content -LiteralPath $sniff1 -Encoding ascii -Value @(
    'PBCount = 3',
    'println "count is " + str$(PBCount)'
)
$sniff2 = Join-Path $sniffDir 'pbcdollar.bas'
Set-Content -LiteralPath $sniff2 -Encoding ascii -Value @(
    'PBC$ = "hello there"',
    'println PBC$'
)
$sniff3 = Join-Path $sniffDir 'pbctab.bas'
Set-Content -LiteralPath $sniff3 -Encoding ascii -Value @(
    "PBC`t= 3",
    'println "tabbed is " + str$(PBC)'
)
$sniff4 = Join-Path $sniffDir 'pbcbare.bas'
Set-Content -LiteralPath $sniff4 -Encoding ascii -Value @(
    'PBC',
    'println "a bare pbc line"'
)
$okO = (Test-SniffRuns 'PBCount = 3'      $sniff1 'count is 3')      -and $okO
$okO = (Test-SniffRuns 'PBC$ = "..."'     $sniff2 'hello there')     -and $okO
$okO = (Test-SniffRuns 'PBC<TAB>= 3'      $sniff3 'tabbed is 3')     -and $okO
$okO = (Test-SniffCompiled 'a bare PBC line' $sniff4 "'pbc' on its own does nothing") -and $okO

# 5. `pack` must give its OWN refusal for source, the one F already pins, and not
#    a version number -- IsBytecode answering True took that branch away.
cmd /c "`"$exe`" pack `"$sniff1`" `"$(Join-Path $sniffDir 'never.exe')`" > `"$sniffOut`" 2>&1"
$o5code = $LASTEXITCODE
$o5text = Get-Content -Raw $sniffOut
if ($null -eq $o5text) { $o5text = '' }
if (($o5code -ne 2) -or ($o5text -notlike '*not a .pbc*') -or ($o5text -like '*format version*')) {
    Write-Host ("        pack of PBC-prefixed source: exit {0}, said '{1}'" -f $o5code,
                ($o5text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
    $okO = $false
}

# 6/7. THE MIRROR. The same program COMPILED is bytecode, and must still be read
#      as bytecode -- run directly, and packed into a standalone executable.
$sniffPbc = Join-Path $sniffDir 'pbcount.pbc'
cmd /c "`"$exe`" compile `"$sniff1`" `"$sniffPbc`" > `"$sniffOut`" 2>&1"
if (($LASTEXITCODE -ne 0) -or (-not (Test-Path $sniffPbc))) {
    Write-Host '        compiling the PBC-prefixed source did not produce a .pbc' -ForegroundColor DarkGray
    $okO = $false
} else {
    $okO = (Test-SniffRuns 'the .pbc compiled from it' $sniffPbc 'count is 3') -and $okO
}

$sniffExe = Join-Path $sniffDir 'pbcount_packed.exe'
cmd /c "`"$exe`" pack `"$sniffPbc`" `"$sniffExe`" > `"$sniffOut`" 2>&1"
if (($LASTEXITCODE -ne 0) -or (-not (Test-Path $sniffExe))) {
    Write-Host '        pack no longer accepts a genuine .pbc' -ForegroundColor DarkGray
    $okO = $false
} else {
    cmd /c "`"$sniffExe`" < NUL > `"$sniffOut`" 2>&1"
    $o7code = $LASTEXITCODE
    $o7text = Get-Content -Raw $sniffOut
    if ($null -eq $o7text) { $o7text = '' }
    if (($o7code -ne 0) -or ($o7text -notlike '*count is 3*')) {
        Write-Host ("        the packed .pbc: exit {0}, said '{1}'" -f $o7code,
                    ($o7text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
        $okO = $false
    }
}

if ($okO) { Write-Host "PASS  O:PBC-prefixed source (read as the source it is, and a real .pbc still as bytecode)" -ForegroundColor Green }
else { Write-Host "FAIL  O:a source file whose first line starts PBC is taken for bytecode" -ForegroundColor Red }

# P. A BREAKPOINT REPORTS, AT EVERY DOOR, AND NEVER ONTO STDOUT.
#    `breakpoint` is the only debugging statement this language has, and the
#    engine has always offered a seam for it that this host left nil. The
#    documented "reports a frame to the host debugger" reported to nobody: the
#    four-line program below printed `bp-stdout-marker` and not one further byte,
#    on stdout or anywhere else. It now writes one line per fired breakpoint to
#    STDERR.
#
#    THREE DOORS, BECAUSE THE HOST BUILDS AN ENGINE AT THREE OF THEM -- RunFile,
#    RunEmbedded (a packed application) and Repl -- and scripts/check-seams.py
#    asks its question once per FILE. A single assignment anywhere in phosphor.lpr
#    turns that gate green while two doors stay silent, so the gate cannot be the
#    proof that the seam is wired; this block is. They are checked separately
#    because their reports differ on purpose: a file run names the file, and a
#    packed application has no source path to name, exactly as their two error
#    diagnostics already differ.
#
#    STDERR AND NOT STDOUT IS THE LOAD-BEARING HALF. Every byte-exact golden in
#    this tree is a comparison of stdout, so a debugger that wrote there would
#    corrupt all of them at once -- which is why stdout is compared EXACTLY here
#    rather than searched, and why `--out` is asked as its own shape: it redirects
#    the PROGRAM's output to a file, and a host that reported a frame through the
#    output seam instead of stderr would put the frame in that file and still look
#    right on a terminal.
$bpDir = Join-Path $tmp 'phosphor_bp'
New-Item -ItemType Directory -Force $bpDir | Out-Null
$bpBas = Join-Path $bpDir 'bp.bas'
Set-Content -LiteralPath $bpBas -Encoding ascii -Value @(
    'trace 1',
    'x = 5',
    'breakpoint "checkpoint", x, "five"',
    'trace 0',
    'breakpoint "after trace off", x',
    'println "bp-stdout-marker"'
)
$bpReplIn = Join-Path $bpDir 'repl.in'
Set-Content -LiteralPath $bpReplIn -Encoding ascii -Value @(
    'trace 1',
    'breakpoint "repl frame", 7',
    'println "repl-done"'
)

# The operand list is the assertion that matters: `[1]=5` is the NUMBER five and
# `[2]="five"` is the TEXT, which is the one thing ValToStr alone cannot say --
# it renders a vkString as bare text, so an unquoted renderer prints 5 for both
# `breakpoint "m", 5` and `breakpoint "m", "5"`. Substring comparison with
# .Contains and not -like: `[` and `]` are wildcard metacharacters in -like, so
# -like '*[1]=5*' asks for the character '1' followed by '=5' and quietly fails
# to match the very text it appears to spell.
$bpFrame = 'breakpoint: checkpoint [1]=5 [2]="five"'
$okP = $true
function Read-BpText([string] $p) {
    if (-not (Test-Path $p)) { return '' }
    $t = Get-Content -Raw $p
    if ($null -eq $t) { return '' }
    return $t
}
function Test-BpStdout([string] $p, [string] $want) {
    # Byte-exact, because "stdout is untouched" is the claim, not "stdout still
    # mentions the marker". The engine ends a println with LF on both systems.
    if (-not (Test-Path $p)) { return $false }
    $b = [IO.File]::ReadAllBytes($p)
    $w = [Text.Encoding]::ASCII.GetBytes($want)
    if ($b.Length -ne $w.Length) { return $false }
    for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -ne $w[$i]) { return $false } }
    return $true
}
function Report-Bp([string] $what, [string] $text) {
    Write-Host ("        {0}: stderr was '{1}'" -f $what, ($text -replace "`r?`n", ' / ')) -ForegroundColor DarkGray
}

# P1. The FILE door. The frame names the file and the LINE the breakpoint is on,
#     and `trace 0` still silences the one below it -- the seam fires only while
#     tracing is on, and wiring it must not have changed that.
$p1out = Join-Path $bpDir 'p1.out'; $p1err = Join-Path $bpDir 'p1.err'
cmd /c "`"$exe`" `"$bpBas`" < NUL > `"$p1out`" 2> `"$p1err`""
$p1code = $LASTEXITCODE
$p1text = Read-BpText $p1err
if (($p1code -ne 0) -or (-not $p1text.Contains($bpFrame)) -or
    (-not $p1text.Contains('bp.bas:3:')) -or $p1text.Contains('after trace off') -or
    (-not (Test-BpStdout $p1out "bp-stdout-marker`n"))) {
    Report-Bp ("file door (exit {0})" -f $p1code) $p1text
    $okP = $false
}

# P2. The PACKED door. A packed application has no source path, so the frame
#     carries a bare line number -- the same shape its error diagnostic uses.
$bpPbc = Join-Path $bpDir 'bp.pbc'; $bpExe = Join-Path $bpDir 'bp_packed.exe'
$p2out = Join-Path $bpDir 'p2.out'; $p2err = Join-Path $bpDir 'p2.err'
& $exe 'compile' $bpBas $bpPbc
if ($LASTEXITCODE -ne 0) { throw "breakpoint fixture: compile exited $LASTEXITCODE" }
& $exe 'pack' $bpPbc $bpExe
if ($LASTEXITCODE -ne 0) { throw "breakpoint fixture: pack exited $LASTEXITCODE" }
cmd /c "`"$bpExe`" < NUL > `"$p2out`" 2> `"$p2err`""
$p2code = $LASTEXITCODE
$p2text = Read-BpText $p2err
if (($p2code -ne 0) -or (-not $p2text.Contains('phosphor: 3: ' + $bpFrame)) -or
    $p2text.Contains('bp.bas') -or
    (-not (Test-BpStdout $p2out "bp-stdout-marker`n"))) {
    Report-Bp ("packed door (exit {0})" -f $p2code) $p2text
    $okP = $false
}

# P3. The REPL door. Also the one place `trace 1` PERSISTS: the VM resets FTrace
#     in Run and not in RunFrom, which is what a typed line goes through -- so
#     tracing switched on at one prompt is still on at the next, and the frame
#     from line 2 proves both the seam and that carry-over.
$p3out = Join-Path $bpDir 'p3.out'; $p3err = Join-Path $bpDir 'p3.err'
cmd /c "`"$exe`" < `"$bpReplIn`" > `"$p3out`" 2> `"$p3err`""
$p3code = $LASTEXITCODE
$p3text = Read-BpText $p3err
if (($p3code -ne 0) -or (-not $p3text.Contains('phosphor: 2: breakpoint: repl frame [1]=7')) -or
    (-not (Read-BpText $p3out).Contains('repl-done'))) {
    Report-Bp ("repl door (exit {0})" -f $p3code) $p3text
    $okP = $false
}

# P4. --out. The program's output goes to the file; the frame does NOT. A host
#     that reported through the OUTPUT seam rather than stderr would pass P1 on a
#     terminal and fail here, which is the whole reason this shape is asked.
$p4out = Join-Path $bpDir 'p4.out'; $p4err = Join-Path $bpDir 'p4.err'
cmd /c "`"$exe`" run `"$bpBas`" --out `"$p4out`" < NUL 2> `"$p4err`""
$p4code = $LASTEXITCODE
$p4text = Read-BpText $p4err
if (($p4code -ne 0) -or (-not $p4text.Contains($bpFrame)) -or
    (-not (Test-BpStdout $p4out "bp-stdout-marker`n"))) {
    Report-Bp ("--out door (exit {0})" -f $p4code) $p4text
    $okP = $false
}

# P5. THE CEILINGS. The operand COUNT and every operand's LENGTH come from the
#     program being debugged, and the seam fires inside one VM instruction -- so
#     none of MaxSteps, TimeoutMs or MaxOutputBytes is tested while this line is
#     being built. Unbounded, one `breakpoint` with 8000 operands of a 10 000-byte
#     string cost 65 011 ms and wrote 80 079 047 bytes of stderr from a 32 KB
#     source; the host now caps the message, each operand and the whole line, and
#     is flat at ~8 KB. Asserted here rather than left to check-budget.py's
#     exemption, because an exemption is a sentence and this is a measurement:
#     delete a ceiling and this block fails.
#
#     THE SHAPE OF THE ASSERTION IS DERIVED, NOT READ OFF A RUN. An operand of
#     exactly BP_MAX_OPERAND_BYTES (256) is AT the ceiling and must come through
#     untouched -- a guard that refuses something legitimate is the failure mode
#     this half exists for -- while 5000 bytes must be cut and must DECLARE the
#     true length. And for the count: however many operands the line shows, the
#     ones it does not show must be counted in the marker, so shown + dropped is
#     exactly what the program passed.
#     Five frames, and the derivation of each is written beside it below. Nothing
#     in the fixture is a literal backslash or a literal non-ASCII byte: both are
#     built at RUNTIME with string$, so the lexer never sees them and the .bas
#     escape rules cannot change what is being tested.
$bpCapBas = Join-Path $bpDir 'bpcap.bas'
$manyOps = (@('c$') * 300) -join ', '
Set-Content -LiteralPath $bpCapBas -Encoding ascii -Value @(
    'trace 1',
    'a$ = string$(5000, 65)',
    'b$ = string$(256, 66)',
    'breakpoint "cap", a$, b$',
    'm$ = string$(5000, 68)',
    'breakpoint m$, 1',
    'u$ = "x" + string$(128, 233)',
    'breakpoint "utf", u$',
    's$ = string$(300, 92)',
    'breakpoint "esc", s$',
    'c$ = string$(256, 67)',
    ('breakpoint "many", ' + $manyOps),
    'println "bp-cap-marker"'
)
$p5out = Join-Path $bpDir 'p5.out'; $p5err = Join-Path $bpDir 'p5.err'
cmd /c "`"$exe`" `"$bpCapBas`" < NUL > `"$p5out`" 2> `"$p5err`""
$p5code = $LASTEXITCODE
# READ SO THAT AN EMPTY STDERR IS A FAILURE AND NOT AN EXCEPTION. PowerShell
# unrolls a zero-length array out of an `if` expression into $null, so the
# obvious spelling threw "cannot call GetString with 1 argument" the first time a
# mutation made this stream empty -- taking the whole runner down in place of the
# FAIL it was supposed to print. Empty is exactly what the defect being guarded
# looks like, so it has to be the one case this reads cleanly.
$p5raw = $null
if (Test-Path $p5err) { $p5raw = [IO.File]::ReadAllBytes($p5err) }
$p5text = ''
if (($null -ne $p5raw) -and ($p5raw.Length -gt 0)) { $p5text = [Text.Encoding]::UTF8.GetString($p5raw) }
$p5lines = @($p5text -split "`n" | Where-Object { $_ -ne '' })
# THE UTF-8 TAIL, DERIVED. u$ is 'x' plus 128 two-byte characters = 257 bytes, so
# the cut at 256 falls BETWEEN the two bytes of the 128th -- that character goes
# whole and 'x' plus 127 of them, 255 bytes, is what survives. A byte-blind
# Copy(s, 1, 256) would instead end the operand on a lone lead byte, which this
# comparison fails on and which no amount of line-length checking would notice.
$p5wantUtf = 'breakpoint: utf [1]="x' + (([string][char]0xE9) * 127) + '"...(257 bytes)'
# The MESSAGE ceiling, spelled the same way: 5000 bytes in, BP_MAX_MESSAGE_BYTES
# out, the true size declared. Compared whole rather than counted, because the
# fixture's own path carries a capital D of its own.
$p5wantMsg = 'breakpoint: ' + ('D' * 1024) + '...(5000 bytes) [1]=1'
# 300 backslashes: capped to 256 BEFORE escaping, and each escapes to two, so the
# rendering carries 512. Capping AFTER escaping would leave 256 and is the shape
# that can also split a backslash from the character it escapes. Compared whole
# rather than counted, because a Windows path is made of backslashes too.
$p5wantEsc = 'breakpoint: esc [1]="' + ('\' * 512) + '"...(300 bytes)'
# ORDINAL, AND THE REASON IS A MUTATION THAT SURVIVED THIS BLOCK. String.EndsWith
# with one argument compares by CURRENT CULTURE in .NET, and a culture comparison
# treats some characters as having no weight at all -- so when the codepoint
# boundary was deliberately broken and the frame gained a U+FFFD from a lone lead
# byte, this twin still said PASS while its bash counterpart failed. A comparison
# that ignores the very byte under test measures nothing.
function Test-BpTail([string] $line, [string] $want) {
    return $line.EndsWith($want, [StringComparison]::Ordinal)
}
# shown + dropped must account for every operand the program passed. Computed
# only once there ARE five frames: a test that throws instead of reporting a
# failure takes its own runner down and says nothing about the defect.
$p5shown = -1; $p5dropN = -1
if ($p5lines.Count -eq 5) {
    $p5shown = ([regex]::Matches($p5lines[4], ' \[\d+\]=')).Count
    $p5d = [regex]::Match($p5lines[4], '\.\.\.\((\d+) more\)$')
    if ($p5d.Success) { $p5dropN = [int]$p5d.Groups[1].Value }
}
$p5why = ''
if ($p5code -ne 0) { $p5why = "exit $p5code" }
elseif ($p5lines.Count -ne 5) { $p5why = "$($p5lines.Count) frames, wanted 5 (a cut must not split a line)" }
elseif (-not $p5lines[0].Contains('...(5000 bytes)')) { $p5why = 'a 5000-byte operand did not declare its true length' }
elseif ($p5text.Contains('...(256 bytes)')) { $p5why = 'an operand AT the ceiling was cut; the guard refuses something legitimate' }
elseif ($p5lines[0].Length -gt 1200) { $p5why = "the 5000-byte operand still cost $($p5lines[0].Length) bytes of line" }
elseif (-not (Test-BpTail $p5lines[1] $p5wantMsg)) { $p5why = 'a 5000-byte MESSAGE was not capped to 1024 and declared' }
elseif (-not (Test-BpTail $p5lines[2] $p5wantUtf)) { $p5why = 'the operand cut did not land on a character boundary' }
elseif (-not (Test-BpTail $p5lines[3] $p5wantEsc)) { $p5why = 'the operand cut landed after escaping, not before (or did not declare its length)' }
elseif ($p5lines[4].Length -gt 9500) { $p5why = "300 operands cost $($p5lines[4].Length) bytes of line" }
elseif ($p5dropN -lt 0) { $p5why = 'the operands left out of the line were not declared' }
elseif (($p5shown + $p5dropN) -ne 300) {
    $p5why = "shown $p5shown + dropped $p5dropN is not the 300 passed"
}
elseif (-not (Test-BpStdout $p5out "bp-cap-marker`n")) { $p5why = 'stdout is not byte-exact' }
if ($p5why -ne '') {
    Write-Host ("        ceilings: {0}" -f $p5why) -ForegroundColor DarkGray
    $okP = $false
}

if ($okP) { Write-Host "PASS  P:breakpoint reports (all three doors, on stderr, stdout byte-exact, bounded)" -ForegroundColor Green }
else { Write-Host "FAIL  P:a breakpoint reports to nobody, reports onto stdout, or reports without a ceiling" -ForegroundColor Red }


# --- Q: `phosphor debug` -------------------------------------------------------
# See scripts/test.sh's block Q for what each of the five asks and why the third
# is the one that matters: the program's own stdout must not move when a debugger
# is attached to it.
$okQ = $true
$dbgDir = Join-Path $tmp 'dbg'
if (-not (Test-Path $dbgDir)) { New-Item -ItemType Directory -Path $dbgDir | Out-Null }
$qBas = Join-Path $dbgDir 'q.bas'
Set-Content -LiteralPath $qBas -Encoding ascii -Value @(
    'total = 0',
    'function dobro(n) local r',
    '  r = n * 2',
    '  return r',
    'endfunction',
    'for i = 1 to 3',
    '  total = total + dobro(i)',
    'next',
    'println "total="; total'
)

function Dbg-Run([string] $argline, [string] $stdinFile, [string] $tag) {
    $o = Join-Path $dbgDir "$tag.out"
    $e = Join-Path $dbgDir "$tag.err"
    if ($stdinFile -eq '') {
        cmd /c "`"$exe`" $argline > `"$o`" 2> `"$e`" < NUL"
    } else {
        cmd /c "`"$exe`" $argline > `"$o`" 2> `"$e`" < `"$stdinFile`""
    }
    return @{ Code = $LASTEXITCODE; Out = $o; Err = $e }
}

# 1. no terminal: runs to completion, says why once, exit 0
$q1 = Dbg-Run "debug `"$qBas`"" '' 'q1'
$q1err = Read-Text $q1.Err
if ($q1.Code -ne 0) { Write-Host ("        no-terminal: exit {0}" -f $q1.Code) -ForegroundColor DarkGray; $okQ = $false }
if ($q1err -notlike '*not a terminal*') { Write-Host '        no-terminal: did not say why it continued' -ForegroundColor DarkGray; $okQ = $false }

# 2. a scripted session
$cmds = Join-Path $dbgDir 'cmds'
Set-Content -LiteralPath $cmds -Encoding ascii -Value @('s','s','s','s','s','w','v','c')
$q2 = Dbg-Run "debug `"$qBas`"" $cmds 'q2'
$q2err = Read-Text $q2.Err
if ($q2err -notlike '*dobro()*') { Write-Host '        session: the call stack never named the function' -ForegroundColor DarkGray; $okQ = $false }
if ($q2err -notlike '*depth 1*') { Write-Host '        session: never stepped into the call' -ForegroundColor DarkGray; $okQ = $false }

# 3. THE DEBUGGER IS INVISIBLE TO THE PROGRAM
$plain = Dbg-Run "`"$qBas`"" '' 'plain'
$a = [System.IO.File]::ReadAllBytes($q2.Out)
$b = [System.IO.File]::ReadAllBytes($plain.Out)
$c = [System.IO.File]::ReadAllBytes($q1.Out)
if (-not (@(Compare-Object $a $b -SyncWindow 0).Count -eq 0)) {
    Write-Host '        invisible: stdout differs with the debugger attached' -ForegroundColor DarkGray; $okQ = $false }
if (-not (@(Compare-Object $c $b -SyncWindow 0).Count -eq 0)) {
    Write-Host '        invisible: stdout differs with the debugger attached but silent' -ForegroundColor DarkGray; $okQ = $false }

# 4. --break stops where it was asked and nowhere else. Line 9 is outside the
#    loop, so once; line 7 is inside it, so once per iteration -- which is what a
#    breakpoint in a loop is for, and the first version of this asserted 1 for it.
$cmds2 = Join-Path $dbgDir 'cmds2'
Set-Content -LiteralPath $cmds2 -Encoding ascii -Value @('w','c')
$q4 = Dbg-Run "debug --break 9 `"$qBas`"" $cmds2 'q4'
$q4err = Read-Text $q4.Err
$hits = ([regex]::Matches($q4err, '-- breakpoint at')).Count
if ($hits -ne 1) { Write-Host ("        --break 9: stopped {0} times, wanted 1" -f $hits) -ForegroundColor DarkGray; $okQ = $false }
if ($q4err -like '*-- entry at*') { Write-Host '        --break: still stopped at entry, which the flag replaces' -ForegroundColor DarkGray; $okQ = $false }
$cmds3 = Join-Path $dbgDir 'cmds3'
Set-Content -LiteralPath $cmds3 -Encoding ascii -Value @('c','c','c')
$q4b = Dbg-Run "debug --break 7 `"$qBas`"" $cmds3 'q4b'
$hitsB = ([regex]::Matches((Read-Text $q4b.Err), '-- breakpoint at')).Count
if ($hitsB -ne 3) { Write-Host ("        --break 7: stopped {0} times in a 3-pass loop, wanted 3" -f $hitsB) -ForegroundColor DarkGray; $okQ = $false }

# 5. bytecode is refused with the reason
$qPbc = Join-Path $dbgDir 'q.pbc'
cmd /c "`"$exe`" compile `"$qBas`" `"$qPbc`" > NUL 2>&1"
$q5 = Dbg-Run "debug `"$qPbc`"" '' 'q5'
if ($q5.Code -eq 0) { Write-Host '        pbc: accepted a file that carries no names' -ForegroundColor DarkGray; $okQ = $false }
if ((Read-Text $q5.Err) -notlike '*no source and no variable names*') {
    Write-Host '        pbc: refused without saying why' -ForegroundColor DarkGray; $okQ = $false }

if ($okQ) { Write-Host "PASS  Q:phosphor debug (steps, names frames and variables, invisible to the program)" -ForegroundColor Green }
else { Write-Host "FAIL  Q:the debugger waits with no terminal, cannot name what it stopped in, or moves the program" -ForegroundColor Red }

if ($okA -and $okB -and $okC -and $okD -and $okE -and $okF -and $okG -and
    $okH -and $okI -and $okJ -and $okK -and $okL -and $okM -and $okN -and $okO -and
    $okP -and $okQ) { exit 0 } else { exit 1 }
