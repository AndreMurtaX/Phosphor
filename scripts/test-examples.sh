#!/usr/bin/env bash
# Runs every program in examples/ and byte-compares it to a golden.
#
# WHY THIS EXISTS. examples/ is the face of the project -- the README points at
# it, and it is the first code anyone runs. Nothing executed it. Every other
# corpus in tests/ has a runner; the one directory a person actually opens had
# none, so examples/interactive.bas shipped answering every INPUT with an empty
# string (the GUI host assigned no input seam) and examples/crt_keys.bas shipped
# unable to reach its own last line (a number assigned into a string variable).
# Both were found by a human typing the command. That is not a test strategy.
#
# Modes, from examples/manifest.txt ("<name>|<mode>"):
#   run      run with stdin closed, compare stdout+stderr to <name>.expected
#   input    the same, with <name>.in piped in (a recorded session)
#   compile  compile only -- it opens a window and waits, and the compiler is
#            host-agnostic so this is what CAN be checked without a display
#
# Every run is sandboxed to the checkout, so an example that writes files cannot
# write them anywhere else.  --prove-failure corrupts one golden to show the
# comparison reports it.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
examples="$root/examples"
exe="$root/bin/phosphor"
prove=0
[ "${1:-}" = "--prove-failure" ] && prove=1

# The binary must be the CURRENT one: running a stale build is running old code.
bash "$here/build.sh" >/dev/null 2>&1 || { echo "FAIL  build: phosphor did not build"; exit 1; }
[ -x "$exe" ] || { echo "FAIL  build: no phosphor binary"; exit 1; }

manifest="$examples/manifest.txt"
[ -f "$manifest" ] || { echo "FAIL  manifest: examples/manifest.txt is missing"; exit 1; }

allok=0
names=""
modes=""
while IFS= read -r line; do
  t="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$t" in ''|\#*) continue;; esac
  case "$t" in *\|*) : ;; *) echo "FAIL  manifest: '$t' is not '<name>|<mode>'"; exit 1;; esac
  names="$names ${t%%|*}"
  modes="$modes ${t##*|}"
done < "$manifest"

# The manifest covers the directory in both directions.
for f in "$examples"/*.bas; do
  b="$(basename "$f" .bas)"
  case " $names " in *" $b "*) : ;; *) echo "FAIL  manifest: $b.bas is in examples/ but not in manifest.txt -- it never runs"; allok=1;; esac
done
for n in $names; do
  [ -f "$examples/$n.bas" ] || { echo "FAIL  manifest: $n is listed but $n.bas is missing"; allok=1; }
done
[ "$allok" -eq 0 ] || { echo; echo "EXAMPLES FAILED"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

i=0
set -- $modes
for n in $names; do
  i=$((i + 1))
  mode="$(eval echo \${$i})"
  bas="$examples/$n.bas"
  gold="$examples/$n.expected"
  out="$tmp/$n.out"

  if [ "$mode" = "compile" ]; then
    if "$exe" compile "$bas" "$tmp/$n.pbc" >/dev/null 2>&1 && [ -f "$tmp/$n.pbc" ]; then
      echo "PASS  $n  (compiles; it opens a window, so it is not run here)"
    else
      echo "FAIL  $n  did not compile"; allok=1
    fi
    continue
  fi

  [ -f "$gold" ] || { echo "FAIL  $n  has no golden ($n.expected)"; allok=1; continue; }

  if [ "$mode" = "input" ]; then
    [ -f "$examples/$n.in" ] || { echo "FAIL  $n  is listed as 'input' but $n.in is missing"; allok=1; continue; }
    "$exe" --sandbox "$root" run "$bas" > "$out" 2>&1 < "$examples/$n.in"
  elif [ "$mode" = "run" ]; then
    "$exe" --sandbox "$root" run "$bas" > "$out" 2>&1 < /dev/null
  else
    echo "FAIL  $n  unknown mode '$mode'"; allok=1; continue
  fi
  code=$?

  want="$gold"
  if [ "$prove" -eq 1 ] && [ "$i" -eq 1 ]; then
    cp "$gold" "$tmp/corrupt"
    printf 'X' | dd of="$tmp/corrupt" bs=1 seek=0 conv=notrunc 2>/dev/null
    want="$tmp/corrupt"
    echo "ProveFailure: one golden byte corrupted"
  fi

  if cmp -s "$out" "$want" && [ "$code" -eq 0 ]; then
    echo "PASS  $n  ($(wc -c < "$out" | tr -d ' ') B, exit 0)"
  else
    echo "FAIL  $n  (exit $code)"
    echo "        expected $(wc -c < "$want" | tr -d ' ') B, got $(wc -c < "$out" | tr -d ' ') B"
    allok=1
  fi
done

echo
if [ "$prove" -eq 1 ]; then
  if [ "$allok" -eq 0 ]; then echo "ProveFailure: the corruption was NOT detected"; exit 1; fi
  echo "ProveFailure: mismatch correctly detected"
  echo "EXAMPLES OK"
  exit 0
fi
if [ "$allok" -eq 0 ]; then echo "EXAMPLES OK"; exit 0; fi
echo "EXAMPLES FAILED"
exit 1
