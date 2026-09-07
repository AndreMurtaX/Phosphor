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

# K: THE MIRROR, and it matters as much as J. NO trailer magic means this file is
#    a bare stub, and being the CLI is then exactly right -- that is the whole
#    reason one binary can be both. A refusal that swallowed this case would have
#    broken `phosphor` itself. Two shapes: the stub as built, and a packed file
#    truncated so that the magic is gone with it.
stub="$hidir/truncated"
head -c $((sizeA - 1)) "$packed" > "$stub"; chmod +x "$stub"

okK=0
check_is_cli() {  # path what
  local out code
  if out="$("$1" < /dev/null 2>&1)"; then code=0; else code=$?; fi
  if [ "$code" -eq 0 ] && echo "$out" | grep -q REPL; then return 0; fi
  echo "        $2: exit $code, said '$out'"
  return 1
}
check_is_cli "$exe"  "the stub itself"                   || okK=1
check_is_cli "$stub" "packed, truncated past its magic"  || okK=1
if [ "$okK" -eq 0 ]; then echo "PASS  K:no magic is the CLI (a bare stub still opens the REPL)"
else echo "FAIL  K:a file with no trailer magic no longer behaves as the CLI"; fail=1; fi

exit "$fail"
