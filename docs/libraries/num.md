# num — numeric functions over the numeric family

`engine/libs/PhosphorNumLib.pas` · 34 functions · always available

## What it is for

Arithmetic that the operators do not cover: sign and magnitude, rounding and
truncation, logarithms, trigonometry and its inverses, hyperbolics, angle
conversion, random numbers, and the two finiteness predicates. They are thin
wrappers over FPC's `Math` unit. Every argument is the **numeric family** — an
`int%` is widened to a Double on the way in — and every result is a number.

The design stance is the engine's: **a number that cannot be produced is an
error value, never a crash and never a poisoned result**. Three rules follow
from that, and they are the ones a caller would otherwise be surprised by.

**A domain is checked before the RTL sees it.** `ln(0)`, `log2(-1)`, `acos(2)`
answer a catchable runtime error whose message names the function, the value and
the domain it needed — `ln: 0 is outside the domain (needs a positive number)`.
Without the check these raised the RTL's own `Invalid floating point operation`,
which told a reader neither which call went wrong nor with what.

**A conversion that will not fit is an overflow, not an exception.** `round`,
`fix`, `cint` and `int` all produce an `int%`; an argument past Int64 range
answers error code `1` (integer overflow) with a message naming the function.

**No value in a running program is ever NaN or infinite.** That is an
engine-wide invariant, not a library one: when a library result comes back
non-finite the VM reports it at the call that produced it — `exp(1000)` answers
`exp has no finite result for those arguments`, code `1`, instead of putting an
infinity into a variable where some later operator would meet it. The practical
consequence is that `isnan` and `isinfinite` answer `0` for everything a
Phosphor program can hold; they are the guard on that invariant, not a test a
program can currently fail.

Every error here is an ordinary catchable one: with `on error goto` in force the
handler reads it through `err()` and `errmsg$()`, and the assignment that
produced it simply never completes — the variable keeps the value it had.

## Functions

### Sign, magnitude and comparison

| function | what it answers |
| --- | --- |
| `abs(n) → num` | absolute value. Always answers; the result is a Double, so an `int%` past 2^53 loses precision passing through |
| `sgn(n) → num` | `-1`, `0` or `1`. `sgn(0)` is `0` — zero has no sign, and that is a third answer, not a failure |
| `sqr(n) → num` | square **root**, not square (decisions.md). A negative argument is a runtime error, `sqr of a negative number`; nothing is assigned |
| `min(a, b) → num` | the smaller of two, as a Double |
| `max(a, b) → num` | the larger of two, as a Double |
| `cmpval(a, b) → num` | `-1` when `a < b`, `1` when `a > b`, `0` when equal. A comparison that answers a number, for sorting |

### Rounding and truncation

All four answer an `int%`. A magnitude past Int64 range is error code `1`,
`number too large to convert to an integer (<fn>)`, and the call yields nothing.

| function | what it answers |
| --- | --- |
| `round(n) → num` | nearest integer, **ties to even**: `round(2.5)` is `2`, `round(3.5)` is `4`, `round(-2.5)` is `-2` |
| `fix(n) → num` | truncate **toward zero**: `fix(-3.7)` is `-3` |
| `cint(n) → num` | the same truncation as `fix` under the classic name — it truncates, it does not round |
| `int(n) → num` | floor, i.e. **downward**: `int(-3.7)` is `-4`. `int` and `fix` agree on positives and part on negatives |
| `frac(n) → num` | the fractional part, keeping the sign: `frac(-2.25)` is `-0.25`. Never errors |

### Logarithms and exponential

| function | what it answers |
| --- | --- |
| `log10(n) → num` | base-10 logarithm. Needs a strictly positive argument; `0` or negative is a domain error naming the value |
| `log2(n) → num` | base-2 logarithm, same domain rule |
| `ln(n) → num` | natural logarithm, same domain rule |
| `exp(n) → num` | e raised to `n`. Unbounded input: an argument large enough to overflow the Double answers the finiteness error (code `1`) rather than an infinity |

### Trigonometry and angles

Angles are **radians**. There is no pi constant in the engine; `degtorad(180)`
is the idiom the test corpus uses for it.

| function | what it answers |
| --- | --- |
| `sin(n) → num` | sine. Always answers |
| `cos(n) → num` | cosine. Always answers |
| `tan(n) → num` | tangent. Near a quarter turn it answers a very large **finite** number (a Double cannot land exactly on pi/2), never an infinity |
| `asin(n) → num` | arc sine, in `-pi/2 .. pi/2`. Outside `-1 .. 1` is a domain error naming the value |
| `acos(n) → num` | arc cosine, in `0 .. pi`. Same `-1 .. 1` domain rule |
| `atan(n) → num` | arc tangent, in `-pi/2 .. pi/2`. Accepts the whole line |
| `atan2(y, x) → num` | the angle of the vector `(x, y)` in `-pi .. pi` — note the argument order is **y first**. It knows the quadrant, which `atan(y / x)` cannot; `atan2(0, 0)` answers `0` rather than erroring |
| `degtorad(n) → num` | degrees → radians |
| `radtodeg(n) → num` | radians → degrees |

