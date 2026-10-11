#!/usr/bin/env python3
"""Keys and lines TYPED into a real terminal: a Windows console, or a Unix pty.

Two readers in this tree take UTF-16 from the console one piece at a time, and
both lost what did not fit the piece (adversarial round 7, 2026-10-11):

  * getkey$/inkey$ (host/packages/PhosphorCrtLib.pas#KbdRead). A key event
    carries ONE UTF-16 unit, so a character outside the BMP -- an emoji --
    arrives as two events, a high surrogate and a low one. Each was converted
    alone by UTF8Encode, which drops a lone surrogate: both halves answered '',
    which KbdRead takes for "not a key", and the keystroke VANISHED -- the
    program read the next key in its place. Measured: U+1F600, 'q', 'z' typed;
    getkey$ twice answered 71 7a.
  * INPUT (host/console/phosphor.lpr#ReadLine, TConsoleHost's). One ReadConsoleW
    into an 8192-unit buffer was taken for the whole line, so a typed line
    longer than that arrived as TWO lines -- the second INPUT silently given the
    tail of the first -- and a pair cut at the boundary became two U+FFFD.
    Measured: 10000 'a' typed answered 8192 and then 1808.

Round 8 (2026-10-11) defined ONE KEYBOARD MODEL for both systems and pinned it
here, every case a measured defect (see PhosphorCrtLib.pas#CrtEventKey):

  * INPUT after any key function read with line input still off: 'h', and the
    next INPUT 'ello'; with both lines queued, both at once and a hang. Linux:
    the line read took the keys typed after the Enter, and inkey$ never saw
    them. A line is now read in line mode, and no further than its end.
  * A modifier alone (Shift, Ctrl) was a key, chr(0)+chr(16), ahead of every
    capital letter; Alt+numpad entry answered Alt and the digits, never the
    character; a key-down with a repeat count of 3 was one key; keypressed()
    answered 0 forever behind 32 events that are not keys; and an emoji whose
    halves arrive in two writes -- the normal shape, since the reader wakes on
    the first -- became two U+FFFD.
  * Linux getkey$ answered raw bytes that are not UTF-8; it answers U+FFFD.

No headless runner can reach any of this: these paths run only when stdin IS a
terminal. On Windows this script starts a copy of itself in a NEW console
(CREATE_NEW_CONSOLE), which writes key events into that console's input buffer
with WriteConsoleInputW -- a key-down and a key-up per UTF-16 unit, as a
keyboard makes them, or the exact records a case names -- before the program
starts or, for the timed cases, in bursts while it runs, stdout to a file. On
Unix it runs the program on a pty (python's pty module) and writes bytes to it.

EXPECTED VALUES are written out below from definitions, never from a run:
U+1F600 is D83D DE00 in UTF-16 and F0 9F 98 80 in UTF-8; U+FFFD is EF BF BD; a
line is everything up to the Enter, so its length is what was typed; a key is
what the model above says. INPUT prints its "? " prompt to stdout, which is why
the lines of a Windows case's output start so.

Usage: console_input_test.py <phosphor executable>
Exit 0 pass, 1 fail, 2 the harness could not set a case up.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

# ---- the records a case can name -------------------------------------------
# A key event: [1, down, unit, vk, scan, control-state, repeat]. A mouse move:
# [2, x, y]. A focus change: [16, set]. Codes from winuser.h / wincon.h.
SHIFT_PRESSED, LEFT_CTRL, LEFT_ALT = 0x10, 0x08, 0x02


def key(u, vk=0, down=True, scan=0, state=0, rep=1):
    return [1, 1 if down else 0, u, vk, scan, state, rep]


def tap(u, vk=0, scan=0, state=0):
    """A key pressed and released."""
    return [key(u, vk, True, scan, state), key(u, vk, False, scan, state)]


def units(text):
    """The UTF-16 units a keyboard would deliver for text, with a virtual-key
    code where one is obvious (Enter, letters, digits)."""
    out = []
    raw = text.encode('utf-16-le', 'surrogatepass')
    for k in range(0, len(raw), 2):
        u = raw[k] | (raw[k + 1] << 8)
        c = chr(u) if u < 0xD800 or u > 0xDFFF else ''
        if u == 13:
            vk = 0x0D
        elif c.isascii() and c.isalnum():
            vk = ord(c.upper())
        else:
            vk = 0
        out.append([u, vk])
    return out


def typed(text):
    """The records for text typed: a key-down and a key-up per unit."""
    recs = []
    for u, vk in units(text):
        recs += tap(u, vk)
    return recs


def inner(spec_path):
    """Runs inside the new console: type the keys, then run the program."""
    import ctypes
    import ctypes.wintypes as wt

    class KEY_EVENT_RECORD(ctypes.Structure):
        _fields_ = [('bKeyDown', wt.BOOL), ('wRepeatCount', wt.WORD),
                    ('wVirtualKeyCode', wt.WORD), ('wVirtualScanCode', wt.WORD),
                    ('UnicodeChar', wt.WORD), ('dwControlKeyState', wt.DWORD)]

    class MOUSE_EVENT_RECORD(ctypes.Structure):
        _fields_ = [('X', ctypes.c_short), ('Y', ctypes.c_short),
                    ('dwButtonState', wt.DWORD), ('dwControlKeyState', wt.DWORD),
                    ('dwEventFlags', wt.DWORD)]

    class EVENT(ctypes.Union):
        _fields_ = [('KeyEvent', KEY_EVENT_RECORD), ('MouseEvent', MOUSE_EVENT_RECORD),
                    ('SetFocus', wt.BOOL), ('pad', ctypes.c_byte * 16)]

    class INPUT_RECORD(ctypes.Structure):
        _fields_ = [('EventType', wt.WORD), ('Event', EVENT)]

    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    k32.CreateFileW.restype = wt.HANDLE
    with open(spec_path, encoding='utf-8') as f:
        spec = json.load(f)
    h = k32.CreateFileW('CONIN$', 0xC0000000, 3, None, 3, 0, None)

    def fill(r, rec):
        r.EventType = rec[0]
        if rec[0] == 1:
            e = r.Event.KeyEvent
            (e.bKeyDown, e.UnicodeChar, e.wVirtualKeyCode, e.wVirtualScanCode,
             e.dwControlKeyState, e.wRepeatCount) = rec[1:7]
        elif rec[0] == 2:
            m = r.Event.MouseEvent
            m.X, m.Y, m.dwEventFlags = rec[1], rec[2], 1      # MOUSE_MOVED
        else:
            r.Event.SetFocus = rec[1]

    def write(recs):
        """One WriteConsoleInputW; '' or what went wrong."""
        if not recs:
            return ''
        arr = (INPUT_RECORD * len(recs))()
        for r, rec in zip(arr, recs):
            fill(r, rec)
        written = wt.DWORD(0)
        ok = k32.WriteConsoleInputW(h, arr, len(recs), ctypes.byref(written))
        if not ok or written.value != len(recs):
            return 'HARNESS: wrote %d of %d events\n' % (written.value, len(recs))
        return ''

    with open(spec['out'], 'wb') as fo, open(spec['err'], 'wb') as fe:
        bad = write(spec['pre'])
        if bad:
            fe.write(bad.encode())
            return
        if spec.get('calibrate'):
            # The console's OWN answer, read here and not by phosphor: cooked
            # ReadConsoleW calls, as many as it takes, until the line's CR.
            # Their total is how many units of a typed line this console keeps.
            k32.ReadConsoleW.argtypes = [wt.HANDLE, ctypes.c_void_p, wt.DWORD,
                                         ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
            size = spec['calibrate']
            buf = ctypes.create_unicode_buffer(size)
            got = ''
            for _ in range(256):
                n = wt.DWORD(0)
                if not k32.ReadConsoleW(h, buf, size, ctypes.byref(n), None) or n.value == 0:
                    break
                got += buf[:n.value]
                if '\r' in got or '\n' in got:
                    break
            cut = min([i for i in (got.find('\r'), got.find('\n')) if i >= 0] or [len(got)])
            fo.write(str(cut).encode())
            fe.write(b'exit 0\n')
            return
        k32.GetConsoleMode.argtypes = [wt.HANDLE, ctypes.POINTER(wt.DWORD)]
        mode_before = wt.DWORD(0)
        k32.GetConsoleMode(h, ctypes.byref(mode_before))
        if spec.get('ctrlc'):
            # This harness lives through the Ctrl+C it sends: a handler that
            # answers TRUE (a FUNCTION, which a child does not inherit -- the
            # ignore flag NULL would set, it does).
            # And Ctrl+C is turned back ON for this process and the program
            # it starts: "ignore Ctrl+C" is inherited, and a harness started
            # from a parent that set it (Git Bash's python does) passed it to
            # phosphor, which then never saw the Ctrl+C and waited in getkey$
            # until the timeout -- a FAIL that measured the parent, not phosphor.
            k32.SetConsoleCtrlHandler(None, False)
            HANDLER = ctypes.WINFUNCTYPE(wt.BOOL, wt.DWORD)
            keep = HANDLER(lambda t: True)
            k32.SetConsoleCtrlHandler(keep, True)
        p = subprocess.Popen([spec['exe'], spec['bas']], stdout=fo, stderr=fe)
        # The timed bursts: the program is running, and blocked in what it
        # reads, before each arrives. A burst written 'separate' is one write
        # per event -- the shape the console host itself delivers.
        for delay, recs, separate in spec['bursts']:
            time.sleep(delay)
            for chunk in ([[r] for r in recs] if separate else [recs]):
                bad = write(chunk)
                if bad:
                    fe.write(bad.encode())
        if spec.get('ctrlc'):
            # Ctrl+C once the program says it is in getkey$, as a person
            # would press it: to every process on this console.
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and b'ready' not in open(spec['out'], 'rb').read():
                time.sleep(0.05)
            time.sleep(0.3)
            k32.GenerateConsoleCtrlEvent(0, 0)          # CTRL_C_EVENT
        try:
            p.wait(spec['timeout'])
            if spec.get('ctrlc'):
                mode_after = wt.DWORD(0)
                k32.GetConsoleMode(h, ctypes.byref(mode_after))
                fe.write(('modes %x %x\n' % (mode_before.value, mode_after.value)).encode())
            fe.write(('exit %d\n' % (p.returncode & 0xFFFFFFFF)).encode())
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(10)
            fe.write(b'TIMEOUT (killed)\n')
        if spec.get('screen'):
            # What the console SHOWS: its first row, read back from the
            # screen buffer. The program's stdout is a file, so the screen
            # holds only what the console's own line editor echoed.
            class COORD(ctypes.Structure):
                _fields_ = [('X', ctypes.c_short), ('Y', ctypes.c_short)]
            k32.ReadConsoleOutputCharacterW.argtypes = [wt.HANDLE, ctypes.c_wchar_p, wt.DWORD,
                                                        COORD, ctypes.POINTER(wt.DWORD)]
            ho = k32.CreateFileW('CONOUT$', 0xC0000000, 3, None, 3, 0, None)
            row = ctypes.create_unicode_buffer(80)
            n = wt.DWORD(0)
            k32.ReadConsoleOutputCharacterW(ho, row, 80, COORD(0, 0), ctypes.byref(n))
            with open(spec['screen'], 'w', encoding='utf-8') as fs:
                fs.write(row.value[:n.value].rstrip())


def run_windows(exe, work):
    CREATE_NEW_CONSOLE = 0x10
    failed = 0
    harness = 0

    def case(name, program, pre, want, timeout=20, calibrate=False, bursts=(), screen=None,
             ctrlc=False):
        """screen: what the console's first row must show afterwards. ctrlc:
        send Ctrl+C once the program prints 'ready'; `want` is then the
        exit status, and the console mode must be what it was before."""
        nonlocal failed, harness
        bas = os.path.join(work, name + '.bas')
        with open(bas, 'w', newline='\n', encoding='utf-8') as f:
            f.write(program)
        if isinstance(pre, str):
            pre = typed(pre)
        spec = {'pre': pre, 'exe': exe, 'bas': bas, 'timeout': timeout,
                'calibrate': calibrate, 'ctrlc': ctrlc,
                'screen': os.path.join(work, name + '.screen') if screen is not None else None,
                'bursts': [[d, typed(r) if isinstance(r, str) else r, sep]
                           for d, r, sep in bursts],
                'out': os.path.join(work, name + '.out'),
                'err': os.path.join(work, name + '.err')}
        sp = os.path.join(work, name + '.json')
        with open(sp, 'w', encoding='utf-8') as f:
            json.dump(spec, f)
        # THROUGH conhost.exe BY NAME, minimised and not activated. A bare
        # CREATE_NEW_CONSOLE is handed by Windows 11 to the default terminal
        # application, Windows Terminal, which opens a TAB per console and
        # keeps it open after the program exits: 356 dead tabs (and as many
        # OpenConsole/conhost processes) were left on the owner's desktop on
        # 2026-10-11 by two days of these cases. conhost.exe named directly
        # hosts its command in a classic console and closes with it.
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        si.wShowWindow = 7                      # SW_SHOWMINNOACTIVE
        conhost = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32', 'conhost.exe')
        p = subprocess.Popen([conhost, sys.executable, '-I', os.path.abspath(__file__), '--inner', sp],
                             creationflags=CREATE_NEW_CONSOLE, startupinfo=si)
        try:
            p.wait(timeout + 30 + sum(b[0] for b in bursts))
        except subprocess.TimeoutExpired:
            # the whole tree: conhost, the inner harness and the program
            subprocess.run(['taskkill', '/T', '/F', '/PID', str(p.pid)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            p.wait(10)
        try:
            got = open(spec['out'], 'rb').read().decode('utf-8', 'replace').replace('\r', '')
            err = open(spec['err'], 'rb').read().decode('utf-8', 'replace').strip()
        except OSError:
            got, err = None, 'no output files'
        if calibrate:
            if got is None or err.startswith('HARNESS') or not got.isdigit():
                print('HARNESS  %s: %s %r' % (name, err, got))
                harness += 1
                return None
            return int(got)
        shown = None
        if screen is not None:
            try:
                shown = open(spec['screen'], encoding='utf-8').read()
            except OSError:
                shown = None
        if got is None or 'HARNESS' in err:
            print('HARNESS  %s: %s' % (name, err))
            harness += 1
        elif ctrlc:
            m = re.search(r'modes (\w+) (\w+)\s+exit (\d+)$', err)
            if m and m.group(1) == m.group(2) and int(m.group(3)) == want:
                print('PASS  %s' % name)
            else:
                print('FAIL  %s: want the mode kept and exit %d, got %r' % (name, want, err))
                failed += 1
        elif got == want and err.endswith('exit 0') and (screen is None or shown == screen):
            print('PASS  %s' % name)
        else:
            print('FAIL  %s: want %r%s, got %r%s (%s)' % (
                name, want, '' if screen is None else ' showing %r' % screen, got,
                '' if screen is None else ' showing %r' % shown, err.replace('\n', ' / ')))
            failed += 1

    emoji = '\U0001F600'
    keys = ('crt_init()\nk1$ = getkey$()\nk2$ = getkey$()\ncrt_done()\n'
            'println hex_encode$(k1$) + " " + hex_encode$(k2$)\n')
    # One key outside the BMP is ONE key, and the key after it is the second.
    case('getkey-pair', keys, emoji + 'qz', 'f09f9880 71\n')
    # inkey$ the same, without blocking, and nothing left over after them. The
    # keys are in the buffer before the program starts, so nothing waits for them.
    case('inkey-pair', 'crt_init()\nk1$ = inkey$()\nk2$ = inkey$()\n'
         'k3$ = inkey$()\ncrt_done()\nprintln "[" + hex_encode$(k1$) + "] [" + '
         'hex_encode$(k2$) + "] [" + hex_encode$(k3$) + "]"\n',
         emoji + 'q', '[f09f9880] [71] []\n')
    # keypressed() agrees with inkey$: a key is waiting, inkey$ answers it, and
    # once the pair is read nothing is waiting -- its second half is not a
    # second key. (The old reader answered 1, then "", then 1.)
    case('keypressed-pair', 'crt_init()\na = keypressed()\nk$ = inkey$()\nb = keypressed()\n'
         'crt_done()\nprintln str$(a) + " " + hex_encode$(k$) + " " + str$(b)\n',
         emoji, '1 f09f9880 0\n')
    # A half with no partner is U+FFFD, never nothing -- and the key after it
    # is still the next key, not swallowed as the missing half.
    case('getkey-lone-high', keys, '\ud83dq', 'efbfbd 71\n')
    case('getkey-lone-low', keys, '\ude00q', 'efbfbd 71\n')

    # ---- round 8: the keyboard model ----------------------------------------
    # THE HALVES IN SEPARATE WRITES, after the program is blocked in getkey$:
    # the reader wakes on the high half with the low one not queued yet, and
    # must wait for it (it answered efbfbd efbfbd in 7 runs of 8). Then with
    # only the two key-downs, each its own write.
    case('getkey-pair-split', keys, [], 'f09f9880 71\n',
         bursts=[(1.0, tap(0xD83D) + tap(0xDE00) + tap(ord('q'), 0x51), True)])
    case('getkey-pair-split-downs', keys, [], 'f09f9880 71\n',
         bursts=[(1.0, [key(0xD83D), key(0xDE00)] + tap(ord('q'), 0x51), True)])
    # A MODIFIER ALONE IS NOT A KEY. Shift+A typed as a person types it is
    # 'A', and the next key 'q' (it was 0010 41: chr(0)+chr(16), then 'A').
    shift_a = ([key(0, 0x10, True, 0x2A, SHIFT_PRESSED)] + tap(ord('A'), 0x41, 0x1E, SHIFT_PRESSED)
               + [key(0, 0x10, False, 0x2A, 0)] + tap(ord('q'), 0x51, 0x10))
    case('shift-a', keys, shift_a, '41 71\n')
    # Ctrl+A is chr(1), as a terminal sends it; the Ctrl press is nothing.
    ctrl_a = ([key(0, 0x11, True, 0x1D, LEFT_CTRL)] + tap(1, 0x41, 0x1E, LEFT_CTRL)
              + [key(0, 0x11, False, 0x1D, 0)] + tap(ord('q'), 0x51, 0x10))
    case('ctrl-a', keys, ctrl_a, '01 71\n')
    # A Shift pressed and released alone: no key is waiting, and inkey$ agrees.
    case('shift-alone', 'crt_init()\na = keypressed()\nk$ = inkey$()\ncrt_done()\n'
         'println str$(a) + " [" + hex_encode$(k$) + "]"\n',
         [key(0, 0x10, True, 0x2A, SHIFT_PRESSED), key(0, 0x10, False, 0x2A, 0)], '0 []\n')
    # And a Shift between the halves of a pair does not break the pair.
    case('pair-shift-between', keys,
         tap(0xD83D) + [key(0, 0x10, True, 0x2A, SHIFT_PRESSED)] + tap(0xDE00)
         + [key(0, 0x10, False, 0x2A, 0)] + tap(ord('q'), 0x51), 'f09f9880 71\n')
    # ALT+NUMPAD: Alt down, numpad 2 3 0 (VK_NUMPAD2 62 / 3 63 / 0 60, scan
    # codes 50 51 52), and the Alt KEY-UP carrying the composed U+00E9, whose
    # UTF-8 is C3 A9. It answered 0012 then 0062.
    altnum = ([key(0, 0x12, True, 0x38, LEFT_ALT)] + tap(0, 0x62, 0x50, LEFT_ALT)
              + tap(0, 0x63, 0x51, LEFT_ALT) + tap(0, 0x60, 0x52, LEFT_ALT)
              + [key(0xE9, 0x12, False, 0x38, 0)] + tap(ord('q'), 0x51))
    case('alt-numpad', keys, altnum, 'c3a9 71\n')
    # A REPEAT COUNT IS PRESSES: 'a' down with wRepeatCount 3 is three keys
    # (KEY_EVENT_RECORD: "one event with this member equal to 5" for five), and
    # keypressed() counts the ones not yet read. An arrow likewise.
    four = ('crt_init()\nk1$ = getkey$()\nk2$ = getkey$()\nk3$ = getkey$()\n'
            'k4$ = getkey$()\ncrt_done()\nprintln hex_encode$(k1$) + " " + hex_encode$(k2$)'
            ' + " " + hex_encode$(k3$) + " " + hex_encode$(k4$)\n')
    case('repeat-3', four, [key(ord('a'), 0x41, rep=3), key(ord('a'), 0x41, False)]
         + tap(ord('q'), 0x51), '61 61 61 71\n')
    case('repeat-arrow', four, [key(0, 0x26, scan=0x48, state=0x100, rep=3),
                                key(0, 0x26, False, 0x48, 0x100)] + tap(ord('q'), 0x51),
         '0026 0026 0026 71\n')
    case('repeat-keypressed', 'crt_init()\nk$ = getkey$()\na = keypressed()\nk2$ = inkey$()\n'
         'b = keypressed()\ncrt_done()\nprintln hex_encode$(k$) + " " + str$(a) + " " + '
         'hex_encode$(k2$) + " " + str$(b)\n',
         [key(ord('a'), 0x41, rep=2), key(ord('a'), 0x41, False)], '61 1 61 0\n')
    # KEYPRESSED BEHIND 100 EVENTS THAT ARE NOT KEYS: 40 mouse moves, 20 focus
    # changes, 40 stray key-ups, then 'q'. It peeked 32 and answered 0 on every
    # poll while inkey$ read the q at once (30 [71]); a key is waiting: 0 [71].
    junk = ([[2, i, 1] for i in range(40)] + [[16, i % 2] for i in range(20)]
            + [key(ord('z'), 0x5A, False) for _ in range(40)])
    case('keypressed-behind-junk', 'crt_init()\nc = 0\nwhile keypressed() = 0 and c < 30\n'
         '  pause(0.05)\n  c = c + 1\nwend\nk$ = inkey$()\ncrt_done()\n'
         'println str$(c) + " [" + hex_encode$(k$) + "]"\n',
         junk + tap(ord('q'), 0x51), '0 [71]\n')
    # INPUT AFTER A KEY FUNCTION IS A LINE: getkey$ reads 'x', then the keys
    # arrive in bursts as a person types -- 'h'; 'ello' Enter; 'world' Enter.
    # It answered 68 / 656c6c6f: one character, and the next INPUT the rest.
    gk_lines = ('crt_init()\nk$ = getkey$()\ninput a$\ninput b$\ncrt_done()\n'
                'println "|" + hex_encode$(k$) + " " + hex_encode$(a$) + " " + hex_encode$(b$)\n')
    case('getkey-then-input', gk_lines, [], '? ? |78 68656c6c6f 776f726c64\n',
         bursts=[(1.0, 'x', False), (0.5, 'h', False), (0.2, 'ello\r', False),
                 (0.2, 'world\r', False)])
    # A lone keypressed() puts the console in the same state.
    case('keypressed-then-input', 'crt_init()\nz = keypressed()\ninput a$\ninput b$\n'
         'crt_done()\nprintln "|" + str$(z) + " " + hex_encode$(a$) + " " + hex_encode$(b$)\n',
         [], '? ? |0 68656c6c6f 776f726c64\n',
         bursts=[(1.0, 'h', False), (0.2, 'ello\r', False), (0.2, 'world\r', False)])
    # Everything typed before the program starts: the first INPUT took BOTH
    # lines and the second waited forever. Raw mode resumes after the lines,
    # so the key after them is getkey$'s.
    case('getkey-then-input-queued', 'crt_init()\nk$ = getkey$()\ninput a$\ninput b$\n'
         'k2$ = getkey$()\ncrt_done()\nprintln "|" + hex_encode$(k$) + " " + hex_encode$(a$)'
         ' + " " + hex_encode$(b$) + " " + hex_encode$(k2$)\n',
         'xhello\rworld\rq', '? ? |78 68656c6c6f 776f726c64 71\n')
    # The presses of a repeated key not yet read were typed BEFORE the rest of
    # the line, so INPUT takes them first: 'a' x3, one read by getkey$, then
    # 'bc' Enter is the line 'aabc'.
    # ROUND 9: AND THE SCREEN SHOWS THEM, and Backspace erases them. They were
    # joined after the console's read -- never shown, out of its editing -- so
    # the line said 'aabc' with 'bc' on the screen. Now what the screen shows
    # is what INPUT answers. (The program's stdout is a file, so the screen's
    # first row holds only the line as the console echoed it.)
    gk_in = ('crt_init()\nk$ = getkey$()\ninput a$\ncrt_done()\n'
             'println "|" + hex_encode$(k$) + " " + hex_encode$(a$)\n')
    case('repeat-then-input', gk_in,
         [key(ord('a'), 0x41, rep=3), key(ord('a'), 0x41, False)] + typed('bc\r'),
         '? |61 61616263\n', screen='aabc')
    # Two Backspaces erase the two presses getkey$ had not answered: the line
    # is 'bc', as three separate taps of 'a' would have made it.
    case('repeat-then-backspace', gk_in,
         [key(ord('a'), 0x41, rep=3), key(ord('a'), 0x41, False)] + tap(8, 0x08) + tap(8, 0x08)
         + typed('bc\r'), '? |61 6263\n', screen='bc')
    case('taps-then-backspace', gk_in, typed('aaa') + tap(8, 0x08) + tap(8, 0x08) + typed('bc\r'),
         '? |61 6263\n', screen='bc')
    # ROUND 10: A HELD TAB OR CTRL CHORD IS TEXT TOO. Only presses from ' ' up
    # were kept, so the two unanswered presses of a Tab held for three vanished
    # ('|09 78'). Expected: what the same keys TAPPED answer -- the console's
    # own cooked read keeps a Tab and a Ctrl chord in a line (measured on
    # Windows 11: three taps of ^A then 'x' Enter answer 01 01 01 78, shown
    # ^A^A^Ax) -- and a held Backspace's unanswered presses erase nothing, as
    # three taps of it before 'x' leave the line 'x'.
    case('repeat-tab-then-input', gk_in,
         [key(9, 0x09, rep=3), key(9, 0x09, False)] + typed('x\r'), '? |09 090978\n')
    case('repeat-ctrl-a-then-input', gk_in,
         [key(1, 0x41, state=LEFT_CTRL, rep=3), key(1, 0x41, False, state=LEFT_CTRL)] + typed('x\r'),
         '? |01 010178\n', screen='^A^Ax')
    case('repeat-backspace-then-input', gk_in,
         [key(8, 0x08, rep=3), key(8, 0x08, False)] + typed('x\r'), '? |08 78\n', screen='x')

    # ROUND 9: INKEY$ NEVER WAITS FOR A HALF. Five lone high halves queued
    # (key-downs, no partners): each of the first four is settled by the key
    # behind it, U+FFFD; the fifth has nothing behind it, so it is not a key
    # YET -- inkey$ answers "" and keypressed() 0 rather than waiting 500 ms
    # for it. Once its PAIR_WAIT_MS (500) has passed it is U+FFFD, and
    # keypressed() says so first.
    halves = ('crt_init()\nk1$ = inkey$()\nk2$ = inkey$()\nk3$ = inkey$()\nk4$ = inkey$()\n'
              'k5$ = inkey$()\na = keypressed()\npause(0.7)\nb = keypressed()\nk6$ = inkey$()\n'
              'crt_done()\nprintln hex_encode$(k1$) + " " + hex_encode$(k2$) + " " + '
              'hex_encode$(k3$) + " " + hex_encode$(k4$) + " [" + hex_encode$(k5$) + "] " + '
              'str$(a) + " " + str$(b) + " " + hex_encode$(k6$)\n')
    case('inkey-lone-halves', halves, [key(u) for u in (0xD83D, 0xD83E, 0xD83F, 0xD840, 0xD841)],
         'efbfbd efbfbd efbfbd efbfbd [] 0 1 efbfbd\n')

    # ROUND 9: CTRL+C IN getkey$ PUTS THE CONSOLE BACK. Its default handler
    # ends the process past finalization, and the console stayed with line
    # input and echo off (0x1F7 before, 0x1F1 after). Expected: the mode the
    # console had before, and the exit status Ctrl+C always gave,
    # STATUS_CONTROL_C_EXIT (C000013A, ntstatus.h) -- the handler restores and
    # lets the default one run.
    case('ctrlc-getkey', 'crt_init()\nz = keypressed()\nprintln "ready"\nk$ = getkey$()\n'
         'println "|" + hex_encode$(k$)\n', [], 0xC000013A, ctrlc=True)

    lines = ('input a$\nprintln str$(bytelen(a$)) + " " + hex_encode$(right$(a$, 3))\n'
             'input b$\nprintln str$(bytelen(b$)) + " " + hex_encode$(b$)\n')

    # HOW MANY UNITS PHOSPHOR ASKS FOR IN ONE READ: CONSOLE_READ_UNITS, read
    # from host/console/phosphor.lpr itself rather than copied here, so the
    # line lengths below sit on the boundary the host really has.
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'host',
                       'console', 'phosphor.lpr')
    try:
        m = re.search(r'CONSOLE_READ_UNITS\s*=\s*(\d+)\s*;', open(src, encoding='utf-8').read())
    except OSError:
        m = None
    if not m:
        print('HARNESS  CONSOLE_READ_UNITS not found in %s' % src)
        return 2
    read = int(m.group(1))

    # HOW MUCH OF A TYPED LINE THIS CONSOLE KEEPS, asked of the console itself
    # and not of phosphor: cooked reads of 4096 units, as many as it takes, of
    # a line longer than phosphor's read. Two consoles, measured 2026-10-11:
    # Windows 11 keeps the whole line across as many reads as it takes; the
    # GitHub Windows Server runner's legacy conhost keeps only what the FIRST
    # read's buffer holds, less two units (its CR LF) -- 4096 answered 4094,
    # and phosphor's then-8192-unit read 8190 -- and DISCARDS the rest. So an
    # answer short of one 4096 read says the console truncates, by
    # 4096 - answer units, and what it keeps of a line PHOSPHOR reads is its
    # own first read less that; any other answer is the console's own cap.
    # What phosphor must answer is what the console hands over: the first
    # `cap` units of the line, as ONE line, then the next line -- never the
    # line's tail as a second INPUT.
    probe = 4096
    longest = read + 1808
    got = case('console-cap', '', 'a' * longest + '\r', None, timeout=120, calibrate=probe)
    if got is None:
        return 2
    cap = read - (probe - got) if got < probe else got

    def line_want(typed_line):
        u = typed_line.encode('utf-16-le', 'surrogatepass')[:2 * cap]
        b = u.decode('utf-16-le', 'surrogatepass').encode('utf-8', 'surrogatepass')
        # a pair the console's cut halves is one unpaired surrogate: U+FFFD
        b = b.replace(b'\xed\xa0\xbd', b'\xef\xbf\xbd')
        # right$(a$, 3) counts CHARACTERS: the last three, in UTF-8
        tail = b.decode('utf-8')[-3:].encode('utf-8')
        return '? %d %s\n? 1 7a\n' % (len(b), tail.hex())

    if cap < read:
        print('NOTE  this console keeps %d units of a line phosphor reads (its 4096-unit '
              'read kept %d), fewer than one %d-unit read: no line it hands over can '
              'span two reads, so the cases below check that what it keeps is one '
              'line' % (cap, got, read))
    # A line longer than one read is still ONE line; the next INPUT gets the
    # next line. Typed 'a' are one byte each, where the console keeps them.
    case('line-long', lines, 'a' * longest + '\rz\r', line_want('a' * longest), timeout=120)
    # A pair across the read boundary: read-1 'a' fill the buffer to its last
    # unit, the high half lands there and the low half in the next read. The
    # whole line is read - 1 + 4 + 1 bytes, ending a, U+1F600, b.
    case('line-pair-cut', lines, 'a' * (read - 1) + emoji + 'b\rz\r',
         line_want('a' * (read - 1) + emoji + 'b'), timeout=120)
    # A line that fills the buffer EXACTLY up to its CR: the LF is left for the
    # next read, and must not become an empty second line.
    case('line-cr-at-end', lines, 'a' * (read - 1) + '\rz\r', line_want('a' * (read - 1)),
         timeout=120)
    # A Ctrl+Z (1A) inside a long line ends the LINE's text, not the read: the
    # line is 'ab', and the next INPUT the next line 'z' -- it was given the
    # line's tail (811 'c' of 9000 behind an 8192-unit read) when the Ctrl+Z
    # sat in the first full read. On a console that truncates, 'ab' still.
    case('line-ctrlz-long', lines, 'ab\x1a' + 'c' * (read + 800) + '\rz\r',
         '? 2 6162\n? 1 7a\n', timeout=120)

    if harness:
        return 2
    return 1 if failed else 0


# ---- Unix: the same model on a pty ---------------------------------------------
def run_unix(exe, work):
    import pty
    import select
    import signal

    failed = 0

    import termios
    # termios.IUTF8 is missing from some Pythons (Ubuntu 24.04's 3.12 among
    # them, round 10); the value is the kernel's, octal 0040000, as
    # PhosphorCrtLib declares it.
    IUTF8 = getattr(termios, 'IUTF8', 0o40000)

    def case(name, program, bursts, want, timeout=20, shows=None, iflag=(0, 0), lflag=(0, 0)):
        """bursts: (seconds to wait, bytes to write). The program's own answer
        is its line starting '|', found in what the pty echoes back; shows,
        bytes the terminal must have been sent (the prompt and the echo).
        iflag, lflag: (bits to set, bits to clear) in the terminal's modes
        before the program starts, as `stty` would -- a new pty has IUTF8
        off (the kernel's tty_std_termios), where a UTF-8 terminal sets it."""
        nonlocal failed
        bas = os.path.join(work, name + '.bas')
        with open(bas, 'w', newline='\n', encoding='utf-8') as f:
            f.write(program)
        pid, fd = pty.fork()
        if pid == 0:
            try:
                if iflag != (0, 0) or lflag != (0, 0):
                    a = termios.tcgetattr(0)
                    a[0] = (a[0] | iflag[0]) & ~iflag[1]
                    a[3] = (a[3] | lflag[0]) & ~lflag[1]
                    termios.tcsetattr(0, termios.TCSANOW, a)
                os.execv(exe, [exe, bas])
            finally:
                os._exit(127)
        out = b''
        start = time.monotonic()
        plan = []
        t = 0.0
        for d, data in bursts:
            t += d
            plan.append((t, data))
        while time.monotonic() - start < timeout:
            now = time.monotonic() - start
            while plan and plan[0][0] <= now:
                os.write(fd, plan.pop(0)[1])
            wait = (plan[0][0] - now) if plan else 0.2
            r, _, _ = select.select([fd], [], [], max(0.0, min(wait, 0.2)))
            if r:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    chunk = b''
                if not chunk:
                    break                 # the program has ended
                out += chunk
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _, status = os.waitpid(pid, 0)
        os.close(fd)
        m = re.search(rb'\|([^\r\n]*)', out)
        got = m.group(1).decode('ascii', 'replace') if m else None
        if got == want and (shows is None or shows in out):
            print('PASS  %s' % name)
        else:
            print('FAIL  %s: want %r%s, got %r (pty said %r)' % (
                name, want, '' if shows is None else ' showing %r' % shows, got, out[-200:]))
            failed += 1

    gk_lines = ('crt_init()\nk$ = getkey$()\ninput a$\ninput b$\ncrt_done()\n'
                'println "|" + hex_encode$(k$) + " " + hex_encode$(a$) + " " + hex_encode$(b$)\n')
    # The Windows defect's shape, pinned here too: a line after a key function
    # is the line (Linux answered it right; now the model says so on both).
    case('getkey-then-input', gk_lines,
         [(0.7, b'x'), (0.5, b'h'), (0.2, b'ello\r'), (0.2, b'world\r')],
         '78 68656c6c6f 776f726c64')
    mix = ('crt_init()\nk1$ = getkey$()\ninput a$\nk2$ = inkey$()\nc = 0\n'
           'while k2$ = "" and c < 20\n  pause(0.1)\n  k2$ = inkey$()\n  c = c + 1\nwend\n'
           'crt_done()\nprintln "|" + hex_encode$(k1$) + " " + hex_encode$(a$) + " [" + '
           'hex_encode$(k2$) + "]"\n')
    # A KEY TYPED IN THE SAME BURST AS THE LINE'S ENTER is the next key, not
    # part of the line read: 'hello' CR 'q' in one write. It answered [] -- the
    # line read's buffer took the q, and no key function reads that buffer.
    case('input-then-inkey-burst', mix, [(0.7, b'x'), (0.5, b'hello\rq')],
         '78 68656c6c6f [71]')
    # And typed before INPUT even began, while getkey$ held the terminal raw.
    case('input-then-inkey-typed-ahead', mix, [(0.7, b'xhello\rq')], '78 68656c6c6f [71]')
    three = ('crt_init()\nk1$ = getkey$()\nk2$ = getkey$()\nk3$ = getkey$()\ncrt_done()\n'
             'println "|" + hex_encode$(k1$) + " " + hex_encode$(k2$) + " " + hex_encode$(k3$)\n')
    # WHAT IS NOT UTF-8 IS U+FFFD (EF BF BD), one per maximal ill-formed
    # subpart, and the key after it is still its own: a Latin-1 e-acute E9
    # before 'q' 'r'; a stray continuation 80 before a whole C3 A9; a four-byte
    # lead F0 9F cut short, then 'q' 'r' half a second later. It answered the
    # raw E9, 80 and F0 9F.
    case('utf8-latin1-byte', three, [(0.7, b'\xe9qr')], 'efbfbd 71 72')
    case('utf8-stray-continuation', three, [(0.7, b'\x80\xc3\xa9q')], 'efbfbd c3a9 71')
    case('utf8-cut-short', three, [(0.7, b'\xf0\x9f'), (0.5, b'qr')], 'efbfbd 71 72')
    case('utf8-whole', three, [(0.7, b'\xc3\xa9\xf0\x9f\x98\x80q')], 'c3a9 f09f9880 71')

    # ---- round 9: ONE KEY PER KEY, however the bytes arrive -----------------
    # KEYS TYPED WHILE THE PROGRAM IS BUSY: queued, then read. An escape
    # sequence ends at its final byte (ECMA-48), so three presses of Up are
    # three keys and Esc, q, r three more -- as Windows answers them. It
    # answered one key of everything waiting (1b5b411b5b411b5b41), and the
    # program then blocked for keys typed later ('12' here, so the old binary
    # fails with an answer rather than a timeout).
    busy = ('crt_init()\nz = keypressed()\nprintln "ready"\npause(1.5)\nk1$ = getkey$()\n'
            'k2$ = getkey$()\nk3$ = getkey$()\ncrt_done()\nprintln "|" + hex_encode$(k1$) + " " + '
            'hex_encode$(k2$) + " " + hex_encode$(k3$)\n')
    up, down = b'\x1b[A', b'\x1b[B'
    case('arrows-busy', busy, [(0.7, up), (0.2, up), (0.2, up), (2.0, b'12')],
         '1b5b41 1b5b41 1b5b41')
    case('esc-busy', busy, [(0.7, b'\x1b'), (0.3, b'q'), (0.3, b'r'), (2.0, b'12')], '1b 71 72')
    case('esc-burst', three, [(0.7, up + down + b'q'), (2.0, b'12')], '1b5b41 1b5b42 71')
    # A KEY SPLIT ACROSS TWO READS is one key: the reader blocked in getkey$
    # wakes on the first part and waits for the rest (100 ms for an escape
    # sequence, 500 for a UTF-8 character). It answered 1b 5b 41, and two or
    # three U+FFFD for one character.
    case('esc-split', three, [(0.7, b'\x1b'), (0.02, b'[A'), (0.1, b'qr')], '1b5b41 71 72')
    case('utf8-split', three, [(0.7, b'\xc3'), (0.01, b'\xa9'), (0.1, b'qr')], 'c3a9 71 72')
    case('emoji-split', three, [(0.7, b'\xf0\x9f'), (0.01, b'\x98\x80'), (0.1, b'qr')],
         'f09f9880 71 72')
    # Escape on its own is still a key: decided when its wait runs out.
    case('esc-alone', three, [(0.7, b'\x1b'), (0.5, b'q'), (0.2, b'r')], '1b 71 72')
    # And inkey$, which never waits: polled while half an arrow has arrived,
    # it answers "" until the rest comes -- then the arrow, whole.
    poll = ('crt_init()\nk$ = ""\nc = 0\nwhile k$ = "" and c < 300\n  k$ = inkey$()\n'
            '  if k$ = "" then\n    pause(0.01)\n  end if\n  c = c + 1\nwend\ncrt_done()\n'
            'println "|" + hex_encode$(k$)\n')
    case('inkey-split', poll, [(0.7, b'\x1b'), (0.03, b'[A')], '1b5b41')

    # ---- round 9: KEYS TYPED AHEAD OF INPUT ARE EDITED AND SHOWN -------------
    # Typed while getkey$ held the terminal raw, they were handed to INPUT as
    # raw bytes -- a DEL inside the line, nothing on the screen ('68656c6f7f6c6f').
    # Expected from the line discipline's definition (n_tty, `stty sane`):
    # DEL erases a character and shows BS SP BS; Ctrl+U erases the line; the
    # Enter shows a newline (CR LF, through the terminal's own output map).
    gk_in = ('crt_init()\nk$ = getkey$()\ninput a$\ncrt_done()\n'
             'println "|" + hex_encode$(k$) + " " + hex_encode$(a$)\n')
    case('typeahead-del', gk_in, [(0.7, b'xhelo\x7flo\r')], '78 68656c6c6f',
         shows=b'? helo\x08 \x08lo\r\n')
    case('typeahead-kill', gk_in, [(0.7, b'xab\x15hello\r')], '78 68656c6c6f',
         shows=b'? ab\x08 \x08\x08 \x08hello\r\n')
    # Part of the line typed ahead, the rest typed during INPUT: still one
    # line under one editor -- the DELs reach back into what was typed ahead.
    case('typeahead-then-live', gk_in, [(0.7, b'xhel'), (0.5, b'\x7f\x7fy\r')], '78 6879',
         shows=b'? hel\x08 \x08\x08 \x08y\r\n')
    # Nothing typed ahead: the line discipline's own line mode, as before.
    case('typed-live', gk_in, [(0.7, b'x'), (0.5, b'helo\x7flo\r')], '78 68656c6c6f')

    # ---- round 10: THE SAME LINE TYPED AHEAD AS TYPED LIVE -------------------
    # Each expected line is what Linux's own line discipline answered for the
    # same keys typed after INPUT began (measured in round 10's verification),
    # and what n_tty.c defines: Ctrl+W after 'n a-tilde o' takes the whole
    # word under IUTF8 (isalnum() of the lead byte C3, _U in the kernel's
    # Latin-1 table) -- typed ahead it took the 'o' alone; without IUTF8 erase
    # takes one byte (61 c3 78); without ICANON nothing is edited and DEL is
    # in the line (61 62 7f 63).
    case('typeahead-werase-utf8', gk_in, [(0.7, b'xab n\xc3\xa3o\x17x\r')], '78 61622078',
         iflag=(IUTF8, 0))
    case('typeahead-erase-no-iutf8', gk_in, [(0.7, b'xa\xc3\xa9\x7fx\r')], '78 61c378',
         iflag=(0, IUTF8))
    case('typeahead-no-icanon', gk_in, [(0.7, b'xab\x7fc\r')], '78 61627f63',
         lflag=(0, termios.ICANON))
    # A TAB ERASED TYPED AHEAD goes back the columns it took FROM WHERE THE
    # PROMPT ENDED: after 'Name:' (5 columns) 'ab' Tab took 8 - 7 = 1, after
    # '? ' 8 - 4 = 4 -- the backspaces the live line discipline sent. It sent
    # six for both, into the prompt.
    name_in = ('crt_init()\nk$ = getkey$()\ninput "Name:", a$\ncrt_done()\n'
               'println "|" + hex_encode$(k$) + " " + hex_encode$(a$)\n')
    case('typeahead-tab-after-name', name_in, [(0.7, b'xab\t\x7fx\r')], '78 616278',
         shows=b'Name:ab\t\x08x')
    case('typeahead-tab-after-question', gk_in, [(0.7, b'xab\t\x7fx\r')], '78 616278',
         shows=b'? ab\t\x08\x08\x08\x08x')
    # A PASTE INTO A getkey$ LOOP costs a key's work per key: 256 KB took 2 s
    # and a megabyte 21 (each key was cut off the front of a queue as long as
    # the paste). Expected: every key counted inside the case's limit, 20 s --
    # a bound on the whole run that the linear reader meets several times
    # over (round 10's slowest machine, WSL, ran 2M keys of a bare loop in
    # 7 s) and the quadratic one missed on every machine measured (21 to 84
    # s for the megabyte). Judge it on WSL or CI, never on the VM.
    paste = ('crt_init()\nprintln "ready"\nn = 0\nk$ = getkey$()\nwhile k$ <> "q" and k$ <> ""\n'
             '  n = n + 1\n  k$ = getkey$()\nwend\ncrt_done()\nprintln "|n=" + str$(n) + "|"\n')
    case('paste-1mb', paste, [(0.7, b'a' * (1 << 20) + b'q')], 'n=1048576|', timeout=20)

    # ---- round 10: CTRL+Z, AND fg ---------------------------------------------
    # A program stopped in getkey$ with the terminal raw: bash put its own
    # modes back and did not re-apply the job's on fg, so after fg 'b' was
    # echoed and getkey$ waited for Enter; dash left the terminal raw while the
    # shell prompted. Expected, the convention vim, less and readline keep:
    # ECHO and ICANON on while stopped, and after fg 'b' answered at once,
    # unechoed. Run under each shell's job control, on a pty.
    import shlex
    import shutil

    def job_control(shell, argv, judge_stopped_modes):
        nonlocal failed
        path = shutil.which(shell)
        if not path:
            print('FAIL  ctrlz-fg-%s: no %s on this machine' % (shell, shell))
            failed += 1
            return
        bas = os.path.join(work, 'tstp.bas')
        with open(bas, 'w', newline='\n', encoding='utf-8') as f:
            f.write('crt_init()\nprintln "ready"\nk$ = getkey$()\nprintln "|A" + hex_encode$(k$) + "|"\n'
                    'k$ = getkey$()\nprintln "|B" + hex_encode$(k$) + "|"\ncrt_done()\nprintln "done"\n')
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.execve(path, [shell] + argv, {'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
                                                 'PS1': 'PROMPT$ ', 'TERM': 'dumb', 'HOME': work})
            finally:
                os._exit(127)
        out = b''

        def wait_until(test, secs):
            nonlocal out
            end = time.monotonic() + secs
            while time.monotonic() < end and not test():
                r, _, _ = select.select([fd], [], [], 0.1)
                if r:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        chunk = b''
                    if not chunk:
                        break
                    out += chunk
            return test()

        steps = []
        ok = wait_until(lambda: b'PROMPT$ ' in out, 10)
        steps.append('prompt %s' % ok)
        if ok:
            os.write(fd, ('%s %s\n' % (shlex.quote(exe), shlex.quote(bas))).encode())
            ok = wait_until(lambda: b'ready' in out, 15)
            steps.append('ready %s' % ok)
        if ok:
            time.sleep(0.3)
            os.write(fd, b'a')
            ok = wait_until(lambda: b'|A61|' in out, 5)
            steps.append('A %s' % ok)
        stopped_modes = False
        if ok:
            prompts = out.count(b'PROMPT$ ')
            os.write(fd, b'\x1a')
            ok = wait_until(lambda: out.count(b'PROMPT$ ') > prompts, 5)
            steps.append('stopped %s' % ok)
            time.sleep(0.2)
            lf = termios.tcgetattr(fd)[3]
            stopped_modes = bool(lf & termios.ECHO) and bool(lf & termios.ICANON)
            steps.append('modes while stopped %s' % stopped_modes)
        got_b = False
        if ok:
            os.write(fd, b'fg\n')
            # read what the shell shows for fg (the job's command line, which
            # has a 'b' in it) before marking where 'b' is typed
            wait_until(lambda: False, 1.0)
            mark = len(out)
            os.write(fd, b'b')
            got_b = wait_until(lambda: b'|B62|' in out[mark:], 3)
            before = out[mark:].split(b'|B62|')[0]
            if got_b and b'b' in before:
                got_b = False
                steps.append('b echoed')
            steps.append('B %s' % got_b)
            if got_b:
                wait_until(lambda: b'done' in out[mark:], 5)
        try:
            os.write(fd, b'\x04exit\n')
        except OSError:
            pass
        end = time.monotonic() + 5
        status = None
        while time.monotonic() < end:
            done, st = os.waitpid(pid, os.WNOHANG)
            if done:
                status = st
                break
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try:
                    os.read(fd, 4096)
                except OSError:
                    break
        if status is None:
            try:
                os.killpg(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
        os.close(fd)
        if (stopped_modes or not judge_stopped_modes) and got_b:
            print('PASS  ctrlz-fg-%s' % shell)
        else:
            print('FAIL  ctrlz-fg-%s: want %sb answered unechoed after fg, got %s (pty said %r)'
                  % (shell, 'ECHO and ICANON while stopped and ' if judge_stopped_modes else '',
                     ', '.join(steps), out[-300:]))
            failed += 1

    # WHICH SHELL CAN SHOW WHICH HALF. Interactive bash reads its prompt through
    # readline, which turns ICANON and ECHO OFF while it waits -- so the modes
    # read at bash's prompt are readline's, whatever the program left (the first
    # Linux run of this case, 2026-10-11, failed on exactly that, with the
    # program right). bash still shows the fg half: 'b' answered at once and
    # unechoed. dash reads its prompt in cooked mode and restores nothing of its
    # own, so the modes at ITS prompt are the ones the stopped program left:
    # dash shows the stop half too.
    job_control('bash', ['--norc', '--noprofile', '-i'], False)
    job_control('dash', ['-i'], True)

    # ---- round 9: CTRL+C IN getkey$ PUTS THE TERMINAL BACK -------------------
    # The default action of SIGINT ended the process past finalization, and the
    # terminal stayed with ECHO and ICANON off. Expected: both on again after
    # it, and the process still killed BY SIGINT -- the handler restores and
    # re-raises, so a shell sees what it always saw.
    bas = os.path.join(work, 'ctrlc.bas')
    with open(bas, 'w', newline='\n', encoding='utf-8') as f:
        f.write('crt_init()\nz = keypressed()\nprintln "ready"\nk$ = getkey$()\n'
                'println "|" + hex_encode$(k$)\n')
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execv(exe, [exe, bas])
        finally:
            os._exit(127)
    out = b''
    start = time.monotonic()
    sent = False
    status = None
    while time.monotonic() - start < 20:
        if not sent and b'ready' in out:
            time.sleep(0.3)
            os.write(fd, b'\x03')
            sent = True
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                chunk = b''
            out += chunk
        done, st = os.waitpid(pid, os.WNOHANG)
        if done:
            status = st
            break
    if status is None:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
    lflag = termios.tcgetattr(fd)[3]
    os.close(fd)
    echo_on = bool(lflag & termios.ECHO) and bool(lflag & termios.ICANON)
    by_sigint = status is not None and os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGINT
    if echo_on and by_sigint:
        print('PASS  ctrlc-getkey')
    else:
        print('FAIL  ctrlc-getkey: want ECHO and ICANON back and death by SIGINT, got '
              'ECHO|ICANON %s, status %r (pty said %r)' % (echo_on, status, out[-200:]))
        failed += 1
    return 1 if failed else 0


def main():
    exe = os.path.abspath(sys.argv[1])
    work = tempfile.mkdtemp(prefix='phosphor-coninput-')
    if os.name == 'nt':
        sys.exit(run_windows(exe, work))
    sys.exit(run_unix(exe, work))


if __name__ == '__main__':
    if len(sys.argv) >= 3 and sys.argv[1] == '--inner':
        inner(sys.argv[2])
    else:
        main()
