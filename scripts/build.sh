#!/usr/bin/env bash
# Builds the Phosphor console host on Linux (or any Unix) with FPC.
# The Unix counterpart of scripts/build.ps1: same boundary check, same
# trust-the-artifact discipline. The engine and host sources are portable; the
# console host guards the Windows console API with {$IFDEF WINDOWS} and falls
# back to raw UTF-8 bytes on Unix (where the terminal is UTF-8 natively).
#
# Usage:  bash scripts/build.sh          (set FPC=/path/to/fpc to override)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
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

# --- compile -----------------------------------------------------------------
bin="$root/bin"
cpu="$("$FPC" -iTP)"           # e.g. x86_64
units="$bin/units/${cpu}-linux"
exe="$bin/phosphor"

echo "compiler: $FPC"
# The LCL comes in because phosphor IS the GUI host now -- one binary that brings
# the widgetset up when a session is reachable and stays a console interpreter
# when there is not. NOTE the units it will name in its own uses clause: Gtk2Int
# and InterfaceBase, never `Interfaces` -- that unit's initialization calls
# CreateWidgetset, which opens the X display before main and is exactly what made
# an LCL-linked binary unusable headless. The engine still sees none of it; the
# boundary check above fails the build if a unit under engine/ reaches the LCL.
#
# ASKED BEFORE ANYTHING IS DESTROYED. This probe used to sit after the `rm -f`
# below, so a machine without Lazarus lost its working phosphor to build a
# replacement that was never going to be attempted -- silently, with an error
# about units and no hint that anything had been removed. Same ordering defect as
# the PowerShell twin, fixed in the same change.
#
# $LAZARUSDIR FIRST, because someone who built Lazarus with fpcupdeluxe or by hand
# has it nowhere on this list and knows where it is. The list after it covers the
# distribution packages and the two common manual locations, and the failure names
# every root it looked in rather than only the package to install: a search that
# reports what it searched is one the reader can correct.
lcl=""
roots=""
[ -n "${LAZARUSDIR:-}" ] && roots="$LAZARUSDIR/lcl/units/${cpu}-linux"
roots="$roots /usr/share/lazarus/*/lcl/units/${cpu}-linux"
roots="$roots /usr/lib/lazarus/*/lcl/units/${cpu}-linux"
roots="$roots /opt/lazarus/lcl/units/${cpu}-linux"
roots="$roots $HOME/lazarus/lcl/units/${cpu}-linux"
roots="$roots $HOME/fpcupdeluxe/lazarus/lcl/units/${cpu}-linux"
for d in $roots; do
  [ -d "$d/gtk2" ] && { lcl="$d"; break; }
done
if [ -z "$lcl" ]; then
  echo "LCL gtk2 units not found (install lazarus/lcl-gtk2, or set \$LAZARUSDIR)"
  echo "looked in:"
  for d in $roots; do echo "  $d"; done
  exit 1
fi
lazroot="${lcl%/lcl/units/*}"

mkdir -p "$units"
rm -f "$exe"
buildlog="$(mktemp)"

"$FPC" -Mobjfpc -Scghi -O2 -vewn -Tlinux -dLCL -dLCLgtk2 \
  -Fu"$lcl/gtk2" -Fu"$lcl" \
  -Fu"$lazroot/components/lazutils/lib/${cpu}-linux" \
  -Fu"$lazroot/packager/units/${cpu}-linux" \
  -Fu"$root/engine" -Fu"$root/engine/libs" \
  -Fu"$root/host/gui/libs" -Fu"$root/host/packages" \
  -FU"$units" -FE"$bin" -o"$exe" \
  "$root/host/console/phosphor.lpr" >"$buildlog" 2>&1 || fpcfailed=$?
# PRINTED BEFORE THE EXIT CODE IS ACTED ON, and that is the whole point of the
# `|| fpcfailed=$?` above. This `cat` used to be the statement after a bare fpc
# call, so under `set -e` a FAILED build aborted the script here -- two lines of
# output, exit 1, and the compiler's actual message left in a temporary file
# nobody was told the name of. On 2026-09-18 that turned a one-line Linux error
# ("Identifier not found IsATTY") into a silent failure that had to be traced
# with `bash -x` to recover. A build log is never more wanted than when the build
# failed.
cat "$buildlog"
if [ "${fpcfailed:-0}" -ne 0 ]; then
  echo "build FAILED (fpc exit $fpcfailed)"
  exit "$fpcfailed"
fi

# --- a -vewn build must be clean: FAIL on any warning/note (host packages too) ---
# The trailing '|| true' matters under 'set -euo pipefail': a CLEAN log has no
# matches, so the grep pipeline exits non-zero, and without the guard that
# non-zero would abort the script (via set -e) on the very success it is meant
# to confirm -- exit 1 on a clean build. With the guard, 'issues' captures the
# (possibly empty) matches and the '[ -z ]' below is what decides clean vs dirty.
issues="$(grep -iE 'warning|note:|error|fatal' "$buildlog" | grep -viE 'Compiling|Linking' || true)"
rm -f "$buildlog"
[ -z "$issues" ] || { echo "build NOT clean (warnings/notes above)"; exit 1; }

# --- trust the artifact, not the exit code -----------------------------------
[ -x "$exe" ] || { echo "no binary produced; build failed"; exit 1; }
ver="$("$exe" --version)"
case "$ver" in
  *"Phosphor BASIC"*) ;;
  *) echo "binary exists but does not run as expected: '$ver'"; exit 1 ;;
esac
echo "built:  $exe"
echo "verify: $ver"
