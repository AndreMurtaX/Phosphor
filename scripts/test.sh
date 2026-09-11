#!/usr/bin/env bash
# Builds Phosphor and runs the skeleton smoke test on Unix, byte-comparing the
# output against the golden through both non-console output paths (--out file and
# redirected stdout). The Unix counterpart of scripts/test.ps1.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"

bash "$here/build.sh"

exe="$root/bin/phosphor"
bas="$root/tests/skeleton/hello.bas"
expected="$root/tests/skeleton/hello.expected"
outA="$(mktemp)"; outB="$(mktemp)"; outC="$(mktemp)"; outD="$(mktemp)"
pbc="$(mktemp -u).pbc"; packed="$(mktemp -u).run"; packedD="$(mktemp -u).nc.run"
trap 'rm -f "$outA" "$outB" "$outC" "$outD" "$pbc" "$packed" "$packedD"' EXIT

echo
"$exe" run "$bas" --out "$outA"                 # A: --out file path
"$exe" run "$bas" > "$outB"                      # B: redirected stdout (raw bytes)
# C: pack takes COMPILED bytecode, so the pipeline is compile-then-pack.
"$exe" compile "$bas" "$pbc"
"$exe" pack "$pbc" "$packed"
"$packed" > "$outC"                              #    and run it with no arguments
# D: the same, packed --no-console. On Unix the flag is a NO-OP -- the terminal is
# the user's, never the program's -- and it must still be accepted and still
# produce the same bytes, because a flag that is refused on one platform makes a
# build script platform-specific for no reason.
"$exe" pack --no-console "$pbc" "$packedD"
"$packedD" > "$outD"

fail=0
if cmp -s "$outA" "$expected"; then echo "PASS  A:--out        ($(wc -c <"$outA") bytes match golden)"
else echo "FAIL  A:--out"; fail=1; fi
if cmp -s "$outB" "$expected"; then echo "PASS  B:stdout-redir ($(wc -c <"$outB") bytes match golden)"
else echo "FAIL  B:stdout-redir"; fail=1; fi
if cmp -s "$outC" "$expected"; then echo "PASS  C:packed       ($(wc -c <"$outC") bytes match golden)"
else echo "FAIL  C:packed"; fail=1; fi
if cmp -s "$outD" "$expected"; then echo "PASS  D:packed-noconsole ($(wc -c <"$outD") bytes match golden)"
else echo "FAIL  D:packed-noconsole"; fail=1; fi

# The trailer has to be the VERSIONED one, or there is nowhere for a flag to live.
okE=0
for f in "$packed" "$packedD"; do
  m="$(tail -c 8 "$f")"
  if [ "$m" != "PHOSPBC2" ]; then
    echo "FAIL  trailer: $(basename "$f") ends with '$m', wanted 'PHOSPBC2'"; okE=1; fail=1
  fi
done
[ "$okE" -eq 0 ] && echo "PASS  E:trailer        (both packed files carry a v2 trailer)"

# F: pack REFUSES source. The rule is only real if something fails when broken.
# The `if` form is not optional: this script runs under `set -e`, and a plain
# assignment from a command that exits non-zero ABORTS the script -- which is
# exactly what happened here, silently, after E had already printed PASS. A
# condition is exempt from set -e; an assignment is not.
if refuse="$("$exe" pack "$bas" "$(mktemp -u).never" 2>&1)"; then refusecode=0; else refusecode=$?; fi
if [ "$refusecode" -eq 2 ] && echo "$refuse" | grep -q "not a .pbc" && echo "$refuse" | grep -q "phosphor compile"; then
  echo "PASS  F:pack refuses source (exit 2, and says how to compile)"
else
  echo "FAIL  F:pack refuses source (exit $refusecode)"; echo "$refuse" | sed 's/^/        /'; fail=1
fi

# G: a name no host built from this binary can provide. The COMPILER cannot judge
# that -- it has no registry, which is what lets one .pbc run on hosts with
# different packages -- but PACK can, because it carries this binary as its stub.
badbas="$(mktemp -u).bas"; badpbc="$(mktemp -u).pbc"; neverexe="$(mktemp -u).never"
printf '%s\n' 'println "before"' 'x = no_such_function_anywhere(1)' > "$badbas"

# compile alone must not complain: late binding is the point.
if out1="$("$exe" compile "$badbas" "$badpbc" 2>&1)"; then c1=0; else c1=$?; fi
okG1=0; { [ "$c1" -eq 0 ] && [ -z "$out1" ]; } || okG1=1

# compile --check must warn, still succeed, and still write the file.
if out2="$("$exe" compile --check "$badbas" "$badpbc" 2>&1)"; then c2=0; else c2=$?; fi
okG2=0
{ [ "$c2" -eq 0 ] && [ -f "$badpbc" ] && echo "$out2" | grep -q warning \
  && echo "$out2" | grep -q no_such_function_anywhere; } || okG2=1

