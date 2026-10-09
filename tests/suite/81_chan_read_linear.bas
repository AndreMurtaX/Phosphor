rem ---------------------------------------------------------------
rem A classic channel read costs what it reads: O(N), not O(N^2).
rem
rem Until 2026-10-09 ONE read that needed more than the window held was
rem quadratic inside a single VM instruction. The window grew by one
rem 64 KB chunk at a time with Buf := Buf + chunk -- a copy of everything
rem held so far, per chunk -- and LINE INPUT and INPUT rescanned the
rem whole window from the cursor after every chunk. Measured: one 64 MB
rem line took 28 s (8 MB 0.42 s, 16 MB 1.6 s, 32 MB 6.2 s -- four times
rem the time for twice the bytes), and one input$(128 MB) 30 s, while
rem the same bytes read as 1 MB input$ calls took 0.08 s.
rem
rem Each case reads one 32 MB run in ONE statement and is timed against
rem a control that reads the same file as 32 calls of 1 MB, which is
rem linear on both sides of the fix. The bound is 8x the control plus
rem 1.5 s: generous for a loaded machine, and the quadratic shape blew
rem it by seconds. The lengths are checked exactly, so a fast wrong
rem answer cannot pass either.
rem ---------------------------------------------------------------

f$ = "bin/phos_chan_linear.tmp"
g$ = "bin/phos_chan_linear_q.tmp"
rem 2^25 bytes: "a" doubled 25 times.
n = 33554432
s$ = "a"
for i = 1 to 25
  s$ = s$ + s$
next
assert_eq(len(s$), n, "the run is 2^25 bytes")

rem f$: the run as one line, then a short second line.
open f$ for output as #1
println #1, s$
println #1, "x"
close #1
rem g$: the run as ONE quoted field, then a numeric field.
open g$ for output as #1
println #1, chr$(34); s$; chr$(34); ",7"
close #1

test_case("chan/control: the same bytes as 1 MB input$ calls")
open f$ for input as #1
t0 = now()
got = 0
for i = 1 to 32
  got = got + len(input$(1048576, #1))
next
cms = millisecondsbetween(t0, now())
close #1
assert_eq(got, n, "32 reads of 1 MB read the whole run")
bound = 8 * cms + 1500

test_case("chan/line input of one 32 MB line")
open f$ for input as #1
t0 = now()
line input #1, l$
ms = millisecondsbetween(t0, now())
line input #1, after$
close #1
assert_eq(len(l$), n, "the whole line came back")
assert_eq(after$, "x", "and the next line after it")
assert_true(ms <= bound, "line input took " + str$(ms) + " ms; bound " + str$(bound))

test_case("chan/input of one 32 MB unquoted field")
open f$ for input as #1
t0 = now()
input #1, w$
ms = millisecondsbetween(t0, now())
close #1
assert_eq(len(w$), n, "the whole field came back")
assert_true(ms <= bound, "input took " + str$(ms) + " ms; bound " + str$(bound))

test_case("chan/input of one 32 MB quoted field")
open g$ for input as #1
t0 = now()
input #1, q$, k
ms = millisecondsbetween(t0, now())
close #1
assert_eq(len(q$), n, "the whole quoted field came back, quotes removed")
assert_eq(k, 7, "and the field after it")
assert_true(ms <= bound, "quoted input took " + str$(ms) + " ms; bound " + str$(bound))

rem input$ only paid the copying half, which is cheaper per byte: 32 MB took
rem 1.95 s before the fix and sat inside the bound, so this case reads 64 MB
rem (7.7 s before). Twice the bytes, so the control's half of the bound
rem doubles with it.
test_case("chan/one input$ of 64 MB")
l$ = ""
w$ = ""
q$ = ""
h$ = "bin/phos_chan_linear_b.tmp"
s$ = s$ + s$
open h$ for output as #1
print #1, s$
close #1
s$ = ""
open h$ for input as #1
t0 = now()
b$ = input$(2 * n, #1)
ms = millisecondsbetween(t0, now())
close #1
assert_eq(len(b$), 2 * n, "every byte asked for")
bound = 16 * cms + 1500
assert_true(ms <= bound, "input$ took " + str$(ms) + " ms; bound " + str$(bound))
b$ = ""

file_delete(f$)
file_delete(g$)
file_delete(h$)
