#!/usr/bin/env bash
# Builds the opt-in-package test runner (phosphorpkgtest) on Unix and runs it over
# the package suite (base64, zip, ...), byte-comparing each summary to its golden.
# The Unix counterpart of scripts/test-packages.ps1. The packages used here ship
# with FPC (fcl-base, paszlib), so no external runtime library is needed.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
FPC="${FPC:-$(command -v fpc || true)}"
[ -n "$FPC" ] || { echo "fpc not found on PATH (set FPC=/path/to/fpc)"; exit 1; }

bin="$root/bin"; cpu="$("$FPC" -iTP)"; units="$bin/pkg-units/${cpu}-linux"
exe="$bin/phosphorpkgtest"
mkdir -p "$units"; rm -f "$exe"
"$FPC" -Mobjfpc -Scghi -O2 -vewn -Tlinux \
  -Fu"$root/engine" -Fu"$root/engine/libs" -Fu"$root/tests" -Fu"$root/host/packages" \
  -FU"$units" -FE"$bin" -o"$exe" \
  "$root/host/packages/phosphorpkgtest.lpr" >/dev/null
[ -x "$exe" ] || { echo "phosphorpkgtest did not build"; exit 1; }
echo "package runner built: $exe"; echo

pkg="$root/tests/packages"
manifest="$(grep -vE '^[[:space:]]*#' "$pkg/manifest.txt" | tr '\n' ' ')"
out="$(mktemp)"; err="$(mktemp)"; trap 'rm -f "$out" "$err"' EXIT
allok=0

for name in $manifest; do
  "$exe" "$pkg/$name.bas" > "$out" 2> "$err"; code=$?
  if [ "$code" -eq 0 ] && cmp -s "$out" "$pkg/$name.expected"; then
    echo "PASS  $name  ($(wc -c <"$out") B, exit 0)"
  else
    echo "FAIL  $name  (exit $code)"; echo "  expected: $(cat "$pkg/$name.expected")"; echo "  actual:   $(cat "$out")"; [ -s "$err" ] && sed 's/^/    /' "$err"; allok=1
  fi
done

echo
if [ "$allok" -eq 0 ]; then echo "PACKAGES OK"; else echo "PACKAGES FAILED"; fi
exit "$allok"