# pack must refuse it and name it.
if out3="$("$exe" pack "$badpbc" "$neverexe" 2>&1)"; then c3=0; else c3=$?; fi
okG3=0
{ [ "$c3" -eq 1 ] && echo "$out3" | grep -q no_such_function_anywhere; } || okG3=1

if [ "$okG1" -eq 0 ] && [ "$okG2" -eq 0 ] && [ "$okG3" -eq 0 ]; then
  echo "PASS  G:name check     (compile is silent, --check warns, pack refuses)"
else
  echo "FAIL  G:name check     (silent=$okG1 warned=$okG2 refused=$okG3)"
  echo "$out3" | sed 's/^/        /'; fail=1
fi
rm -f "$badbas" "$badpbc" "$neverexe"

# H/I: A COMMAND THAT CANNOT WRITE ITS OUTPUT MUST SAY SO. `compile` and `pack`
#      used to exit 0 with zero bytes on both streams and no file produced, so a
#      build script that checked the exit code was told the artifact existed and
#      the next step packed or ran a stale one. Two shapes that fail for two
#      different reasons, because one of them passing is not the rule.
hidir="$(mktemp -d)"; mkdir -p "$hidir/adir"
# Re-declare the trap rather than adding one: a second `trap ... EXIT` REPLACES
# the first, and silently leaking every file the earlier one was cleaning up is
# not a trade this script should make for a temp directory.
trap 'rm -f "$outA" "$outB" "$outC" "$outD" "$pbc" "$packed" "$packedD"; rm -rf "$hidir"' EXIT

check_unwritable() {  # verb infile shape target
  local verb="$1" infile="$2" shape="$3" target="$4" out code
  if out="$("$exe" "$verb" "$infile" "$target" 2>&1)"; then code=0; else code=$?; fi
  if [ "$code" -ne 0 ] && echo "$out" | grep -q "cannot write to" && [ ! -f "$target" ]; then
    return 0
  fi
  echo "        $verb / $shape: exit $code, said '$out'"
  return 1
}

okH=0
check_unwritable compile "$bas" "missing directory"    "$hidir/nodir/x.pbc" || okH=1
check_unwritable compile "$bas" "output is a directory" "$hidir/adir"       || okH=1
if [ "$okH" -eq 0 ]; then echo "PASS  H:compile unwritable (exit<>0, names the path, writes nothing)"
else echo "FAIL  H:compile unwritable output is silent"; fail=1; fi

okI=0
check_unwritable pack "$pbc" "missing directory"    "$hidir/nodir/app" || okI=1
check_unwritable pack "$pbc" "output is a directory" "$hidir/adir"     || okI=1
if [ "$okI" -eq 0 ]; then echo "PASS  I:pack unwritable    (exit<>0, names the path, writes nothing)"
else echo "FAIL  I:pack unwritable output is silent"; fail=1; fi

# J: A PACKED EXECUTABLE WHOSE PAYLOAD WILL NOT VERIFY MUST REFUSE, NOT PROMPT.
#    It used to fall through to the CLI, and the CLI with no arguments is an
#    interactive BASIC prompt that runs whatever is typed and never ends by
#    itself: a corrupted or tampered app handed a user a shell, and every script
#    that shipped it saw exit 0.
#
#    The damaged files are built by SPLICING two genuinely packed executables, so
#    no byte pattern has to be guessed: both carry an intact PHOSPBC2 magic --
#    the file still says "I am a packed application" -- and only the trailer's
#    description of the payload is wrong.
basB="$hidir/second.bas"; pbcB="$hidir/second.pbc"; exeB="$hidir/second.run"
printf '%s\n' 'println "a second program, with different bytes and a different length"' > "$basB"
"$exe" compile "$basB" "$pbcB"
"$exe" pack "$pbcB" "$exeB"

sizeA="$(wc -c < "$packed")"
dmg1="$hidir/damaged_trailer";  dmg2="$hidir/damaged_cksum";  dmg3="$hidir/damaged_flags"
# B's whole trailer on A's body: a different offset, size and checksum.
head -c $((sizeA - 32)) "$packed" > "$dmg1"
tail -c 32 "$exeB"               >> "$dmg1"
# Only B's checksum word, so nothing but the checksum is wrong. `tail | head`
# would SIGPIPE tail the moment head had its four bytes, and under `pipefail`
# that aborts this whole script -- so the slice goes through a file.
head -c $((sizeA - 16)) "$packed" > "$dmg2"
tail -c 16 "$exeB"                > "$hidir/tail16"
head -c 4 "$hidir/tail16"        >> "$dmg2"
tail -c 12 "$packed"             >> "$dmg2"
# Flag bits this build has never defined: it cannot honour what the file asks
# for, and running it anyway while ignoring the request is the same silence.
head -c $((sizeA - 12)) "$packed" > "$dmg3"
printf '\377\377\377\377'        >> "$dmg3"
tail -c 8 "$packed"              >> "$dmg3"
chmod +x "$dmg1" "$dmg2" "$dmg3"

