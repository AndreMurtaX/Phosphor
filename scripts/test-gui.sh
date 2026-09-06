#!/usr/bin/env bash
# Builds the headless GUI suite runner (phosphorguitest) on Unix against the LCL
# gtk2 widgetset and runs it over the phase-2 GUI oracle files, byte-comparing
# each summary to its golden. The Unix counterpart of scripts/test-gui.ps1.
#
# gtk2 needs an X display. Over SSH there is none, so this reaches the logged-in
# session's live XWayland display (DISPLAY=:0 + the mutter auth cookie). If no
# usable display is found the GUI files are SKIPPED with a message rather than
# failing -- the engine/console suites (test-suite.sh) do not need one.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
FPC="${FPC:-$(command -v fpc || true)}"
[ -n "$FPC" ] || { echo "fpc not found on PATH (set FPC=/path/to/fpc)"; exit 1; }

cpu="$("$FPC" -iTP)"

# locate the LCL gtk2 units (Lazarus install dir varies by version/distro)
lcl=""
for d in /usr/share/lazarus/*/lcl/units/${cpu}-linux /usr/lib/lazarus/*/lcl/units/${cpu}-linux ~/lazarus/lcl/units/${cpu}-linux; do
  [ -d "$d/gtk2" ] && { lcl="$d"; break; }
done
[ -n "$lcl" ] || { echo "LCL gtk2 units not found (install lazarus/lcl-gtk2)"; exit 1; }
lazroot="${lcl%/lcl/units/*}"   # strip '/lcl/units/<cpu>-linux' -> .../lazarus/<ver>

# headless display: keep an existing one, else the live session's XWayland
if [ -z "${DISPLAY:-}" ]; then
  export DISPLAY=:0
  xa="$(ls /run/user/"$(id -u)"/.mutter-Xwaylandauth.* 2>/dev/null | head -1 || true)"
  [ -n "$xa" ] && export XAUTHORITY="$xa"
fi

# build the gtk2 GUI runner
bin="$root/bin"; units="$bin/gui-units/${cpu}-linux"; exe="$bin/phosphorguitest"
mkdir -p "$units"; rm -f "$exe"
"$FPC" -Mobjfpc -Scghi -O2 -vewn -Tlinux -dLCL -dLCLgtk2 \
  -Fu"$lcl/gtk2" -Fu"$lcl" \
  -Fu"$lazroot/components/lazutils/lib/${cpu}-linux" \
  -Fu"$lazroot/packager/units/${cpu}-linux" \
  -Fu"$root/engine" -Fu"$root/engine/libs" -Fu"$root/tests" -Fu"$root/host/gui/libs" \
  -FU"$units" -FE"$bin" -o"$exe" "$root/host/gui/phosphorguitest.lpr" >/dev/null
[ -x "$exe" ] || { echo "phosphorguitest did not build"; exit 1; }
echo "gui runner built: $exe (DISPLAY=${DISPLAY:-none})"; echo

gui="$root/tests/gui"
out="$(mktemp)"; err="$(mktemp)"; trap 'rm -f "$out" "$err"' EXIT

# probe the display once: if the widgetset cannot connect, skip cleanly.
if ! "$exe" "$gui/00_smoke.bas" > "$out" 2> "$err"; then
  if grep -qiE 'display|gtk|cannot open|X11|Gtk' "$err"; then
    echo "GUI SUITE SKIPPED: no usable display (need a logged-in desktop session; DISPLAY=${DISPLAY:-none})"
    exit 0
  fi
fi

manifest="$(grep -vE '^[[:space:]]*#' "$gui/manifest.txt" | tr '\n' ' ')"
allok=0
for name in $manifest; do
  "$exe" "$gui/$name.bas" > "$out" 2> "$err"; code=$?
  if [ "$code" -eq 0 ] && cmp -s "$out" "$gui/$name.expected"; then
    echo "PASS  $name  ($(wc -c <"$out") B, exit 0)"
  else
    echo "FAIL  $name  (exit $code)"; echo "  expected: $(cat "$gui/$name.expected")"; echo "  actual:   $(cat "$out")"; [ -s "$err" ] && sed 's/^/    /' "$err"; allok=1
  fi
done


# --- the --gui handoff --------------------------------------------------------
# `phosphor --gui <file>` is what a person types to run a GUI program, and until
# now nothing ran it. It makes four decisions -- is there a graphical session, is
# phosphorgui beside me, spawn it, hand back its exit code. The fixtures under
# tests/gui/handoff/ open no window: the handoff is the subject.
echo
console="$bin/phosphor"
guiexe="$bin/phosphorgui"
hodir="$gui/handoff"
bash "$here/build.sh" >/dev/null 2>&1 || { echo "FAIL  handoff: phosphor did not build"; allok=1; }

handoff_case() {   # name, want_exit, want_text, args...
  local name="$1" wantexit="$2" wanttext="$3"; shift 3
  local o="$out"
  "$console" "$@" > "$o" 2>&1; local code=$?
  local ok=0
  [ "$code" -eq "$wantexit" ] || ok=1
  if [ -n "$wanttext" ] && ! grep -qF -- "$wanttext" "$o"; then ok=1; fi
  if [ "$ok" -eq 0 ]; then
    echo "PASS  handoff: $name  (exit $code)"
  else
    echo "FAIL  handoff: $name"
    echo "        wanted exit $wantexit, got $code"
    [ -n "$wanttext" ] && echo "        wanted text containing '$wanttext'"
    sed 's/^/        /' "$o"
    allok=1
  fi
}

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  # THE CASE ONLY LINUX HAS. No session: the console host must refuse before it
  # spawns anything, name the problem and exit 3 -- distinct from 1 (program
  # error) and 2 (usage), so a script can tell them apart.
  handoff_case "refuses without a graphical session (exit 3)" 3 "needs a graphical session" --gui "$hodir/hello.bas"
  handoff_case "and points at the console host instead" 3 "phosphor run" --gui "$hodir/hello.bas"
else
  bash "$here/build-gui.sh" >/dev/null 2>&1 || { echo "FAIL  handoff: phosphorgui did not build"; allok=1; }
  if [ -x "$guiexe" ]; then
    handoff_case "runs the program through phosphorgui" 0 "handoff ok" --gui "$hodir/hello.bas"
    handoff_case "gives back the failing exit code" 1 "about to fail" --gui "$hodir/fails.bas"
    handoff_case "refuses --gui with no file" 2 "needs a file to run" --gui
    mv "$guiexe" "$guiexe.hidden"
    handoff_case "says what is missing when phosphorgui is not there" 2 "needs phosphorgui beside this binary" --gui "$hodir/hello.bas"
    mv "$guiexe.hidden" "$guiexe"
  else
    echo "FAIL  handoff: phosphorgui is not present, so the handoff was not tested"
    allok=1
  fi
fi

echo
if [ "$allok" -eq 0 ]; then echo "GUI SUITE OK"; else echo "GUI SUITE FAILED"; fi
exit "$allok"
