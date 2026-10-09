#!/usr/bin/env bash
# Builds the headless suite runner (phosphortest) on Unix and runs it over the
# phase-1 oracle files + negatives, byte-comparing each summary to its golden.
# The Unix counterpart of scripts/test-suite.ps1.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"

# FIRST, before the fpc lookup below -- a runner must be able to refuse a flag it
# does not understand on a machine that cannot build. This one used to parse at
# line 91, after that lookup and after the staleness probe, so on a host with no
# fpc on PATH a bogus flag was answered `fpc not found` and exit 1.
. "$here/lib/runner.sh"
runner_args "test-suite.sh" prove "$@"

FPC="${FPC:-$(command -v fpc || true)}"
[ -n "$FPC" ] || { echo "fpc not found on PATH (set FPC=/path/to/fpc)"; exit 1; }

# --- boundary check: the engine must not reach a host/GUI unit ---------------
# ONE COPY, in scripts/lib/boundary.sh, with its PowerShell twin beside it. There
# were four, they disagreed, and on 2026-09-15 they were scored for the first time
# against tests/boundary: the bash halves 8/11, the PowerShell halves 10/11. The
# comment that used to sit here claimed this script stripped (* *) comments. It
# did not. scripts/check-boundary.py now runs both halves over those fixtures.
. "$here/lib/boundary.sh"
boundary_check "$root/engine" || { echo "engine must stay host-agnostic (see docs/architecture.md)"; exit 1; }
echo "boundary check: engine stays host-agnostic"

bin="$root/bin"; cpu="$("$FPC" -iTP)"; units="$bin/units/${cpu}-linux"
exe="$bin/phosphortest"
mkdir -p "$units"; rm -f "$exe"
strict_build "phosphortest" "$FPC" -Mobjfpc -Scghi -O2 -vewn -Tlinux \
  -Fu"$root/engine" -Fu"$root/engine/libs" -Fu"$root/tests" -FU"$units" -FE"$bin" -o"$exe" \
  "$root/host/console/phosphortest.lpr"
[ -x "$exe" ] || { echo "phosphortest did not build"; exit 1; }
echo "runner built: $exe"

out="$(mktemp)"; err="$(mktemp)"; trap 'rm -f "$out" "$err"' EXIT

# EVERY PROGRAM THIS SCRIPT HANDS TO phosphortest RUNS UNDER A BOUND. There was
# none until 2026-10-07, when a compiler mutation (FLocalIdx.Clear() removed from
# ParseFunction) made phosphortest spin on 60_stack_operands for eight minutes and
# more, and the suite said nothing at all -- a hang reads as "still running", never
# as FAIL, the same tell as the REPL and app_run traps in CLAUDE.md. The bound is
# MEASURED, not chosen: the slowest suite file that day was 60_stack_operands, at
# 0.35 s on Windows (ten runs) and 0.36 s on the Linux VM, and 30 s is about
# eighty-five times that -- room for a machine loaded by other sessions' suites,
# and a hang now costs half a minute instead of the run. Re-measure before you
# lower it. test-suite.ps1 holds the same number and check-crossrefs.py demands
# that the two agree.
test_timeout_s=30

# Runs phosphortest on $1 with its streams in $out and $err, under a bound of $2
# seconds; answers the exit code, and 124 when the bound ran out. timeout(1)
# signals the child it started, never a process found by name -- other sessions
# run phosphortest too. -k: a child that ignores TERM gets KILL five seconds
# later, and timeout then exits 137. phosphortest itself exits 0 to 3, so
# neither number can be a real answer. The twin of Invoke-Bounded in
# test-suite.ps1.
run_bounded() {
  local rc
  timeout -k 5 "$2" "$exe" "$1" > "$out" 2> "$err"; rc=$?
  case "$rc" in 124|137) return 124 ;; esac
  return "$rc"
}
timed_out() {   # $1 label, $2 the bound in seconds
  echo "FAIL  $1  timed out after $2 s -- killed, the run goes on"
}

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
run_bounded "$root/tests/suite/00_harness.bas" "$test_timeout_s"
stale_rc=$?
touch -r "$exe.stamp" "$exe"
rm -f "$exe.stamp"
if [ "$stale_rc" -ne 3 ]; then
  echo "phosphortest ran with a back-dated binary (exit $stale_rc, expected 3) -- the staleness guard is not working"
  exit 1
