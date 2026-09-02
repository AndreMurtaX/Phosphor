#!/usr/bin/env bash
# Runs the classic-BASIC feature tests through the `phosphor` console host, byte-
# comparing each program's output to its golden. The Linux counterpart of
# test-classic.ps1 (same tests/classic files, so the two OSes never drift).
#
#   INPUT / LINE INPUT / INPUT$, classic #-numbered file I/O, PRINT USING, SWAP,
#   and that every function package is reachable through the host.
#
# --prove corrupts one golden byte and confirms the comparison reports a mismatch.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
exe="$root/bin/phosphor"
[ -x "$exe" ] || { echo "phosphor not built -- run scripts/build.sh first"; exit 2; }
dir="$root/tests/classic"
tmp="$(mktemp -d)"
prove="${1:-}"
allok=1

run_one() {  # bas inpath expected label
  local bas="$1" inp="$2" expected="$3" label="$4"
  local out="$tmp/classic.out"
  rm -f "$out"
  if [ -n "$inp" ]; then
    "$exe" run "$bas" --out "$out" < "$inp" 2>/dev/null
  else
    "$exe" run "$bas" --out "$out" < /dev/null 2>/dev/null
  fi
  local code=$?
  if cmp -s "$out" "$expected" && [ "$code" -eq 0 ]; then
    echo "PASS  $label  ($(wc -c < "$out" | tr -d ' ') B)"
    return 0
  fi
  echo "FAIL  $label"
  [ "$code" -ne 0 ] && echo "  exit $code"
  if ! cmp -s "$out" "$expected"; then
    echo "  expected: $(tr '\n' '|' < "$expected")"
    echo "  actual:   $(tr '\n' '|' < "$out")"
  fi
  return 1
}

if [ "$prove" = "--prove" ] || [ "$prove" = "-ProveFailure" ]; then
  first="$(ls "$dir"/*.bas | sort | head -1)"
  base="$(basename "$first" .bas)"
  bad="$tmp/bad.expected"
  cp "$dir/$base.expected" "$bad"
  printf 'X' | dd of="$bad" bs=1 seek=0 count=1 conv=notrunc 2>/dev/null
  inp=""; [ -f "$dir/$base.in" ] && inp="$dir/$base.in"
  echo "ProveFailure: one golden byte corrupted"
  if run_one "$first" "$inp" "$bad" "$base (corrupted, expect mismatch)" >/dev/null; then
    echo "ProveFailure: NOT detected -- the check is broken"; allok=0
  else
    echo "ProveFailure: mismatch correctly detected"
  fi
else
  for bas in "$dir"/*.bas; do
    base="$(basename "$bas" .bas)"
    inp=""; [ -f "$dir/$base.in" ] && inp="$dir/$base.in"
    run_one "$bas" "$inp" "$dir/$base.expected" "$base" || allok=0
  done
fi

echo ""
if [ "$allok" -eq 1 ]; then echo "CLASSIC OK"; exit 0; else echo "CLASSIC FAILED"; exit 1; fi
