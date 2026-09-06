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
forbidden="crt video keyboard lcl lclintf lcltype forms controls dialogs graphics interfaces windows unix baseunix"
violation=0
for f in $(find "$root/engine" -name '*.pas'); do
  # Strip Pascal comments (line //, brace { }, paren (* *)) BEFORE flattening, so a
  # unit name named in prose (an engine comment naming the LCL host it must NOT
  # reach) is documentation, not a dependency, and cannot trip the check.
  flat="$(sed -E 's://.*$::' "$f" | tr '\n' ' ' | sed -E 's/\{[^}]*\}/ /g' | tr 'A-Z' 'a-z')"
  for u in $forbidden; do
    if printf '%s' "$flat" | grep -qE "uses[^;]*[ ,]$u[ ,;]"; then
      echo "BOUNDARY VIOLATION: $(basename "$f") uses '$u'"
      violation=1
    fi
  done
done
[ "$violation" -eq 0 ] || { echo "engine must stay host-agnostic (see docs/architecture.md)"; exit 1; }
echo "boundary check: engine stays host-agnostic"

# --- compile -----------------------------------------------------------------
bin="$root/bin"
cpu="$("$FPC" -iTP)"           # e.g. x86_64
units="$bin/units/${cpu}-linux"
exe="$bin/phosphor"
mkdir -p "$units"
rm -f "$exe"

echo "compiler: $FPC"
buildlog="$(mktemp)"
# The LCL comes in because phosphor IS the GUI host now -- one binary that brings
# the widgetset up when a session is reachable and stays a console interpreter
# when there is not. NOTE the units it will name in its own uses clause: Gtk2Int
# and InterfaceBase, never `Interfaces` -- that unit's initialization calls
# CreateWidgetset, which opens the X display before main and is exactly what made
# an LCL-linked binary unusable headless. The engine still sees none of it; the
# boundary check above fails the build if a unit under engine/ reaches the LCL.
cpu="$("$FPC" -iTP)"
lcl=""
for d in /usr/share/lazarus/*/lcl/units/${cpu}-linux /usr/lib/lazarus/*/lcl/units/${cpu}-linux ~/lazarus/lcl/units/${cpu}-linux; do
  [ -d "$d/gtk2" ] && { lcl="$d"; break; }
done
[ -n "$lcl" ] || { echo "LCL gtk2 units not found (install lazarus/lcl-gtk2)"; exit 1; }
lazroot="${lcl%/lcl/units/*}"

"$FPC" -Mobjfpc -Scghi -O2 -vewn -Tlinux -dLCL -dLCLgtk2 \
  -Fu"$lcl/gtk2" -Fu"$lcl" \
  -Fu"$lazroot/components/lazutils/lib/${cpu}-linux" \
  -Fu"$lazroot/packager/units/${cpu}-linux" \
  -Fu"$root/engine" -Fu"$root/engine/libs" \
  -Fu"$root/host/gui/libs" -Fu"$root/host/packages" \
  -FU"$units" -FE"$bin" -o"$exe" \
  "$root/host/console/phosphor.lpr" >"$buildlog" 2>&1
cat "$buildlog"

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
