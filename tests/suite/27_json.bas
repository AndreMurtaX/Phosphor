rem ---------------------------------------------------------------
rem JsonLib. check-coverage.py reported 25/50: the scalar
rem constructors, the type predicates, arrays, paths and cloning had
rem never been run.
rem
rem Two conventions worth stating, because both are already documented
rem and neither is what a reader guesses:
rem
rem   * json_count is object keys ONLY. An array is counted by json_len,
rem     which handles both. json_count on an array answers zero, which
rem     reads exactly like an empty array.
rem   * item and path indices are 1-based, like the rest of this
rem     library's positional arguments.
rem ---------------------------------------------------------------

test_case("json/scalars")
rem Every JSON value is a handle, including the ones that hold a single
rem thing. That is what lets them be pushed into arrays and set into
rem objects without a second set of functions.
n@ = json_null@()
assert_true(json_isnull(n@), "json_null@ answers a null")
assert_eq(json_typename$(n@), "null", "and names itself")

b@ = json_bool@(1)
assert_true(json_isbool(b@), "json_bool@ answers a boolean")
assert_eq(json_value(b@), 1, "json_value reads it as a number")

num@ = json_number@(42.5)
assert_true(json_isnum(num@), "json_number@ answers a number")
assert_near(json_value(num@), 42.5, 0.0001, "json_value reads it")

s@ = json_string@("text")
assert_true(json_isstr(s@), "json_string@ answers a string")
assert_eq(json_value$(s@), "text", "json_value$ reads it")

test_case("json/type-codes")
rem json_type answers a code and json_typename$ the name for the same
rem value, so the two have to agree on every kind.
o@ = json_object@()
a@ = json_array@()
differ = 0
if json_type(o@) <> json_type(a@) then differ = 1
assert_true(differ, "an object and an array are different types")
assert_eq(json_typename$(o@), "object", "and each names itself")
assert_eq(json_typename$(a@), "array", "both of them")

test_case("json/object-writes")
json_sets@(o@, "name", "Alice")
json_setn@(o@, "age", 30)
json_setb@(o@, "member", 1)
json_setnull@(o@, "middle")

assert_eq(json_gets$(o@, "name"), "Alice", "a string reads back")
assert_eq(json_getn(o@, "age"), 30, "a number reads back")
assert_true(json_getb(o@, "member"), "a boolean reads back")
assert_true(json_has(o@, "middle"), "a null key is still a key")
assert_true(json_isnull(json_get@(o@, "middle")), "and what is under it is null")
assert_eq(json_count(o@), 4, "json_count counts the object's keys")

rem json_set@ takes a handle, which is how a nested object is built.
inner@ = json_object@()
json_sets@(inner@, "city", "Lisbon")
json_set@(o@, "address", inner@)
assert_eq(json_gets$(json_get@(o@, "address"), "city"), "Lisbon", "a nested object reads through")

test_case("json/defaults")
rem The two-argument getters answer a default rather than zero when the
rem key is absent, which is the difference between missing and empty.
assert_eq(json_getn(o@, "absent", 99), 99, "a missing number answers the default")
assert_eq(json_gets$(o@, "absent", "none"), "none", "and a missing string")

test_case("json/keys-and-removal")
k@ = json_keys@(o@)
assert_true(json_isarr(k@), "json_keys@ answers an array")
assert_eq(json_len(k@), 5, "with one entry per key")

json_remove@(o@, "middle")
assert_false(json_has(o@, "middle"), "json_remove@ takes a key out")
assert_eq(json_count(o@), 4, "and the count follows")

test_case("json/arrays")
json_pushs@(a@, "first")
json_pushn@(a@, 2)
json_pushb@(a@, 1)
json_pushnull@(a@)
assert_eq(json_len(a@), 4, "json_len counts an array")
assert_eq(json_count(a@), 0, "json_count, which is object keys, says nothing about one")

assert_eq(json_items$(a@, 1), "first", "json_items$ reads by position")
assert_eq(json_itemn(a@, 2), 2, "json_itemn too")
assert_true(json_itemb(a@, 3), "and json_itemb")
assert_true(json_isnull(json_item@(a@, 4)), "json_item@ answers the handle itself")

assert_eq(json_itemn(a@, 10, 77), 77, "an index past the end answers the default")
assert_eq(json_items$(a@, 10, "none"), "none", "for strings as well")

