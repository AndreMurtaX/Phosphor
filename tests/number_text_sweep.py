#!/usr/bin/env python3
"""A GENERATED sweep of decimal text read into a Double, at every door the
engine reads number text through -- each expected answer from Python's float(),
which is correctly rounded (IEEE 754 round-half-even, like every libc strtod),
never from a run of Phosphor.

WHY IT EXISTS (2026-10-09). The engine read number text with FPC 3.2.2's Val,
which rounds once with an inexact cached power of ten and no correction step
(rtl/inc/flt_core.inc, compiled because FLOAT_ASCII_FALLBACK is off): `1e126`
read as 5A17A2ECC414A040 where the correctly rounded Double is ...03F, and about
7 in 20000 random literals came back one ulp off. And Val goes through a
ShortString, so val(), isnumeric() and `input #` refused any number text past
255 bytes and read only up to an embedded NUL. docs/language-reference.md
("Number text") now states the grammar and the rounding; this checks both.

THE GRAMMAR (the reference for which strings are numbers, and where a refused
one stops -- written from the documented rule, not from the engine):
    [sign] ( digits [ "." [digits] ] | "." digits ) [ (e|E) [sign] digits ]
val() and isnumeric() first strip space, tab, CR, LF, VT and FF from both ends
-- nothing else, so a NUL anywhere makes the text not a number. A refused text
stops at the first byte that does not fit, or one past the end when the text
ends too soon; valcode() reports that position.

FOUR DOORS, three of them over one list of strings:
  A. val() and isnumeric() -- every string, valid or not. Each line prints the
     Double's 64 bits as a signed integer; "O" when the text is a number too
     large for a Double (val faults, isnumeric says 0); "N<stop>:0" when it is
     not a number at all.
  B. `input #` (CoerceField) -- every string that is one field on its own line,
     read as number text after val()'s trim: bits, "O" for an out-of-range
     number, "E" for "is not a number".
  C. numeric literals in source (the lexer) -- the strings spelled the way a
     literal is (no sign, a digit first, a digit after any "."), finite ones.
  D. the WRITER: str$ of 100000 random finite bit patterns, every power of ten
     and of two in range, and the edges. Its text must be number text that
     float() reads back as exactly that Double, and val() must agree -- the
     round trip docs/libraries/str.md promises to every correctly rounded
     reader, not only this engine's.

THE LIST, generated and seeded (every run asks the same questions):
  * random digit strings, 1..40 digits, a "." anywhere or nowhere, exponents
    across and past the whole Double range, every sign and exponent spelling;
  * EXACT MIDPOINTS between random adjacent Doubles (subnormals included), each
    written out in full -- up to ~770 significant digits, far past 255 bytes --
    and the same nudged a hair above and below;
  * Python's shortest repr, and %.17g / %.15g, of random bit patterns;
  * integers past 2^53 and past Int64;
  * the subnormal and DBL_MAX boundaries, each side of each midpoint;
  * the three literals the finding named; huge digit strings; exponents far out
    of range ("1e-99999999999999999999", "0e99999999999"); "-0" and its kin;
  * strings that are NOT numbers, including a NUL inside, at the start and at
    the end.

Usage: number_text_sweep.py <phosphor> [--prove-failure]
  --prove-failure corrupts one expectation in each door and must see all three
  mismatches. Exit 0 when every line matches; 1 with the first mismatches named;
  2 on a bad argument. Any other argument is refused, so a misspelt flag is not
  a silent full run.
"""
import math
import os
import random
import struct
import subprocess
import sys
import tempfile
from decimal import Decimal, getcontext

getcontext().prec = 3000          # every midpoint below is exact at this precision
SEED = 20261009
WS = b' \t\r\n\x0b\x0c'          # what val() and isnumeric() trim, both ends
DIG = b'0123456789'


def stop_pos(t):
    """0 when bytes t are number text; else the 1-based position of the first
    byte that does not fit (one past the end when the text ends too soon)."""
    n = len(t)
    p = 0
    if p < n and t[p] in b'+-':
        p += 1
    a = p
    while p < n and t[p] in DIG:
        p += 1
    nint = p - a
    nfrac = 0
    if p < n and t[p] == ord('.'):
        p += 1
        b = p
        while p < n and t[p] in DIG:
            p += 1
        nfrac = p - b
    if nint + nfrac == 0:
        return p + 1
    if p < n and t[p] in b'eE':
        p += 1
        if p < n and t[p] in b'+-':
            p += 1
        if not (p < n and t[p] in DIG):
            return p + 1
        while p < n and t[p] in DIG:
            p += 1
    if p < n:
        return p + 1
    return 0


