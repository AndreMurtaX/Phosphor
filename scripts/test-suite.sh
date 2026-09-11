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
for f in $(find "$root/engine" -name '*.pas'); do
  # Strip Pascal comments (line //, brace { }) before flattening, so a unit named
  # in prose (an engine comment naming the LCL host it must NOT reach) cannot trip
  # the check -- documentation is not a dependency.
  flat="$(sed -E 's://.*$::' "$f" | tr '\n' ' ' | sed -E 's/\{[^}]*\}/ /g' | tr 'A-Z' 'a-z')"
  for u in $forbidden; do
    printf '%s' "$flat" | grep -qE "uses[^;]*[ ,]$u[ ,;]" && { echo "boundary violation: $(basename "$f") uses '$u'"; exit 1; }
  done
done
echo "boundary check: engine stays host-agnostic"

bin="$root/bin"; cpu="$("$FPC" -iTP)"; units="$bin/units/${cpu}-linux"
exe="$bin/phosphortest"
mkdir -p "$units"; rm -f "$exe"
"$FPC" -Mobjfpc -Scghi -O2 -vewn -Tlinux \
  -Fu"$root/engine" -Fu"$root/engine/libs" -Fu"$root/tests" -FU"$units" -FE"$bin" -o"$exe" \
  "$root/host/console/phosphortest.lpr" >/dev/null
[ -x "$exe" ] || { echo "phosphortest did not build"; exit 1; }
echo "runner built: $exe"

# THE RUNNER MUST REFUSE TO ANSWER WHEN IT IS OLDER THAN THE ENGINE, proved here
# because this is the one moment we know it is fresh. build.sh does not build this
# file; running it after an engine edit ran old code and answered confidently with
# it. RefuseIfStale in phosphortest.lpr turns that into exit 3.
#
# The BINARY's timestamp is moved back, never a source file's: bin/ is a build
# artifact and the next compile overwrites it. Restored immediately either way.
# It is moved to just BEFORE the newest source that guard actually reads,
# computed here rather than by a fixed offset. The four sets below mirror
# RefuseIfStale's four NewestIn calls exactly, and non-recursively, because it
# scans each directory and not its children.
#
# A fixed '2 hours ago' fired only when the runner happened to be built within two
# hours of an engine edit -- which is to say only when nobody needs the guard. On
# 2026-09-11 this tree's newest .pas was SIXTEEN hours old here, because a git pull
# that changes no .pas leaves every source stamped at the previous checkout, so the
# back-dated binary stayed newer than all of them and this check declared the guard
# broken. It had never once run on Linux. Windows passed the same morning by a
# one-minute margin, which is luck, not a test.
newest_src=$(
  { find "$root/engine"       -maxdepth 1 -name '*.pas' -printf '%T@\n'
    find "$root/engine/libs"  -maxdepth 1 -name '*.pas' -printf '%T@\n'
    find "$root/tests"        -maxdepth 1 -name '*.pas' -printf '%T@\n'
    find "$root/host/console" -maxdepth 1 -name '*.lpr' -printf '%T@\n'
  } | sort -rn | head -1 | cut -d. -f1
)
case "$newest_src" in
  ''|*[!0-9]*)
    echo "cannot read the source timestamps the staleness guard compares against;" >&2
    echo "the proof cannot run, and a check that silently does not run is worse than none" >&2
    exit 1 ;;
esac
touch -r "$exe" "$exe.stamp"
touch -d "@$((newest_src - 60))" "$exe"
"$exe" "$root/tests/suite/00_harness.bas" >/dev/null 2>&1
stale_rc=$?
touch -r "$exe.stamp" "$exe"
rm -f "$exe.stamp"
if [ "$stale_rc" -ne 3 ]; then
  echo "phosphortest ran with a back-dated binary (exit $stale_rc, expected 3) -- the staleness guard is not working"
  exit 1
fi
# And the other direction, because a guard that refused EVERYTHING would also have
# passed the check above. With its own timestamp restored the runner must answer.
"$exe" "$root/tests/suite/00_harness.bas" >/dev/null 2>&1
fresh_rc=$?
if [ "$fresh_rc" -eq 3 ]; then
  echo "phosphortest refused its own freshly built binary (exit 3) -- the guard refuses everything"
  exit 1
fi
echo "runner refuses when stale (exit 3), answers when fresh (exit $fresh_rc)"; echo

suite="$root/tests/suite"; neg="$root/tests/negative"
# Single-source manifest, shared with test-suite.ps1 so Windows/Linux never drift.
manifest="$(grep -vE '^[[:space:]]*#' "$suite/manifest.txt" | tr '\n' ' ')"
out="$(mktemp)"; err="$(mktemp)"; trap 'rm -f "$out" "$err"' EXIT
allok=0
prove="${1:-}"

