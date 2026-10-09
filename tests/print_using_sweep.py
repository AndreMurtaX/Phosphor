#!/usr/bin/env python3
"""A GENERATED sweep of PRINT USING numeric fields against exact decimal
arithmetic -- every expected line derived from the value's own binary digits by
Python's decimal module, never from a run.

WHY IT EXISTS (2026-10-09). PRINT USING laid a Double out with FPC's
FloatToStrF(ffFixed, 18, ...), which from 1e256 up answers in EXPONENT form;
the formatter split "1.0E+300" at its '.' and printed `1` for 1e300 in a `#`
field, `%-1` for -1e300, and "  1.0E+300" in "###.##" -- a wrong number with no
overflow mark. And FloatToStrF caps the decimals at 18, so a field with 25 '#'
after the point printed 18. The hand-written goldens never went past 1e16 or
past 2 decimals. docs/proof-axes.md rule 0.1: a sweep is GENERATED, not chosen.

THE REFERENCE is the rule docs/language-reference.md states for PRINT USING,
computed on the EXACT value (Decimal(float) is exact):
  * the digits are the value's own up to its 17th significant digit, and every
    position past that prints as 0;
  * the value is rounded once, half away from zero, at whichever comes first:
    the 17th significant digit or the field's last decimal;
  * a field too narrow for the integer part (sign included) gets a leading '%'
    and then the whole of it;
  * never an exponent.
The layout around the digits (width, '+', trailing '-', ',' grouping) is the
one the same section documents.

THE GRID, crossed rather than sampled:
  * 1eK and -1eK for K = 0..308, each in "#" and "#." + N '#' for N = 1..60;
  * 1e-K and -1e-K for K = 1..323 (down into the subnormals), same 61 fields;
  * 3000 Doubles drawn from uniformly random BIT PATTERNS (seeded, so every
    run asks the same questions), finite ones only -- every exponent, both
    signs, subnormals included -- each in a field of random integer width,
    random decimals 0..60, and a random choice of leading '+', trailing '-'
    and ',' grouping.

Usage: print_using_sweep.py <phosphor> [--prove-failure]
  --prove-failure corrupts one expected line and must see the mismatch.
Exit 0 when every line matches; 1 with the first mismatches named; 2 on a bad
argument. Any other argument is refused, so a misspelt flag is not a silent
full run.
"""
import os
import random
import struct
import subprocess
import sys
import tempfile
from decimal import Decimal, ROUND_HALF_UP, getcontext

getcontext().prec = 2000          # every Double's exact expansion fits easily
SEED = 20261009


def fixed_text(a, frac):
    """A non-negative Decimal as fixed-point text with exactly `frac` decimals."""
    if a == 0:
        ip, fp = '0', ''
    else:
        p = a.adjusted() + 1                       # digits before the point
        cut = max(p - 17, -frac)                   # smallest place kept
        r = a.quantize(Decimal(1).scaleb(cut), rounding=ROUND_HALF_UP)
        s = format(r, 'f')
        ip, _, fp = s.partition('.')
    fp = (fp + '0' * frac)[:frac]
    return ip + ('.' + fp if frac > 0 else '')


def group(digits):
    out = []
    for i, ch in enumerate(reversed(digits)):
        if i and i % 3 == 0:
            out.append(',')
        out.append(ch)
    return ''.join(reversed(out))


def reference(spec, x):
    """What `print using spec; x` must print for one numeric field."""
    s = spec
    lead_plus = s.startswith('+')
    trail_minus = s.endswith('-')
    core = s[:-1] if trail_minus else s
    width = core.index('.') if '.' in core else len(core)
    frac = core[core.index('.') + 1:].count('#') if '.' in core else 0
    neg = x < 0
    text = fixed_text(abs(Decimal(x)), frac)
    ip, _, fp = text.partition('.')
    if ',' in core:
        ip = group(ip)
    trail = ''
    left = ''
    if trail_minus:
        trail = '-' if neg else ' '
    elif lead_plus:
        left = '-' if neg else '+'
    elif neg:
        left = '-'
    body = left + ip
    field = ' ' * (width - len(body)) + body if len(body) <= width else '%' + body
    if '.' in core:
        field += '.' + fp
    return field + trail


def literal(x):
    """How a mismatch names its value: Python's shortest round-trip text."""
    return repr(x).replace('e+', 'e')


def construction(x):
    """A BASIC expression that computes EXACTLY x, without a decimal literal.

    A decimal literal goes through the lexer's own text-to-Double conversion,
    and that is a second component under test: on 2026-10-09 the first run of
    this sweep found that `1e126` reads back as 1.0000000000000001e126 where the
    correctly rounded Double is 9.9999999999999992e125, so the reference and the
    program were not looking at the same number. Here x is m * 2^e with m an
    integer of at most 53 bits -- an integer literal, exact -- and mk() doubles
    or halves it e times. Every intermediate m * 2^j lies between m and x with
    the same significant bits, so each step is exact, down into the subnormals."""
    if x == 0:
        return '0'
    n, d = abs(x).as_integer_ratio()
    if d == 1:
        e = (n & -n).bit_length() - 1
        m = n >> e
    else:
        m, e = n, -(d.bit_length() - 1)
    assert m < 2 ** 53 and m * Decimal(2) ** e == abs(Decimal(x))
    return 'mk(%s%d, %d)' % ('-' if x < 0 else '', m, e)


