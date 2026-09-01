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
outA="$(mktemp)"; outB="$(mktemp)"; outC="$(mktemp)"; packed="$(mktemp -u).run"
trap 'rm -f "$outA" "$outB" "$outC" "$packed"' EXIT

echo
"$exe" run "$bas" --out "$outA"                 # A: --out file path
"$exe" run "$bas" > "$outB"                      # B: redirected stdout (raw bytes)
"$exe" pack "$bas" "$packed"                     # C: pack into a standalone binary
"$packed" > "$outC"                              #    and run it with no arguments

fail=0
if cmp -s "$outA" "$expected"; then echo "PASS  A:--out        ($(wc -c <"$outA") bytes match golden)"
else echo "FAIL  A:--out"; fail=1; fi
if cmp -s "$outB" "$expected"; then echo "PASS  B:stdout-redir ($(wc -c <"$outB") bytes match golden)"
else echo "FAIL  B:stdout-redir"; fail=1; fi
if cmp -s "$outC" "$expected"; then echo "PASS  C:packed       ($(wc -c <"$outC") bytes match golden)"
else echo "FAIL  C:packed"; fail=1; fi

exit "$fail"
