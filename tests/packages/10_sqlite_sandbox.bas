rem ---------------------------------------------------------------
rem SQLite under the sandbox: the paths that arrive inside a STRING.
rem
rem sqlite_open@(path$) has asked the gate since the day a confined run
rem created a database in C:\Dev. That closed the front door and left
rem the side one open, because SQL NAMES FILES OF ITS OWN:
rem
rem   attach database '<anywhere>' as x    opens it, or creates it
rem   vacuum into '<anywhere>'             writes a whole copy of it
rem
rem The path there is a few characters inside a query, so a gate on the
rem ARGUMENTS never sees it -- and a sandboxed script used that to read
rem any database on the disk and to drop complete copies of its own
rem outside the root, while file_writealltext to the same directory was
rem refused. sqlite_backup was the third door: it pastes its caller's
rem path into VACUUM INTO and asked nothing.
rem
rem The guard is not a SQL parser. It is SQLite's own authorizer
rem (sqlite3_set_authorizer), which the parser consults for every
rem statement, so every spelling of ATTACH reaches it -- upper case,
rem comments and newlines between the tokens, a second statement after
rem a semicolon -- and VACUUM INTO reaches it too, because SQLite
rem implements that as an attach of the destination. Both are refused
rem BEFORE the file is opened or created, which is why the assertions
rem below can name an outside path at all.
rem
rem NOTHING HERE DELETES OR OVERWRITES ANYTHING OUTSIDE THE ROOT, and
rem nothing outside it is even expected to exist. Every refusal asserted
rem here is a CREATE that must not happen; if the guard ever regressed,
rem the worst this file could do is leave a few stray databases in the
rem parent of the checkout. The runner sets the root to its working
rem directory, so "outside" means the parent of that -- the same
rem convention as 58_sandbox.
rem
rem Two things this file deliberately does NOT do.
rem
rem It does not assert file_exists() on an outside path. A confined
rem script cannot see out of its own cage: file_exists is gated too and
rem answers 0 whether or not the file is there, so such an assertion can
rem never fail and would be decoration dressed as proof. The refusal is
rem asserted on the answer the call gives, which is the thing the guard
rem decides. That nothing lands outside was measured from OUTSIDE the
rem cage, by listing the directory after a sweep of every spelling.
rem
rem And no two refusals share a destination. VACUUM INTO declines to
rem overwrite a file that already exists, so a second write to a path an
rem earlier line had created would answer 0 for a reason that has
rem nothing to do with the sandbox -- an assertion passing for the wrong
rem reason, which is how a guard gets removed without a test noticing.
rem Each line below names a path of its own.
rem
rem PRAGMA temp_store_directory / data_store_directory and
rem load_extension() are gated by the same authorizer, and are left out
rem of this file on purpose: the first two are compiled in on some
rem platforms and not others, so an assertion on them would be
rem byte-exact on one OS and not the other. data_store_directory has a
rem second reason, and it is worth writing down because it hides a real
rem escape. Setting it moves the base a RELATIVE database name resolves
rem against -- but only on Windows, whose VFS reads the global; the unix
rem VFS ignores it. So the very sequence that walks a relative ATTACH out
rem of the root on one OS is an ordinary inside-the-root attach on the
rem other, and no assertion on it can be byte-exact on both. The gate
rem answers it by resolving every name through SQLITE'S OWN resolver
rem (sqlite3_vfs_find(nil)^.xFullPathname) instead of the process's
rem working directory, so whatever base SQLite prefers is the base the
rem gate judges. What IS the same on both systems is the OTHER half of
rem that class -- the MOMENT rather than the base -- and the last two
rem cases below are that half.
rem ---------------------------------------------------------------

test_case("sqlite/sandbox/the cage is real")

root$ = sandboxroot$()
assert_true(len(root$), "the runner set a sandbox root")
out$ = dir_getparent$(root$)
assert_true(len(out$), "and the parent of it is a real path")