rem json_push@ takes a handle, so an object goes into an array whole.
row@ = json_object@()
json_sets@(row@, "k", "v")
json_push@(a@, row@)
assert_eq(json_len(a@), 5, "json_push@ appends a handle")
assert_eq(json_gets$(json_item@(a@, 5), "k"), "v", "which reads back as what it was")

json_removeat@(a@, 1)
assert_eq(json_len(a@), 4, "json_removeat@ takes one out by position")
assert_eq(json_itemn(a@, 1), 2, "and the rest shift down")

json_pop@(a@)
assert_eq(json_len(a@), 3, "json_pop@ takes the last one off")

test_case("json/paths")
rem A path walks nested objects with dots, which is the whole reason it
rem exists: json_get@ would need one call per level.
deep@ = json_parse@("{\"a\":{\"b\":{\"n\":7,\"s\":\"x\",\"f\":true}}}")
assert_true(pnttonum(deep@), "json_parse@ answers a handle")
assert_eq(json_pathn(deep@, "a.b.n"), 7, "json_pathn walks to a number")
assert_eq(json_paths$(deep@, "a.b.s"), "x", "json_paths$ to a string")
assert_true(json_pathb(deep@, "a.b.f"), "json_pathb to a boolean")
assert_true(json_isobj(json_path@(deep@, "a.b")), "json_path@ to the value itself")

assert_eq(json_pathn(deep@, "a.b.missing", 5), 5, "a path that is not there answers the default")
assert_eq(json_paths$(deep@, "nowhere.at.all", "gone"), "gone", "for strings too")

test_case("json/clone-and-merge")
rem A clone is deep: changing the copy must not reach the original.
orig@ = json_object@()
json_sets@(orig@, "k", "before")
copy@ = json_clone@(orig@)
json_sets@(copy@, "k", "after")
assert_eq(json_gets$(orig@, "k"), "before", "the original is untouched")
assert_eq(json_gets$(copy@, "k"), "after", "and the clone carries the change")

target@ = json_object@()
json_sets@(target@, "keep", "mine")
source@ = json_object@()
json_sets@(source@, "added", "theirs")
json_merge@(target@, source@)
assert_eq(json_gets$(target@, "keep"), "mine", "json_merge@ keeps what was there")
assert_eq(json_gets$(target@, "added"), "theirs", "and takes what was given")

test_case("json/rendering")
r@ = json_object@()
json_sets@(r@, "k", "v")
flat$ = json_stringify$(r@)
assert_true(len(flat$), "json_stringify$ renders")
assert_eq(instr(flat$, "\n"), 0, "on one line")

pretty$ = json_pretty$(r@)
atleast = 0
if len(pretty$) >= len(flat$) then atleast = 1
assert_true(atleast, "json_pretty$ renders at least as much")
wide$ = json_pretty$(r@, 4)
assert_true(len(wide$), "and its indent form answers too")

rem What was rendered parses back to the same thing, which is the only
rem claim about the text that matters.
back@ = json_parse@(flat$)
assert_eq(json_gets$(back@, "k"), "v", "and what comes back is what went out")

test_case("json/a number too big for a double is refused at the door")
rem `1e400` is well-formed JSON text and fpjson parses it into +Inf, so the tree
rem held a Double the engine promises does not exist (FiniteD, in PhosphorValue:
rem "no TValue ever holds a non-finite Double"). Everything downstream then lied
rem in its own way -- json_stringify$ and json_pretty$ wrote "+Inf" padded to
rem nineteen columns, which is not JSON and which Phosphor's own parser rejects,
rem and json_stringify$ is what feeds file_writealltext and an HTTP body.
rem
rem A parsed document is the third door foreign text comes through, and it now
rem answers the way the other two already do: the lexer refuses `x = 1e999`, and
rem `input x` on a field of "1e999" says it is out of range and stores nothing.
caught = 0
msg$ = ""
on error goto wildnum
bad@ = json_parse@("{""score"": 1e400}")
goto after_wild
wildnum:
caught = 1
msg$ = errmsg$()
resume next
after_wild:
on error goto 0
assert_eq(caught, 1, "a number that overflows a double is refused")
assert_true(instr(msg$, "out of range"), "and said to be out of range")
assert_true(instr(msg$, "score"), "naming where in the document it is")

