#!/usr/bin/env python3
"""After crt_hideconsole() and crt_showconsole(), does the NEW console get the
program's output and the host's diagnostics? Windows only.

Until 2026-10-05 it got neither, and nothing said so:

  * the host's diagnostics are `Writeln(StdErr, ...)`, and on win64 StdErr is a
    Text record of its own, not an alias of ErrOutput (rtl/inc/systemh.inc: the
    alias exists only under FPC_STDOUT_TRUE_ALIAS). PhosphorCrtLib re-pointed
    ErrOutput and Output and left StdErr on the console it had let go of;
  * TConsoleHost took its stdout handle, and whether it was a console, once, at
    creation -- so `println` kept writing to the old console too.

Both writes SUCCEED into the released console, which is why the recorded theory
of this defect -- that a faulting `--no-console` program raises and exits 3 --
was wrong: measured, it exits 1. The real loss is silent and only visible in the
console a person is looking at, so that is what this reads.

HOW: the program hides its console, shows a new one, prints a line, writes a
ready file and waits for a go file (sentinels, never a process listing). This
script ATTACHES to the new console -- so the console outlives the program --
writes a line of its own as a control on the reader, lets the program fault,
and reads the screen buffer. Three things must be there: the control, the
program's `println`, and the host's diagnostic for the fault.

WATCHED FAILING, one half at a time: without StdErr re-pointed in
crt_showconsole only the diagnostic is missing; without TConsoleHost following
the Output record only the `println` is.

AND THE KEYBOARD, added the same day with the same two causes: Input was left
on the released console and ReadLine kept the stdin handle from creation, so a
`line input` after crt_showconsole read an EMPTY line while the new console had
a whole one waiting -- measured as `PROGRAM-READ[]`. The harness types a line
into the new console's input buffer (WriteConsoleInputW) before letting the
program ask. Watched failing with either half of that repair removed.

Usage: console_reshow_test.py <phosphor.exe>
Exit 0 pass, 1 fail, 2 the harness could not set the case up.
"""
import ctypes
import ctypes.wintypes as wt
import os
import subprocess
import sys
import tempfile
import time

if os.name != 'nt':
    print('SKIP  Windows only: there is no console to let go of on this platform')
    sys.exit(0)

EXE = os.path.abspath(sys.argv[1])
W = tempfile.mkdtemp(prefix='phosphor-reshow-')
ready = os.path.join(W, 'ready.txt').replace(chr(92), '/')
go = os.path.join(W, 'go.txt').replace(chr(92), '/')
bas = os.path.join(W, 'reshow.bas')
with open(bas, 'w', newline='\n') as f:
    f.write('rem hide, show a new console, print, wait, then fault\n'
            'h = crt_hideconsole()\n'
            's = crt_showconsole()\n'
            'println "PROGRAM-PRINTED"\n'
            'n = file_writealltext("%s", str$(h) + str$(s))\n'
            'while file_exists("%s") = 0\n'
            'wend\n'
            'line input "Q: "; got$\n'
            'println "PROGRAM-READ[" + got$ + "]"\n'
            'x = 0\n'
            'y = 1 / x\n'
            'end\n' % (ready, go))
TYPED = 'typed-by-harness'

k = ctypes.WinDLL('kernel32', use_last_error=True)
k.CreateFileW.restype = wt.HANDLE


class COORD(ctypes.Structure):
    _fields_ = [('X', wt.SHORT), ('Y', wt.SHORT)]


class CSBI(ctypes.Structure):
    _fields_ = [('dwSize', COORD), ('dwCursorPosition', COORD), ('wAttributes', wt.WORD),
                ('srWindow', wt.SHORT * 4), ('dwMaximumWindowSize', COORD)]


class KEY_EVENT_RECORD(ctypes.Structure):
    _fields_ = [('bKeyDown', wt.BOOL), ('wRepeatCount', wt.WORD),
                ('wVirtualKeyCode', wt.WORD), ('wVirtualScanCode', wt.WORD),
                ('UnicodeChar', wt.WCHAR), ('dwControlKeyState', wt.DWORD)]


