# sqlite — a SQL database, from one statement to a cursor

`host/packages/PhosphorSqliteLib.pas` · 56 functions · opt-in host package, and it
needs an external SQLite runtime

## What it is for

This is a database a program can keep its own data in: create tables, run
statements, walk results a row at a time. It sits on the **raw sqlite3 C API**
through FPC's dynamic binding, not on SQLdb, because the point was the whole
statement-level surface — prepare → step → reset → finalize, per-parameter binding,
per-column type and value access, a JSON row bridge. `sqlite3_prepare_v2`, `bind`,
`step` and `column` map onto these names one-for-one; a `TSQLQuery` layer would only
have been something to fight.

It is an **opt-in host package**: the console host registers it, and unlike
base64 or zip it depends on a library that is not part of the binary
(`sqlite3.dll` on Windows, `libsqlite3.so` on Linux). The binding loads that at
*runtime*, so the unit compiles everywhere and nothing crashes where the library is
missing — the functions simply answer their empty values. `sqlite_available()` is
how a program finds out which world it is in, and it is worth asking once at
startup rather than guessing from a `0` later.

**There is one API here, not two.** A handle from `sqlite_open@` serves every
function on the page, the one-line `sqlite_exec` path and the cursor path alike;
there is no "simple driver" and "advanced driver" to choose between. Statements are
handles too, validated the same way, and **no cursor can outlive its connection**:
closing a database finalizes every statement opened on it and revokes their handle
ids, so a stale statement id is refused rather than dereferenced into freed memory.
For the same reason `sqlite_close` and `sqlite_finalize` are type-checked — each
frees only what it owns, and answers `0` when handed something else.

Two things will surprise a caller who knows SQLite. **Indices are 1-based**, both
bind parameters and result columns, like strings, arrays and JSON everywhere else in
Phosphor; the package maps that onto SQLite's own mixed convention (1-based binds,
0-based columns) so the BASIC side stays uniformly 1. And **nothing here raises**:
a bad handle, a statement that will not compile, a column that is not there all
answer an empty value — `""`, `0`, an empty JSON object — and leave a code behind
for `sqlite_error()` and `sqlite_errormsg$()`. That is the last-error-as-a-value
pattern `ioerror()` and `http_error()` follow. The consequence is worth stating
plainly: `sqlite_scalar$()` answering `""` may mean *no rows*, *a NULL*, *an empty
string*, or *the query was nonsense* — only `sqlite_error()` separates them.

## Functions

### Connection

| function | what it answers |
| --- | --- |
| `sqlite_available() → num` | `1` if the SQLite runtime library loaded at startup, `0` if it is not installed. Everything else on this page is inert in the `0` case |
| `sqlite_open@() → handle` | an in-memory database that never touches the disk (`":memory:"`) |
| `sqlite_open@(path$) → handle` | a database on `path$`, created if absent. Handle `0` when the runtime never loaded or SQLite refused to open the file — the code is in `sqlite_error()` |
| `sqlite_isopen(db@) → num` | `1` while the handle really is an open database. `0` for a closed one, a stale id, or a handle belonging to some other library |
| `sqlite_path$(db@) → str` | the path it was opened on — `":memory:"` for the memory form, `""` when the handle is not a database |
| `sqlite_version$() → str` | the SQLite library version, `""` when no library loaded |
| `sqlite_close(db@) → num` | `1` when it closed and freed the database and every cursor on it. `0` when the handle is not a database — closing a JSON handle destroys nothing — and `0` for one already closed |

### Running a statement