### Hyperbolic

| function | what it answers |
| --- | --- |
| `sinh(n) → num` | hyperbolic sine; a large argument overflows to the finiteness error, code `1` |
| `cosh(n) → num` | hyperbolic cosine, likewise |
| `tanh(n) → num` | hyperbolic tangent; bounded, always answers |
| `asinh(n) → num` | inverse hyperbolic sine; accepts the whole line |
| `acosh(n) → num` | inverse hyperbolic cosine. Needs `n >= 1`, but this is **not** one of the guarded domains: a smaller argument is a runtime error carrying the RTL's own `Invalid floating point operation`, which names neither the function nor the value |
| `atanh(n) → num` | inverse hyperbolic tangent. Needs strictly between `-1` and `1`, with the same unguarded, unnamed message outside it |

### Random

| function | what it answers |
| --- | --- |
| `randomize() → num` | reseed the generator from the clock, and answer `0`. There is no seed argument, so a program cannot reproduce a sequence on purpose |
| `rnd(n) → num` | a random `int%` in `0 .. n-1`. The bound is Int64 throughout, so a bound above 2^31 is honoured. `n < 1` is clamped to `1`, which means `rnd(0)` and `rnd(-5)` answer `0` every time instead of erroring |
| `rnd() → num` | a random Double in `[0, 1)` — never exactly `1` |

### Predicates

| function | what it answers |
| --- | --- |
| `isnan(n) → num` | `1` when `n` is NaN, else `0`. Under the finiteness invariant above, `0` for every value a program can hold |
| `isinfinite(n) → num` | `1` when `n` is infinite, else `0`; the same practical answer, for the same reason |

## A worked example

Great-circle distance and initial bearing between two points on Earth. It
converts degrees to radians once at the edge, and the clamp in the middle is the
interesting line.

```basic
rem Haversine distance in kilometres, and the bearing to walk.

function haversine(lat1, lon1, lat2, lon2) local a, dlat, dlon
  dlat = degtorad(lat2 - lat1)
  dlon = degtorad(lon2 - lon1)
  a = sin(dlat / 2) ^ 2 + cos(degtorad(lat1)) * cos(degtorad(lat2)) * sin(dlon / 2) ^ 2
  rem rounding can push a a hair past 1, and asin outside -1..1 is an error;
  rem min makes that impossible instead of catching it afterwards.
  return 2 * 6371.0088 * asin(sqr(min(a, 1)))
endfunction

function bearing(lat1, lon1, lat2, lon2) local x, y, dlon
  dlon = degtorad(lon2 - lon1)
  y = sin(dlon) * cos(degtorad(lat2))
  x = cos(degtorad(lat1)) * sin(degtorad(lat2)) - sin(degtorad(lat1)) * cos(degtorad(lat2)) * cos(dlon)
  return radtodeg(atan2(y, x))
endfunction

d = haversine(38.7223, -9.1393, 41.1579, -8.6291)   rem Lisbon -> Porto
println "distance " + str$(round(d)) + " km"
println "bearing  " + str$(round(bearing(38.7223, -9.1393, 41.1579, -8.6291))) + " deg"
println "further than 300 km? " + str$(cmpval(d, 300))
```

It prints a distance of `274` km and a bearing of `9` degrees, and the
comparison answers `-1` — Lisbon and Porto are nearer than 300 km apart.

Two things worth noticing:

- **`atan2` takes y before x.** That order is the C convention and it is what
  makes the quadrant recoverable; `atan(y / x)` would fold north-west onto
  south-east, silently.
- **`min(a, 1)` is not paranoia about crashes.** `asin` outside its domain is a
  perfectly catchable error here — clamping is just cheaper than an `on error`
  handler for a case that only exists because of floating-point rounding.

## Notes

- **`sqr` is square root.** It is the classic BASIC spelling and it catches
  every reader once. Squaring is the `^` operator: `n ^ 2`.
- **Integer overflow, division by zero and `^` belong to the operators**, not to
  this library — the compiler emits them and they are described in
  [language-reference.md](../language-reference.md). This page covers only what a
  program calls by name.
- **Parsing a string into a number is `val`**, in the string library. Nothing
  here reads text.
- The registry holds 35 entries for these 34 names: `rnd` is registered twice,
  once taking a bound and once taking nothing.