fi
# And the other direction, because a guard that refused EVERYTHING would also have
# passed the check above. With its own timestamp restored the runner must answer.
run_bounded "$root/tests/suite/00_harness.bas" "$test_timeout_s"
fresh_rc=$?
if [ "$fresh_rc" -eq 3 ]; then
  echo "phosphortest refused its own freshly built binary (exit 3) -- the guard refuses everything"
  exit 1
fi
echo "runner refuses when stale (exit 3), answers when fresh (exit $fresh_rc)"; echo

suite="$root/tests/suite"; neg="$root/tests/negative"
# Single-source manifest, shared with test-suite.ps1 so Windows/Linux never drift.
manifest="$(grep -vE '^[[:space:]]*#' "$suite/manifest.txt" | tr '\n' ' ')"
allok=0

# The stderr of a FAILED probe, indented, at most 40 lines -- probe_sweep can name a
# hundred programs, and one screen of them is the diagnosis. The twin of
# Show-ProbeErr in test-suite.ps1; keep the cap and the wording equal.
show_probe_err() {   # $1 the stderr file
  local n
  n=$(grep -c '' "$1")
  if [ "$n" -eq 0 ]; then echo "         (the probe wrote nothing to stderr)"; return 0; fi
  head -n 40 "$1" | tr -d '\r' | sed 's/^/         /'
  [ "$n" -gt 40 ] && echo "         ... $((n - 40)) more stderr lines"
  return 0
}

# --prove: corrupt ONE expected value so an assertion must fail, then confirm the
# byte comparison catches it. The harness is seen failing before it is trusted.
#
# The refusal that used to live here -- and the paragraph explaining that
# `--prove-failure` once fell through to an ordinary run which printed SUITE OK --
# now lives in scripts/lib/runner.sh, parsed at the top of this file, because on
# 2026-09-15 that rule was measured to exist in THIS FILE ONLY while five sibling
# runners ignored the canonical spelling in silence.

# A NEGATIVE IS REJECTED FOR ITS OWN REASON, OR IT IS NOT A TEST (ledger d53).
# This used to accept any non-zero exit. phosphortest exits 1 on a failed assert
# and 2 on a compile or runtime error, so a negative that merely contained a
# failing assert read as a correct rejection -- and so did one rejected by some
# OTHER rule than the one it was written for, which is what 10_ turned out to be.
# Exit 2 and the diagnostic carrying the reason tests/negative/manifest.txt
# records for the file -- a reason derived from the file's own rem header. The
# twin of Judge-Negative in test-suite.ps1.
neg_reason() {   # the reason recorded for basename $1, or nothing
  [ -f "$neg/manifest.txt" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    case "$line" in *"|"*) ;; *) continue ;; esac
    k="${line%%|*}"; k="${k//[[:space:]]/}"
    if [ "$k" = "$1" ]; then
      r="${line#*|}"
      r="${r#"${r%%[![:space:]]*}"}"; r="${r%"${r##*[![:space:]]}"}"
      printf '%s' "$r"; return 0
    fi
  done < "$neg/manifest.txt"
}
judge_negative() {   # $1 program, $2 reason, $3 label; 0 when rejected for its reason
  local code why
  run_bounded "$1" "$test_timeout_s"; code=$?
  if [ "$code" -eq 124 ]; then timed_out "reject: $3" "$test_timeout_s"; return 1; fi
  why="$(cat "$err")"
  if [ "$code" -eq 2 ] && [ -n "$2" ]; then
    case "$why" in *"$2"*) echo "PASS  reject: $3  (exit 2)"; echo "         $why"; return 0 ;; esac
  fi
  if [ "$code" -eq 0 ]; then
    echo "FAIL  reject: $3  ran instead of being rejected"
  elif [ "$code" -ne 2 ]; then
    echo "FAIL  reject: $3  exit $code, wanted 2 -- that is not a rejection (1 is a failed assert)"
  elif [ -z "$2" ]; then
    echo "FAIL  reject: $3  has no reason in tests/negative/manifest.txt, so nothing says WHICH rule rejected it"
  else
    echo "FAIL  reject: $3  rejected, but not for its reason"
    echo "  wanted: $2"
    echo "  said:   $why"
  fi
  return 1
}

