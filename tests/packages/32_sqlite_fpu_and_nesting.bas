rem ---------------------------------------------------------------
rem SQLite: valid SQL that makes an infinity or a NaN, and a JSON
rem member that is itself an array or an object.
rem (2026-10-09, round 4.)
rem
rem THE FPU. The VM runs with the invalid-operation trap UNMASKED, and
rem the package called into sqlite3 with it live. SQLite's C code
rem computes Inf - Inf, Inf * 0, sqrt(-1) and compares infinities as a
rem matter of course; each of those raised EInvalidOp in the middle of
rem the C code. The unwind skipped SQLite's own cleanup and this
rem package's sqlite3_finalize, so the statement's transaction stayed
rem open while autocommit said none was, every later "successful"
rem insert stayed uncommitted, sqlite3_close answered BUSY to nobody,
rem and the rows were gone when the database was opened again.
rem
rem THE NESTED MEMBER. bindjson, insertjson and updatejson read every
rem member that was not a number, a null or a boolean as fpjson's
rem AsString, which RAISES for an array or an object; insertjson then
rem skipped its finalize and the connection could not be closed.
rem A nested member is now bound as its JSON text, the text
rem json_stringify$ writes for it.
rem
rem Every expected value is SQLite's own answer, taken from Python's
rem sqlite3 module (SQLite 3.49.1), never from a Phosphor run:
rem   select 1e999                      -> inf     (text 'Inf')
rem   select -1e999                     -> -inf    (text '-Inf')
rem   select 2e308 = 2e308              -> 1
rem   select '1e999' + 0                -> inf
rem   select cast('1e999' as real)      -> inf
rem   select 1e308 * 10 - 1e308 * 10    -> None    (a NaN is NULL)
rem   select 1e308 * 10 * 0             -> None
rem   select sqrt(-1), acos(2)          -> None, None
rem A nested member's text is json_stringify$'s, which json.md specifies:
rem an object with no padding ({"x":1,"y":"z"}), array elements
rem separated by ", " ([1, 2]) -- the docs' spelling, not any run's.
rem
rem sqrt and acos exist only where SQLite was built with its math
rem functions. Where a build lacks them, the call is refused with
rem "no such function" and there is nothing to ask; those two probes
rem then accept that refusal in place of the NULL, and say so below.
rem Runs only where the SQLite runtime library is present, like every
rem *sqlite* file in this corpus.
rem ---------------------------------------------------------------

db$ = "bin/phosphor_sqlfpu.db"
jr$ = db$ + "-journal"
x = file_delete(db$)
x = file_delete(jr$)

test_case("sqlite-fpu/a NaN mid-statement is a NULL, not a raise")
db@ = sqlite_open@(db$)
ok = sqlite_exec(db@, "create table src (x); insert into src values (4), (-1); create table dst (y); create table log (msg text)")
assert_eq(ok, 1, "the tables")
rem For x = 4 the CASE is 4 / 2.0 = 2.0. For x = -1 it is
rem (-1e308 * 10) - (-1e308 * 10) = -Inf + Inf, a NaN, which SQLite
rem stores as NULL. Portable: no math function is needed. And no
rem literal overflows, so the NaN is made while the statement STEPS,
rem inside the write transaction -- the reporter's case. (A literal
rem 1e999 faults at PREPARE instead, before any transaction exists.)
caught% = 0
m$ = ""
r = 7
on error goto nan_raised
r = sqlite_exec(db@, "insert into dst select case when x > 0 then x / 2.0 else x * 1e308 * 10 - x * 1e308 * 10 end from src")
goto after_nan
nan_raised:
caught% = 1
m$ = errmsg$()
resume next
after_nan:
on error goto 0
assert_eq(caught%, 0, "valid SQL does not raise")
assert_eq(m$, "", "and leaves no error message")
assert_eq(r, 1, "sqlite_exec answers 1")
assert_eq(sqlite_scalar$(db@, "select group_concat(v, ',') from (select coalesce(y, 'NULL') as v from dst order by rowid)"), "2.0,NULL", "2.0 for 4, NULL for the NaN")

