#!/usr/bin/env bash
# Builds the headless suite runner (phosphortest) on Unix and runs it over the
# phase-1 oracle files + negatives, byte-comparing each summary to its golden.
# The Unix counterpart of scripts/test-suite.ps1.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
FPC="${FPC:-$(command -v fpc || true)}"
[ -n "$FPC" ] || { echo "fpc not found on PATH (set FPC=/path/to/fpc)"; exit 1; }

# boundary check (same as build.sh)
forbidden="crt video keyboard lcl lclintf lcltype forms controls dialogs graphics interfaces windows unix baseunix"
for f in "$root"/engine/*.pas; do
  flat="$(tr '\n' ' ' < "$f" | tr 'A-Z' 'a-z')"
  for u in $forbidden; do
    printf '%s' "$flat" | grep -qE "uses[^;]*[ ,]$u[ ,;]" && { echo "boundary violation: $(basename "$f") uses '$u'"; exit 1; }
  done
done
echo "boundary check: engine stays host-agnostic"

bin="$root/bin"; cpu="$("$FPC" -iTP)"; units="$bin/units/${cpu}-linux"
exe="$bin/phosphortest"
mkdir -p "$units"; rm -f "$exe"
"$FPC" -Mobjfpc -Scghi -O2 -vewn -Tlinux \
  -Fu"$root/engine" -Fu"$root/tests" -FU"$units" -FE"$bin" -o"$exe" \
  "$root/host/console/phosphortest.lpr" >/dev/null
[ -x "$exe" ] || { echo "phosphortest did not build"; exit 1; }
echo "runner built: $exe"; echo

suite="$root/tests/suite"; neg="$root/tests/negative"
# Single-source manifest, shared with test-suite.ps1 so Windows/Linux never drift.
manifest="$(grep -vE '^[[:space:]]*#' "$suite/manifest.txt" | tr '\n' ' ')"
out="$(mktemp)"; err="$(mktemp)"; trap 'rm -f "$out" "$err"' EXIT
allok=0

for name in $manifest; do
  "$exe" "$suite/$name.bas" > "$out" 2> "$err"; code=$?
  if [ "$code" -eq 0 ] && cmp -s "$out" "$suite/$name.expected"; then
    echo "PASS  $name  ($(wc -c <"$out") B, exit 0)"
  else
    echo "FAIL  $name  (exit $code)"; echo "  expected: $(cat "$suite/$name.expected")"; echo "  actual:   $(cat "$out")"; allok=1
  fi
done

echo
for f in "$neg"/*.bas; do
  "$exe" "$f" > "$out" 2> "$err"; code=$?
  if [ "$code" -ne 0 ]; then
    echo "PASS  reject: $(basename "$f")  (exit $code)"
    [ -s "$err" ] && echo "         $(cat "$err")"
  else
    echo "FAIL  reject: $(basename "$f")  ran instead of being rejected"; allok=1
  fi
done

echo
if [ "$allok" -eq 0 ]; then echo "SUITE OK"; else echo "SUITE FAILED"; fi
exit "$allok"