okJ=0
check_refused() {  # path what
  local out code
  if out="$("$1" < /dev/null 2>&1)"; then code=0; else code=$?; fi
  # exit 2 is this host's "I will not run: what I was given is wrong", the same
  # code a missing file, an unwritable --out and an unbindable sandbox answer.
  if [ "$code" -eq 2 ] && echo "$out" | grep -q corrupt && ! echo "$out" | grep -q REPL; then
    return 0
  fi
  echo "        damaged $2: exit $code, said '$out'"
  return 1
}
check_refused "$dmg1" "trailer"       || okJ=1
check_refused "$dmg2" "checksum"      || okJ=1
check_refused "$dmg3" "unknown flags" || okJ=1
if [ "$okJ" -eq 0 ]; then echo "PASS  J:corrupt payload    (exit 2, says so, never opens a prompt)"
else echo "FAIL  J:corrupt payload falls through to the CLI"; fail=1; fi

# K: THE MIRROR, and it matters as much as J. A file that carries NO evidence of
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
stubjunk="$hidir/stub_plus_junk"
cat "$exe" > "$stubjunk"
printf 'not a trailer, just some bytes riding along' >> "$stubjunk"
chmod +x "$stubjunk"

okK=0
check_is_cli() {  # path what
  local out code
  if out="$("$1" < /dev/null 2>&1)"; then code=0; else code=$?; fi
  if [ "$code" -eq 0 ] && echo "$out" | grep -q REPL; then return 0; fi
  echo "        $2: exit $code, said '$out'"
  return 1
}
check_is_cli "$exe"      "the stub itself"                             || okK=1
check_is_cli "$stubjunk" "the stub with non-trailer bytes appended"    || okK=1
if [ "$okK" -eq 0 ]; then echo "PASS  K:no magic is the CLI (a bare stub still opens the REPL)"
else echo "FAIL  K:a file with no trailer magic no longer behaves as the CLI"; fail=1; fi

# L: A TRUNCATED PACKED APPLICATION IS A DAMAGED APPLICATION, NOT A BARE STUB.
#    J covers every corruption that leaves the TAIL intact, because the tail was
#    the only place a file said "I am a packed application". Truncation -- an
#    interrupted copy or download, a partial write, an antivirus that cuts a file
#    short, and the commonest corruption there is -- removes exactly those bytes,
#    so the reader found no magic, answered "bare stub" and RunCommandLine opened
#    the REPL with exit 0: a damaged application handing a user a BASIC prompt
#    that runs whatever is typed into it, which is word for word what J exists to
#    refuse. The stub now carries a compiled-in mark in its MIDDLE, where
#    truncation cannot reach, holding the length the packer finished with.
#
#    Each shape asserts its own REASON, not just "corrupt": a refusal that fired
#    for the wrong branch would pass a message-blind check while proving nothing.
trunc4="$hidir/trunc4"; trunc1="$hidir/trunc1"; nomagic="$hidir/nomagic"
head -c $((sizeA - 4)) "$packed" > "$trunc4"
head -c $((sizeA - 1)) "$packed" > "$trunc1"
# The magic overwritten IN PLACE: the same length, so only the mark can tell.
head -c $((sizeA - 8)) "$packed" > "$nomagic"; printf 'XXXXXXXX' >> "$nomagic"
chmod +x "$trunc4" "$trunc1" "$nomagic"

okL=0
check_refused_because() {  # path what needle
  local out code
  if out="$("$1" < /dev/null 2>&1)"; then code=0; else code=$?; fi
  # [[ ]] rather than `echo | grep -q`: grep -q exits at its first match and
  # SIGPIPEs what feeds it, which under `pipefail` reads non-zero even when it
  # matched -- a trap this project has already paid for twice.
  if [ "$code" -eq 2 ] && [[ "$out" == *corrupt* ]] && [[ "$out" == *"$3"* ]] \
     && [[ "$out" != *REPL* ]]; then
    return 0
  fi
  echo "        $2: exit $code, said '$out'"
  return 1
}
check_refused_because "$trunc4"  "truncated by 4"             truncated   || okL=1
check_refused_because "$trunc1"  "truncated by 1"             truncated   || okL=1
check_refused_because "$nomagic" "magic overwritten in place" overwritten || okL=1

# AND THE MIRROR OF L, or the length check would be free to refuse everything: an
# intact packed application must still run after being copied somewhere else,
# byte-exact against the same golden as A-D.
movedapp="$hidir/moved_app"; outL="$hidir/L.actual"
cp "$packed" "$movedapp"; chmod +x "$movedapp"
if "$movedapp" < /dev/null > "$outL"; then mcode=0; else mcode=$?; fi
if [ "$mcode" -eq 0 ] && cmp -s "$outL" "$expected"; then
  echo "PASS  L:packed, moved  ($(wc -c <"$outL") bytes match golden)"
