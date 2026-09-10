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

if ($okA -and $okB -and $okC -and $okD -and $okE -and $okF -and $okG -and
    $okH -and $okI -and $okJ -and $okK -and $okL -and $okM -and $okN) { exit 0 } else { exit 1 }