stray$ = path_combine$(out$, "p9b_sqlite_escape.db")
assert_eq(file_writealltext(stray$, "x"), 0, "a plain write outside the root is refused")
rem Cleared first, every time a message is asserted on: without that, a stale
rem message from an earlier refusal would let the assertion pass while the call
rem under it succeeded -- a green line proving nothing.
sqlite_clearerror()
assert_eq(sqlite_isopen(sqlite_open@(stray$)), 0, "sqlite_open@ outside the root is refused too")
assert_eq(sqlite_errormsg$(), "refused: the path is outside the sandbox root", "in this package's own words")

test_case("sqlite/sandbox/a path inside a statement is still a path")

db@ = sqlite_open@()
assert_true(sqlite_isopen(db@), "an in-memory database opens")
rem The reported escape started here -- with no file of its own at all.
assert_eq(sqlite_exec(db@, "create table t (a text)"), 1, "and takes ordinary SQL")
assert_eq(sqlite_exec(db@, "insert into t values ('payload')"), 1, "and holds a row worth stealing")

sqlite_clearerror()
assert_eq(sqlite_exec(db@, "attach database '" + stray$ + "' as e1"), 0, "ATTACH outside the root is refused")
assert_eq(sqlite_errormsg$(), "refused: the path is outside the sandbox root", "with the same words as sqlite_open@")
assert_eq(sqlite_error(), 14, "and the same code")

rem Every spelling reaches the same guard, because SQLite's own parser
rem is what recognises the statement -- not a scan of the text.
up$ = root$ + "/../p9b_sqlite_escape2.db"
assert_eq(sqlite_exec(db@, "attach database '" + up$ + "' as e2"), 0, "a '..' climbing out of the root is refused")
assert_eq(sqlite_exec(db@, "AtTaCh   DataBase   '" + stray$ + "'   As   e3"), 0, "so is the mixed-case spelling")
assert_eq(sqlite_exec(db@, "/*x*/ attach /*y*/ database '" + stray$ + "' as e4"), 0, "and one with comments between the tokens")
assert_eq(sqlite_exec(db@, "select 1; attach database '" + stray$ + "' as e5"), 0, "and one hiding behind a first statement")
assert_eq(sqlite_exec(db@, "attach database ?1 as e6"), 0, "a filename bound as a parameter, which the gate cannot read, is refused")

test_case("sqlite/sandbox/vacuum into and backup name a file too")

rem A destination of its own for each, so that none of these can answer 0
rem because an earlier line already made the file.
vac1$ = path_combine$(out$, "p9b_sqlite_vac1.db")
vac2$ = root$ + "/../p9b_sqlite_vac2.db"
bak1$ = path_combine$(out$, "p9b_sqlite_bak1.db")
rem And the message is asserted with each of them, not just the answer.
rem VACUUM INTO also answers 0 for "output file already exists" -- so if the
rem guard ever regressed and left these files behind, the NEXT run would read a
rem refusal that never happened. The words say which of the two it was.
sqlite_clearerror()
assert_eq(sqlite_exec(db@, "vacuum into '" + vac1$ + "'"), 0, "VACUUM INTO outside the root is refused")
assert_eq(sqlite_errormsg$(), "refused: the path is outside the sandbox root", "before the file is made, not after")
sqlite_clearerror()
assert_eq(sqlite_exec(db@, "VaCuUm   InTo   '" + vac2$ + "'"), 0, "however it is spelt, wherever it points")
assert_eq(sqlite_errormsg$(), "refused: the path is outside the sandbox root", "and the same words for that one")
sqlite_clearerror()
assert_eq(sqlite_backup(db@, bak1$), 0, "sqlite_backup outside the root is refused")
assert_eq(sqlite_errormsg$(), "refused: the path is outside the sandbox root", "by the gate on its own argument")
assert_eq(sqlite_backup(db@, ""), 0, "and the empty path -- the drive root -- with it")

test_case("sqlite/sandbox/inside it, nothing changed")

rem The mirror. A sandbox that refuses legitimate work is as useless as
rem one that lets everything through, so every ordinary use of these
rem three still has to answer 1.
kept$ = "bin/p9b_sqlite_attached.db"
copy$ = "bin/p9b_sqlite_vacuum.db"
back$ = "bin/p9b_sqlite_backup.db"
file_delete(kept$)
file_delete(copy$)
file_delete(back$)

