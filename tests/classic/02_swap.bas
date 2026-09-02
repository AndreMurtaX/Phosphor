rem SWAP -- scalars, strings, and @-array elements.
a% = 10
b% = 20
swap a%, b%
println "ints: "; a%; " "; b%

x$ = "left"
y$ = "right"
swap x$, y$
println "strs: "; x$; " "; y$

p = 1.5
q = 9.5
swap p, q
println "reals: "; p; " "; q

v@ = dim@(3)
arr_set(v@, 1, 100)
arr_set(v@, 2, 200)
arr_set(v@, 3, 300)
swap v@[1], v@[3]
println "array: "; v@[1]; " "; v@[2]; " "; v@[3]

rem swap inside a function, over locals
function demo() local m, n
  m = 7
  n = 8
  swap m, n
  return m * 10 + n
endfunction
println "locals: "; demo()