def bits_of(x):
    return struct.unpack('<q', struct.pack('<d', x))[0]


def value_of(t):
    """The correctly rounded Double of valid number text t (bytes): float() is
    the oracle. Python's float() takes a superset of the grammar, so it is only
    asked about text the grammar above has already accepted."""
    return float(t.decode('ascii'))


def is_literal(t):
    """Spelled the way the lexer reads a literal: a digit first, no sign, a
    digit after any '.'."""
    if not t or t[0] not in DIG or stop_pos(t) != 0:
        return False
    i = t.find(b'.')
    return i < 0 or (i + 1 < len(t) and t[i + 1] in DIG)


def dec_text(d, rng):
    """An exact Decimal as number text, in one of several spellings."""
    sign, digits, exp = d.as_tuple()
    ds = ''.join(map(str, digits))
    form = rng.random()
    if form < 0.5:
        s = ds + 'e' + str(exp)
    elif form < 0.8:
        k = rng.randint(1, len(ds))                 # d.ddd form
        s = ds[:k] + '.' + ds[k:] + 'E' + str(exp + len(ds) - k)
    else:
        if exp >= 0:
            s = ds + '0' * exp
        else:
            pad = -exp - len(ds)
            s = ('0.' + '0' * pad + ds) if pad >= 0 else (ds[:pad] + '.' + ds[pad:])
    return ('-' if sign else '') + s


def rand_double(rng, allow_sub=True):
    while True:
        b = rng.getrandbits(64)
        x = struct.unpack('<d', struct.pack('<Q', b))[0]
        if math.isfinite(x) and (allow_sub or x == 0 or abs(x) >= 2.2250738585072014e-308):
            return x


