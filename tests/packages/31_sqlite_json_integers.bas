rem ---------------------------------------------------------------
rem SQLite: an integer from a JSON object is stored as an INTEGER.
rem (2026-10-09, round 3, found by the JSON fixer.)
rem
rem sqlite_insertjson and sqlite_bindjson bind each member through one
rem routine, and it bound only fpjson's 32-bit integers as integers. A
rem 64-bit one went through a Double: 2^53 + 1 was stored as the REAL
rem 9007199254740992, and every integer past 2^31 changed its SQL type.
rem The expected values are arithmetic: 2^31 = 2147483648,
rem 2^53 + 1 = 9007199254740993, 2^63 - 1 = 9223372036854775807. And a
rem number past 2^63 - 1 cannot be an SQLite INTEGER; it is the REAL
rem nearest to it, which for 2^64 - 1 is 2^64.
rem Runs only where the SQLite runtime library is present, like every
rem *sqlite* file in this corpus.
rem ---------------------------------------------------------------

db@ = sqlite_open@(":memory:")
assert_eq(sqlite_exec(db@, "create table t (k text, n)"), 1, "the table")

test_case("sqlite-json/integers past 32 bits stay integers")
j@ = json_parse@("{""k"": ""a"", ""n"": 2147483648}")
assert_eq(sqlite_insertjson(db@, "t", j@), 1, "2^31 is inserted")
assert_eq(sqlite_scalar$(db@, "select typeof(n) from t where k = 'a'"), "integer", "and stored as an INTEGER")
assert_eq(sqlite_scalar$(db@, "select cast(n as text) from t where k = 'a'"), "2147483648", "with every digit")

j@ = json_parse@("{""k"": ""b"", ""n"": 9007199254740993}")
assert_eq(sqlite_insertjson(db@, "t", j@), 1, "2^53 + 1 is inserted")
assert_eq(sqlite_scalar$(db@, "select typeof(n) from t where k = 'b'"), "integer", "and stored as an INTEGER")
assert_eq(sqlite_scalar$(db@, "select cast(n as text) from t where k = 'b'"), "9007199254740993", "not rounded to 2^53")

j@ = json_parse@("{""k"": ""c"", ""n"": 9223372036854775807}")
assert_eq(sqlite_insertjson(db@, "t", j@), 1, "2^63 - 1 is inserted")
assert_eq(sqlite_scalar$(db@, "select cast(n as text) from t where k = 'c'"), "9223372036854775807", "the largest INTEGER, exactly")

test_case("sqlite-json/past 2^63 - 1 it is the nearest REAL")
j@ = json_parse@("{""k"": ""d"", ""n"": 18446744073709551615}")
assert_eq(sqlite_insertjson(db@, "t", j@), 1, "2^64 - 1 is inserted")
assert_eq(sqlite_scalar$(db@, "select typeof(n) from t where k = 'd'"), "real", "as a REAL")
rem Read back as a Double and compared with 2^64, an exact power of two --
rem not through SQLite's printf, whose %g stops at 16 significant digits
rem unless given its '!' flag (this file's first draft asked %.17g and
rem was answered 16 digits).
assert_eq(sqlite_scalar(db@, "select n from t where k = 'd'"), 2 ^ 64, "the Double nearest to it, 2^64")

test_case("sqlite-json/a small integer is unchanged")
j@ = json_parse@("{""k"": ""e"", ""n"": 42}")
assert_eq(sqlite_insertjson(db@, "t", j@), 1, "42 is inserted")
assert_eq(sqlite_scalar$(db@, "select typeof(n) || ':' || n from t where k = 'e'"), "integer:42", "as before")

x = sqlite_close(db@)