else
  echo "        an intact packed app, copied elsewhere: exit $mcode"; okL=1
fi
if [ "$okL" -eq 0 ]; then echo "PASS  L:truncated payload  (exit 2, says truncated, never opens a prompt)"
else echo "FAIL  L:a truncated packed application falls through to the CLI"; fail=1; fi

# M: `--sandbox ""` MUST REFUSE, exactly as `--sandbox "   "` already did.
#    '' is the encoding for "no sandbox was asked for" AND what an operator hands
#    over when they write `phosphor --sandbox "$RUNDIR" untrusted.bas` with RUNDIR
#    unset. BindSandbox used the VALUE to decide whether the flag had been given,
#    so the empty argument ran the script COMPLETELY UNCONFINED, silently, exit 0
#    -- the outcome that routine's own comment says it exists to prevent -- while
#    the whitespace spelling of the same intent was correctly refused.
sbxdir="$hidir/sandbox_arg"
mkdir -p "$sbxdir/cage"
# No backslash anywhere in this heredoc, and none possible: a backslash in a .bas
# literal is an escape, and a heredoc would mangle it on the way in besides.
cat > "$sbxdir/escape.bas" <<'EOF'
println "sandboxroot=[" + sandboxroot$() + "]"
n = file_writealltext("escaped_outside.txt", "ESCAPED")
println "write outside -> " + str$(n)
EOF
sbxescaped="$sbxdir/escaped_outside.txt"

# The answers come back in GLOBALS, and the call is never wrapped in a command
# substitution: `m=$(sbx_run ...)` would run the function in a SUBSHELL, so the
# exit code it recorded would be thrown away with that subshell and `set -u`
# would abort on the next read. Measured on the Linux VM, where it did.
sbxout=''; sbxcode=0
sbx_run() {  # args... -> $sbxout and $sbxcode
  if sbxout="$(cd "$sbxdir" && "$exe" "$@" < /dev/null 2>&1)"; then sbxcode=0; else sbxcode=$?; fi
}

okM=0
rm -f "$sbxescaped"
sbx_run --sandbox "" escape.bas
# TWO SPACES before the dash: the root printed back is the empty string, which is
# the case under test. A shell that dropped the empty argument would leave the
# .bas name there instead, and the refusal would be right for the wrong reason.
if [ "$sbxcode" -eq 2 ] && [[ "$sbxout" == *"cannot establish the sandbox root  --"* ]] \
   && [[ "$sbxout" != *sandboxroot=* ]] && [ ! -e "$sbxescaped" ]; then :; else
  echo "        --sandbox \"\": exit $sbxcode, said '$sbxout'"; okM=1
fi

# The whitespace spelling, which was right all along and must stay right.
rm -f "$sbxescaped"
sbx_run --sandbox "   " escape.bas
if [ "$sbxcode" -eq 2 ] && [[ "$sbxout" == *"cannot establish the sandbox root"* ]] \
   && [ ! -e "$sbxescaped" ]; then :; else
  echo "        --sandbox \"   \": exit $sbxcode, said '$sbxout'"; okM=1
fi

# AND THE DOCUMENTED DEFAULT MUST NOT MOVE. No --sandbox is no sandbox: the
# script runs unconfined and the write succeeds. A guard that refused this would
# have broken `phosphor` itself, exactly as a refusal in K would have.
rm -f "$sbxescaped"
sbx_run escape.bas
if [ "$sbxcode" -eq 0 ] && [[ "$sbxout" == *"sandboxroot=[]"* ]] \
   && [[ "$sbxout" == *"write outside -> 1"* ]] && [ -e "$sbxescaped" ]; then :; else
  echo "        no --sandbox: exit $sbxcode, said '$sbxout'"; okM=1
fi

# And a real root still confines rather than refuses: the run succeeds, the write
# outside it does not.
rm -f "$sbxescaped"
sbx_run --sandbox cage escape.bas
if [ "$sbxcode" -eq 0 ] && [[ "$sbxout" == *cage* ]] \
   && [[ "$sbxout" == *"write outside -> 0"* ]] && [ ! -e "$sbxescaped" ]; then :; else
  echo "        --sandbox cage: exit $sbxcode, said '$sbxout'"; okM=1
fi

if [ "$okM" -eq 0 ]; then echo 'PASS  M:--sandbox "" refused (empty argument never runs unconfined)'
else echo 'FAIL  M:--sandbox argument handling'; fail=1; fi

