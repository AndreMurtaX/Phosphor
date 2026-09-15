# The engine boundary check. SOURCED, never executed.
#
#   . "$here/lib/boundary.sh"
#   boundary_check "$root/engine"     # prints and returns 1 on a violation
#
# THE RULE: engine/ is host-agnostic and must not name a host, GUI, console or OS
# unit in a uses clause. A name appearing in PROSE is documentation, not a
# dependency -- an engine comment that says "this must never reach Forms" is
# correct and must not trip the check -- so comments are stripped first, and
# stripping them correctly is the whole difficulty.
#
# WHY THIS FILE EXISTS. There were FOUR copies of this check: build.sh,
# test-suite.sh, build.ps1, test-suite.ps1. They did not agree, and on 2026-09-15
# all four were scored against eleven cases whose expected answers are derived
# from Pascal rather than from any implementation (tests/boundary/):
#
#     bash copies         8/11
#     PowerShell copies  10/11
#
# Two separate defects, and the second is on BOTH platforms.
#
# d64 -- the bash copies never stripped (* *) at all, so a forbidden unit named
#   inside a paren comment failed the build on Linux and passed on Windows. Worse,
#   build.sh's own comment claimed it stripped them. CLAUDE.md tells authors to
#   reach for (* *) whenever a brace comment would nest, so the tree actively
#   produces the shape that splits the two operating systems.
#
# n13 -- all four stripped // to end-of-line BEFORE the block forms. A brace
#   comment whose closing } shares a line with a // therefore lost its terminator,
#   and the brace stripper then ran from { to the next } ANYWHERE LATER, swallowing
#   whatever lay between -- including a real uses clause. That direction HIDES a
#   violation, which is the one a boundary check must never do.
#
# AND REORDERING IS NOT THE FIX -- that was measured too. Stripping braces first
# breaks the mirror case: a { inside a // line comment then opens a block that runs
# to the next } or to end of file. Both orders are wrong because a sequence of
# passes cannot express "whichever form OPENS FIRST wins", which is what Pascal
# says. One alternation can, because a regex engine scans left to right and the
# earliest match wins -- so a // inside a brace comment is comment text, and a {
# inside a // line is comment text, with no ordering decision to get wrong.
#
# The same alternation scores 11/11 under perl and under .NET, which is what lets
# the two halves of this pair stay in step. scripts/check-boundary.py runs both
# over the same fixtures and fails if either slips or if they disagree.

BOUNDARY_FORBIDDEN="crt video keyboard lcl lclintf lcltype forms controls dialogs graphics interfaces windows unix baseunix"

# One pass, three comment forms, earliest-opening wins. The two tails matter:
# `\}?` lets an unterminated brace comment run to end of file instead of falling
# through as code, and `(?:\*\)|\z)` does the same for an unterminated paren one.
BOUNDARY_STRIP='s@//[^\n]*|\{[^}]*\}?|\(\*.*?(?:\*\)|\z)@ @gs'

boundary_flatten() {   # $1 = file -> the source with comments removed, lowercased
  perl -0777 -pe "$BOUNDARY_STRIP" "$1" | tr '\n' ' ' | tr 'A-Z' 'a-z'
}

boundary_check() {     # $1 = directory to scan; returns 1 if anything was reported
  local dir="$1"
  local bad=0 f flat u
  for f in $(find "$dir" -name '*.pas'); do
    flat="$(boundary_flatten "$f")"
    for u in $BOUNDARY_FORBIDDEN; do
      # A HERESTRING, NOT A PIPE. `printf | grep -q` is the shape CLAUDE.md warns
      # about: grep -q exits at the first match and SIGPIPEs upstream, so under
      # `set -o pipefail` the pipeline can read non-zero even when it matched.
      # Measured here at 100/100 on a real 80KB engine unit, because printf is a
      # bash builtin -- but the herestring costs nothing and removes the question.
      if grep -qE "uses[^;]*[ ,]$u[ ,;]" <<< "$flat"; then
        echo "BOUNDARY VIOLATION: $(basename "$f") uses '$u'"
        bad=1
      fi
    done
  done
  return "$bad"
}