caught = 0
on error goto wildneg
bad@ = json_parse@("[1, -1e400]")
goto after_wildneg
wildneg:
caught = 1
resume next
after_wildneg:
on error goto 0
assert_eq(caught, 1, "the negative one too, and inside an array")

rem The band either side of it must be untouched: 1e308 fits a double, 1e-400
rem merely underflows to zero (which is a number), and a big plain integer was
rem already refused by fpjson itself.
ok@ = json_parse@("[1e308, -1e308, 1e-400, 0, 1.5]")
assert_eq(json_len(ok@), 5, "the whole representable range still parses")
assert_near(json_itemn(ok@, 1), 1e308, 1e295, "1e308 is a number")
assert_near(json_itemn(ok@, 3), 0, 0.0000001, "and 1e-400 underflows to zero")
assert_true(len(json_stringify$(ok@)), "and the document still renders")

rem ---------------------------------------------------------------
rem THREE CRASHES: the process dying, not an error a script could catch.
rem Every one of them was found by the 2026-09-10 gauntlet and every one
rem is a door that let a tree deeper than MaxJsonDepth reach fpjson's
rem recursive parser, its recursive walkers, or its recursive DESTRUCTOR.
rem Quotes are built with chr$ throughout, so nothing here depends on how
rem this file's own literals are escaped.
rem ---------------------------------------------------------------

test_case("json/a single-quoted value cannot hide the nesting")
rem The depth scan opened a literal only on a double quote. fpjson opens one on a
rem single quote too, so a document could hand the scan an ODD number of double
rem quotes: the one inside a single-quoted value turned the scan ON, the one
rem opening the next key turned it OFF, and every bracket after that was read as
rem text. depth never rose, the ceiling was never reached, and the parser recursed
rem until the process died -- exit 127 at 50,000 levels, a segmentation fault with
rem no diagnostic at all at 200,000.
q$ = chr$(34)
sq$ = chr$(39)
opens$ = ""
closes$ = ""
for i% = 1 to 300
  opens$ = opens$ + "["
  closes$ = closes$ + "]"
next
hostile$ = "{" + sq$ + "x" + sq$ + ":" + sq$ + q$ + sq$ + "," + q$ + "y" + q$ + ":" + opens$ + closes$ + "}"
plain$ = "{" + q$ + "y" + q$ + ":" + opens$ + closes$ + "}"

deepcaught = 0
deepmsg$ = ""
on error goto deepbad
bad@ = json_parse@(hostile$)
goto after_deep
deepbad:
deepcaught = 1
deepmsg$ = errmsg$()
resume next
after_deep:
on error goto 0
assert_eq(deepcaught, 1, "the hostile document is refused")
assert_true(instr(deepmsg$, "nests more than 256"), "for nesting, and it says so")

rem THE CONTROL: the same nesting with no single-quoted prefix was always refused.
rem Both must now give the same answer, which is what makes this a bypass and not
rem a difference of opinion about the document.
plaincaught = 0
plainmsg$ = ""
on error goto plainbad
bad@ = json_parse@(plain$)
goto after_plain
plainbad:
plaincaught = 1
plainmsg$ = errmsg$()
resume next
after_plain:
on error goto 0
assert_eq(plaincaught, 1, "and so is the same nesting without the prefix")
assert_true(instr(plainmsg$, "nests more than 256"), "with the same reason")

rem AND SINGLE QUOTES STILL PARSE. The scan learned the delimiter; it did not
rem learn to refuse it. A guard that refused something legitimate would be the
rem failure mode this project names first.
sqok@ = json_parse@("{" + sq$ + "a" + sq$ + ":1," + sq$ + "b" + sq$ + ":" + sq$ + "two" + sq$ + "}")
assert_eq(json_getn(sqok@, "a"), 1, "a single-quoted key still parses")
assert_eq(json_gets$(sqok@, "b"), "two", "and a single-quoted value")