# --prove: corrupt ONE expected value so an assertion must fail, then confirm the
# byte comparison catches it. The harness is seen failing before it is trusted --
# the same discipline test-suite.ps1 applies, which Linux was missing entirely.
# An argument this script does not know is an ERROR, not a silent full run. It
# already cost a false report once: `--prove-failure` (the PowerShell spelling with
# a dash) fell through to the ordinary suite, which printed SUITE OK, and the run
# was almost recorded as a ProveFailure that had never happened. A check that can
# silently not run is worse than no check.
case "$prove" in
  ''|--prove|-ProveFailure) ;;
  *) echo "test-suite.sh: unknown argument '$prove' (use --prove or -ProveFailure)" >&2; exit 2 ;;
esac

if [ "$prove" = "--prove" ] || [ "$prove" = "-ProveFailure" ]; then
  bad="$(mktemp)"
  sed 's/assert_eq(2 + 3, 5)/assert_eq(2 + 3, 6)/' "$suite/00_harness.bas" > "$bad"
  echo "ProveFailure: one expected value corrupted"
  "$exe" "$bad" > "$out" 2> "$err"; code=$?
  if [ "$code" -eq 0 ] && cmp -s "$out" "$suite/00_harness.expected"; then
    echo "ProveFailure: NOT detected -- the check is broken"; allok=1
  else
    echo "ProveFailure: mismatch correctly detected"
  fi
  rm -f "$bad"
  echo
  if [ "$allok" -eq 0 ]; then echo "SUITE OK"; exit 0; else echo "SUITE FAILED"; exit 1; fi
fi

