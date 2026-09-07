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

# K. THE MIRROR, and it matters as much as J. NO trailer magic means this file is
#    a bare stub, and being the CLI is then exactly right -- that is the whole
#    reason one binary can be both. A refusal that swallowed this case would have
#    broken `phosphor` itself. Two shapes: the stub as built, and a packed file
#    truncated so that the magic is gone with it.
$stub = Join-Path $tmp 'phosphor_truncated.exe'
$trunc = New-Object byte[] ($bytesA.Length - 1)
[Array]::Copy($bytesA, $trunc, $trunc.Length)
[IO.File]::WriteAllBytes($stub, $trunc)

$okK = $true
foreach ($k in @(@($exe,'the stub itself'), @($stub,'packed, truncated past its magic'))) {
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

if ($okA -and $okB -and $okC -and $okD -and $okE -and $okF -and $okG -and
    $okH -and $okI -and $okJ -and $okK) { exit 0 } else { exit 1 }
