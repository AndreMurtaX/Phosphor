rem ---------------------------------------------------------------
rem SQLite, the full statement-level surface (opt-in host package):
rem prepared statements and binding, a cursor with column metadata,
rem transactions with a commit and a rollback both observed, JSON
rem row/table introspection and a JSON write path, changes/lastid
rem bookkeeping, escaping, error reporting and maintenance. The suite
rem runs this file only where the SQLite runtime library is installed
rem (it is skipped otherwise), so sqlite_available() is 1 whenever it
rem runs. 02_sqlite covers the simple exec/scalar/query path.
rem
rem Two conventions to hold on to, both Phosphor-wide:
rem
rem   * parameter and column indices are 1-BASED, like strings, arrays
rem     and JSON everywhere else in Phosphor. (The reference's SQL
rem     indices were 0-based; SQLite's own C API mixes 1-based binds
rem     with 0-based columns -- this package presents a uniform 1.)
rem   * a cursor is not positioned until sqlite_step has been called.
rem     Before the first step, sqlite_eof answers true and every getter
rem     answers empty -- which reads exactly like an empty table.
rem ---------------------------------------------------------------

db$ = "bin/phosphor_sqlfull.db"
file_delete(db$)

test_case("sqlite/open")
d@ = sqlite_open@(db$)
assert_true(pnttonum(d@), "sqlite_open@ answers a handle")
assert_true(sqlite_isopen(d@), "and the handle says it is open")
assert_eq(sqlite_path$(d@), db$, "which remembers its file")
assert_true(len(sqlite_version$()), "sqlite_version$ answers the library version")
assert_eq(sqlite_error(), 0, "and nothing has gone wrong yet")