def build_strings():
    rng = random.Random(SEED)
    out = []

    def add(s):
        out.append(s.encode('latin-1') if isinstance(s, str) else s)

    # 1. random digit strings
    for _ in range(150000):
        nd = rng.choice([1, 2, 3, 5, 8, 12, 15, 16, 17, 18, 19, 20, 22, 25, 30, 40])
        nd = rng.randint(1, nd)
        ds = ''.join(rng.choice('0123456789') for _ in range(nd))
        f = rng.random()
        if f < 0.35:
            m = ds
        else:
            k = rng.randint(0, nd)
            m = ds[:k] + '.' + ds[k:]
        if rng.random() < 0.75:
            e = rng.randint(-345, 330)
            es = rng.choice(['', '+']) if e >= 0 else '-'
            es += ('0' * rng.choice([0, 0, 0, 1, 3])) + str(abs(e))
            m += rng.choice('eE') + es
        add(rng.choice(['', '', '-', '+']) + m)

    # 2. exact midpoints between adjacent Doubles, and a hair either side
    for _ in range(25000):
        x = abs(rand_double(rng))
        y = math.nextafter(x, math.inf)
        if not math.isfinite(y):
            continue
        mid = (Decimal(x) + Decimal(y)) / 2
        _, digits, exp = mid.as_tuple()
        up = mid + Decimal(1).scaleb(exp - 3)
        down = mid - Decimal(1).scaleb(exp - 3)
        sg = rng.choice(['', '-'])
        for d in (mid, up, down):
            add(sg + dec_text(d, rng))

    # 3. what other writers spell
    for _ in range(20000):
        x = rand_double(rng)
        add(repr(x))
        add('%.17g' % x)
        add('%.15g' % x)

    # 4. integers: past 2^53, past Int64, and plain small ones
    for _ in range(10000):
        k = rng.choice([1, 10, 16, 17, 18, 19, 20, 25, 40])
        v = rng.randint(0, 10 ** k)
        add(rng.choice(['', '-']) + str(v))
    for v in (2 ** 53, 2 ** 53 + 1, 2 ** 53 + 3, 2 ** 63 - 1, 2 ** 63, 2 ** 63 + 1, 2 ** 64,
              9223372036854775807, 9223372036854775808, 18446744073709551616):
        add(str(v))
        add('-' + str(v))

    # 5. the three the finding named, and the subnormal / DBL_MAX boundaries
    for s in ('1e126', '57311.8821011', '6.20035e28', '1E126', '-1e126'):
        add(s)
    tiny = Decimal(2) ** -1074                     # smallest subnormal
    for k in (0, 1, 2, 3, 4503599627370495, 4503599627370496):
        lo = tiny * k
        for d in (lo, lo + tiny / 2, lo + tiny / 2 + Decimal(1).scaleb(-1100),
                  lo + tiny / 2 - Decimal(1).scaleb(-1100), lo + tiny):
            if d > 0:
                add(dec_text(d, rng))
    for s in ('4.9406564584124654e-324', '2.4703282292062327e-324', '2.4703282292062328e-324',
              '2.47032822920623272e-324', '5e-324', '3e-324', '2e-324', '1e-324', '1e-325',
              '2.2250738585072014e-308', '2.2250738585072011e-308', '2.2250738585072012e-308',
              '2.225073858507201136057409796709131975934819546351645648e-308'):
        add(s)
    dmax = Decimal(2) ** 1024 - Decimal(2) ** 971   # DBL_MAX
    half = Decimal(2) ** 970                       # half its ulp
    for d in (dmax, dmax + half, dmax + half - 1, dmax + half + 1, dmax - half, dmax + 2 * half):
        add(dec_text(d, rng))
        add(str(int(d)))
    for s in ('1.7976931348623157e308', '1.7976931348623158e308', '1.7976931348623159e308',
              '1.797693134862315807e308', '1.797693134862315808e308', '1e308', '1e309', '2e308'):
        add(s)

    # 6. huge digit strings and far exponents
    for k in (256, 300, 1000, 5000):
        add('1' * k)
        add('0' * k + '1')
        add('0.' + '0' * k + '1e' + str(k))
        add('1' + '0' * k + 'e-' + str(k))
        add('9' * k + 'e-' + str(k - 3))
    for s in ('1e-99999999999999999999', '1e99999999999999999999', '0e99999999999',
              '-0e99999999999', '123e-99999999999999999999', '0.0000e-99999999999',
              '1e-400', '1e400', '-1e400', '1e+0000000000000000000000000000010'):
        add(s)

    # 7. zeros
    for s in ('0', '-0', '+0', '-0.0', '0.0', '-0e5', '-.0', '-0.', '00000', '-00000', '.0', '0.'):
        add(s)

    # 8. not numbers -- every way the grammar can refuse
    for s in ('', '.', '-', '+', '+.', '-.', 'e5', '.e5', '1e', '1e+', '1e-', '1E+x', '1.2.3',
              '1..2', '--1', '+-1', '1e5.5', '1ee5', 'inf', 'nan', 'Infinity', '-inf',
              '1_000', '1,5', '1d5', '12abc', 'abc', '0x', '1 2', '- 1', '1e 5',
              '1\x002', '\x001', '1\x00', '\x00', '5.\x00', '1e\x005', '\xd9\xa1'):
        add(s)
    # a long refused one: past 255 bytes, refused at its last byte
    add('1' * 300 + 'x')
    # surrounding whitespace val() trims, and what it does not
    for s in (' 1.5', '1.5 ', '\t2\t', '\x0b3\x0c', ' \t 4e1 \t ', ' - 5', '\x017'):
        add(s)
    return out


def classify(t):
    """(stop, value-or-None) for door A, which trims WS first."""
    u = t.strip(WS)
    sp = stop_pos(u)
    if sp:
        return sp, None
    return 0, value_of(u)


def expect_a(t):
    sp, v = classify(t)
    if sp:
        return 'N%d:0' % sp
    if math.isinf(v):
        return 'O'
    return str(bits_of(v))


def field_ok(t):
    """Can t stand alone as one `input #` field on its own line? (No blank,
    comma, quote or line break in it, not empty, and not a radix-prefixed
    integer -- `input #` still reads $FF, &17, %101 and 0x1F as integers; that
    is pinned in tests/suite/84_number_text.bas, not here.)"""
    if not t or any(c in b' \t\r\n,"' for c in t):
        return False
    u = t.lstrip(b'+-')
    return not (u[:1] in (b'$', b'&', b'%') or u[:2].lower() == b'0x')


