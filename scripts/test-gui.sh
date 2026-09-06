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


# --- host mode: one binary that decides ---------------------------------------
# phosphor links the LCL and calls CreateWidgetset itself, only when a graphical
# session is reachable. Unix is the platform that can produce BOTH answers, so
# both are checked here -- and the no-session one is produced deliberately, by
# taking the session away for one command, rather than by hoping the machine
# running the suite happens not to have one. (This script exports DISPLAY=:0 near
# the top so the GUI files can reach the live session, which means asking "is
# DISPLAY empty?" here would always answer no.)
echo
console="$bin/phosphor"
hm="$gui/hostmode"
bash "$here/build.sh" > "$out" 2>&1 || { echo "FAIL  hostmode: phosphor did not build"; sed 's/^/        /' "$out" | tail -12; allok=1; }

host_case() {   # name, want_exit, want_text, args...
  local name="$1" wantexit="$2" wanttext="$3"; shift 3
  local o="$out"
  "$console" "$@" > "$o" 2>&1; local code=$?
  local ok=0
  [ "$code" -eq "$wantexit" ] || ok=1
  if [ -n "$wanttext" ] && ! grep -qF -- "$wanttext" "$o"; then ok=1; fi
  if [ "$ok" -eq 0 ]; then
    echo "PASS  hostmode: $name  (exit $code)"
  else
    echo "FAIL  hostmode: $name"
    echo "        wanted exit $wantexit, got $code"
    [ -n "$wanttext" ] && echo "        wanted text containing '$wanttext'"
    sed 's/^/        /' "$o"
    allok=1
  fi
}

host_case_nosession() {   # the same, with the session taken away
  local name="$1" wantexit="$2" wanttext="$3"; shift 3
  local o="$out"
  env -u DISPLAY -u WAYLAND_DISPLAY "$console" "$@" > "$o" 2>&1; local code=$?
  local ok=0
  [ "$code" -eq "$wantexit" ] || ok=1
  if [ -n "$wanttext" ] && ! grep -qF -- "$wanttext" "$o"; then ok=1; fi
  if [ "$ok" -eq 0 ]; then
    echo "PASS  hostmode: $name  (exit $code)"
  else
    echo "FAIL  hostmode: $name"
    echo "        wanted exit $wantexit, got $code"
    [ -n "$wanttext" ] && echo "        wanted text containing '$wanttext'"
    sed 's/^/        /' "$o"
    allok=1
  fi
}

if [ -x "$console" ]; then
  # --- with a session ---------------------------------------------------------
  host_case "a GUI program runs with no flag" 0 "gui ok: registrado" run "$hm/gui.bas"
  host_case "and a console program still does" 0 "console ok" run "$hm/hello.bas"
  host_case "a failing program fails the run" 1 "about to fail" run "$hm/fails.bas"
  host_case "--gui is accepted and answered" 0 "no longer needed" --gui run "$hm/gui.bas"
  # --no-console is a no-op on a shared console, and on Unix altogether: the
  # terminal is the user's. The run still prints and still succeeds.
  host_case "--no-console leaves a terminal console alone" 0 "console ok" --no-console run "$hm/hello.bas"
  cage="$(mktemp -d)"
  host_case "the sandbox root reaches a GUI program" 0 "gui ok" --sandbox "$cage" run "$hm/gui.bas"
  rm -rf "$cage"

  # --- WITHOUT a session: the half that only exists here ----------------------
  # The binary links the LCL either way. With nothing to connect to it must not
  # try -- it must stay a console interpreter, which is the entire reason the
  # widgetset is created by us instead of by a unit initialization.
  host_case_nosession "with no session it is still a console interpreter" 0 "console ok" run "$hm/hello.bas"
  # And the GUI functions are simply NOT REGISTERED, which the program is told.
  host_case_nosession "and the GUI functions are not registered" 1 "no function form@" run "$hm/gui.bas"
else
  echo "FAIL  hostmode: no phosphor binary, so host mode was not tested"
  allok=1
fi

echo
if [ "$allok" -eq 0 ]; then echo "GUI SUITE OK"; else echo "GUI SUITE FAILED"; fi
exit "$allok"
