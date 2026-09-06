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
packed="$(mktemp -u).run"; packedD="$(mktemp -u).nc.run"
trap 'rm -f "$outA" "$outB" "$outC" "$outD" "$packed" "$packedD"' EXIT

echo
"$exe" run "$bas" --out "$outA"                 # A: --out file path
"$exe" run "$bas" > "$outB"                      # B: redirected stdout (raw bytes)
"$exe" pack "$bas" "$packed"                     # C: pack into a standalone binary
"$packed" > "$outC"                              #    and run it with no arguments
# D: the same, packed --no-console. On Unix the flag is a NO-OP -- the terminal is
# the user's, never the program's -- and it must still be accepted and still
# produce the same bytes, because a flag that is refused on one platform makes a
# build script platform-specific for no reason.
"$exe" pack --no-console "$bas" "$packedD"
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

exit "$fail"
