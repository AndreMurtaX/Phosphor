#!/usr/bin/env bash
# Builds phosphorgui -- the COMPLETE Phosphor runner: engine + every function
# package + the LCL GUI libraries. The Unix counterpart of build-gui.ps1.
#
# `phosphor` (build.sh) is the headless host and deliberately does NOT link the LCL:
# on Linux the gtk2 widgetset opens the X display in a unit INITIALIZATION section,
# so an LCL-linked binary exits 1 with "cannot open display" wherever none is
# reachable -- CI, containers, headless servers, a plain ssh session. (With a live
# display it runs fine; the console host simply must not DEPEND on one.)
#
# Building needs no display; only RUNNING the result does.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
FPC="${FPC:-$(command -v fpc || true)}"
[ -n "$FPC" ] || { echo "fpc not found on PATH (set FPC=/path/to/fpc)"; exit 1; }
cpu="$("$FPC" -iTP)"

lcl=""
for d in /usr/share/lazarus/*/lcl/units/${cpu}-linux /usr/lib/lazarus/*/lcl/units/${cpu}-linux ~/lazarus/lcl/units/${cpu}-linux; do
  [ -d "$d/gtk2" ] && { lcl="$d"; break; }
done
[ -n "$lcl" ] || { echo "LCL gtk2 units not found (install lazarus/lcl-gtk2)"; exit 1; }
lazroot="${lcl%/lcl/units/*}"

bin="$root/bin"; units="$bin/gui-units/${cpu}-linux"; exe="$bin/phosphorgui"
mkdir -p "$units"; rm -f "$exe"
log="$("$FPC" -Mobjfpc -Scghi -O2 -vewn -Tlinux -dLCL -dLCLgtk2 \
  -Fu"$lcl/gtk2" -Fu"$lcl" \
  -Fu"$lazroot/components/lazutils/lib/${cpu}-linux" \
  -Fu"$lazroot/packager/units/${cpu}-linux" \
  -Fu"$root/engine" -Fu"$root/engine/libs" \
  -Fu"$root/host/gui/libs" -Fu"$root/host/packages" \
  -FU"$units" -FE"$bin" -o"$exe" "$root/host/gui/phosphorgui.lpr" 2>&1)"
echo "$log" | grep -viE 'compiling|linking' | grep -iE 'warning|note:|error|fatal' && {
  echo "build NOT clean -- warnings/notes above"; exit 1; }
[ -x "$exe" ] || { echo "no binary produced"; exit 1; }
echo "built:  $exe"