if [ "$runner_prove" -eq 1 ]; then
  bad="$(mktemp)"
  sed 's/assert_eq(2 + 3, 5)/assert_eq(2 + 3, 6)/' "$suite/00_harness.bas" > "$bad"
  echo "ProveFailure: one expected value corrupted"
  run_bounded "$bad" "$test_timeout_s"; code=$?
  if [ "$code" -eq 0 ] && cmp -s "$out" "$suite/00_harness.expected"; then
    echo "ProveFailure: NOT detected -- the check is broken"; allok=1
  else
    echo "ProveFailure: mismatch correctly detected"
  fi
  rm -f "$bad"
  # AND THE NEGATIVE JUDGE, both of its halves (d53): a real negative against a
  # reason its diagnostic does not carry, then a program that only fails an
  # assert (exit 1) judged with a reason its output DOES carry, so only the exit
  # half can catch it. Each must be judged a failure.
  echo "ProveFailure: one negative reason corrupted"
  if judge_negative "$neg/02_fabricated_array_handle.bas" "a reason this diagnostic does not carry" "02_fabricated_array_handle (corrupted reason)"; then
    echo "ProveFailure: wrong reason NOT detected -- the negative judge is broken"; allok=1
  else
    echo "ProveFailure: wrong reason correctly detected"
  fi
  asserts="$(mktemp)"
  printf 'test_case("prove")\nassert_eq(1, 2, "only an assert fails here")\n' > "$asserts"
  if judge_negative "$asserts" "expected 2, got 1" "a failing assert (exit 1)"; then
    echo "ProveFailure: a failed assert WAS taken for a rejection -- the negative judge is broken"; allok=1
  else
    echo "ProveFailure: a failed assert correctly not taken for a rejection"
  fi
  rm -f "$asserts"
  # AND THE BOUND. A program that never ends, under a two-second bound instead of
  # the real one so the proof is cheap: it must come back as timed out.
  echo "ProveFailure: one program never ends"
  hang="$(mktemp)"
  printf 'test_case("hang")\nwhile 1 = 1\nwend\n' > "$hang"
  started=$(date +%s)
  run_bounded "$hang" 2; hcode=$?
  if [ "$hcode" -eq 124 ]; then
    timed_out "never_ends (a bound of 2 s, for this proof only)" 2
    echo "ProveFailure: a hang correctly ended as a FAIL after $(( $(date +%s) - started )) s"
  else
    echo "ProveFailure: a hang was NOT bounded (exit $hcode) -- the timeout is broken"; allok=1
  fi
  rm -f "$hang"
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
  run_bounded "$suite/$name.bas" "$test_timeout_s"; code=$?
  if [ "$code" -eq 124 ]; then timed_out "$name" "$test_timeout_s"; allok=1; continue; fi
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
if [ "$negcount" -gt 0 ] && [ ! -f "$neg/manifest.txt" ]; then
  echo "FAIL  negatives: tests/negative/manifest.txt is missing -- no negative has a reason to be judged against"
  allok=1
