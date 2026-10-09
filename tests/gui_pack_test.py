#!/usr/bin/env python3
"""A PACKED GUI APPLICATION, END TO END: compile, pack, run, and look at the
window from OUTSIDE the process.

Every GUI test before this one ran inside phosphorguitest, a test host that is
not what ships, and examples/gui_demo.bas -- the one real GUI program -- is only
compiled, because it waits for a person. Nothing had started the artifact a user
actually receives, `phosphor pack`'s output, with a window in it. So this does:

  1. compiles a program that opens a form with a known caption and runs a timer
     inside app_run(), and packs it;
  2. starts the PACKED executable and finds its top-level window by caption AND
     by process id, visible -- the fact a user sees, asked of the windowing
     system and not of the program;
  3. tells it to finish through a sentinel file (never a process listing), or
     closes its window the way a person does (WM_CLOSE, Windows);
  4. checks the exit code, its stdout, and a result file the handler wrote.

THE PROGRAM CANNOT HANG, and that is a design rule here, not luck (CLAUDE.md: a
program that calls app_run() never returns by itself): its timer gives up after
about 400 ticks on its own, and this harness kills it after a timeout.

CASES. Windows: piped; `--no-console` started with a console of its own (and the
console must be RELEASED -- asked by trying to attach to it); with a console of
its own; a handler that faults (documented in docs/libraries/gui-timer.md: the
tick returns and gui_error() answers 2; the program carries on); and closing the
window, with and without `--no-console`. Linux, under a display (the runner uses
xvfb-run): piped, `--no-console` (a no-op there, accepted), and the fault; the
window is found with xwininfo and its owner with xprop's _NET_WM_PID. Closing a
window from outside needs a tool the Linux machine does not have, so that case
is Windows-only and is said so in the output.

Measured first on 2026-10-05 as a probe: all six Windows cases green on the
first build that was run. WATCHED FAILING: with the packed-mark's NOCONSOLE flag
ignored by the stub, both `--no-console` cases fail on "console released".

THE FAULT CASE ALSO READS STDERR, since the same day: the handler faults on five
ticks in a row and the host must say so ONCE, with the line, the message and the
handler's name. Watched failing against the build before the report existed
(stderr empty) and with the host's de-duplication removed (five lines).

Usage: gui_pack_test.py <phosphor executable>
Exit 0 pass, 1 fail, 2 could not set up (no display, say).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

EXE = os.path.abspath(sys.argv[1])
W = tempfile.mkdtemp(prefix='phosphor-guipack-')
WIN = os.name == 'nt'
fw = lambda p: p.replace(chr(92), '/')
results = []


def check(name, cond, detail=''):
    results.append((name, bool(cond), detail))
    print('  %-66s %s%s' % (name, 'PASS' if cond else 'FAIL',
                            '' if cond else '  ' + str(detail)[:160]))
    # RETURNED, because callers branch on it. The first draft returned nothing,
    # so `if not check(...)` was always true, every case stopped after "compiles
    # and packs", and the whole file reported PASS 6 FAIL 0 having started
    # nothing. A count that small should have been the tell; it was.
    return bool(cond)


# --- seeing a window from outside -------------------------------------------
if WIN:
    import ctypes
    import ctypes.wintypes as wt
    user32 = ctypes.WinDLL('user32', use_last_error=True)
    EnumProc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def visible_windows(pid, title):
        found = []

        def cb(hwnd, _):
            p = wt.DWORD(0)
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
            if p.value == pid and user32.IsWindowVisible(hwnd):
                n = user32.GetWindowTextLengthW(hwnd)
                buf = ctypes.create_unicode_buffer(n + 1)
                user32.GetWindowTextW(hwnd, buf, n + 1)
                if buf.value == title:
                    found.append(hwnd)
            return True
        user32.EnumWindows(EnumProc(cb), 0)
        return found

    def close_window(h):
        user32.PostMessageW(h, 0x0010, 0, 0)          # WM_CLOSE

    def has_console(pid):
        # From a HELPER process: FreeConsole in this one would kill this one's
        # standard handles and every later Popen with them.
        code = ('import ctypes,sys;k=ctypes.WinDLL("kernel32");k.FreeConsole();'
                'sys.exit(0 if k.AttachConsole(%d) else 10)' % pid)
        r = subprocess.run([sys.executable, '-c', code], capture_output=True,
                           timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
        return r.returncode == 0
else:
    def visible_windows(pid, title):
        try:
            tree = subprocess.run(['xwininfo', '-root', '-tree'], capture_output=True,
                                  text=True, timeout=10).stdout
        except Exception:
            return []
        found = []
        for line in tree.splitlines():
            # NOT GREEDY: a tree line is `0x200029 "TITLE": ("res" "Class") ...`,
            # and `"(.*)"` ran to the LAST quote -- every title compared unequal,
            # and the first Linux run reported three windows missing that were
            # on screen, viewable, owned by the right pid.
            m = re.match(r'\s*(0x[0-9a-f]+) "([^"]*)"', line)
            if not m or m.group(2) != title:
                continue
            wid = m.group(1)
            pr = subprocess.run(['xprop', '-id', wid, '_NET_WM_PID'], capture_output=True,
                                text=True, timeout=10).stdout
            info = subprocess.run(['xwininfo', '-id', wid], capture_output=True,
                                  text=True, timeout=10).stdout
            if pr.strip().endswith(' %d' % pid) and 'IsViewable' in info:
                found.append(wid)
        return found


# --- the program --------------------------------------------------------------
def program(name, title, mode):
    go = fw(os.path.join(W, name + '.go'))
    res = fw(os.path.join(W, name + '.result'))
    if mode == 'fault':
        # FIVE ticks in a row fault on the same line, then the sixth reports and
        # quits. The counter goes up BEFORE the fault: a faulting handler does not
        # reach its own later lines.
        act = ('    faulted = faulted + 1\n'
               '    if faulted <= 5 then\n'
               '      x = 0\n'
               '      y = 1 / x\n'
               '    end if\n'
               '    timer_stop@(sender@)\n'
               '    n = file_writealltext("%s", "gui_error=" + str$(gui_error()))\n'
               '    app_quit()\n') % res
    else:
        act = ('    timer_stop@(sender@)\n'
               '    n = file_writealltext("%s", "visible=" + str$(form_visible(f@)) + '
               '" caption=" + form_caption$(f@))\n'
               '    println "PRINTED-FROM-HANDLER"\n'
               '    app_quit()\n') % res
    body = ('rem packed GUI end-to-end: %s\n'
            'ticks = 0\n'
            'faulted = 0\n'
            'function on_tick(sender@)\n'
            '  ticks = ticks + 1\n'
            '  if file_exists("%s") <> 0 then\n'
            '%s'
            '  elseif ticks > 400 then\n'
            '    rem the program gives up by itself: it must never wait for ever\n'
            '    timer_stop@(sender@)\n'
            '    app_quit()\n'
            '  end if\n'
            '  return 0\n'
            'endfunction\n'
            'f@ = form@()\n'
            'form_caption@(f@, "%s")\n'
            'form_show@(f@)\n'
            't@ = timer@()\n'
            'timer_interval@(t@, 50)\n'
            'timer_ontimer@(t@, "on_tick")\n'
            'timer_start@(t@)\n'
            'println "BEFORE-APP-RUN"\n'
            'app_run()\n'
            'println "AFTER-APP-RUN"\n'
            'end\n') % (name, go, act, title)
    bas = os.path.join(W, name + '.bas')
    with open(bas, 'w', newline='\n') as f:
        f.write(body)
    return bas, go.replace('/', os.sep), res.replace('/', os.sep)


def build(bas, flags):
    pbc = bas[:-4] + '.pbc'
    app = bas[:-4] + ('.exe' if WIN else '.app')
    for argv in ([EXE, 'compile', bas, pbc], [EXE, 'pack'] + flags + [pbc, app]):
        r = subprocess.run(argv, capture_output=True, timeout=60)
        if r.returncode != 0:
            return None, '%s exit %d: %r' % (argv[1], r.returncode, r.stderr[:200])
    return app, ''


def case(name, flags, own_console=False, mode='quit'):
    print('%s  (%s%s)' % (name, ' '.join(flags) or 'no flags',
                          ', own console' if own_console else ''))
    title = 'PHOSPHOR-E2E-' + name.upper()
    bas, go, res = program(name, title, mode)
    app, why = build(bas, flags)
    if not check('compiles and packs', app is not None, why):
        return
    out, err = os.path.join(W, name + '.out'), os.path.join(W, name + '.err')
    if own_console:
        p = subprocess.Popen([app], creationflags=subprocess.CREATE_NEW_CONSOLE)
    else:
        p = subprocess.Popen([app], stdout=open(out, 'wb'), stderr=open(err, 'wb'),
                             stdin=subprocess.DEVNULL)
    mine = []
    t0 = time.time()
    while time.time() - t0 < 20 and p.poll() is None:
        mine = visible_windows(p.pid, title)
        if mine:
            break
        time.sleep(0.1)
    check('its window is on screen: visible, captioned, owned by this process',
          mine, 'exit=%r before any window' % p.poll())
    if own_console and 'no-console' in ' '.join(flags):
        check('and the console it was started with is released', not has_console(p.pid))
    elif own_console:
        check('and the console it was started with is kept', has_console(p.pid))
    if mode == 'close':
        for h in mine:
            close_window(h)
    else:
        open(go, 'w').close()
    try:
        code = p.wait(timeout=30)
    except subprocess.TimeoutExpired:
        p.kill()
        code = 'TIMEOUT'
    result = open(res).read() if os.path.exists(res) else None
    stdout = open(out, 'rb').read().replace(b'\r\n', b'\n') if os.path.exists(out) else b''
    stderr = open(err, 'rb').read() if os.path.exists(err) else b''
    check('it leaves app_run and exits 0', code == 0, 'exit %r stderr %r' % (code, stderr[:120]))
    if mode == 'quit':
        check('the handler saw its own form', result == 'visible=1 caption=' + title, result)
    if mode == 'fault':
        check('a faulting handler is recorded, and the program carries on',
              result == 'gui_error=2', result)
        # AND IT IS SAID, once. A packed application has no path to name, so the
        # line has the no-path shape. The line number is derived from the program
        # text written above, not from a run.
        src = open(bas).read().split('\n')
        fault_line = next(i for i, l in enumerate(src, 1) if l.strip() == 'y = 1 / x')
        want_err = ('phosphor: %d: division by zero -- in the event handler on_tick; '
                    'the program carries on' % fault_line).encode()
        lines = [l for l in stderr.replace(b'\r\n', b'\n').split(b'\n') if l]
        check('the fault is reported on stderr: line, message and handler',
              want_err in lines, stderr[:200])
        check('and reported ONCE, though it happened five times',
              lines.count(want_err) == 1 and len(lines) == 1, lines)
    if not own_console:
        want = {'quit': b'BEFORE-APP-RUN\nPRINTED-FROM-HANDLER\nAFTER-APP-RUN\n',
                'fault': b'BEFORE-APP-RUN\nAFTER-APP-RUN\n',
                'close': b'BEFORE-APP-RUN\nAFTER-APP-RUN\n'}[mode]
        check('its output arrives, in order, around the loop', stdout == want, stdout)


if not WIN and not os.environ.get('DISPLAY'):
    print('SETUP no display: run this under xvfb-run, as scripts/test.sh does')
    sys.exit(2)
# The window is seen through xwininfo and xprop (x11-utils). Without them
# visible_windows() answers "no window", and the first run on a machine that
# lacked them (WSL, 2026-10-09) reported six product failures -- windows that
# never opened -- for what was a missing tool. Say which, and stop.
if not WIN:
    missing = [t for t in ('xwininfo', 'xprop') if shutil.which(t) is None]
    if missing:
        print('SETUP %s not found: install x11-utils' % ' and '.join(missing))
        sys.exit(2)

case('piped', [])
case('fault', [], mode='fault')
if WIN:
    case('noconsole', ['--no-console'], own_console=True)
    case('withconsole', [], own_console=True)
    case('close', [], mode='close')
    case('closenocon', ['--no-console'], own_console=True, mode='close')
else:
    case('noconsole', ['--no-console'])
    print('  (closing the window from outside is Windows-only: no tool here sends WM_DELETE)')

bad = [r for r in results if not r[1]]
print('PASS %d   FAIL %d' % (len(results) - len(bad), len(bad)))
sys.exit(1 if bad else 0)
