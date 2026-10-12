"""Prints the constants of the sin/cos fast path in engine/libs/PhosphorNumLib.pas
(see "THE FAST PATH" there), each spelled as the bit pattern of its Double.

    python scripts/gen-sincos-table.py

Nothing here touches floating point until the last step: pi comes from Machin's
formula in integers, sin and cos of j/64 from their Taylor series summed as
exact fractions to 2^-260, and each value becomes a Double by Python's
float(Fraction), which rounds correctly. A double-double is hi = that rounding,
lo = the rounding of what is left.

  CW_Q     2/pi; pi/2 as C1 + C2 + C3 (33 bits each, so n*Ci is exact for
           |n| < 2^20) + C4 (the Double nearest the rest); 2^-62.
  POLY_Q   -1/3!, 1/5!, -1/7!, 1/4!, -1/6!, each the nearest Double.
  SC_TAB   for j = 0 .. 50: sin(j/64) hi, lo, cos(j/64) hi, lo.
"""
import struct
from fractions import Fraction


def arctan_inv(x, prec):
    """arctan(1/x) * 2^prec, as an integer."""
    total = term = (1 << prec) // x
    x2, n, sign = x * x, 1, -1
    while term:
        term //= x2
        total += sign * (term // (2 * n + 1))
        sign, n = -sign, n + 1
    return total


PREC = 400
PI = Fraction(4 * (4 * arctan_inv(5, PREC) - arctan_inv(239, PREC)), 1 << PREC)
TINY = Fraction(1, 1 << 260)


def q(x):
    return '$%016X' % struct.unpack('<Q', struct.pack('<d', x))[0]


def exact(v):
    d = float(v)
    assert Fraction(d) == v, v
    return d


def top_bits(v, nbits):
    """v > 0 truncated to its leading nbits bits."""
    e = v.numerator.bit_length() - v.denominator.bit_length()
    while Fraction(2) ** e > v:
        e -= 1
    while Fraction(2) ** (e + 1) <= v:
        e += 1
    scale = Fraction(2) ** (nbits - 1 - e)
    return Fraction(int(v * scale)) / scale


def sin_cos(x):
    """sin x and cos x for a Fraction 0 <= x < 1, within TINY."""
    s = c = Fraction(0)
    term, k = Fraction(1), 0          # x^k / k!
    while abs(term) > TINY or k < 4:
        if k % 2 == 0:
            c += term if k % 4 == 0 else -term
        else:
            s += term if k % 4 == 1 else -term
        k += 1
        term = term * x / k
    return s, c


def dd(v):
    hi = float(v)
    return hi, float(v - Fraction(hi))


def wrap(vals, per):
    rows = []
    for i in range(0, len(vals), per):
        rows.append('    ' + ', '.join('QWord(%s)' % q(v) for v in vals[i:i + per]))
    return ',\n'.join(rows)


def main():
    pio2 = PI / 2
    parts, rest = [], pio2
    for _ in range(3):
        c = top_bits(rest, 33)
        parts.append(exact(c))
        rest -= c
    cw = [float(2 / PI)] + parts + [float(rest), exact(Fraction(1, 1 << 62))]
    print('  CW_Q: array[0..5] of QWord = (')
    print(wrap(cw, 3) + ');')
    poly = [Fraction(-1, 6), Fraction(1, 120), Fraction(-1, 5040),
            Fraction(1, 24), Fraction(-1, 720)]
    print('  POLY_Q: array[0..4] of QWord = (')
    print(wrap([float(v) for v in poly], 3) + ');')
    print('  SC_TAB: array[0..203] of QWord = (')
    rows = []
    for j in range(51):
        s, c = sin_cos(Fraction(j, 64))
        sh, sl = dd(s)
        ch, cl = dd(c)
        rows.append('    ' + ', '.join('QWord(%s)' % q(v) for v in (sh, sl, ch, cl))
                    + (');' if j == 50 else ',') + '   // %d/64' % j)
    print('\n'.join(rows))


if __name__ == '__main__':
    main()