| function | what it answers |
| --- | --- |
| `sqlite_exec(db@, sql$) → num` | `1` when the statement (or several, `;`-separated) ran, `0` when it did not; the reason is in `sqlite_errormsg$()`. Nothing is returned from the rows — for that, use the scalar or cursor forms |
| `sqlite_scalar$(db@, sql$) → str` | the first column of the first row, as text. `""` for no rows, a NULL, an empty value, or a query that failed |
| `sqlite_scalar(db@, sql$) → num` | the same value as a number; `0` in all of those cases |
| `sqlite_query$(db@, sql$) → str` | every row at once: columns joined with tabs, each row **terminated** by a newline (so the text ends with one). `""` for no rows and for a failure alike |
| `sqlite_changes(db@) → num` | how many rows the last statement changed; `0` for a bad handle |
| `sqlite_totalchanges(db@) → num` | how many this connection has changed since it opened |
| `sqlite_lastid(db@) → num` | the rowid of the last insert on this connection, `0` if there has been none |

### Introspection

| function | what it answers |
| --- | --- |
| `sqlite_tableexists(db@, t$) → num` | `1` if a table of that name exists, `0` if it does not — and `0`, not an error, for a handle that is not a database |
| `sqlite_tables@(db@) → handle` | a JSON array of the **user** table names, sorted; SQLite's own bookkeeping tables (the ones whose names begin `sqlite_`) are left out. An empty array for a database with no tables; handle `0` for a bad handle |
| `sqlite_columns@(db@, t$) → handle` | a JSON array, one object per column, with `name`, `type`, `notnull` and `pk`. A table that does not exist answers an **empty array**, not an error |

### Prepared statements and cursors

A statement is not positioned on anything until `sqlite_step` has been called.
Before the first step every getter answers empty and `sqlite_eof` answers true —
which reads exactly like an empty table, and is meant to.

| function | what it answers |
| --- | --- |
| `sqlite_prepare@(db@, sql$) → handle` | a statement compiled once and re-runnable. Handle `0` when the SQL will not compile, with the error left in `sqlite_error()` |
| `sqlite_query@(db@, sql$) → handle` | the same thing under the name a SELECT deserves: a cursor is a prepared SELECT, and the two names are one function |
| `sqlite_step(s@) → num` | `1` when it landed on a row, `0` at the end of the result, on an error, or for a handle that is not a statement |
| `sqlite_eof(s@) → num` | `1` unless the cursor is sitting on a row — including before the first step, after the last, and for a bad handle |
| `sqlite_reset(s@) → num` | `1` after rewinding the statement to the top so it can run again; bound values survive. `0` only when the handle is not a statement |
| `sqlite_clearbind(s@) → num` | `1` after dropping every bound value back to NULL. Pair it with `sqlite_reset` before binding a fresh set |
| `sqlite_finalize(s@) → num` | `1` when it finished and freed the statement, `0` for anything that is not a statement — it will not free a database or a JSON handle |
| `sqlite_bindstr(s@, i, v$) → num` | binds a string to parameter `i` (1-based). `1` whenever the handle is a statement — an index outside the statement's parameters is ignored, silently, so `1` is not proof that parameter `i` exists |
| `sqlite_bindnum(s@, i, v) → num` | binds a number, keeping an integer an integer; same `1`/`0` meaning |
| `sqlite_bindnull(s@, i) → num` | binds SQL NULL to parameter `i` |
| `sqlite_bindjson(s@, obj@) → num` | binds an object's members **by name**, each key `k` to a parameter written `:k`. `0` when the handle is not a statement, or the second handle is not a JSON object. A key with no matching parameter is skipped — so a statement full of `?` binds nothing at all and still answers `1` |

### Columns of the current row