assert_eq(sqlite_exec(db@, "attach database '" + kept$ + "' as g1"), 1, "ATTACH inside the root works")
assert_eq(sqlite_exec(db@, "create table g1.kept as select * from t"), 1, "and writing through it works")
assert_eq(sqlite_exec(db@, "attach database ':memory:' as g2"), 1, "':memory:' is no file, and is allowed")
assert_eq(sqlite_exec(db@, "attach database '' as g3"), 1, "nor is sqlite's own anonymous scratch database")
assert_eq(sqlite_exec(db@, "vacuum into '" + copy$ + "'"), 1, "VACUUM INTO inside the root works")
assert_eq(sqlite_backup(db@, back$), 1, "sqlite_backup inside the root works")
assert_eq(sqlite_vacuum(db@), 1, "plain sqlite_vacuum still runs")
assert_eq(sqlite_scalar$(db@, "select a from t"), "payload", "and ordinary queries are untouched")
assert_true(file_exists(copy$), "the vacuum copy is on disk")
assert_true(file_exists(back$), "and so is the backup")
sqlite_close(db@)

rem And what went through the attached handle really landed in the file.
r@ = sqlite_open@(kept$)
assert_true(sqlite_isopen(r@), "the attached database reopens on its own")
assert_eq(sqlite_scalar$(r@, "select a from kept"), "payload", "holding the row written through the attach")
sqlite_close(r@)

assert_eq(file_delete(kept$), 1, "and the three files tidy up")
assert_eq(file_delete(copy$), 1, "the vacuum copy too")
assert_eq(file_delete(back$), 1, "and the backup")

test_case("sqlite/sandbox/the same base, and the same moment")

rem ATTACH is authorized when the statement is PREPARED and opens its
rem file when the statement is STEPPED. Those are two different moments,
rem and between them a script may move the working directory that a
rem relative name resolves against -- so the name the authorizer approved
rem then names a DIFFERENT file. Measured on 3.48.0 before this was
rem closed: prepared one directory down, stepped from its parent, the
rem file landed one level ABOVE the root while the callback had been told
rem a path inside it. sqlite_exec cannot be used this way (it prepares
rem and steps inside one call, with no script in between); sqlite_prepare@
rem plus sqlite_step can, which is why the route is asserted here.
rem
rem The answer is to ask the same question again at the step, against the
rem base in force then -- so a legitimate prepared ATTACH still works,
rem including one stepped from somewhere else inside the root.
rem ABSOLUTE from here on: the cases below move the working directory, and
rem a relative path means something different after each move.
home$ = dir_getcurrent$()
deep$ = home$ + "/bin/p9b_sqlite_deep"
inner$ = deep$ + "/inner"
assert_eq(dir_create(inner$), 1, "a directory two levels inside the root")
rem Cleared first, like the three files above: ATTACH is happy to reopen a
rem database that already exists, so a leftover from an earlier run would
rem let the mirror pass without the attach having created anything.
file_delete(deep$ + "/p9b_sqlite_ok.db")
db2@ = sqlite_open@()
assert_true(sqlite_isopen(db2@), "a second in-memory database")
assert_eq(sqlite_exec(db2@, "create table t (a text)"), 1, "with a table")
assert_eq(sqlite_exec(db2@, "insert into t values ('payload')"), 1, "and a row")

assert_eq(dir_setcurrent(inner$), 1, "the script steps down into it")
rem Three levels up from bin/p9b_sqlite_deep/inner is the root itself, so
rem the authorizer sees a path INSIDE and approves it.
sqlite_clearerror()
mv@ = sqlite_prepare@(db2@, "attach database '../../../p9b_sqlite_moment.db' as mv")
assert_eq(sqlite_error(), 0, "the ATTACH is authorized at prepare, inside the root")
rem One directory up, and the very same '../../..' now names the root's parent.
assert_eq(dir_setcurrent(deep$), 1, "then steps back up one")
sqlite_clearerror()
assert_eq(sqlite_step(mv@), 0, "the step that would create the file is refused")
assert_eq(sqlite_error(), 14, "with the same code as every other door")
assert_eq(sqlite_errormsg$(), "refused: the path is outside the sandbox root", "and the same words")
sqlite_finalize(mv@)
assert_eq(sqlite_exec(db2@, "create table mv.stolen as select * from t"), 0, "so nothing can be written through it")

