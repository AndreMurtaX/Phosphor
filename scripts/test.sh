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

exit "$fail"