| function | what it answers |
| --- | --- |
| `sqlite_colcount(s@) → num` | how many columns the result has — available before the first step; `0` for a statement that returns none |
| `sqlite_colname$(s@, i) → str` | the name of column `i`, `""` when `i` is outside `1..sqlite_colcount` |
| `sqlite_colindex(s@, name$) → num` | the 1-based index of a column by name, case-insensitively. `0` when there is none, which is not a valid index and so cannot be mistaken for one |
| `sqlite_coltype(s@, i) → num` | the type code of column `i` **in this row**: `1` integer, `2` float, `3` text, `4` blob, `5` null. `5` also when the cursor is not on a row or `i` is out of range. The type is captured when the row arrives, so reading the column as text does not change the answer afterwards |
| `sqlite_coltypename$(code) → str` | the name of a type code — `integer`, `float`, `text`, `blob`, `null` — and `unknown` for a number that is not one of the five |
| `sqlite_getstr$(s@, i) → str` | column `i` as text, whole: an embedded NUL is data, not a terminator. `""` off a row and out of range |
| `sqlite_getnum(s@, i) → num` | column `i` as a number, an integer staying an integer. `0` off a row, out of range, and for a NULL |
| `sqlite_gets$(s@, name$) → str` | the same by column name, matched case-insensitively; `""` when there is no such column |
| `sqlite_getn(s@, name$) → num` | the same by name as a number; `0` when there is no such column |
| `sqlite_isnull(s@, i) → num` | `1` when column `i` is SQL NULL. Also `1` off a row, out of range, or for a bad handle — nothing there reads as nothing |
| `sqlite_isn(s@, name$) → num` | the same by name, `1` again for a column that is not there |
| `sqlite_isblob(s@, i) → num` | `1` when column `i` arrived as a blob, `0` otherwise and for anything out of range. Judged on the row's captured type, so it survives a `sqlite_getstr$` of the same column |

### Rows as JSON

| function | what it answers |
| --- | --- |
| `sqlite_row@(s@) → handle` | the current row as a JSON object, column names as keys. An **empty object** when the cursor is not on a row; handle `0` for a non-statement handle |
| `sqlite_fetchone@(s@) → handle` | steps first, then hands back the new current row. At the end of the result that is an empty object — check with `json_count` rather than expecting a failure |
| `sqlite_fetchall@(s@) → handle` | a JSON array of every **remaining** row, stepping a fresh cursor onto the first one for you. Empty array when the cursor is already exhausted. Count it with `json_len` |
| `sqlite_insertjson(db@, t$, o@) → num` | inserts an object as a row, keys as columns, values bound rather than pasted into SQL; answers the number of rows written. `0` for an empty object, a handle that is not an object, or an insert SQLite refused |
| `sqlite_updatejson(db@, t$, o@, where$) → num` | sets the object's keys on the rows matching `where$`, and answers **how many rows changed** — `0` when none matched, which is not an error. `where$` is spliced in as SQL, so it is the one place here you still have to escape by hand; an empty `where$` means *every row* |

### Transactions

| function | what it answers |
| --- | --- |
| `sqlite_begin(db@) → num` | `1` when a transaction opened, `0` when SQLite refused (one is already open, say) |
| `sqlite_commit(db@) → num` | `1` when the transaction committed |
| `sqlite_rollback(db@) → num` | `1` when it was rolled back and nothing inside it survived |
| `sqlite_intrans(db@) → num` | `1` while a transaction is open — read from SQLite's autocommit flag, so it is right even if the `BEGIN` came from a raw `sqlite_exec` |

### Escaping

| function | what it answers |
| --- | --- |
| `sqlite_escape$(s$) → str` | the string with every apostrophe doubled: `O'Brien` → `O''Brien`. Nothing else is touched |
| `sqlite_quote$(s$) → str` | the same, wrapped in apostrophes: `'O''Brien'`, ready to drop into hand-built SQL. Binding is still better where a statement can be prepared |

### Errors and maintenance

| function | what it answers |
| --- | --- |
| `sqlite_error() → num` | the last SQLite error code, `0` when nothing has failed. It is module-wide, not per-database, and it is **sticky**: it stays until the next failure or a `sqlite_clearerror()` |
| `sqlite_errormsg$() → str` | the message that came with it, `""` when there is none |
| `sqlite_strerror$(code) → str` | SQLite's own English name for a code; `""` when the runtime library never loaded |
| `sqlite_clearerror() → num` | clears the code and the message; always answers `0`, which is what `sqlite_error()` will now say. Call it before an operation you intend to test |
| `sqlite_backup(db@, path$) → num` | `1` after writing a standalone copy of the whole database to `path$` (`VACUUM INTO`). `0` when SQLite refused — most often because `path$` already exists, so delete it first |
| `sqlite_vacuum(db@) → num` | `1` after compacting the database in place, `0` when it could not (inside a transaction, for one) |