fi
for f in "$neg"/*.bas; do
  [ -f "$f" ] || continue          # the unexpanded pattern, already reported above
  judge_negative "$f" "$(neg_reason "$(basename "$f" .bas)")" "$(basename "$f")" || allok=1
done

# Pascal probes + the embed host: host-facing programs a .bas file cannot express
# (the value kernel, the execution limits, the embedding API). Each prints ok:/
# fail: and exits non-zero on a failure.
#
# probe_step drives a whole debugging session from Pascal -- the debug seam is a
# CALLBACK the engine waits on, so the test has to be the thing on the other end
# of it, and no .bas file can be that.
#
# probe_sweep is the other half of that proof: probe_step pins named cases from
# fixtures whose traces are derived by hand, and probe_sweep generates program
# shapes it has never seen and judges every step against a rule stated in its own
# header. A sweep that measures the OFF state of a feature has not measured the
# feature -- and a sweep that only ever calls eng.Run has not measured the door a
# GUI host uses, which is why every generated program with functions in it is
# also debugged through a host CallFunction.
#
# It is also where THE DIFFERENTIAL lives, and that is the half that re-runs for
# ever. docs/proof-axes.md section 5: for one source, detached, attached-and-
# continuing and attached-and-stepping must be byte-identical on exit code,
# stdout, error line and error message. All three legs are run on every generated
# program at both doors. The detached one -- no seam installed, nothing armed --
# was missing for three rounds, and it is the only leg that can see a defect
# caused by the PRESENCE of a debugger rather than by its answers.
#
# bench_debug is the COST of the seam, committed rather than quoted: it judges only
# the differential (attached and stepping change nothing a program prints or answers)
# and prints its timings without a threshold, because a fixed millisecond bar on an
# unknown machine is red at random. Three review rounds disagreed about one cell of
# docs/embedding.md's cost table and none could settle it, because each ran a bench
# that lived in a scratch directory. `--full` is the real measurement.
#
# probe_onerror is the WORDING of the abandoned-activation diagnostics:
# tests/negative compares exit codes only and tests/classic discards stderr, so
# without it nothing in the tree would notice either message being garbled. It is
# listed in test-suite.ps1 too -- a probe in one runner only is a probe the other
# operating system never runs.
#
# probe_readcost: a console INPUT$ costs what it reads. It drives OnInput itself,
# because no runner hands a test program console input; the channel twin is
# tests/suite/81_chan_read_linear.bas. Judged against a linear control.
#
# probe_hostmem: MaxMemoryBytes charges a session for what its SCRIPT adds,
# across all its calls, and not for what the HOST allocates between them --
# both halves, through CallFunction and through ReplRun.
echo
for pair in "probe_value:tests/probe_value.lpr" "probe_handles:tests/probe_handles.lpr" "probe_limits:tests/probe_limits.lpr" "probe_bytecode:tests/probe_bytecode.lpr" "probe_sandbox:tests/probe_sandbox.lpr" "probe_registry:tests/probe_registry.lpr" "probe_debug:tests/probe_debug.lpr" "probe_step:tests/probe_step.lpr" "probe_sweep:tests/probe_sweep.lpr" "probe_onerror:tests/probe_onerror.lpr" "probe_readcost:tests/probe_readcost.lpr" "probe_hostmem:tests/probe_hostmem.lpr" "bench_debug:tests/bench_debug.lpr" "probe_crt:tests/probe_crt.lpr" "probe_budget:scripts/probe_budget.lpr" "phosphorembed:host/embed/phosphorembed.lpr" "probe_demo:lazarus/demo/demo_smoke.lpr"; do
  name="${pair%%:*}"; src="${pair#*:}"
  # A probe whose SOURCE has gone missing used to be skipped in silence, so deleting
  # tests/probe_bytecode.lpr or host/embed/phosphorembed.lpr still printed SUITE OK.
  # The same rule the gates below state: not running is not passing.
  [ -f "$root/$src" ] || { echo "FAIL  probe: $name  source $src is missing"; allok=1; continue; }
  pexe="$bin/$name"; rm -f "$pexe"
  strict_build "probe $name" "$FPC" -Mobjfpc -Scghi -O2 -vewn -Tlinux \
    -Fu"$root/engine" -Fu"$root/engine/libs" -Fu"$root/host/packages" \
    -Fu"$root/lazarus/demo" \
    -FU"$units" -FE"$bin" -o"$pexe" \
    "$root/$src"
  if [ ! -x "$pexe" ]; then echo "FAIL  probe: $name  did not build"; allok=1; continue; fi
  "$pexe" >"$out" 2>"$err"; pcode=$?
  psum="$(grep -E '^(ok|fail|skip):' "$out" | tr '\n' ' ')"
  if [ "$pcode" -eq 0 ]; then echo "PASS  probe: $name  ($psum)"
  else
    echo "FAIL  probe: $name  ($psum)"; allok=1
    # Every probe writes its `FAIL: <check> -- got ..., wanted ...` lines, and the
    # RTL its runtime errors, to STDERR. This runner used to print only the ok:/fail:
    # counts, so on 2026-10-06 a one-off `probe_step (ok: 224 fail: 1)` on the VM
    # could not be read from the run that had it, and 27 reruns never failed again.
    # A flake is seen once: print the detail every time. Same cap as test-suite.ps1.
    show_probe_err "$err"
  fi
done

# AND THE DETAIL IS SEEN BEING PRINTED. A path that runs only when a probe fails is
# a path no green run exercises, so it is exercised here on purpose: probe_value
# --fail corrupts one expectation (never the engine), and the lines this runner
# would print for it must name the failed check. The twin of the same block in
# test-suite.ps1.
if [ -x "$bin/probe_value" ]; then
  "$bin/probe_value" --fail >"$out" 2>"$err"; pcode=$?
  shown="$(show_probe_err "$err")"
  if [ "$pcode" -ne 0 ] && printf '%s\n' "$shown" | grep -E '^[[:space:]]+FAIL: ' >/dev/null; then
    echo "PASS  probe detail: probe_value --fail exits $pcode and the runner prints:"
    printf '%s\n' "$shown"
  else
    echo "FAIL  probe detail: probe_value --fail exited $pcode and the runner would print no FAIL: line"
    printf '%s\n' "$shown"; allok=1
  fi
else
  echo "FAIL  probe detail: bin/probe_value was not built, so the failure path went unseen"; allok=1
fi

# AND NO ASSERTION RUNS UNDER A LIVE ERROR TRAP (2026-10-08). A file that armed
# `on error goto` for its whole length SKIPPED every assertion whose own argument
# raised -- `resume next` stepped over it, neither pass nor fail -- so
# tests/PhosphorTestLib.pas now fails an assertion that runs while the VM would
# catch a fault. Nothing in a green corpus reaches that refusal, so it is reached
# here, BOTH ways: one assertion under a live trap must fail and say why, and the
# same file disarmed -- plus one assertion inside the handler, where no trap is
# live -- must pass both. A guard that refused everything would pass the first
# half alone. The twin of the same block in test-suite.ps1.
tg_armed="$(mktemp)"; tg_clear="$(mktemp)"
printf 'test_case("guard")\non error goto h\nassert_eq(1, 1, "under a live trap")\non error goto 0\nend\nh:\nresume next\n' > "$tg_armed"
printf 'test_case("guard")\non error goto h\nx = 1 / 0\non error goto 0\nassert_eq(x, 0, "disarmed first")\nend\nh:\nassert_eq(err(), 2, "inside the handler")\nresume next\n' > "$tg_clear"
run_bounded "$tg_armed" "$test_timeout_s"; a_code=$?
a_text="$(tr -d '\r' < "$out")"
a_why="$(cat "$err")"
run_bounded "$tg_clear" "$test_timeout_s"; c_code=$?
c_text="$(tr -d '\r' < "$out")"
a_named=1
case "$a_why" in *"while an ON ERROR trap was armed"*) a_named=0 ;; esac
if [ "$a_code" -eq 1 ] && [ "$a_text" = "$(printf 'passed: 0\nfailed: 1')" ] && [ "$a_named" -eq 0 ] &&
   [ "$c_code" -eq 0 ] && [ "$c_text" = "$(printf 'passed: 2\nfailed: 0')" ]; then
  echo "PASS  trap guard: an assertion under a live trap fails, one outside it or in the handler passes"
else
  echo "FAIL  trap guard: armed exit $a_code [$(echo $a_text)], clear exit $c_code [$(echo $c_text)] -- wanted 1 [passed: 0 failed: 1] naming the trap, and 0 [passed: 2 failed: 0]"
  allok=1
fi
rm -f "$tg_armed" "$tg_clear"

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
  for gate in check-codepage.py coverage.py check-sandbox.py check-seams.py check-examples.py check-suffix.py check-budget.py check-manifests.py check-crossrefs.py check-boundary.py; do
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

  # THE GENERATED NUMBER TEXT SWEEP (tests/number_text_sweep.py, 2026-10-09):
  # about 300000 strings -- random digits and exponents, exact midpoints between
  # adjacent Doubles written out past 255 bytes, the subnormal and DBL_MAX
  # boundaries, text that is not a number -- read through every door the engine
  # reads number text by (val/isnumeric, input #, literals), each answer judged
  # against Python's float(), which is correctly rounded; and str$ of 100000+
  # Doubles read back by float() and by val(). tests/suite/84_number_text.bas is
  # the readable half; this is the grid. It runs bin/phosphor, which this script
  # does not build: check-examples.py above already fails the run when that
  # binary is older than the engine, so a stale sweep cannot pass. Under --prove
  # it corrupts one expectation per door and must see each. The twin of the same
  # block in test-suite.ps1.
  if [ "$runner_prove" -eq 1 ]; then
    "$PY" -I "$root/tests/number_text_sweep.py" "$bin/phosphor" --prove-failure </dev/null; rc=$?
  else
    "$PY" -I "$root/tests/number_text_sweep.py" "$bin/phosphor" </dev/null; rc=$?
  fi
  [ "$rc" -eq 0 ] || { echo "  (number_text_sweep.py exit $rc)"; allok=1; }
fi

echo
if [ "$allok" -eq 0 ]; then echo "SUITE OK"; else echo "SUITE FAILED"; fi
exit "$allok"
