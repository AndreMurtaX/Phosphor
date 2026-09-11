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
#    just `PBC` are both valid BASIC. Shapes 3 and 4 are those two, and here
#    shape 4's fourth byte is LF where on Windows it is CR -- the same file asks a
#    different half of the rule on each OS, which is the honest thing about it.
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
check_sniff_runs 'PBCount = 3'      "$sniffdir/pbcount.bas"   'count is 3'      || okO=1
check_sniff_runs 'PBC$ = "..."'     "$sniffdir/pbcdollar.bas" 'hello there'     || okO=1
check_sniff_runs 'PBC<TAB>= 3'      "$sniffdir/pbctab.bas"    'tabbed is 3'     || okO=1
check_sniff_runs 'a bare PBC line'  "$sniffdir/pbcbare.bas"   'a bare pbc line' || okO=1

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

exit "$fail"