# N. `--out ""` MUST REFUSE, for the same reason M does and one `else if` down
#    the same argument loop. TConsoleHost.Create guards with `if AOutPath <> ''`,
#    so '' encodes "no --out was asked for" as well as what `--out "$LOG"` hands
#    over with LOG unset: the flag VANISHED and the program's output went to the
#    terminal at exit 0 with nothing said -- while `--out "   "` was refused on
#    Windows and honoured on Linux. Three answers to one intent.
outdir="$hidir/out_arg"
mkdir -p "$outdir/cage"
cat > "$outdir/job.bas" <<'EOF'
println "SECRET-OUTPUT"
EOF
outreal="$outdir/real.txt"

# Globals again, and never a command substitution around the call -- see sbx_run
# above for the subshell that ate an exit code on the Linux VM.
outout=''; outcode=0
out_run() {  # args... -> $outout and $outcode
  if outout="$(cd "$outdir" && "$exe" "$@" < /dev/null 2>&1)"; then outcode=0; else outcode=$?; fi
}

okN=0
rm -f "$outreal"
out_run --out "" job.bas
if [ "$outcode" -eq 2 ] && [[ "$outout" == *"--out needs a path"* ]] \
   && [[ "$outout" != *SECRET-OUTPUT* ]] && [ ! -e "$outreal" ]; then :; else
  echo "        --out \"\": exit $outcode, said '$outout'"; okN=1
fi

# ...and with a sandbox bound too, which is where it was worst: the operator had
# asked for confinement AND for a log, and got a wide-open terminal instead.
out_run --sandbox cage --out "" job.bas
if [ "$outcode" -eq 2 ] && [[ "$outout" == *"--out needs a path"* ]] \
   && [[ "$outout" != *SECRET-OUTPUT* ]]; then :; else
  echo "        --sandbox cage --out \"\": exit $outcode, said '$outout'"; okN=1
fi

# AND THE DOCUMENTED DEFAULT MUST NOT MOVE. No --out is stdout.
out_run job.bas
if [ "$outcode" -eq 0 ] && [[ "$outout" == *SECRET-OUTPUT* ]]; then :; else
  echo "        no --out: exit $outcode, said '$outout'"; okN=1
fi

# And a real path still redirects rather than being refused: the file is written
# and nothing reaches the terminal. A guard that refused this would have broken
# block A, which is what block A is there to catch.
rm -f "$outreal"
out_run --out real.txt job.bas
# Read the file rather than `... | grep -q`: CLAUDE.md records grep -q SIGPIPEing
# its upstream and reading non-zero even when it matched.
if [ "$outcode" -eq 0 ] && [[ "$outout" != *SECRET-OUTPUT* ]] && [ -e "$outreal" ] \
   && [[ "$(cat "$outreal")" == *SECRET-OUTPUT* ]]; then :; else
  echo "        --out real.txt: exit $outcode, said '$outout'"; okN=1
fi

# The sentence the empty case now gives is the one --out-with-nothing-after-it
# already gave. Pinned so the two cannot drift apart.
out_run --out
if [ "$outcode" -eq 2 ] && [[ "$outout" == *"--out needs a path"* ]]; then :; else
  echo "        --out with no value: exit $outcode, said '$outout'"; okN=1
fi

if [ "$okN" -eq 0 ]; then echo 'PASS  N:--out "" refused    (empty argument never silently unredirects)'
else echo 'FAIL  N:--out argument handling'; fail=1; fi

# O: A SOURCE FILE IS NOT BYTECODE BECAUSE ITS FIRST THREE LETTERS ARE PBC.
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
#    are those two, and here shape 4's fourth byte is LF where on Windows it is
#    CR -- the same file asks a different half of the rule on each OS, which is
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
sniffdir="$hidir/sniff"
mkdir -p "$sniffdir"
okO=0

printf '%s\n' 'PBCount = 3' 'println "count is " + str$(PBCount)' > "$sniffdir/pbcount.bas"
printf '%s\n' 'PBC$ = "hello there"' 'println PBC$'               > "$sniffdir/pbcdollar.bas"
printf 'PBC\t= 3\n%s\n' 'println "tabbed is " + str$(PBC)'        > "$sniffdir/pbctab.bas"
printf '%s\n' 'PBC' 'println "a bare pbc line"'                   > "$sniffdir/pbcbare.bas"

check_sniff_runs() {  # shape path want
  local out code
  if out="$("$exe" "$2" < /dev/null 2>&1)"; then code=0; else code=$?; fi
  # 'format version' is the tell of the old defect, so it is asserted ABSENT: a
  # refusal for the right reason and one for this reason are not the same. [[ ]]
  # rather than `echo | grep -q`, which SIGPIPEs its upstream under pipefail.
  if [ "$code" -eq 0 ] && [[ "$out" == *"$3"* ]] && [[ "$out" != *"format version"* ]]; then
    return 0
  fi
  echo "        $1: exit $code, said '$out'"
  return 1
}

