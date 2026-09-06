rem ---------------------------------------------------------------
rem Size and depth: two ways a program could kill the interpreter
rem outright, with no message and nothing for `on error` to catch.
rem
rem 1. dim@ checked the element COUNT against Int64 and never the
rem    BYTE size. An element is a TValue -- 48 bytes, not 1 -- so
rem    dim@(2^30, 2^30) passed the count check (2^60 is a fine Int64)
rem    and then asked SetLength for 2^60 * 48 bytes, which is exactly
rem    0 modulo 2^64. The block came back near-empty while the array
rem    header still claimed 2^60 elements, and the fill loop wrote off
rem    the end of it: exit 0xC0000374, STATUS_HEAP_CORRUPTION, empty
rem    stdout, empty stderr. A wild write is not a Pascal exception,
rem    so the VM's try/except around library calls never saw it either.
rem
rem 2. json_parse@ had no nesting ceiling. fpjson parses recursively
rem    AND frees the tree recursively, so depth is spent on the process
rem    stack twice. 50000 levels parsed correctly, printed the right
rem    answer, and then died in teardown -- a correct run handing the
rem    shell 0xC0000005. 200000 never came back from the parse.
rem
rem Both are now refusals the program can catch, named after the limit
rem they crossed. The house rule (decisions.md): a library fault is an
rem error VALUE, never a process death -- Phosphor is embeddable, and a
rem crash takes the host's process with it.
rem ---------------------------------------------------------------

test_case("alloc/an array whose BYTE size wraps past Int64 is refused")
caught1% = 0
on error goto big1
a1@ = dim@(1073741824, 1073741824)
goto after1
big1:
caught1% = 1
resume next
after1:
on error goto 0
assert_eq(caught1%, 1, "2^60 elements x 48 bytes wrapped to a ~0-byte block and corrupted the heap before this")
assert_true(instr(errmsg$(), "array is too large") > 0, "and the refusal says so")
assert_true(instr(errmsg$(), "1152921504606846976") > 0, "naming the element count that crossed the limit")

test_case("alloc/the one-dimensional forms are refused the same way")
rem Reported twice, with different reproductions: dim@ with one huge count,
rem and pdim@/sdim@ with the same. One guard covers all of them because they
rem share DoDim -- but a fix that only ever ran on the two-argument path would
rem have looked just as green, so each spelling is pinned.
caught2% = 0
on error goto big2
a2@ = sdim@(4611686018427387904)
goto after2
big2:
caught2% = 1
resume next
after2:
on error goto 0
assert_eq(caught2%, 1, "sdim@ of 2^62 is a refusal, not a heap corruption")

caught3% = 0
on error goto big3
a3@ = pdim@(1152921504606846976)
goto after3
big3:
caught3% = 1
resume next
after3:
on error goto 0
assert_eq(caught3%, 1, "and pdim@ of 2^60 too")

test_case("alloc/a size that merely does not fit still says Out of memory")
rem The ceiling is the representable range, not a policy about how much memory
rem is reasonable. A count whose byte size is a perfectly good Int64 but larger
rem than the machine has must keep failing the way it always has -- through
rem SetLength raising, caught by the VM and reported as a value.
caught4% = 0
on error goto big4
a4@ = dim@(1000000000000)
goto after4
big4:
caught4% = 1
resume next
after4:
on error goto 0
assert_eq(caught4%, 1, "10^12 elements is still a catchable error")
assert_true(instr(errmsg$(), "array is too large") = 0, "but NOT the new refusal: 10^12 x 48 is a good Int64, so it fails on the allocation, exactly as it always did")

test_case("alloc/ordinary arrays are untouched by the size guard")
b@ = dim@(3, 4)
arr_set@(b@, 3, 4, 7)
assert_eq(narr_get(b@, 3, 4), 7, "an ordinary array still allocates and indexes")
assert_eq(arraysize(b@), 12, "and reports the size it was given")
c@ = sdim@(1000)
sarr_set@(c@, 1000, "last")
assert_eq(sarr_get$(c@, 1000), "last", "a thousand string elements are still fine")

test_case("alloc/json_parse@ refuses a document that nests past the ceiling")
rem 50000 is the depth that used to parse CORRECTLY and then crash while the
rem tree was freed -- the sharp half of the report, because the program was
rem right, its output was right, and it still handed the shell a crash status.
deep$ = mulstring$("[", 50000) + mulstring$("]", 50000)
caught5% = 0
on error goto deep5
d5@ = json_parse@(deep$)
goto after5
deep5:
caught5% = 1
resume next
after5:
on error goto 0
assert_eq(caught5%, 1, "a catchable error, not EStackOverflow escaping to the host")
assert_true(instr(errmsg$(), "nests more than 256 levels deep") > 0, "and it names the ceiling it crossed")

test_case("alloc/documents under the ceiling parse exactly as before")
rem Only NESTING counts, so a long FLAT document is unaffected however long it
rem gets -- the same distinction the compiler's expression ceiling makes.
ok$ = mulstring$("[", 256) + mulstring$("]", 256)
e@ = json_parse@(ok$)
assert_eq(json_typename$(e@), "array", "256 levels is inside the limit and still parses")
flat@ = json_parse@("[1,2,3,4,5,6,7,8,9,10]")
assert_eq(json_len(flat@), 10, "a flat array is not nesting")
rem Brackets inside a string literal are text, not structure: a scan that missed
rem that would refuse ordinary documents that nest no deeper than one level.
str@ = json_parse@("{\"a\": \"[[[[[[[[[[\"}")
assert_eq(json_gets$(str@, "a"), "[[[[[[[[[[", "ten brackets inside a string are ten characters")