test_case("json/merge refuses two values that overlap")
rem json_merge@ evaluated the source's Count once and then dereferenced the source
rem on every turn. Merging an object into its own ancestor means one of the
rem source's names collides with the target key that OWNS the source: SetMember
rem finds it, empties every borrowed handle onto it, and then FREES it -- and the
rem library's own local still pointed there. An access violation, deterministic.
ov@ = json_object@()
inner@ = json_object@()
x@ = json_setn@(inner@, "b", 1)
x@ = json_setn@(inner@, "c", 2)
x@ = json_setn@(inner@, "d", 3)
x@ = json_set@(ov@, "b", inner@)
sub@ = json_get@(ov@, "b")
mergecaught = 0
mergemsg$ = ""
on error goto mergebad
x@ = json_merge@(ov@, sub@)
goto after_merge
mergebad:
mergecaught = 1
mergemsg$ = errmsg$()
resume next
after_merge:
on error goto 0
assert_eq(mergecaught, 1, "merging a value with something inside it is refused")
assert_true(instr(mergemsg$, "overlap"), "and the reason is that they overlap")
assert_eq(json_getn(json_get@(ov@, "b"), "c"), 2, "and the target is untouched")

rem The other direction, and the degenerate one, are the same answer.
mergecaught = 0
on error goto mergebad2
x@ = json_merge@(sub@, ov@)
goto after_merge2
mergebad2:
mergecaught = 1
resume next
after_merge2:
on error goto 0
assert_eq(mergecaught, 1, "so is merging the other way round")

mergecaught = 0
on error goto mergebad3
x@ = json_merge@(ov@, ov@)
goto after_merge3
mergebad3:
mergecaught = 1
resume next
after_merge3:
on error goto 0
assert_eq(mergecaught, 1, "and so is merging a value with itself")

rem AND AN HONEST MERGE STILL WORKS -- two trees that share nothing.
ma@ = json_object@()
x@ = json_setn@(ma@, "keep", 1)
mb@ = json_object@()
x@ = json_sets@(mb@, "add", "yes")
x@ = json_merge@(ma@, mb@)
assert_eq(json_getn(ma@, "keep"), 1, "an honest merge keeps what was there")
assert_eq(json_gets$(ma@, "add"), "yes", "and takes what was offered")

test_case("json/a tree a SCRIPT builds cannot pass the ceiling either")
rem MaxJsonDepth was asked exactly one question, in json_parse@, and everything a
rem script BUILT walked around it. A plain loop nesting a fragment in a fragment
rem reached depth 131072: the program printed its complete and correct output and
rem then died in teardown with an unhandled stack overflow and exit 3, handing the
rem shell a failure for a run that had succeeded. json_stringify$ on the same tree
rem was a segmentation fault.
root@ = json_array@()
cur@ = root@
built = 0
buildcaught = 0
buildmsg$ = ""
on error goto buildbad
rem `resume next` continues INSIDE the loop, at the line after the one that
rem failed -- so the flag is read there and the loop is left deliberately. A first
rem draft let it run on to 400 and caught "array index out of bounds" from the
rem item@ after a refused push, which is a test passing for the wrong reason.
for i% = 1 to 400
  nxt@ = json_array@()
  x@ = json_push@(cur@, nxt@)
  if buildcaught = 1 then
    break
  end if
  cur@ = json_item@(cur@, 1)
  built = built + 1
next
goto after_build
buildbad:
buildcaught = 1
buildmsg$ = errmsg$()
resume next
after_build:
on error goto 0
assert_eq(buildcaught, 1, "building past the ceiling one level at a time is refused")
assert_true(instr(buildmsg$, "nest more than 256"), "and the reason names the ceiling")
assert_true(built < 400, "the loop did not finish")
assert_true(built > 200, "but it got most of the way there before refusing")

rem The scalar doors are the same gate: a value that adds no nesting is still a
rem level, and the deepest node cannot take one.
scalarcaught = 0
on error goto scalarbad
x@ = json_pushn@(cur@, 1)
goto after_scalar
scalarbad:
scalarcaught = 1
resume next
after_scalar:
on error goto 0
assert_eq(scalarcaught, 1, "and so is a plain number at the deepest node")

rem AND ORDINARY NESTING IS UNTOUCHED. Ten deep is what a real document looks
rem like, and the whole point of the ceiling is that it never meets one.
ok@ = json_array@()
tip@ = ok@
for i% = 1 to 10
  n2@ = json_array@()
  x@ = json_push@(tip@, n2@)
  tip@ = json_item@(tip@, 1)
next
x@ = json_pushn@(tip@, 42)
assert_eq(json_len(ok@), 1, "a ten-deep tree still builds")
assert_true(len(json_stringify$(ok@)) > 20, "and still renders")