rem The mirror for that guard: a prepared ATTACH whose meaning MOVES with
rem the working directory but stays inside the root must still go through.
assert_eq(dir_setcurrent(inner$), 1, "back down into the inner directory")
ok@ = sqlite_prepare@(db2@, "attach database 'p9b_sqlite_ok.db' as okdb")
assert_eq(dir_setcurrent(deep$), 1, "and up one again")
sqlite_clearerror()
assert_eq(sqlite_step(ok@), 0, "an ATTACH is not a row, so its step answers 0")
assert_eq(sqlite_errormsg$(), "", "but it was not refused")
sqlite_finalize(ok@)
assert_eq(sqlite_exec(db2@, "create table okdb.kept as select * from t"), 1, "and it can be written through")
assert_eq(dir_setcurrent(home$), 1, "the working directory goes back where it was")
assert_true(file_exists(deep$ + "/p9b_sqlite_ok.db"), "the attached file is where the STEP said, not where the prepare did")

test_case("sqlite/sandbox/a refusal that lands on the step says so too")

rem VACUUM INTO's authorizer callback arrives at the STEP, not at the
rem prepare -- measured against the library, not assumed -- so the
rem prepare@/step route saw sqlite's own "authorization denied" (23)
rem while the exec route answered this package's words. Same guard, same
rem outcome (no file is created either way); different story told to the
rem script. All four doors now answer 14 and the one sentence.
rem A destination of its own for each, again: VACUUM INTO also declines to
rem overwrite a file that exists, and that 0 would mean something else.
ps$ = path_combine$(out$, "p9b_sqlite_prepstep.db")
sc$ = path_combine$(out$, "p9b_sqlite_scalar.db")
qy$ = path_combine$(out$, "p9b_sqlite_query.db")
sqlite_clearerror()
vi@ = sqlite_prepare@(db2@, "vacuum into '" + ps$ + "'")
assert_eq(sqlite_error(), 0, "the prepare itself is never asked about the path")
assert_eq(sqlite_step(vi@), 0, "the step is, and refuses")
assert_eq(sqlite_error(), 14, "with the code every other door reports")
assert_eq(sqlite_errormsg$(), "refused: the path is outside the sandbox root", "in the package's words, not sqlite's")
sqlite_finalize(vi@)

rem sqlite_scalar$ and sqlite_query$ prepare and step inside one call and
rem reported NOTHING for this: no code, no message, an empty answer.
sqlite_clearerror()
assert_eq(sqlite_scalar$(db2@, "vacuum into '" + sc$ + "'"), "", "sqlite_scalar$ answers empty")
assert_eq(sqlite_error(), 14, "and now records why")
assert_eq(sqlite_errormsg$(), "refused: the path is outside the sandbox root", "with the same sentence")
sqlite_clearerror()
assert_eq(sqlite_query$(db2@, "vacuum into '" + qy$ + "'"), "", "sqlite_query$ answers empty")
assert_eq(sqlite_error(), 14, "and records why as well")
assert_eq(sqlite_errormsg$(), "refused: the path is outside the sandbox root", "same words at the last door")
sqlite_close(db2@)

rem Tidied with the ONE-ARGUMENT dir_delete, which is RemoveDir and refuses
rem a directory that still has anything in it. No shipped test of this
rem project calls a recursive remover, and this one does not need to: the
rem two assertions below are also the proof that the refused ATTACH left
rem nothing behind.
assert_eq(file_delete(deep$ + "/p9b_sqlite_ok.db"), 1, "the attached file tidies up")
assert_eq(dir_delete(inner$), 1, "the inner directory comes out, so it was empty")
assert_eq(dir_delete(deep$), 1, "and the one above it, so nothing else was written")
