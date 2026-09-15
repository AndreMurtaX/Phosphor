# Shared argument handling for every test runner. SOURCED, never executed.
#
#   . "$here/lib/runner.sh"
#   runner_args "test-suite.sh" prove "$@"      # this runner has a prove mode
#   runner_args "test-gui.sh"   noprove "$@"    # this one does not
#
# and afterwards `$runner_prove` is 1 or 0.
#
# WHY THIS FILE EXISTS. On 2026-09-15 a survey measured that `-ProveFailure` --
# the project's own canonical spelling, and one of the five conditions CLAUDE.md
# lists for calling anything done -- was a SILENT FULL RUN on five of the six
# bash runners:
#
#   test-examples.sh   read only `--prove-failure`
#   test-classic.sh    read only `--prove` / `-ProveFailure`, so it ignored its
#                      own neighbour's spelling
#   test.sh            never read $1, though test.ps1 has a prove mode
#   test-packages.sh   never read $1
#   test-gui.sh        never read $1
#
# Each of them printed OK and exited 0, which reads exactly like a proof that
# happened. test-suite.sh was the one that refused, and its comment says why --
# "it already cost a false report once".
#
# THE RULE WAS WRITTEN DOWN IN ONE FILE AND NOWHERE ELSE, which is this project's
# oldest shape: a promise in prose that nothing could fail. So it lives here now,
# once, and scripts/check-crossrefs.py asks every runner to demonstrate it.
#
# AND IT IS PARSED FIRST, BEFORE ANY LOOKUP THAT CAN FAIL ON THE MACHINE. That is
# not tidiness. Measured the same day: test-suite.sh's refusal sits after the
# staleness probe and the fpc lookup, so on a host with no fpc on PATH it answered
# `fpc not found` and exit 1 to a bogus flag -- refusing late is not refusing. And
# test-classic.sh answered exit 2 to a flag it had never looked at, because its
# line 18 exits 2 when build.sh fails. An exit code answers the question the tool
# asked, not the one you meant, so the refusal NAMES THE ARGUMENT and the gate
# requires the name as well as the code.

runner_prove=0

# ---------------------------------------------------------------------------
# strict_build -- a -vewn build must be CLEAN, and the log is the only witness.
#
#   strict_build "phosphortest" "$FPC" -Mobjfpc ... file.lpr
#
# WHY IT IS HERE AND NOT COPIED A THIRD TIME. Eight fpc invocations in
# test-suite.{ps1,sh} and test-gui.{ps1,sh} discarded their log and judged the
# build by whether the file appeared. That is not a weaker check, it is a
# DIFFERENT one: fpc EXITS 0 ON A WARNING and still writes the binary, so neither
# the exit code nor the file can see one. Measured 2026-09-15 --
#
#   probe_budget.lpr(588,5) Warning: Comment level 2 found
#   fpc exit=0   binary produced: True
#
# -- a live warning the suite had been printing PASS over, in a tree whose stated
# bar is zero warnings and zero notes. The class was fixed once, in build.* and
# test-packages.*, and the copies that needed it most never got it. Now there is
# one copy.
#
# The exclusion is deliberately narrow. `Compiling` and `Linking` are fpc's own
# progress lines and nothing else is filtered: widening this past those two is how
# a real note gets hidden inside a noisy build, which is the exact shape being
# repaired here.
strict_build() {   # $1 = label; $2.. = the fpc command
  local label="$1"; shift
  local log; log="$(mktemp)"
  "$@" >"$log" 2>&1
  local code=$?
  local issues; issues="$(grep -iE 'warning|note:|error|fatal' "$log" | grep -viE 'Compiling|Linking')"
  rm -f "$log"
  if [ -n "$issues" ]; then
    echo "$label build NOT clean:"
    echo "$issues"
    exit 1
  fi
  [ "$code" -eq 0 ] || { echo "$label build failed (fpc exit $code)"; exit 1; }
}

runner_args() {
  local who="$1"; shift
  local mode="$1"; shift

  while [ $# -gt 0 ]; do
    case "$1" in
      # Every spelling that exists anywhere in this tree, canonicalised here so
      # no runner has to know which one its neighbour chose.
      --prove|--prove-failure|-ProveFailure|-provefailure)
        if [ "$mode" != "prove" ]; then
          echo "$who: unknown argument '$1' -- this runner has no prove mode." >&2
          echo "$who: refusing rather than running the ordinary suite and" >&2
          echo "$who: printing OK, which would read as a proof that happened." >&2
          exit 2
        fi
        runner_prove=1
        ;;
      --help|-h)
        if [ "$mode" = "prove" ]; then
          echo "usage: $who [--prove|--prove-failure|-ProveFailure]"
        else
          echo "usage: $who   (no arguments; this runner has no prove mode)"
        fi
        exit 0
        ;;
      *)
        echo "$who: unknown argument '$1'" >&2
        if [ "$mode" = "prove" ]; then
          echo "$who: use --prove, --prove-failure or -ProveFailure, or nothing." >&2
        else
          echo "$who: this runner takes no arguments." >&2
        fi
        exit 2
        ;;
    esac
    shift
  done
}