# THE MANIFEST MUST COVER THE DIRECTORY, BOTH WAYS. Nothing used to check this. A
# .bas dropped into tests/suite and never listed simply did not run -- on either OS --
# while scripts/coverage.py still counted it as "exercised by a test", because that
# gate globs tests/**/*.bas rather than reading the manifest. The two checks then
# agreed on a green nobody had earned: one proved the function was mentioned, the
# other never executed the file mentioning it.
for f in "$suite"/*.bas; do
  [ -e "$f" ] || { echo "FAIL  manifest: tests/suite holds no .bas files at all"; allok=1; break; }
  b="$(basename "$f" .bas)"
  case " $manifest " in
    *" $b "*) ;;
    *) echo "FAIL  manifest: $b.bas is in tests/suite but not in manifest.txt -- it never runs"; allok=1 ;;
  esac
done
for name in $manifest; do
  [ -f "$suite/$name.bas" ]      || { echo "FAIL  manifest: $name is listed but $name.bas is missing"; allok=1; }
  [ -f "$suite/$name.expected" ] || { echo "FAIL  manifest: $name is listed but $name.expected is missing"; allok=1; }
done

for name in $manifest; do
  "$exe" "$suite/$name.bas" > "$out" 2> "$err"; code=$?
  if [ "$code" -eq 0 ] && cmp -s "$out" "$suite/$name.expected"; then
    echo "PASS  $name  ($(wc -c <"$out") B, exit 0)"
  else
    echo "FAIL  $name  (exit $code)"; echo "  expected: $(cat "$suite/$name.expected")"; echo "  actual:   $(cat "$out")"; allok=1
  fi
done

echo
# An emptied tests/negative used to print "PASS  reject: *.bas" and leave the suite
# green: without nullglob the loop runs ONCE on the unexpanded pattern, phosphortest
# fails to open a file called "*.bas", the non-zero exit reads as a correct rejection,
# and the hollow pass is indistinguishable from a real one. Demonstrated, then fixed.
negcount=0
for f in "$neg"/*.bas; do [ -f "$f" ] && negcount=$((negcount + 1)); done
if [ "$negcount" -eq 0 ]; then
  echo "FAIL  negatives: no .bas files found in tests/negative -- the suite proves nothing about rejection"
  allok=1
fi
for f in "$neg"/*.bas; do
  [ -f "$f" ] || continue          # the unexpanded pattern, already reported above
  "$exe" "$f" > "$out" 2> "$err"; code=$?
  if [ "$code" -ne 0 ]; then
    echo "PASS  reject: $(basename "$f")  (exit $code)"
    [ -s "$err" ] && echo "         $(cat "$err")"
  else
    echo "FAIL  reject: $(basename "$f")  ran instead of being rejected"; allok=1
  fi
done

# Pascal probes + the embed host: host-facing programs a .bas file cannot express
# (the value kernel, the execution limits, the embedding API). Each prints ok:/
# fail: and exits non-zero on a failure.
echo
for pair in "probe_value:tests/probe_value.lpr" "probe_handles:tests/probe_handles.lpr" "probe_limits:tests/probe_limits.lpr" "probe_bytecode:tests/probe_bytecode.lpr" "probe_sandbox:tests/probe_sandbox.lpr" "probe_registry:tests/probe_registry.lpr" "probe_debug:tests/probe_debug.lpr" "probe_crt:tests/probe_crt.lpr" "probe_budget:scripts/probe_budget.lpr" "phosphorembed:host/embed/phosphorembed.lpr" "probe_demo:lazarus/demo/demo_smoke.lpr"; do
  name="${pair%%:*}"; src="${pair#*:}"
  # A probe whose SOURCE has gone missing used to be skipped in silence, so deleting
  # tests/probe_bytecode.lpr or host/embed/phosphorembed.lpr still printed SUITE OK.
  # The same rule the gates below state: not running is not passing.
  [ -f "$root/$src" ] || { echo "FAIL  probe: $name  source $src is missing"; allok=1; continue; }
  pexe="$bin/$name"; rm -f "$pexe"
  "$FPC" -Mobjfpc -Scghi -O2 -vewn -Tlinux \
    -Fu"$root/engine" -Fu"$root/engine/libs" -Fu"$root/host/packages" \
    -Fu"$root/lazarus/demo" \
    -FU"$units" -FE"$bin" -o"$pexe" \
    "$root/$src" >/dev/null 2>&1
  if [ ! -x "$pexe" ]; then echo "FAIL  probe: $name  did not build"; allok=1; continue; fi
  "$pexe" >"$out" 2>"$err"; pcode=$?
  psum="$(grep -E '^(ok|fail|skip):' "$out" | tr '\n' ' ')"
  if [ "$pcode" -eq 0 ]; then echo "PASS  probe: $name  ($psum)"; else echo "FAIL  probe: $name  ($psum)"; allok=1; fi
done

# --- source-level gates -------------------------------------------------------
# The invariants no compiler can check and no golden happens to cover:
#   check-codepage.py  no Char is concatenated into a code-page string (bytes >= 128
#                      are silently destroyed; the class has been swept three times)
#   coverage.py        every registered built-in is exercised by a test AND listed in
#                      the function reference
#   check-sandbox.py   every routine a script can reach that touches the filesystem
#                      asks the sandbox gate first (or is exempt, by name, with a
#                      reason) -- the rule that would otherwise rot one function at a
#                      time, as PhosphorConfigLib's .ini did until 2026-09-06
#   check-seams.py     every host either fills each engine seam (OnOutput, OnInput,
#                      OnBreakpoint, HostServices) or records why it is right to leave
#                      it nil -- a nil seam answers silently, which is how the GUI host
#                      of the day shipped answering every INPUT with an empty line
#   check-budget.py    every library loop or allocation over a quantity the VM cannot
#                      see -- a count from a script, a directory, a decompressed
#                      stream, a wait, a regex -- consults engine/PhosphorBudget.pas
#                      (or is exempt, by name, with a reason). The three execution
#                      ceilings are tested BETWEEN instructions and a library call is
#                      one instruction, so without this rule a single regex_find$,
#                      string$ or pause ran for ever with every ceiling set
#   check-suffix.py    a registered name's type SUFFIX is the kind its body returns.
#                      The suffix is the whole return-type system for built-ins and
#                      nothing enforced it: fifteen registrations lied, across three
#                      unrelated libraries, and each one aborted a caller at run time
#                      with "cannot store X into Y variable"
#   check-examples.py  every ```basic block in the docs COMPILES. coverage.py already
#                      refuses a block that calls a function which does not exist; it
#                      cannot refuse one whose functions are all real and whose syntax
#                      is wrong, and on 2026-09-06 four such blocks were in the tree,
#                      including the worked example a reader is most likely to copy
# They are run HERE, in the acceptance gate, rather than in the build: building
# should not need Python, but passing the suite should mean the invariants hold.
# A missing interpreter is a FAILURE, not a skip -- a gate that quietly does not run
# is worse than no gate, because it reads as a pass.
echo
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  echo "FAIL  gates: no python interpreter found (needed by the source checks)"; allok=1
else
  for gate in check-codepage.py coverage.py check-sandbox.py check-seams.py check-examples.py check-suffix.py check-budget.py check-manifests.py; do
    # The comment above says a gate that quietly does not run is worse than no gate,
    # and then this line skipped a gate whose FILE was missing. A deleted gate is
    # exactly the case the sentence was written about.
    [ -f "$here/$gate" ] || { echo "FAIL  gate: $gate is missing from scripts/"; allok=1; continue; }
    if gout="$("$PY" "$here/$gate" 2>&1)"; then
      echo "PASS  gate: $gate"
    else
      echo "FAIL  gate: $gate"
      echo "$gout" | sed 's/^/         /'
      allok=1
    fi
  done
fi

echo
if [ "$allok" -eq 0 ]; then echo "SUITE OK"; else echo "SUITE FAILED"; fi
exit "$allok"