check_sniff_compiled() {  # shape path want -- the same question for a file the
  # COMPILER refuses: the refusal has to be the compiler's, naming the source
  # line, and never a format version.
  local out code
  if out="$("$exe" "$2" < /dev/null 2>&1)"; then code=0; else code=$?; fi
  if [ "$code" -ne 0 ] && [[ "$out" == *"$3"* ]] && [[ "$out" != *"format version"* ]]; then
    return 0
  fi
  echo "        $1: exit $code, said '$out'"
  return 1
}
check_sniff_runs 'PBCount = 3'      "$sniffdir/pbcount.bas"   'count is 3'      || okO=1
check_sniff_runs 'PBC$ = "..."'     "$sniffdir/pbcdollar.bas" 'hello there'     || okO=1
check_sniff_runs 'PBC<TAB>= 3'      "$sniffdir/pbctab.bas"    'tabbed is 3'     || okO=1
check_sniff_compiled 'a bare PBC line' "$sniffdir/pbcbare.bas" \
                     "'pbc' on its own does nothing" || okO=1

# 5: `pack` must give its OWN refusal for source, the one F already pins, and not
#    a version number -- IsBytecode answering True took that branch away.
if o5="$("$exe" pack "$sniffdir/pbcount.bas" "$sniffdir/never" 2>&1)"; then o5code=0; else o5code=$?; fi
if [ "$o5code" -eq 2 ] && [[ "$o5" == *"not a .pbc"* ]] && [[ "$o5" != *"format version"* ]]; then :; else
  echo "        pack of PBC-prefixed source: exit $o5code, said '$o5'"; okO=1
fi

# 6/7: THE MIRROR. The same program COMPILED is bytecode, and must still be read
#      as bytecode -- run directly, and packed into a standalone executable.
"$exe" compile "$sniffdir/pbcount.bas" "$sniffdir/pbcount.pbc"
check_sniff_runs 'the .pbc compiled from it' "$sniffdir/pbcount.pbc" 'count is 3' || okO=1

"$exe" pack "$sniffdir/pbcount.pbc" "$sniffdir/pbcount_packed"
chmod +x "$sniffdir/pbcount_packed"
if o7="$("$sniffdir/pbcount_packed" < /dev/null 2>&1)"; then o7code=0; else o7code=$?; fi
if [ "$o7code" -eq 0 ] && [[ "$o7" == *"count is 3"* ]]; then :; else
  echo "        the packed .pbc: exit $o7code, said '$o7'"; okO=1
fi

if [ "$okO" -eq 0 ]; then echo 'PASS  O:PBC-prefixed source (read as the source it is, and a real .pbc still as bytecode)'
else echo 'FAIL  O:a source file whose first line starts PBC is taken for bytecode'; fail=1; fi

# P: A BREAKPOINT REPORTS, AT EVERY DOOR, AND NEVER ONTO STDOUT.
#    `breakpoint` is the only debugging statement this language has, and the
#    engine has always offered a seam for it that this host left nil. The
#    documented "reports a frame to the host debugger" reported to nobody: the
#    program below printed `bp-stdout-marker` and not one further byte, on stdout
#    or anywhere else. It now writes one line per fired breakpoint to STDERR.
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
#
#    The frame ends in a bare LF on BOTH systems. The host writes the handle
#    directly instead of using Writeln, which would end the line CRLF on Windows
#    and LF here -- one stream, one spelling, so this block and its PowerShell
#    twin can ask for the same bytes.
bpdir="$hidir/breakpoint"
mkdir -p "$bpdir"
okP=0
printf '%s\n' 'trace 1' 'x = 5' 'breakpoint "checkpoint", x, "five"' 'trace 0' \
              'breakpoint "after trace off", x' 'println "bp-stdout-marker"' > "$bpdir/bp.bas"
printf '%s\n' 'trace 1' 'breakpoint "repl frame", 7' 'println "repl-done"' > "$bpdir/repl.in"
printf 'bp-stdout-marker\n' > "$bpdir/want.out"

# The operand list is the assertion that matters: `[1]=5` is the NUMBER five and
# `[2]="five"` is the TEXT, which is the one thing ValToStr alone cannot say -- it
# renders a vkString as bare text, so an unquoted renderer prints 5 for both
# `breakpoint "m", 5` and `breakpoint "m", "5"`. The pattern is QUOTED inside
# [[ ]], which makes its brackets literal rather than a bracket expression.
bpframe='breakpoint: checkpoint [1]=5 [2]="five"'

# P1: the FILE door. The frame names the file and the LINE the breakpoint is on,
# and `trace 0` still silences the one below it -- the seam fires only while
# tracing is on, and wiring it must not have changed that.
if "$exe" "$bpdir/bp.bas" < /dev/null > "$bpdir/p1.out" 2> "$bpdir/p1.err"; then p1code=0; else p1code=$?; fi
p1err="$(cat "$bpdir/p1.err")"
if [ "$p1code" -eq 0 ] && [[ "$p1err" == *"$bpframe"* ]] && [[ "$p1err" == *"bp.bas:3:"* ]] \
   && [[ "$p1err" != *"after trace off"* ]] && cmp -s "$bpdir/p1.out" "$bpdir/want.out"; then :; else
  echo "        file door: exit $p1code, stderr '$p1err'"; okP=1
