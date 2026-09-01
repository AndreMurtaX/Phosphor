rem ---------------------------------------------------------------
rem SQLite (opt-in host package): an in-memory database -- create a
rem table, insert rows, and query them back. The suite runs this file
rem only where the SQLite runtime library is installed (it is skipped
rem otherwise), so sqlite_available() is 1 whenever this runs.
rem ---------------------------------------------------------------

db@ = sqlite_open@(":memory:")
assert_true(sqlite_available(), "the SQLite library is present")

test_case("sqlite/create and insert")
assert_eq(sqlite_exec(db@, "create table t (id integer, name text)"), 1, "create table")
assert_eq(sqlite_exec(db@, "insert into t values (1, 'alice')"), 1, "insert the first row")
assert_eq(sqlite_exec(db@, "insert into t values (2, 'bob')"), 1, "insert the second row")

test_case("sqlite/scalar queries")
assert_eq(sqlite_scalar(db@, "select count(*) from t"), 2, "two rows")
assert_eq(sqlite_scalar$(db@, "select name from t where id = 1"), "alice", "a name by id")
assert_eq(sqlite_scalar(db@, "select sum(id) from t"), 3, "sum of the ids")

test_case("sqlite/multi-row query")
rows$ = sqlite_query$(db@, "select name from t order by id")
assert_true(instr(rows$, "alice"), "the result holds alice")
assert_true(instr(rows$, "bob"), "and bob")

test_case("sqlite/close")
assert_eq(sqlite_close(db@), 1, "the database closes")