def expect_b(t):
    """A numeric field is read as number text after the same trim val() makes
    (a console field keeps its leading blanks, so the reader trims them)."""
    u = t.strip(WS)
    if stop_pos(u):
        return 'E'
    v = value_of(u)
    return 'O' if math.isinf(v) else str(bits_of(v))


def bas_str(path):
    """A path as a BASIC string literal: a backslash there is an escape."""
    return '"' + path.replace(chr(92), chr(92) * 2) + '"'


def writer_values():
    """Bit patterns for door D: random finite Doubles of every exponent, the
    powers of ten and of two across the range, and the edges."""
    rng = random.Random(SEED + 1)
    qs = []
    while len(qs) < 100000:
        q = rng.getrandbits(64)
        if (q >> 52) & 0x7FF == 0x7FF:
            continue                               # NaN / Inf: no number has them
        qs.append(q)
    for k in range(-323, 309):
        qs.append(bits_of(float('1e%d' % k)) & (2 ** 64 - 1))
    for k in range(-1074, 1024):
        qs.append(bits_of(2.0 ** k) & (2 ** 64 - 1))
    qs += [1, 2, 3, 0x000FFFFFFFFFFFFF, 0x0010000000000000, 0x7FEFFFFFFFFFFFFF,
           0x3FB999999999999A, 0x3FD3333333333334, 0x4009_21FB_5444_2D18, 0]
    out = []
    for q in qs:
        s = q - 2 ** 64 if q >= 2 ** 63 else q     # the signed Int64 of the bits
        if s != -2 ** 63:                          # -0.0: no int literal spells it
            out.append(s)
    return out


def writer_ok(q, line):
    """str$(x) must be number text that EVERY correctly rounded reader -- here
    Python's float() -- reads back as x, and the engine's own val() must agree."""
    text, _, back = line.partition(' ')
    t = text.encode('latin-1')
    return stop_pos(t) == 0 and bits_of(value_of(t)) == q and back == str(q)


def build(strings, pa, pb):
    """(program text, file A bytes, file B bytes, expected lines)."""
    a_lines = [t for t in strings if b'\r' not in t and b'\n' not in t]
    b_lines = [t for t in a_lines if field_ok(t)]
    lits = [t for t in a_lines if is_literal(t) and not math.isinf(value_of(t))]
    wq = writer_values()
    expected = [('A', t, expect_a(t)) for t in a_lines]
    expected += [('B', t, expect_b(t)) for t in b_lines]
    expected += [('C', t, str(bits_of(value_of(t)))) for t in lits]
    expected += [('D', str(q).encode(), q) for q in wq]
    prog = [
        'b@ = buffer_new@(8)',
        'function bits%(x) local z',
        '  z = buffer_setdbl(b@, 1, x)',
        '  return buffer_getint(b@, 1, 8)',
        'endfunction',
        'function wr(q%) local z, x, s$',
        '  z = buffer_setint(b@, 1, 8, q%)',
        '  x = buffer_getdbl(b@, 1)',
        '  s$ = str$(x)',
        '  println s$; " "; bits%(val(s$))',
        '  return 0',
        'endfunction',
        'fa$ = ' + bas_str(pa),
        'fb$ = ' + bas_str(pb),
        'on error goto h',
        'open fa$ for input as #1',
        'mode = 1',
        'while not eof(1)',
        '  line input #1, s$',
        '  if isnumeric(s$) = 1 then',
        '    r$ = str$(bits%(val(s$)))',
        '  else',
        '    r$ = "N"',
        '    v = val(s$)',
        '    if r$ = "N" then r$ = "N" + str$(valcode()) + ":" + str$(v)',
        '  endif',
        '  println r$',
        'wend',
        'close #1',
        'mode = 2',
        'open fb$ for input as #2',
        'while not eof(2)',
        '  r$ = ""',
        '  input #2, x',
        '  if r$ = "" then r$ = str$(bits%(x))',
        '  println r$',
        'wend',
        'close #2',
        'on error goto 0',
    ]
    for t in lits:
        prog.append('println bits%(' + t.decode('ascii') + ')')
    for q in wq:
        prog.append('z = wr(%d)' % q)
    prog += [
        'end',
        'h:',
        '  if mode = 1 then',
        '    r$ = "O"',
        '  elseif instr(errmsg$(), "out of range") > 0 then',
        '    r$ = "O"',
        '  else',
        '    r$ = "E"',
        '  endif',
        '  resume next',
    ]
    return ('\n'.join(prog) + '\n', b'\n'.join(a_lines) + b'\n',
            b'\n'.join(b_lines) + b'\n', expected)