def build():
    """(program text, [(spec, value, expected), ...]) in output order."""
    lines = []
    cases = []
    fields = ['#'] + ['#.' + '#' * n for n in range(1, 61)]
    lines.append('function mk(m, e) local i, x')
    # + 0.0: an integer literal stays an int% in an unsuffixed name, and
    # doubling it past 2^63 is an integer overflow, not a Double.
    lines.append('  x = m + 0.0')
    lines.append('  for i = 1 to e')
    lines.append('    x = x * 2')
    lines.append('  next')
    lines.append('  for i = 1 to 0 - e')
    lines.append('    x = x / 2')
    lines.append('  next')
    lines.append('  return x')
    lines.append('endfunction')
    lines.append('function sw(x) local n, f$')
    lines.append('  println using "#"; x')
    lines.append('  f$ = "#."')
    lines.append('  for n = 1 to 60')
    lines.append('    f$ = f$ + "#"')
    lines.append('    println using f$; x')
    lines.append('  next')
    lines.append('  return 0')
    lines.append('endfunction')

    def grid(x):
        lines.append('z = sw(%s)' % construction(x))
        for f in fields:
            cases.append((f, x, reference(f, x)))

    for k in range(0, 309):
        grid(float('1e%d' % k))
        grid(-float('1e%d' % k))
    for k in range(1, 324):
        grid(float('1e-%d' % k))
        grid(-float('1e-%d' % k))

    rng = random.Random(SEED)
    drawn = 0
    while drawn < 3000:
        bits = rng.getrandbits(64)
        x = struct.unpack('<d', struct.pack('<Q', bits))[0]
        if x != x or x in (float('inf'), float('-inf')):
            continue
        drawn += 1
        w = rng.randint(1, 25)
        n = rng.randint(0, 60)
        sign = rng.choice(['', 'lead', 'trail'])
        intpart = '#' * w
        if rng.random() < 0.3 and w >= 2:
            intpart = '#,' + '#' * (w - 2)      # grouping; the ',' is a column
        spec = ('+' if sign == 'lead' else '') + intpart
        if n > 0:
            spec += '.' + '#' * n
        if sign == 'trail':
            spec += '-'
        lines.append('println using "%s"; %s' % (spec, construction(x)))
        cases.append((spec, x, reference(spec, x)))
    return '\n'.join(lines) + '\n', cases


def main(argv):
    prove = False
    exe = None
    for a in argv[1:]:
        if a == '--prove-failure':
            prove = True
        elif a.startswith('-') or exe is not None:
            print('print_using_sweep.py: unknown argument %r' % a)
            print('usage: print_using_sweep.py <phosphor> [--prove-failure]')
            return 2
        else:
            exe = a
    if exe is None:
        print('usage: print_using_sweep.py <phosphor> [--prove-failure]')
        return 2
    src, cases = build()
    if prove:
        spec, x, exp = cases[0]
        cases[0] = (spec, x, exp + 'X')            # one expectation corrupted
    # Two named temporary FILES, each removed by name -- never a directory and
    # never anything recursive (CLAUDE.md: this tree has lost working copies to
    # recursive removal).
    fd, bas = tempfile.mkstemp(prefix='pusweep', suffix='.bas')
    os.close(fd)
    fd, out = tempfile.mkstemp(prefix='pusweep', suffix='.out')
    os.close(fd)
    try:
        with open(bas, 'w', newline='\n') as f:
            f.write(src)
        try:
            r = subprocess.run([exe, 'run', bas, '--out', out],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=120)
        except subprocess.TimeoutExpired:
            print('FAIL  print using sweep: the program did not finish in 120 s')
            return 1
        if r.returncode != 0:
            print('FAIL  print using sweep: phosphor exited %d' % r.returncode)
            print(r.stderr.decode('utf-8', 'replace')[:2000])
            return 1
        with open(out, 'rb') as f:
            got = f.read().decode('ascii').split('\n')
    finally:
        for p in (bas, out):
            try:
                os.remove(p)
            except OSError:
                pass
    if got and got[-1] == '':
        got.pop()
    bad = 0
    if len(got) != len(cases):
        print('FAIL  print using sweep: %d lines, expected %d' % (len(got), len(cases)))
        bad += 1
    for i, (spec, x, exp) in enumerate(cases):
        line = got[i] if i < len(got) else '<missing>'
        if line != exp:
            bad += 1
            if bad <= 12:
                print('  MISMATCH  print using "%s"; %s' % (spec, literal(x)))
                print('    expected %s' % exp)
                print('    got      %s' % line)
    if prove:
        if bad:
            print('ProveFailure: print using sweep caught the corrupted expectation')
            return 0
        print('ProveFailure: print using sweep did NOT catch a corrupted expectation')
        return 1
    if bad:
        print('FAIL  print using sweep: %d of %d lines differ' % (bad, len(cases)))
        return 1
    print('PASS  print using sweep  (%d fields, exact decimal reference)' % len(cases))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
