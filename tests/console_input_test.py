#!/usr/bin/env python3
"""Keys and lines TYPED into a real Windows console. Windows only.

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

No headless runner can reach either: both paths run only when stdin IS a
console. So this script starts a copy of itself in a NEW console
(CREATE_NEW_CONSOLE), which writes the keystrokes into that console's input
buffer with WriteConsoleInputW -- a key-down and a key-up per UTF-16 unit, as
a keyboard makes them -- and then runs the program there, stdout to a file.

EXPECTED VALUES are written out below from definitions, never from a run:
U+1F600 is D83D DE00 in UTF-16 and F0 9F 98 80 in UTF-8; U+FFFD is EF BF BD; a
line is everything up to the Enter, so its length is what was typed. INPUT
prints its "? " prompt to stdout, which is why each line of output starts so.

Usage: console_input_test.py <phosphor.exe>
Exit 0 pass, 1 fail, 2 the harness could not set a case up.
"""
import ctypes
import ctypes.wintypes as wt
import json
import os
import subprocess
import sys
import tempfile

if os.name != 'nt':
    print('SKIP  Windows only: a Unix terminal hands the program bytes, not UTF-16 units')
    sys.exit(0)

CREATE_NEW_CONSOLE = 0x10


class KEY_EVENT_RECORD(ctypes.Structure):
    _fields_ = [('bKeyDown', wt.BOOL), ('wRepeatCount', wt.WORD),
                ('wVirtualKeyCode', wt.WORD), ('wVirtualScanCode', wt.WORD),
                ('UnicodeChar', wt.WORD), ('dwControlKeyState', wt.DWORD)]


class EVENT(ctypes.Union):
    _fields_ = [('KeyEvent', KEY_EVENT_RECORD), ('pad', ctypes.c_byte * 16)]


class INPUT_RECORD(ctypes.Structure):
    _fields_ = [('EventType', wt.WORD), ('Event', EVENT)]


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


def inner(spec_path):
    """Runs inside the new console: type the keys, then run the program."""
    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    k32.CreateFileW.restype = wt.HANDLE
    with open(spec_path, encoding='utf-8') as f:
        spec = json.load(f)
    us = spec['units']
    h = k32.CreateFileW('CONIN$', 0xC0000000, 3, None, 3, 0, None)
    recs = (INPUT_RECORD * (2 * len(us)))()
    for i, (u, vk) in enumerate(us):
        for j, down in enumerate((1, 0)):
            r = recs[2 * i + j]
            r.EventType = 1                     # KEY_EVENT
            r.Event.KeyEvent.bKeyDown = down
            r.Event.KeyEvent.wRepeatCount = 1
            r.Event.KeyEvent.wVirtualKeyCode = vk
            r.Event.KeyEvent.UnicodeChar = u
    written = wt.DWORD(0)
    ok = k32.WriteConsoleInputW(h, recs, len(recs), ctypes.byref(written))
    with open(spec['out'], 'wb') as fo, open(spec['err'], 'wb') as fe:
        if not ok or written.value != len(recs):
            fe.write(('HARNESS: wrote %d of %d key events\n' % (written.value, len(recs))).encode())
            return
        try:
            p = subprocess.run([spec['exe'], spec['bas']], stdout=fo, stderr=fe,
                               timeout=spec['timeout'])
            fe.write(('exit %d\n' % p.returncode).encode())
        except subprocess.TimeoutExpired:
            fe.write(b'TIMEOUT (killed)\n')


def main():
    exe = os.path.abspath(sys.argv[1])
    work = tempfile.mkdtemp(prefix='phosphor-coninput-')
    failed = 0
    harness = 0

    def case(name, program, typed, want, timeout=20):
        nonlocal failed, harness
        bas = os.path.join(work, name + '.bas')
        with open(bas, 'w', newline='\n', encoding='utf-8') as f:
            f.write(program)
        spec = {'units': units(typed), 'exe': exe, 'bas': bas, 'timeout': timeout,
                'out': os.path.join(work, name + '.out'),
                'err': os.path.join(work, name + '.err')}
        sp = os.path.join(work, name + '.json')
        with open(sp, 'w', encoding='utf-8') as f:
            json.dump(spec, f)
        p = subprocess.Popen([sys.executable, '-I', os.path.abspath(__file__), '--inner', sp],
                             creationflags=CREATE_NEW_CONSOLE)
        try:
            p.wait(timeout + 30)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(10)
        try:
            got = open(spec['out'], 'rb').read().decode('utf-8', 'replace').replace('\r', '')
            err = open(spec['err'], 'rb').read().decode('utf-8', 'replace').strip()
        except OSError:
            got, err = None, 'no output files'
        if got is None or err.startswith('HARNESS'):
            print('HARNESS  %s: %s' % (name, err))
            harness += 1
        elif got == want and err.endswith('exit 0'):
            print('PASS  %s' % name)
        else:
            print('FAIL  %s: want %r, got %r (%s)' % (name, want, got, err.replace('\n', ' / ')))
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
    lines = ('input a$\nprintln str$(bytelen(a$)) + " " + hex_encode$(right$(a$, 3))\n'
             'input b$\nprintln str$(bytelen(b$)) + " " + hex_encode$(b$)\n')
    # A line longer than one read is still ONE line; the next INPUT gets the
    # next line. 10000 typed 'a' are 10000 bytes.
    case('line-long', lines, 'a' * 10000 + '\rz\r', '? 10000 616161\n? 1 7a\n', timeout=40)
    # A pair across the read boundary: 8191 'a' fill the buffer to its last
    # unit, the high half lands there and the low half in the next read. The
    # line is 8191 + 4 + 1 = 8196 bytes, ending a, U+1F600, b.
    case('line-pair-cut', lines, 'a' * 8191 + emoji + 'b\rz\r',
         '? 8196 61f09f988062\n? 1 7a\n', timeout=40)
    # A line that fills the buffer EXACTLY up to its CR: the LF is left for the
    # next read, and must not become an empty second line.
    case('line-cr-at-end', lines, 'a' * 8191 + '\rz\r', '? 8191 616161\n? 1 7a\n', timeout=40)

    if harness:
        sys.exit(2)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    if len(sys.argv) >= 3 and sys.argv[1] == '--inner':
        inner(sys.argv[2])
    else:
        main()