def show(t):
    r = repr(t)[2:-1]
    return r if len(r) <= 90 else r[:60] + '...(%d bytes)...' % len(t) + r[-20:]


def main(argv):
    prove = False
    exe = None
    for a in argv[1:]:
        if a == '--prove-failure':
            prove = True
        elif a.startswith('-') or exe is not None:
            print('number_text_sweep.py: unknown argument %r' % a)
            print('usage: number_text_sweep.py <phosphor> [--prove-failure]')
            return 2
        else:
            exe = a
    if exe is None:
        print('usage: number_text_sweep.py <phosphor> [--prove-failure]')
        return 2
    paths = []
    for suffix in ('.bas', '.a', '.b', '.out'):
        fd, p = tempfile.mkstemp(prefix='ntsweep', suffix=suffix)
        os.close(fd)
        paths.append(p)
    bas, pa, pb, out = paths
    src, fa, fb, cases = build(build_strings(), pa, pb)
    if prove:
        for door in 'ABCD':                      # one expectation corrupted per door
            i = next(k for k, c in enumerate(cases) if c[0] == door)
            exp = cases[i][2]
            cases[i] = (door, cases[i][1], exp + 'X' if door != 'D' else exp ^ 1)
    # Named temporary FILES (made above), each removed by name -- never a
    # directory and never anything recursive (CLAUDE.md: this tree has lost
    # working copies to one).
    try:
        with open(bas, 'w', newline='\n') as f:
            f.write(src)
        with open(pa, 'wb') as f:
            f.write(fa)
        with open(pb, 'wb') as f:
            f.write(fb)
        try:
            r = subprocess.run([exe, 'run', bas, '--out', out],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=300)
        except subprocess.TimeoutExpired:
            print('FAIL  number text sweep: the program did not finish in 300 s')
            return 1
        if r.returncode != 0:
            print('FAIL  number text sweep: phosphor exited %d' % r.returncode)
            print(r.stderr.decode('utf-8', 'replace')[:2000])
            return 1
        with open(out, 'rb') as f:
            got = f.read().decode('latin-1').split('\n')
    finally:
        for p in paths:
            try:
                os.remove(p)
            except OSError:
                pass
    if got and got[-1] == '':
        got.pop()
    bad = {'A': 0, 'B': 0, 'C': 0, 'D': 0}
    shown = 0
    if len(got) != len(cases):
        print('FAIL  number text sweep: %d lines, expected %d' % (len(got), len(cases)))
        bad['A'] += 1
    for i, (door, t, exp) in enumerate(cases):
        line = got[i] if i < len(got) else '<missing>'
        ok = writer_ok(exp, line) if door == 'D' else line == exp
        if not ok:
            bad[door] += 1
            if shown < 15:
                shown += 1
                print('  MISMATCH  door %s  %s' % (door, show(t)))
                if door == 'D':
                    print('    str$ of the Double with bits %d, read back by float() and by val()' % exp)
                else:
                    print('    expected %s' % exp)
                print('    got      %s' % line)
    total = sum(bad.values())
    counts = {d: sum(1 for c in cases if c[0] == d) for d in 'ABCD'}
    if prove:
        if all(bad[d] for d in 'ABCD'):
            print('ProveFailure: number text sweep caught the corrupted expectation in all four doors')
            return 0
        print('ProveFailure: number text sweep did NOT catch every corrupted expectation %r' % bad)
        return 1
    if total:
        print('FAIL  number text sweep: %d of %d lines differ (val/isnumeric %d, input # %d, '
              'literals %d, str$ round trip %d)'
              % (total, len(cases), bad['A'], bad['B'], bad['C'], bad['D']))
        return 1
    print('PASS  number text sweep  (%d cases: val/isnumeric %d, input # %d, literals %d, '
          'str$ round trip %d; Python float() reference)'
          % (len(cases), counts['A'], counts['B'], counts['C'], counts['D']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