class INPUT_RECORD(ctypes.Structure):
    _fields_ = [('EventType', wt.WORD), ('Key', KEY_EVENT_RECORD)]


p = subprocess.Popen([EXE, bas], creationflags=subprocess.CREATE_NEW_CONSOLE)
t0 = time.time()
while not os.path.exists(ready):
    if p.poll() is not None or time.time() - t0 > 30:
        if p.poll() is None:
            p.kill()
        print('SETUP the program never reached the wait (exit %r)' % p.poll())
        sys.exit(2)
    time.sleep(0.05)
time.sleep(0.2)
answered = open(ready).read()
if answered != '11':
    open(go, 'w').close()
    p.wait(timeout=30)
    print('SETUP crt_hideconsole/crt_showconsole answered %r, not 11: this run '
          'had no console of its own to let go of' % answered)
    sys.exit(2)

k.FreeConsole()
if not k.AttachConsole(p.pid):
    err = ctypes.get_last_error()
    open(go, 'w').close()
    p.wait(timeout=30)
    print('SETUP AttachConsole failed: %d' % err)
    sys.exit(2)
h = k.CreateFileW('CONOUT$', 0x80000000 | 0x40000000, 3, None, 3, 0, None)
mark = 'HARNESS-WROTE\r\n'
k.WriteConsoleW(wt.HANDLE(h), mark, len(mark), ctypes.byref(wt.DWORD(0)), None)

# TYPED INTO THE NEW CONSOLE'S INPUT BUFFER before the program asks, so the
# `line input` finds a whole line waiting. Key-down and key-up per character, and
# Enter, which is what a person's keystrokes put there.
hin = k.CreateFileW('CONIN$', 0x80000000 | 0x40000000, 3, None, 3, 0, None)
recs = (INPUT_RECORD * (2 * (len(TYPED) + 1)))()
for i, ch in enumerate(TYPED + '\r'):
    for j, down in enumerate((True, False)):
        r = recs[2 * i + j]
        r.EventType = 1                         # KEY_EVENT
        r.Key.bKeyDown = down
        r.Key.wRepeatCount = 1
        r.Key.wVirtualKeyCode = 0x0D if ch == '\r' else 0
        r.Key.UnicodeChar = ch
wrote = wt.DWORD(0)
k.WriteConsoleInputW(wt.HANDLE(hin), recs, len(recs), ctypes.byref(wrote))
k.CloseHandle(wt.HANDLE(hin))

open(go, 'w').close()
try:
    code = p.wait(timeout=30)
except subprocess.TimeoutExpired:
    p.kill()
    code = 'TIMEOUT'

info = CSBI()
k.GetConsoleScreenBufferInfo(wt.HANDLE(h), ctypes.byref(info))
n = info.dwSize.X * (info.dwCursorPosition.Y + 1)
buf = ctypes.create_unicode_buffer(n + 1)
got = wt.DWORD(0)
k.ReadConsoleOutputCharacterW(wt.HANDLE(h), buf, n, COORD(0, 0), ctypes.byref(got))
k.CloseHandle(wt.HANDLE(h))
k.FreeConsole()
text = ' '.join(buf.value[:got.value].split())

checks = [
    ('the reader sees the console (its own control line)', 'HARNESS-WROTE' in text),
    ("the program's println reached the new console", 'PROGRAM-PRINTED' in text),
    ("the program's line input read the new console's keyboard",
     'PROGRAM-READ[%s]' % TYPED in text),
    ("the host's diagnostic reached the new console",
     'reshow.bas:11: division by zero' in text),
    ('and the fault exits 1, a runtime error', code == 1),
]
bad = 0
for name, ok in checks:
    print('  %-56s %s' % (name, 'PASS' if ok else 'FAIL'))
    if not ok:
        bad += 1
if not checks[0][1]:
    print('SETUP the reader saw nothing: %r' % text[:200])
    sys.exit(2)
if bad:
    print('the new console held: %r' % text[:300])
print('PASS %d   FAIL %d' % (len(checks) - bad, bad))
sys.exit(1 if bad else 0)