fi

# P2: the PACKED door. A packed application has no source path, so the frame
# carries a bare line number -- the same shape its error diagnostic uses.
"$exe" compile "$bpdir/bp.bas" "$bpdir/bp.pbc"
"$exe" pack "$bpdir/bp.pbc" "$bpdir/bp_packed"
chmod +x "$bpdir/bp_packed"
if "$bpdir/bp_packed" < /dev/null > "$bpdir/p2.out" 2> "$bpdir/p2.err"; then p2code=0; else p2code=$?; fi
p2err="$(cat "$bpdir/p2.err")"
if [ "$p2code" -eq 0 ] && [[ "$p2err" == *"phosphor: 3: $bpframe"* ]] \
   && [[ "$p2err" != *"bp.bas"* ]] && cmp -s "$bpdir/p2.out" "$bpdir/want.out"; then :; else
  echo "        packed door: exit $p2code, stderr '$p2err'"; okP=1
fi

# P3: the REPL door. Also the one place `trace 1` PERSISTS: the VM resets FTrace
# in Run and not in RunFrom, which is what a typed line goes through -- so tracing
# switched on at one prompt is still on at the next, and the frame from line 2
# proves both the seam and that carry-over.
if "$exe" < "$bpdir/repl.in" > "$bpdir/p3.out" 2> "$bpdir/p3.err"; then p3code=0; else p3code=$?; fi
p3err="$(cat "$bpdir/p3.err")"
if [ "$p3code" -eq 0 ] && [[ "$p3err" == *'phosphor: 2: breakpoint: repl frame [1]=7'* ]] \
   && [[ "$(cat "$bpdir/p3.out")" == *"repl-done"* ]]; then :; else
  echo "        repl door: exit $p3code, stderr '$p3err'"; okP=1
fi

# P4: --out. The program's output goes to the file; the frame does NOT. A host
# that reported through the OUTPUT seam rather than stderr would pass P1 on a
# terminal and fail here, which is the whole reason this shape is asked.
if "$exe" run "$bpdir/bp.bas" --out "$bpdir/p4.out" < /dev/null 2> "$bpdir/p4.err"; then p4code=0; else p4code=$?; fi
p4err="$(cat "$bpdir/p4.err")"
if [ "$p4code" -eq 0 ] && [[ "$p4err" == *"$bpframe"* ]] \
   && cmp -s "$bpdir/p4.out" "$bpdir/want.out"; then :; else
  echo "        --out door: exit $p4code, stderr '$p4err'"; okP=1
fi

# P5: THE CEILINGS. The operand COUNT and every operand's LENGTH come from the
# program being debugged, and the seam fires inside one VM instruction -- so none
# of MaxSteps, TimeoutMs or MaxOutputBytes is tested while this line is being
# built. Unbounded, one `breakpoint` with 8000 operands of a 10 000-byte string
# cost 65 011 ms and wrote 80 079 047 bytes of stderr from a 32 KB source; the
# host now caps the message, each operand and the whole line. Asserted here and
# not left to check-budget.py's exemption, because an exemption is a sentence and
# this is a measurement: delete a ceiling and this block fails.
#
# DERIVED, NOT READ OFF A RUN: an operand of exactly BP_MAX_OPERAND_BYTES (256)
# is AT the ceiling and must come through untouched -- a guard that refuses
# something legitimate is the failure mode this half exists for -- 5000 bytes
# must be cut AND declare its true length, and however many operands the line
# shows, shown + dropped must be exactly what the program passed.
# Five frames. Nothing in the fixture is a literal backslash or a literal
# non-ASCII byte: both are built at RUNTIME with string$, so the lexer never sees
# them and the .bas escape rules cannot change what is being tested.
# BASH ONLY -- NO awk, NO seq. This file used no external text tool before this
# block and must not gain one: how an awk handles \ooo and a lone backslash
# differs between gawk, mawk and busybox, and this block's whole job is to
# compare exact bytes on two machines that have to agree.
bprep() {   # bprep <count> <string> -> that string repeated <count> times
  local n="$1" c="$2" s='' i
  for ((i = 0; i < n; i++)); do s="$s$c"; done
  printf '%s' "$s"
}
manyops="c\$$(bprep 299 ', c$')"
printf '%s\n' 'trace 1' 'a$ = string$(5000, 65)' 'b$ = string$(256, 66)' \
              'breakpoint "cap", a$, b$' 'm$ = string$(5000, 68)' \
              'breakpoint m$, 1' 'u$ = "x" + string$(128, 233)' \
              'breakpoint "utf", u$' 's$ = string$(300, 92)' \
              'breakpoint "esc", s$' 'c$ = string$(256, 67)' \
              "breakpoint \"many\", $manyops" 'println "bp-cap-marker"' > "$bpdir/bpcap.bas"