test_case("sqlite-fpu/the writes after it are durable")
assert_eq(sqlite_exec(db@, "insert into log values ('one')"), 1, "insert one")
assert_eq(sqlite_exec(db@, "insert into log values ('two')"), 1, "insert two")
assert_eq(sqlite_exec(db@, "insert into log values ('three')"), 1, "insert three")
assert_eq(sqlite_intrans(db@), 0, "autocommit: no transaction is open")
assert_eq(sqlite_close(db@), 1, "sqlite_close answers 1")
assert_eq(sqlite_isopen(db@), 0, "and the handle is closed")
assert_eq(file_exists(jr$), 0, "no journal is left behind on disk")
rem A SECOND connection is what tells a commit from a write the first
rem connection can see only in its own open transaction.
d2@ = sqlite_open@(db$)
assert_eq(sqlite_scalar(d2@, "select count(*) from log"), 3, "a new connection finds the three rows")
assert_eq(sqlite_scalar(d2@, "select count(*) from dst"), 2, "and both rows of the insert-select")
assert_eq(sqlite_close(d2@), 1, "the second connection closes")
assert_eq(file_delete(db$), 1, "and nothing holds the file open")

test_case("sqlite-fpu/infinities and NaNs at prepare and at step")
m@ = sqlite_open@()
q@ = sdim@(9)
want@ = sdim@(9)
q@[1] = "select 1e999"
want@[1] = "Inf"
q@[2] = "select -1e999"
want@[2] = "-Inf"
q@[3] = "select 2e308 = 2e308"
want@[3] = "1"
q@[4] = "select '1e999' + 0"
want@[4] = "Inf"
q@[5] = "select cast('1e999' as real)"
want@[5] = "Inf"
q@[6] = "select coalesce(1e308 * 10 - 1e308 * 10, 'NULL')"
want@[6] = "NULL"
q@[7] = "select coalesce(1e308 * 10 * 0, 'NULL')"
want@[7] = "NULL"
q@[8] = "select coalesce(sqrt(-1), 'NULL')"
want@[8] = "NULL"
q@[9] = "select coalesce(acos(2), 'NULL')"
want@[9] = "NULL"
rem A label belongs to the program, not to a block, so the loop that
rem arms a trap per query is written with goto.
i = 1
probe_top:
got$ = "unset"
x = sqlite_clearerror()
on error goto probe_raised
got$ = sqlite_scalar$(m@, q@[i])
goto after_probe
probe_raised:
got$ = "raised: " + errmsg$()
resume next
after_probe:
on error goto 0
e$ = sqlite_errormsg$()
rem A build without the math functions: nothing to ask (see the header).
if (i >= 8) and (left$(e$, 16) = "no such function") then got$ = "NULL"
assert_eq(got$, want@[i], q@[i])
i = i + 1
if i <= 9 then goto probe_top

rem The same values through a cursor, stepped by the script.
s@ = sqlite_query@(m@, "select 1e308 * 10 - 1e308 * 10, 1e999, -1e999")
assert_true(pnttonum(s@), "a cursor over non-finite arithmetic prepares")
assert_eq(sqlite_step(s@), 1, "and steps onto its row")
assert_eq(sqlite_isnull(s@, 1), 1, "Inf - Inf is NULL")
assert_eq(sqlite_coltype(s@, 2), 2, "1e999 is a float")
assert_eq(sqlite_getstr$(s@, 2), "Inf", "whose text is Inf")
assert_eq(sqlite_getstr$(s@, 3), "-Inf", "and -1e999's is -Inf")
assert_eq(sqlite_step(s@), 0, "one row only")
assert_eq(sqlite_finalize(s@), 1, "the cursor finalizes")

test_case("sqlite-fpu/an infinite number is refused by the engine, and the statement is still freed")
rem num.md: no value in a running program is ever infinite, and the VM
rem reports a non-finite library result at the call. That refusal is
rem the documented one; what this asks is that it costs nothing else.
fdb$ = "bin/phosphor_sqlfpu2.db"
x = file_delete(fdb$)
f@ = sqlite_open@(fdb$)
assert_eq(sqlite_exec(f@, "create table t (v)"), 1, "a file database")
caught% = 0
m$ = ""
on error goto inf_raised
v = sqlite_scalar(f@, "select 1e999")
goto after_inf
inf_raised:
caught% = 1
m$ = errmsg$()
resume next
after_inf:
on error goto 0
assert_eq(caught%, 1, "sqlite_scalar of 1e999 is refused")
assert_eq(m$, "sqlite_scalar has no finite result for those arguments", "by the engine's finiteness rule")
assert_eq(sqlite_close(f@), 1, "the connection closes")
assert_eq(file_delete(fdb$), 1, "and really closed: the file can be deleted")