test_case("sqlite/exec")
sqlite_exec(d@, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
assert_true(sqlite_tableexists(d@, "people"), "sqlite_tableexists finds the new table")
assert_false(sqlite_tableexists(d@, "nobody"), "and does not invent one")

sqlite_exec(d@, "INSERT INTO people (name, age) VALUES ('Alice', 30)")
assert_eq(sqlite_changes(d@), 1, "sqlite_changes counts the last statement")
assert_eq(sqlite_lastid(d@), 1, "sqlite_lastid answers the new row id")
assert_true(sqlite_totalchanges(d@), "sqlite_totalchanges counts the session")

test_case("sqlite/prepare-and-bind")
rem The parameterised path. Binding is what keeps a name with an
rem apostrophe from becoming a syntax error or worse.
s@ = sqlite_prepare@(d@, "INSERT INTO people (name, age) VALUES (?, ?)")
assert_true(pnttonum(s@), "sqlite_prepare@ answers a statement")

sqlite_bindstr(s@, 1, "Bob")
sqlite_bindnum(s@, 2, 41)
sqlite_step(s@)
assert_eq(sqlite_lastid(d@), 2, "the bound insert made a row")

sqlite_reset(s@)
sqlite_clearbind(s@)
sqlite_bindstr(s@, 1, "O'Brien")
sqlite_bindnum(s@, 2, 55)
sqlite_step(s@)
assert_eq(sqlite_lastid(d@), 3, "and a name with a quote in it is no trouble")

sqlite_reset(s@)
sqlite_clearbind(s@)
sqlite_bindstr(s@, 1, "Nobody")
sqlite_bindnull(s@, 2)
sqlite_step(s@)
assert_eq(sqlite_lastid(d@), 4, "and a bound null makes a row like any other")
sqlite_finalize(s@)

test_case("sqlite/bind-from-json")
rem sqlite_bindjson matches by NAME, not by position: it walks the
rem object's keys and asks the statement for a parameter of that name.
rem So the statement has to be written with named parameters -- a
rem statement full of question marks binds nothing at all, silently,
rem because a parameter that is not found is skipped.
j@ = sqlite_prepare@(d@, "INSERT INTO people (name, age) VALUES (:name, :age)")
p@ = json_object@()
json_sets@(p@, "name", "Dana")
json_setn@(p@, "age", 33)
sqlite_bindjson(j@, p@)
sqlite_step(j@)
sqlite_finalize(j@)

jq@ = sqlite_query@(d@, "SELECT age FROM people WHERE name = 'Dana'")
sqlite_step(jq@)
assert_eq(sqlite_getn(jq@, "age"), 33, "the JSON object became a bound row")
sqlite_finalize(jq@)

test_case("sqlite/query-by-column")
q@ = sqlite_query@(d@, "SELECT id, name, age FROM people ORDER BY id")
assert_true(pnttonum(q@), "sqlite_query@ answers a result")
assert_eq(sqlite_step(q@), 1, "and the first step lands on a row")
assert_false(sqlite_eof(q@), "which is not the end")

assert_eq(sqlite_colcount(q@), 3, "three columns were asked for")
assert_eq(sqlite_colname$(q@, 1), "id", "sqlite_colname$ names the first")
assert_eq(sqlite_colindex(q@, "age"), 3, "sqlite_colindex finds one by name")
assert_true(len(sqlite_coltypename$(sqlite_coltype(q@, 1))), "sqlite_coltypename$ names the type sqlite_coltype answers")

assert_eq(sqlite_getstr$(q@, 2), "Alice", "sqlite_getstr$ reads by position")
assert_eq(sqlite_getnum(q@, 3), 30, "sqlite_getnum too")
assert_eq(sqlite_gets$(q@, "name"), "Alice", "sqlite_gets$ reads by name")
assert_eq(sqlite_getn(q@, "age"), 30, "and sqlite_getn")
assert_false(sqlite_isnull(q@, 2), "a value that is there is not null")
assert_false(sqlite_isblob(q@, 2), "and text is not a blob")

test_case("sqlite/stepping")
rem Walking to the end proves eof means what it says rather than
rem answering true only when nothing was ever opened.
count = 1
while sqlite_step(q@) = 1
  count = count + 1
endwhile
assert_eq(count, 5, "five rows were inserted and five were walked")
assert_true(sqlite_eof(q@), "and the result is at its end")
sqlite_finalize(q@)

test_case("sqlite/nulls")
n@ = sqlite_query@(d@, "SELECT age FROM people WHERE name = 'Nobody'")
sqlite_step(n@)
assert_true(sqlite_isnull(n@, 1), "the bound null really is null")
assert_true(sqlite_isn(n@, "age"), "and sqlite_isn agrees by name")
sqlite_finalize(n@)

test_case("sqlite/json")
rem Every one of these answers a JSON handle, so JsonLib is what reads
rem them back.
r@ = sqlite_query@(d@, "SELECT id, name FROM people ORDER BY id")
sqlite_step(r@)
row@ = sqlite_row@(r@)
assert_true(json_isobj(row@), "sqlite_row@ answers an object")
assert_eq(json_gets$(row@, "name"), "Alice", "holding the current row")

one@ = sqlite_fetchone@(r@)
assert_true(json_isobj(one@), "sqlite_fetchone@ answers an object too")
sqlite_finalize(r@)

rem json_count is object keys only, by definition. An array is counted
rem by json_len, which handles both -- and these three answer arrays.
f@ = sqlite_query@(d@, "SELECT id FROM people")
all@ = sqlite_fetchall@(f@)
assert_true(json_isarr(all@), "sqlite_fetchall@ answers an array")
assert_eq(json_len(all@), 5, "holding every row at once")
assert_eq(json_count(all@), 0, "and json_count, which counts object keys, says nothing about it")
sqlite_finalize(f@)

t@ = sqlite_tables@(d@)
assert_true(json_len(t@), "sqlite_tables@ lists the tables")
c@ = sqlite_columns@(d@, "people")
assert_eq(json_len(c@), 3, "sqlite_columns@ describes the three columns")

test_case("sqlite/json-writes")
rem The JSON write path: an object becomes a row, and a second object
rem updates it.
o@ = json_object@()
json_sets@(o@, "name", "Carol")
json_setn@(o@, "age", 28)
assert_eq(sqlite_insertjson(d@, "people", o@), 1, "sqlite_insertjson writes a row")

k@ = sqlite_query@(d@, "SELECT name, age FROM people WHERE name = 'Carol'")
sqlite_step(k@)
assert_eq(sqlite_gets$(k@, "name"), "Carol", "and the row is there")
sqlite_finalize(k@)

u@ = json_object@()
json_setn@(u@, "age", 29)
assert_eq(sqlite_updatejson(d@, "people", u@, "name = 'Carol'"), 1, "sqlite_updatejson changes it")

k2@ = sqlite_query@(d@, "SELECT age FROM people WHERE name = 'Carol'")
sqlite_step(k2@)
assert_eq(sqlite_getn(k2@, "age"), 29, "and the new value is stored")
sqlite_finalize(k2@)

test_case("sqlite/transactions")
assert_false(sqlite_intrans(d@), "no transaction is open to begin with")
sqlite_begin(d@)
assert_true(sqlite_intrans(d@), "sqlite_begin opens one")
sqlite_exec(d@, "INSERT INTO people (name, age) VALUES ('Temporary', 1)")
sqlite_rollback(d@)
assert_false(sqlite_intrans(d@), "sqlite_rollback closes it")

t1@ = sqlite_query@(d@, "SELECT count(*) AS n FROM people WHERE name = 'Temporary'")
sqlite_step(t1@)
assert_eq(sqlite_getn(t1@, "n"), 0, "and the rolled-back row is not there")
sqlite_finalize(t1@)

sqlite_begin(d@)
sqlite_exec(d@, "INSERT INTO people (name, age) VALUES ('Permanent', 2)")
sqlite_commit(d@)
assert_false(sqlite_intrans(d@), "sqlite_commit closes it too")

t2@ = sqlite_query@(d@, "SELECT count(*) AS n FROM people WHERE name = 'Permanent'")
sqlite_step(t2@)
assert_eq(sqlite_getn(t2@, "n"), 1, "and the committed row stayed")
sqlite_finalize(t2@)

test_case("sqlite/escaping")
rem sqlite_escape$ doubles the quote, sqlite_quote$ wraps the whole thing.
rem Both exist because building SQL by hand is sometimes unavoidable.
assert_eq(sqlite_escape$("O'Brien"), "O''Brien", "sqlite_escape$ doubles an apostrophe")
assert_eq(sqlite_quote$("O'Brien"), "'O''Brien'", "sqlite_quote$ escapes and wraps")

test_case("sqlite/errors")
sqlite_clearerror()
assert_eq(sqlite_error(), 0, "sqlite_clearerror clears the code")
sqlite_exec(d@, "THIS IS NOT SQL")
assert_true(sqlite_error(), "a bad statement leaves a code")
assert_true(len(sqlite_errormsg$()), "and a message")
assert_true(len(sqlite_strerror$(sqlite_error())), "sqlite_strerror$ names the code")
sqlite_clearerror()
assert_eq(sqlite_error(), 0, "and it can be cleared again")

test_case("sqlite/maintenance")
back$ = "bin/phosphor_sqlfull_backup.db"
file_delete(back$)
assert_eq(sqlite_backup(d@, back$), 1, "sqlite_backup writes a copy")
assert_true(file_exists(back$), "and the copy is on disk")

b@ = sqlite_open@(back$)
assert_true(sqlite_tableexists(b@, "people"), "which holds the same tables")
sqlite_close(b@)
file_delete(back$)

assert_eq(sqlite_vacuum(d@), 1, "sqlite_vacuum runs")

test_case("sqlite/memory")
rem The no-argument form opens a database that never touches the disk.
m@ = sqlite_open@()
assert_true(sqlite_isopen(m@), "sqlite_open@ with no file answers an open handle")
sqlite_exec(m@, "CREATE TABLE t (v INTEGER)")
assert_true(sqlite_tableexists(m@, "t"), "which behaves like any other")
sqlite_close(m@)

test_case("sqlite/close")
sqlite_close(d@)
assert_false(sqlite_isopen(d@), "sqlite_close closes it")

file_delete(db$)

test_case("sqlite/a column with an embedded NUL comes back whole")
rem The readers treated the column pointer as a C string and stopped at the first
rem NUL, so a text or blob column holding a zero byte was silently TRUNCATED:
rem length(b) reported 4 while every reader returned 1 byte.
sqlite_exec(db@, "create table nulls(b blob)")
sqlite_exec(db@, "insert into nulls values(x'41004243')")
assert_eq(sqlite_scalar(db@, "select length(b) from nulls"), 4, "SQLite says four bytes")
nb$ = sqlite_scalar$(db@, "select b from nulls")
assert_eq(bytelen(nb$), 4, "and four bytes is what comes back")
assert_eq(byteat(nb$, 1), 65, "A")
assert_eq(byteat(nb$, 2), 0, "the embedded NUL")
assert_eq(byteat(nb$, 3), 66, "B")
assert_eq(byteat(nb$, 4), 67, "C")

test_case("sqlite/a column's type is the ROW's, not the last read's")
rem sqlite3_column_type reports the CURRENT representation, and reading a column as
rem text converts it in place -- so the same row answered BLOB before a getstr$ and
rem TEXT after it, with no step in between. The types are captured at step now.
c@ = sqlite_prepare@(db@, "select b from nulls")
assert_eq(sqlite_step(c@), 1, "one row")
assert_eq(sqlite_isblob(c@, 1), 1, "it is a blob")
junk$ = sqlite_getstr$(c@, 1)
assert_eq(sqlite_isblob(c@, 1), 1, "and it still is, after being read as text")
assert_eq(sqlite_coltype(c@, 1), 4, "the type code has not moved either")
sqlite_finalize(c@)