printf 'bp-cap-marker\n' > "$bpdir/want-cap.out"
if "$exe" "$bpdir/bpcap.bas" < /dev/null > "$bpdir/p5.out" 2> "$bpdir/p5.err"; then p5code=0; else p5code=$?; fi
p5frames=$(wc -l < "$bpdir/p5.err")
p5cap=$(sed -n '1p' "$bpdir/p5.err")
p5msg=$(sed -n '2p' "$bpdir/p5.err")
p5utf=$(sed -n '3p' "$bpdir/p5.err")
p5esc=$(sed -n '4p' "$bpdir/p5.err")
p5many=$(sed -n '5p' "$bpdir/p5.err")
# GREP'S "NO MATCH" IS AN EXIT CODE, AND THIS FILE RUNS UNDER set -e -o pipefail.
# An empty stderr -- exactly what the defect being guarded looks like -- gives
# grep nothing to match, which failed the pipeline and killed the script between
# P4 and the verdict: no "ceilings:" line, no FAIL, no exit "$fail". Measured,
# not feared: it happened on the first run of the mutation that deletes the seam.
p5shown=$( { printf '%s' "$p5many" | grep -o ' \[[0-9][0-9]*\]=' || true; } | wc -l )
p5drop=$(printf '%s' "$p5many" | sed -n 's/.*\.\.\.(\([0-9][0-9]*\) more)$/\1/p')
# THE THREE TAILS, DERIVED AND COMPARED WHOLE rather than counted, because the
# fixture's own path carries backslashes and capital Ds of its own.
#   u$ is 'x' plus 128 two-byte characters = 257 bytes, so the cut at 256 falls
#   BETWEEN the two bytes of the 128th: that character goes whole and 'x' plus
#   127 of them, 255 bytes, survives. A byte-blind cut would end on a lone lead
#   byte, which no length check would notice.
#   s$ is 300 backslashes, capped to 256 BEFORE escaping, each escaping to two:
#   512. Capping AFTER escaping would leave 256, and is the shape that can also
#   split a backslash from the character it escapes.
p5e2=$(printf '\303\251')   # the two bytes of one two-byte character
p5wantutf="breakpoint: utf [1]=\"x$(bprep 127 "$p5e2")\"...(257 bytes)"
p5wantesc="breakpoint: esc [1]=\"$(bprep 512 '\')\"...(300 bytes)"
p5wantmsg="breakpoint: $(bprep 1024 'D')...(5000 bytes) [1]=1"
p5why=''
p5err="$(cat "$bpdir/p5.err")"
if   [ "$p5code" -ne 0 ];                        then p5why="exit $p5code"
elif [ "$p5frames" -ne 5 ];                      then p5why="$p5frames frames, wanted 5 (a cut must not split a line)"
elif [[ "$p5cap" != *'...(5000 bytes)'* ]];      then p5why='a 5000-byte operand did not declare its true length'
elif [[ "$p5err" == *'...(256 bytes)'* ]];       then p5why='an operand AT the ceiling was cut; the guard refuses something legitimate'
elif [ "$(printf '%s' "$p5cap" | wc -c)" -gt 1200 ]; then p5why="the 5000-byte operand still cost $(printf '%s' "$p5cap" | wc -c) bytes of line"
elif [[ "$p5msg" != *"$p5wantmsg" ]];            then p5why='a 5000-byte MESSAGE was not capped to 1024 and declared'
elif [[ "$p5utf" != *"$p5wantutf" ]];            then p5why='the operand cut did not land on a character boundary'
elif [[ "$p5esc" != *"$p5wantesc" ]];            then p5why='the operand cut landed after escaping, not before (or did not declare its length)'
elif [ "$(printf '%s' "$p5many" | wc -c)" -gt 9500 ]; then p5why="300 operands cost $(printf '%s' "$p5many" | wc -c) bytes of line"
elif [ -z "$p5drop" ];                           then p5why='the operands left out of the line were not declared'
elif [ $((p5shown + p5drop)) -ne 300 ];          then p5why="shown $p5shown + dropped $p5drop is not the 300 passed"
elif ! cmp -s "$bpdir/p5.out" "$bpdir/want-cap.out"; then p5why='stdout is not byte-exact'
fi
if [ -n "$p5why" ]; then echo "        ceilings: $p5why"; okP=1; fi

if [ "$okP" -eq 0 ]; then echo 'PASS  P:breakpoint reports (all three doors, on stderr, stdout byte-exact, bounded)'
else echo 'FAIL  P:a breakpoint reports to nobody, reports onto stdout, or reports without a ceiling'; fail=1; fi

exit "$fail"