test_case("sqlite-json/a nested member is bound as its JSON text")
ndb$ = "bin/phosphor_sqlnest.db"
x = file_delete(ndb$)
x = file_delete(ndb$ + "-journal")
c@ = sqlite_open@(ndb$)
assert_eq(sqlite_exec(c@, "create table t (a, b)"), 1, "the table")
o@ = json_parse@("{""a"": 1, ""b"": [1, 2]}")
caught% = 0
m$ = ""
n = 7
on error goto ins_raised
n = sqlite_insertjson(c@, "t", o@)
goto after_ins
ins_raised:
caught% = 1
m$ = errmsg$()
resume next
after_ins:
on error goto 0
assert_eq(caught%, 0, "insertjson with an array member does not raise")
assert_eq(m$, "", "and leaves no error message")
assert_eq(n, 1, "one row is written")
assert_eq(sqlite_scalar$(c@, "select typeof(b) || ':' || b from t where a = 1"), "text:[1, 2]", "the array as JSON text")

o2@ = json_parse@("{""a"": 2, ""b"": {""x"": 1, ""y"": ""z""}}")
caught% = 0
n = 7
on error goto ins2_raised
n = sqlite_insertjson(c@, "t", o2@)
goto after_ins2
ins2_raised:
caught% = 1
resume next
after_ins2:
on error goto 0
assert_eq(caught%, 0, "an object member does not raise")
assert_eq(n, 1, "and is written")
assert_eq(sqlite_scalar$(c@, "select b from t where a = 2"), "{""x"":1,""y"":""z""}", "as JSON text")
assert_eq(sqlite_scalar$(c@, "select b from t where a = 2"), json_stringify$(json_get@(o2@, "b")), "the text json_stringify$ writes for it")

u@ = json_parse@("{""b"": [3, [4]]}")
caught% = 0
n = 7
on error goto upd_raised
n = sqlite_updatejson(c@, "t", u@, "a = 1")
goto after_upd
upd_raised:
caught% = 1
resume next
after_upd:
on error goto 0
assert_eq(caught%, 0, "updatejson with a nested member does not raise")
assert_eq(n, 1, "and changes the one row")
assert_eq(sqlite_scalar$(c@, "select b from t where a = 1"), "[3, [4]]", "to the new JSON text")

s@ = sqlite_prepare@(c@, "insert into t (a, b) values (:a, :b)")
bj@ = json_parse@("{""a"": 3, ""b"": {""k"": [true, null]}}")
caught% = 0
n = 7
on error goto bind_raised
n = sqlite_bindjson(s@, bj@)
goto after_bind
bind_raised:
caught% = 1
resume next
after_bind:
on error goto 0
assert_eq(caught%, 0, "bindjson with a nested member does not raise")
assert_eq(n, 1, "and answers 1")
assert_eq(sqlite_step(s@), 0, "the insert runs to its end")
assert_eq(sqlite_scalar$(c@, "select b from t where a = 3"), "{""k"":[true, null]}", "with the object as JSON text")

test_case("sqlite-json/a nested member with no JSON text binds nothing")
rem An infinity can sit in a tree this package built (a REAL column of a
rem fetched row) and json_stringify$ refuses to write it. A member that
rem has no JSON text is refused, with SQLITE_MISMATCH (20), and nothing
rem of the object is bound or written.
w@ = sqlite_fetchall@(sqlite_query@(c@, "select 1e999 as v"))
bad@ = json_parse@("{""a"": 9}")
x@ = json_set@(bad@, "b", w@)
x = sqlite_clearerror()
assert_eq(sqlite_insertjson(c@, "t", bad@), 0, "insertjson answers 0")
assert_eq(sqlite_error(), 20, "with SQLITE_MISMATCH")
assert_eq(sqlite_scalar(c@, "select count(*) from t where a = 9"), 0, "and writes no row")
assert_eq(sqlite_reset(s@), 1, "the prepared insert rewinds")
assert_eq(sqlite_bindjson(s@, json_parse@("{""a"": 5, ""b"": ""five""}")), 1, "a plain object binds")
x = sqlite_clearerror()
assert_eq(sqlite_bindjson(s@, bad@), 0, "bindjson answers 0 for the one with no text")
assert_eq(sqlite_error(), 20, "with the same code")
assert_eq(sqlite_step(s@), 0, "a step after the refusal")
assert_eq(sqlite_scalar$(c@, "select a || ':' || b from t where rowid = last_insert_rowid()"), "5:five", "writes the bindings that were there before it, untouched")
assert_eq(sqlite_updatejson(c@, "t", bad@, "a = 5"), 0, "updatejson answers 0 too")
assert_eq(sqlite_scalar$(c@, "select b from t where a = 5"), "five", "and changes nothing")

test_case("sqlite-json/the connection really closes")
assert_eq(sqlite_close(c@), 1, "sqlite_close answers 1")
assert_eq(file_exists(ndb$ + "-journal"), 0, "no journal is left behind")
assert_eq(file_delete(ndb$), 1, "and the file can be deleted")
x = sqlite_close(m@)