## A worked example

A tiny staff table in a database that never touches the disk: created, filled
through one prepared statement inside a transaction, then read back twice — once
column by column, once as JSON.

```basic
rem Requires the SQLite runtime library; without it every call below is inert,
rem so ask once and say so rather than printing a page of zeroes.
if sqlite_available() = 0 then
  println "no SQLite runtime on this machine"
else
  db@ = sqlite_open@()
  sqlite_exec(db@, "create table staff (id integer primary key, name text, age integer)")

  names@ = strings@()
  strings_add(names@, "Ada")
  strings_add(names@, "Bob")
  strings_add(names@, "Cat")

  rem One statement, reset and re-bound per row, all inside one transaction.
  ins@ = sqlite_prepare@(db@, "insert into staff (name, age) values (?, ?)")
  sqlite_begin(db@)
  for i = 1 to strings_count(names@)
    sqlite_reset(ins@)
    sqlite_clearbind(ins@)
    sqlite_bindstr(ins@, 1, strings_strings$(names@, i))
    sqlite_bindnum(ins@, 2, 28 + i)
    sqlite_step(ins@)
  next
  sqlite_commit(db@)
  sqlite_finalize(ins@)
  strings_free(names@)
  println "last id " + str$(sqlite_lastid(db@)) + ", " + str$(sqlite_scalar(db@, "select count(*) from staff")) + " rows"

  rem The cursor path: columns by name, one row at a time.
  cur@ = sqlite_query@(db@, "select name, age from staff order by age desc")
  while sqlite_step(cur@) = 1
    println sqlite_gets$(cur@, "name") + " is " + str$(sqlite_getn(cur@, "age"))
  endwhile
  sqlite_finalize(cur@)

  rem The JSON path: the same rows in one handle, read with the json library.
  all@ = sqlite_fetchall@(sqlite_query@(db@, "select name from staff order by name"))
  for i = 1 to json_len(all@)
    println str$(i) + ": " + json_gets$(json_item@(all@, i), "name")
  next

  sqlite_close(db@)      rem closes the database and any cursor still open on it
endif
```

Where the runtime is installed it prints `last id 3, 3 rows`, then the three rows
oldest first — `Cat is 31`, `Bob is 30`, `Ada is 29` — and then the same three names
in alphabetical order out of the JSON array. Two things worth noticing:

- **`sqlite_reset` and `sqlite_clearbind` are separate.** Reset rewinds the
  statement but keeps the bound values, which is exactly what you want when only
  one parameter changes; clearing is a second, deliberate step.
- **The last `sqlite_query@` is never finalized, and that is safe.** `sqlite_close`
  finalizes every statement opened on the connection and revokes its handle id, so
  a leftover cursor is freed rather than leaked — and a program that kept the id
  would find it refused afterwards, not honoured.

## Notes

**Checking a failure takes two calls.** Because every function answers a value
rather than raising, the shape of careful code is `sqlite_clearerror()`, then the
operation, then `if sqlite_error() then ...`. Testing the returned value alone
cannot distinguish "no rows" from "that was not SQL".

**Bytes survive.** A text or blob column is read by its byte length, not to the
first NUL, so a value holding a zero byte comes back whole — `bytelen(v$)` of what
`sqlite_getstr$` answers matches what SQL's own length function reports for the
same column, four bytes for `x'41004243'` and not one. The byte-level readers
in [buffer.md](buffer.md) and the `byte*` string functions are how you then take it
apart.

**Where the JSON handles go.** `sqlite_tables@`, `sqlite_columns@`, `sqlite_row@`,
`sqlite_fetchone@` and `sqlite_fetchall@` each answer a JSON handle that the json
library owns and reads; see [json.md](json.md). They are fresh documents, not
borrowed views into the cursor, so they stay valid after the next `sqlite_step`.
