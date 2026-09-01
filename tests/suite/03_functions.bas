rem ---------------------------------------------------------------
rem User defined functions: arguments, locals, recursion, and the
rem three return kinds (numeric, string, pointer).
rem ---------------------------------------------------------------

function double(n)
  return n * 2
endfunction

function addthree(a, b, c)
  return a + b + c
endfunction

function greet$(name$)
  return "hello " + name$
endfunction

function fact(n) local r
  if n <= 1 then return 1
  r = fact(n - 1)
  return n * r
endfunction

function fib(n) local a, b
  if n < 2 then return n
  a = fib(n - 1)
  b = fib(n - 2)
  return a + b
endfunction

rem locals must not leak into the caller's scope
function uses_local() local counter
  counter = 999
  return counter
endfunction

function mixed$(n, sep$) local out$
  out$ = sep$ + stri$(n) + sep$
  return out$
endfunction

function makearray@(size) local a@
  a@ = dim@(size)
  narr_set@(a@, 1, 11)
  return a@
endfunction

test_case("func/numeric")
assert_eq(double(21), 42)
assert_eq(double(0), 0)
assert_eq(double(-3), -6)

test_case("func/multiple-args")
assert_eq(addthree(1, 2, 3), 6)
assert_eq(addthree(-1, 1, 0), 0)

test_case("func/string-return")
assert_eq(greet$("world"), "hello world")
assert_eq(greet$(""), "hello ")

test_case("func/recursion")
assert_eq(fact(0), 1)
assert_eq(fact(1), 1)
assert_eq(fact(5), 120)
assert_eq(fact(10), 3628800)

test_case("func/double-recursion")
assert_eq(fib(0), 0)
assert_eq(fib(1), 1)
assert_eq(fib(10), 55)

test_case("func/local-isolation")
counter = 1
r = uses_local()
assert_eq(r, 999, "function sees its own local")
assert_eq(counter, 1, "caller's variable is untouched")

test_case("func/mixed-args")
assert_eq(mixed$(7, "|"), "|7|")

test_case("func/pointer-return")
a@ = makearray@(4)
assert_eq(narr_get(a@, 1), 11)
assert_eq(ubound(a@, 1), 4)

test_case("func/nested-calls")
assert_eq(double(double(5)), 20)
assert_eq(addthree(double(1), double(2), double(3)), 12)
