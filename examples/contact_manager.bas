rem ===============================================================
rem Phosphor BASIC -- Contact Manager: suppliers, customers and the
rem people you talk to there, kept in SQLite.
rem
rem THIS PROGRAM DOES NOT RETURN when it is run normally: app_run()
rem below is a message loop that waits for a person. Run it by hand,
rem from a desktop:
rem
rem   phosphor examples/contact_manager.bas
rem
rem The database is phosphor-contacts.db in your Documents folder (in your
rem home folder when there is no Documents folder), or the file named on
rem the command line (phosphor contact_manager.bas my.db), or the one
rem PHOSPHOR_CONTACTS_DB names; File > Open database... picks another one.
rem When that file cannot be opened it says why and offers to pick another
rem file or to end. The first run asks for an administrator account and
rem offers to load sample data. PHOSPHOR_CONTACTS_DEMO=1 skips all of that:
rem a throw-away database with the samples, signed in as "demo".
rem
rem With PHOSPHOR_SELFTEST=1 in the environment it does something else:
rem it builds every window WITHOUT showing one, drives them the way a
rem person would -- typing into fields, clicking buttons, picking grid
rem rows -- against a throw-away database, checks what landed in
rem SQLite, prints "passed: N / failed: M" and returns. That is how
rem scripts/test-examples runs it on Windows and Linux.
rem
rem What it shows off:
rem   - SQLite: a schema with foreign keys (ON DELETE CASCADE / SET
rem     NULL), a partial unique index, a many-to-many link table,
rem     transactions, and every statement prepared with bound
rem     parameters -- no user text is ever pasted into SQL.
rem   - crypto: passwords are kept as salted PBKDF2 records
rem     (password_hash$ / password_verify?), never as text.
rem   - GUI: forms, a main menu, a status bar, page controls with tab
rem     sheets, string grids used as record lists (stringgrid_onselect@),
rem     double click, edits (one masked for passwords), a masked edit,
rem     memos, combo boxes, a check list box, check boxes, a calendar,
rem     group boxes and panels, and the message, confirm, open and save
rem     dialogs.
rem ===============================================================

const APP$ = "Contact Manager"
const KINDS$ = "supplier,customer"

rem --- the columns each record has, in form order -------------------------
const COMPANY_COLS$ = "name,trade_name,tax_id,category,phone,email,website,extra,payment_terms,postal_code,address,number,complement,district,city,state,country,notes"
const CONTACT_COLS$ = "name,job_title,department,email,phone,mobile,whatsapp,linkedin,instagram,other_social,birthday,notes"
const INTERACTION_KINDS$ = "Call,Meeting,E-mail,WhatsApp,Visit,Other"

rem The schema's version, kept in the database as PRAGMA user_version (see
rem create_schema): 1 was the first, 2 added the normalized keys, 3 made
rem them case FOLDED (fold$) and marked the file as this program's.
const SCHEMA_VERSION = 3
rem What PRAGMA application_id holds in a file this program made: "PhCM" as
rem a 32-bit number. Versions 1 and 2 set none; see db_owner$.
const APP_ID = 1349010253
rem Why no database -- opened, or written as a backup -- goes under a name
rem SQLite keeps beside a database.
const JOURNAL_NAME_MSG$ = "A name ending in -journal, -wal or -shm is where SQLite keeps a database's unfinished work: a database there would be cut short by the one it sits beside, or taken for that one's unfinished work and deleted. Use another name."

selftest? = false
if environ$("PHOSPHOR_SELFTEST") = "1" then selftest? = true

rem --- state shared by the handlers (an undeclared name inside a function
rem     is a GLOBAL in Phosphor, which is exactly what these are) ---------------
db@ = sqlite_open@()
sqlite_close(db@)
dbpath$ = ""
read_only? = false         rem the open database refused the sign-in's write
schema_msg$ = ""           rem why create_schema failed, in words
widgets@ = pdict@()        rem every control worth finding again, by name
rowids@ = dict@()          rem per grid: its row <-> id maps, its column widths
current@ = dict@()         rem "s.company", "c.contact", "s.history", "user", "line" -> id
busy = 0                   rem > 0 while the program itself is filling controls
user_id = 0
user_name$ = ""
user_role$ = ""
signing_out? = false
first_run? = false
pw_cost = 600000           rem PBKDF2 rounds: password_hash$'s own default
last_msg$ = ""             rem what the last message box said (self-test)
answer? = true             rem what a confirmation answers (self-test)
save_as$ = ""              rem what a save dialog answers (self-test)
open_as$ = ""              rem what an open dialog answers, once (self-test)
short_write = 0            rem > 0: the export writes only so many bytes (self-test)
step_err$ = ""             rem what the last step_ok failed with
probe_err$ = ""            rem why is_open_db could not tell (backup)
hdr_version = 0            rem what file_header$ read: user_version,
hdr_app = 0                rem   application_id,
hdr_err$ = ""              rem   and why it could not read the file
name_err$ = ""             rem why sqlite_name$ could not answer
canon$ = ""                rem the one name name_refusal$ found a path leads to
name_safe? = false         rem this SQLite names a file without reading it
fold_map@ = sdict@()       rem fold$'s table: character -> its case folding
fold_probe@ = sdict@()     rem what fold$ looks for before walking a string
passed = 0
failed = 0

rem SQLite is a runtime library the interpreter loads when it is there
rem (sqlite3.dll on Windows, libsqlite3 on Linux); without it there is
rem nothing to keep the contacts in.
if sqlite_available() = 0 then
  if selftest? = true then
    println "SKIP: the SQLite runtime library is not installed"
  else
    msgbox("This program keeps its data in SQLite, and the SQLite runtime library was not found. Install it (sqlite3.dll on Windows, libsqlite3 on Linux) and start it again.", APP$)
  end if
  end
end if
rem Before 3.39.0, PRAGMA database_list -- how sqlite_name$ asks SQLite
rem for a file's name -- reads the file to answer, and reading it is what
rem rolls a hot journal back into it (SQLite's tool/mkpragmatab.tcl gives
rem the pragma the NeedSchema flag up to 3.38.x and not from 3.39.0). An
rem older library is still used, without that question: see may_open_db.
name_safe? = version_at_least?(sqlite_version$(), "3.39.0")

fold_init()
randomize()
build_login_form()
build_main_form()
build_password_form()
build_notice_form()

if selftest? = true then
  run_selftest()
  end
end if

opened = 0
if environ$("PHOSPHOR_CONTACTS_DEMO") = "1" then
  opened = start_demo()
elseif paramcount() >= 1 then
  opened = open_database(paramstr$(1))
elseif environ$("PHOSPHOR_CONTACTS_DB") <> "" then
  opened = open_database(environ$("PHOSPHOR_CONTACTS_DB"))
else
  opened = open_database(default_db_path$())
end if
rem app_run() with no window showing would never return: nothing on screen
rem could close it. So a database that would not open is either replaced by
rem one the person picks, or the program ends here.
if opened <> 1 then opened = open_another()
if opened <> 1 then end
app_run()
end

rem ===============================================================
rem  Small helpers
rem ===============================================================

rem The n-th item of a comma list (base-1), "" past the end.
function nth$(list$, n) local i, p, rest$
  rest$ = list$
  for i = 1 to n - 1
    p = instr(rest$, ",")
    if p = 0 then return ""
    rest$ = mid$(rest$, p + 1)
  next
  p = instr(rest$, ",")
  if p = 0 then return rest$
  return left$(rest$, p - 1)
end function

rem How many items a comma list holds.
function count_items(list$) local n, i
  if list$ = "" then return 0
  n = 1
  for i = 1 to len(list$)
    if mid$(list$, i, 1) = "," then n = n + 1
  next
  return n
end function

function kind$(k)
  return nth$(KINDS$, k)
end function

rem 1 or 0 from a condition, for the setters that take a number.
function flag(ok?)
  if ok? = true then return 1
  return 0
end function

rem "s" for suppliers, "c" for customers: the prefix of their widget names.
function pre$(k)
  return left$(kind$(k), 1)
end function

function w@(key$)
  return pdict_get@(widgets@, key$)
end function

function keep@(key$, h@)
  pdict_set@(widgets@, key$, h@)
  return h@
end function

function cur(key$)
  return dict_getdef(current@, key$, 0)
end function

function set_cur(key$, id)
  dict_set@(current@, key$, id)
  return id
end function

rem --- dialogs, routed through one place so the self-test can answer them ---
function say(msg$)
  last_msg$ = msg$
  if selftest? = false then msgbox(msg$, APP$)
  return 0
end function

function ask?(msg$)
  last_msg$ = msg$
  if selftest? = true then return answer?
  return msgbox_confirm(msg$) = 1
end function

rem An open dialog -- or, in the self-test, the path it was told to use,
rem answered once: a loop that asks again gets "" (cancel) the second time.
function choose_file$(filter$) local p$
  if selftest? = false then return openfile$(filter$)
  p$ = open_as$
  open_as$ = ""
  return p$
end function

function show(f@)
  if selftest? = false then form_show@(f@)
  return 0
end function

function hide(f@)
  if selftest? = false then form_close@(f@)
  return 0
end function

function status(msg$)
  statusbar_text@(w@("status"), msg$)
  return 0
end function

rem --- building blocks for the forms ------------------------------------------
function lbl@(parent@, x, y, text$) local l@
  l@ = label@(parent@, text$)
  control_move@(l@, x, y)
  return l@
end function

rem A label with an edit under it, both kept: the edit as key$, the label
rem as key$ + ".label".
function field@(key$, parent@, x, y, wd, caption$) local e@
  keep@(key$ + ".label", lbl@(parent@, x, y, caption$))
  e@ = edit@(parent@)
  control_bounds@(e@, x, y + 17, wd, 24)
  return keep@(key$, e@)
end function

function memo_field@(key$, parent@, x, y, wd, ht, caption$) local m@
  lbl@(parent@, x, y, caption$)
  m@ = memo@(parent@)
  control_bounds@(m@, x, y + 17, wd, ht)
  control_set@(m@, "ScrollBars", "ssAutoVertical")
  return keep@(key$, m@)
end function

function button_at@(key$, parent@, x, y, wd, caption$, handler$, tag) local b@
  b@ = button@(parent@)
  button_caption@(b@, caption$)
  control_bounds@(b@, x, y, wd, 30)
  control_tag@(b@, tag)
  button_onclick@(b@, handler$)
  return keep@(key$, b@)
end function

function pick_list@(key$, parent@, x, y, wd, caption$, items$) local c@, i
  if caption$ <> "" then lbl@(parent@, x, y, caption$)
  c@ = combobox@(parent@)
  control_set@(c@, "Style", "csDropDownList")
  control_bounds@(c@, x, y + 17, wd, 24)
  for i = 1 to count_items(items$)
    combo_add@(c@, nth$(items$, i))
  next
  if count_items(items$) > 0 then combo_itemindex@(c@, 1)
  return keep@(key$, c@)
end function

rem A string grid used as a record list: whole-row selection, one header
rem row, no fixed column, the column titles given as a comma list, and
rem the columns sharing px pixels by the proportions in widths$.
function record_grid@(key$, parent@, titles$, widths$, px, handler$, tag) local g@, i
  g@ = stringgrid@(parent@)
  control_set@(g@, "FixedCols", 0)
  stringgrid_colcount@(g@, count_items(titles$))
  stringgrid_rowcount@(g@, 1)
  stringgrid_fixedrows@(g@, 1)
  control_set@(g@, "Options", "goFixedVertLine,goFixedHorzLine,goVertLine,goHorzLine,goRowSelect,goColSizing,goThumbTracking")
  control_set@(g@, "DefaultRowHeight", 22)
  for i = 1 to count_items(titles$)
    stringgrid_cell@(g@, i, 1, nth$(titles$, i))
  next
  control_tag@(g@, tag)
  rows_begin(key$)
  sdict_set@(rowids@, key$ + ".widths", widths$)
  sdict_set@(rowids@, key$ + ".px", str$(px))
  stringgrid_onselect@(g@, handler$)
  return keep@(key$, g@)
end function

rem Share the grid's width out between its columns by the proportions
rem given as "w,w,w" when it was built.
function size_grid_columns(key$) local g@, total, i, n, ws$, sum
  g@ = w@(key$)
  ws$ = sdict_get$(rowids@, key$ + ".widths")
  n = count_items(ws$)
  sum = 0
  for i = 1 to n
    sum = sum + val(nth$(ws$, i))
  next
  total = val(sdict_get$(rowids@, key$ + ".px")) - 34
  for i = 1 to n
    stringgrid_colwidth@(g@, i, int(total * val(nth$(ws$, i)) / sum))
  next
  return 0
end function

rem Which record each row of a list shows, and which row shows a record:
rem two dictionaries per list, "key.byrow" (row -> id) and "key.byid"
rem (id -> row), so both questions cost the same at ten rows or ten
rem thousand. They were one "id,id,id" string walked with nth$ until
rem 2026-10-10 -- a walk per row looked up, which made a refresh of 2,000
rem companies take seconds, on every keystroke in Search. A refresh frees
rem both and starts again (rows_begin), then numbers its rows as it lists
rem them (rows_add). Row 1 is the first DATA row, under the header.
function rows_begin(key$)
  if dict_haskey(rowids@, key$ + ".byrow") = 1 then
    dict_free(dict_get@(rowids@, key$ + ".byrow"))
    dict_free(dict_get@(rowids@, key$ + ".byid"))
  end if
  dict_set@(rowids@, key$ + ".byrow", dict@())
  dict_set@(rowids@, key$ + ".byid", dict@())
  return 0
end function

function rows_add(key$, row, id)
  dict_set@(dict_get@(rowids@, key$ + ".byrow"), str$(row), id)
  dict_set@(dict_get@(rowids@, key$ + ".byid"), str$(id), row)
  return row
end function

rem The id on data row `row`; 0 when there is no such row.
function row_id(key$, row)
  return dict_getdef(dict_get@(rowids@, key$ + ".byrow"), str$(row), 0)
end function

rem The id of the record shown on the grid's current row; 0 when none.
function grid_id(key$) local row
  row = stringgrid_row(w@(key$)) - 1
  if row < 1 then return 0
  return row_id(key$, row)
end function

rem Put the cursor on the row showing record id (no event while busy);
rem 0 when the list does not show it.
function grid_select(key$, id) local row
  row = dict_getdef(dict_get@(rowids@, key$ + ".byid"), str$(id), 0)
  if row = 0 then return 0
  stringgrid_cursor@(w@(key$), 1, row + 1)
  return 1
end function

rem ===============================================================
rem  Database
rem ===============================================================

rem phosphor-contacts.db in the Documents folder -- or, where there is no
rem such folder (a Linux without ~/Documents), in the home folder, and
rem failing that in the current one. path_combine$ adds a separator only
rem when the folder does not already end in one: documentspath$() does.
function default_db_path$()
  return db_path_in$(documentspath$())
end function

function db_path_in$(docs$) local d$
  d$ = docs$
  if dir_exists(d$) <> 1 then d$ = homepath$()
  if dir_exists(d$) <> 1 then d$ = dir_getcurrent$()
  return path_combine$(d$, "phosphor-contacts.db")
end function

rem Open path$ and make it this session's database, then show the login.
rem The new file is opened and prepared BEFORE the old connection is let
rem go: a file that is not a usable database leaves whatever was open --
rem and whoever was signed in -- exactly as it was, and answers 0.
function open_database(path$) local new@, why$
  if may_open_db(path$) <> 1 then
    say("The database " + path$ + " could not be prepared: " + schema_msg$)
    return 0
  end if
  rem The name the checks judged, and not path$: through a Windows link
  rem SQLite would name the journal after the LINK and never roll back the
  rem one beside the file (round 10), so it is handed the file's own name.
  new@ = sqlite_open@(canon$)
  if sqlite_isopen(new@) <> 1 then
    say("Could not open the database " + path$ + ": " + sqlite_errormsg$())
    return 0
  end if
  if create_schema(new@) <> 1 then
    why$ = schema_msg$
    sqlite_close(new@)
    say("The database " + path$ + " could not be prepared: " + why$)
    return 0
  end if
  if sqlite_isopen(db@) = 1 then sqlite_close(db@)
  db@ = new@
  dbpath$ = path$
  read_only? = false
  dict_clear@(current@)
  prepare_login()
  show(w@("login"))
  return 1
end function

rem --- whose file it is, asked of its bytes and not of SQLite ---------------
rem SQLite does more than read a file it is asked to read. A program killed
rem in the middle of a transaction leaves a "hot journal" beside its file
rem (name-journal), and the first query of whoever opens the file next --
rem even PRAGMA user_version, even on a query_only connection -- rolls that
rem journal back INTO the file and deletes it. So whether a file may be
rem opened through SQLite at all is decided before, from its 100-byte
rem header read as a plain file (sqlite.org/fileformat.html, section 1.3):
rem "SQLite format 3" and a zero byte, then user_version as a big-endian
rem 32-bit number at offset 60 and application_id at offset 68.
rem file_header$ answers what it found -- "missing", "empty", "notdb", or
rem "db" with hdr_version and hdr_app set -- or "unread", with hdr_err$
rem saying why.
function file_header$(p$) local h$, i
  hdr_version = 0
  hdr_app = 0
  hdr_err$ = ""
  if file_exists(p$) <> 1 then return "missing"
  h$ = head$(p$, 100)
  if hdr_err$ <> "" then return "unread"
  if bytelen(h$) = 0 then return "empty"
  rem (two tests: `or` evaluates every operand, and byteat of a byte past
  rem the end of a short file is an error, not a no)
  if bytelen(h$) < 100 then return "notdb"
  if bytemid$(h$, 1, 15) <> "SQLite format 3" or byteat(h$, 16) <> 0 then return "notdb"
  for i = 0 to 3
    hdr_version = hdr_version * 256 + byteat(h$, 61 + i)
    hdr_app = hdr_app * 256 + byteat(h$, 69 + i)
  next
  rem both are SIGNED 32-bit numbers, as the PRAGMAs answer them
  if hdr_version >= 2147483648 then hdr_version = hdr_version - 4294967296
  if hdr_app >= 2147483648 then hdr_app = hdr_app - 4294967296
  return "db"
end function

rem The first n bytes of the file p$, read as a plain file -- "" when it
rem has none -- or "" with hdr_err$ saying why it could not be read. (A
rem channel closed on Linux drops the POSIX locks this process holds on
rem that file; a file is read only between statements, when the open
rem connection holds none.) Only a FILE is opened: opening a FIFO on Linux
rem or the console device CON on Windows waits for input that may never
rem come, and no execution limit reaches a program blocked in the system
rem call (round 10) -- so what is there is asked first (file_kind$).
function head$(p$, n) local h$, m, k$
  hdr_err$ = ""
  h$ = ""
  k$ = file_kind$(p$)
  if k$ <> "file" then
    if k$ = "none" then
      hdr_err$ = "nothing is there"
    elseif k$ = "" then
      hdr_err$ = "what is there could not be told"
    else
      hdr_err$ = "it is a " + k$ + ", not a plain file"
    end if
    return ""
  end if
  on error call header_fault
  open p$ for input as #7
  if hdr_err$ = "" then
    m = lof(7)
    if m > n then m = n
    if m > 0 then h$ = input$(m, #7)
    close #7
  end if
  on error goto 0
  return h$
end function

rem head$'s error handler: what went wrong is its answer, and the reading
rem goes on past the statement that failed (0 = resume next).
function header_fault(code, msg$)
  if hdr_err$ = "" then hdr_err$ = msg$
  return 0
end function

rem The name SQLite itself gives the file p$: the full path it opens, and
rem the one it builds the names of the files it keeps beside it from
rem (NAME-journal, NAME-wal) -- asked of PRAGMA database_list, on a
rem connection that has run no query, so nothing beside the file has been
rem read or acted on yet. It is not always p$ made absolute: on Linux
rem SQLite follows a symbolic link to its target (os_unix.c,
rem unixFullPathname), so the journal it rolls back into a file reached
rem through a link is the one beside the TARGET; and on Windows it drops a
rem trailing dot or space (GetFullPathNameW), so "x.db." is x.db, with
rem x.db-journal. (Windows does NOT follow a link here: its full name of a
rem link is the link's own -- which is why every name is made canonical
rem first, name_refusal$, and SQLite is only ever handed that one.)
rem Opening CREATES a file that is
rem not there -- through a link that points at nothing, at the link's
rem target -- so this is asked only of a file that exists, or of one about
rem to be created anyway. And only a SQLite of 3.39.0 or later is asked
rem about a file that exists: an older one READS the file to answer
rem (name_safe?), which is the very thing this is asked to come before.
rem "" when it cannot be asked, or SQLite cannot open it, with name_err$
rem saying why.
function sqlite_name$(p$) local d@, s@, f$
  f$ = ""
  name_err$ = ""
  if name_safe? = false and file_exists(p$) = 1 then
    name_err$ = "SQLite " + sqlite_version$() + " reads a file to name it; 3.39.0 or later does not"
    return ""
  end if
  sqlite_clearerror()
  d@ = sqlite_open@(p$)
  if sqlite_isopen(d@) <> 1 then
    name_err$ = sqlite_errormsg$()
    return ""
  end if
  s@ = sqlite_prepare@(d@, "PRAGMA database_list")
  while sqlite_step(s@) = 1
    if sqlite_gets$(s@, "name") = "main" then f$ = sqlite_gets$(s@, "file")
  end while
  sqlite_finalize(s@)
  sqlite_close(d@)
  return f$
end function

rem Whether the version v$ ("3.45.3") is min$ or later, compared part by
rem part as numbers: "3.9.2" is older than "3.39.0", which a comparison of
rem the two strings would answer the other way round.
function version_at_least?(v$, min$) local i, a, b
  for i = 1 to 3
    a = val(word$(v$, i, "."))
    b = val(word$(min$, i, "."))
    if a <> b then return a > b
  next
  return true
end function

rem Why the name p$ must not be handed to SQLite as a database's at all;
rem "" when it may be -- and then canon$ holds the name everything after is
rem done with: the one the OS gives the file (path_canonical$).
rem A FILE IS JUDGED BY WHAT IT IS, NOT BY HOW IT IS SPELLED (round 10).
rem Until then this read the name, and the OS has more spellings of a file
rem than any list: on Windows the 8.3 alias of a journal (TRUNCV~1.DB- for
rem truncvictim.db-journal) and of a link that leads to one (LONGLI~1.DAT),
rem a stream inside a journal (other.db-journal:bk, deleted with it at that
rem database's next commit), the main stream spelled out (x.db-wal::$DATA
rem IS x.db-wal), the console (CON, which blocks whoever reads it); on
rem Linux a FIFO (whose open blocks). Each reached a database or a backup
rem past every check. So the OS is asked what the name IS (file_kind$) and
rem what its one name is (path_canonical$), and the name rules are asked
rem of that. Refused:
rem  - one SQLite does not read as a path: "" and ":memory:" are databases
rem    with no file, and one beginning "file:" is a URI wherever the library
rem    was built to read URIs (Ubuntu's libsqlite3 is; the sqlite.org DLL
rem    is not). SQLite would open the file the URI names, which nothing
rem    here has looked at -- and roll a journal beside it back at the first
rem    query. Refused on every system, so the two do not differ -- and
rem    compared EXACTLY, as SQLite compares them (sqlite3ParseUri's memcmp
rem    of "file:", strcmp of ":memory:"): "FILE:x.db" is a file on Linux;
rem  - a stream (Windows: any name:stream, name::$DATA too), a device or a
rem    pipe, a folder, or a link that leads to no file -- which has no
rem    canonical name, and SQLite would create the file it leads to,
rem    wherever that is;
rem  - one SQLite keeps beside a database (journal_name?), as spelled or as
rem    the OS names it.
function name_refusal$(p$) local k$, c$
  canon$ = ""
  if p$ = "" or p$ = ":memory:" or left$(p$, 5) = "file:" then return "SQLite does not read that as the name of a file -- a name beginning with file: is a URI, and :memory: or no name at all is a database with no file. Give the file's path."
  k$ = file_kind$(p$)
  if k$ = "stream" then return "That name is a stream inside a file (name:stream), not a file of its own: a database there goes wherever that file goes, and if it is a journal, SQLite deletes it at its database's next commit. Use the name of a file."
  if k$ = "" then return "Could not tell what is at " + p$ + " (" + iostrerror$() + "). Use the name of a file in a folder you can read."
  c$ = path_canonical$(p$)
  if k$ = "link" and c$ <> "" then k$ = file_kind$(c$)
  if k$ = "device" or k$ = "fifo" or k$ = "socket" then return "Something is at " + p$ + " that is not a file but a device or a pipe: reading it waits for something that may never come. Use the name of a file."
  if k$ = "dir" or k$ = "link" then return "Something is at " + p$ + " that is not a file: a folder, or a link that leads to no file. Use the name of a file, or one that is not there yet."
  if c$ = "" then return "Could not tell where " + p$ + " leads: its folder is not there, or cannot be read. Use the name of a file in a folder that exists."
  if journal_name?(p$) = true then return JOURNAL_NAME_MSG$
  if journal_name?(c$) = true then return "That name leads to " + c$ + ". " + JOURNAL_NAME_MSG$
  canon$ = c$
  return ""
end function

rem The name of a file beside p$ -- p$ as SQLite names it, sqlite_name$ --
rem that SQLite would act on once p$ is opened; "" when there is none.
rem What it acts on is decided as SQLite decides it (pager.c,
rem hasHotJournal; sqlite.org/atomiccommit.html, 4.2):
rem  - NAME-journal holding anything, beside a file of no pages (empty, or
rem    not there): SQLite deletes it;
rem  - NAME-journal beside a file with pages, when its first byte is not
rem    zero: SQLite takes it for a hot journal and rolls it back -- or,
rem    when it does not begin the way a journal does, just deletes it. A
rem    journal whose first byte IS zero is not hot: it is one a program
rem    finished with in PERSIST mode, which commits by zeroing the header
rem    (sqlite.org/fileformat.html, 3.0), and SQLite leaves it alone;
rem  - NAME-wal holding anything: SQLite reads it as part of the file.
rem A journal that cannot be read is counted as one SQLite would act on.
rem ONE PART OF SQLite's DECISION IS NOT MADE HERE: hasHotJournal first
rem asks whether another connection holds a RESERVED lock on the file, and
rem a journal whose writer is still at work is not hot -- SQLite leaves it.
rem That lock cannot be asked from here without SQLite reading the file
rem (and reading it rolls the journal back when there is no such writer),
rem so a journal found here belongs either to a program changing the file
rem right now or to one that stopped in the middle, and judge_copy says so
rem in those words. (A log, likewise: NAME-wal is there while any program
rem has the file open, and after one that stopped.)
function unfinished$(p$) local j$, h$
  j$ = p$ + "-journal"
  if file_getsize(j$) > 0 then
    if file_getsize(p$) <= 0 then return j$
    h$ = head$(j$, 1)
    if hdr_err$ <> "" or bytelen(h$) = 0 then return j$
    if byteat(h$, 1) <> 0 then return j$
  end if
  if file_getsize(p$ + "-wal") > 0 then return p$ + "-wal"
  return ""
end function

rem Whether the file j$ begins the way a rollback journal does: the eight
rem bytes d9 d5 05 f9 20 a1 63 d7 (sqlite.org/fileformat.html, 3.0).
function journal_magic?(j$) local h$, i
  h$ = head$(j$, 8)
  if bytelen(h$) < 8 then return false
  for i = 1 to 8
    if byteat(h$, i) <> val(nth$("217,213,5,249,32,161,99,215", i)) then return false
  next
  return true
end function

rem Whether p$ may be opened through SQLite: 1 when its header carries this
rem program's application id, or when it is not there yet or empty or not
rem marked by any program -- then db_owner$ looks at its tables, which only
rem reads. Else 0, schema_msg$ says why, and the file has not been opened.
rem An unmarked file with unfinished work beside it is the one case where
rem looking is not only reading: SQLite acts on that work at the first
rem query. And it is THIS program's most likely crash: an upgrade marks the
rem file only as its last statement, so a version-1 or -2 file killed in
rem mid-upgrade (11 s for 50,000 companies) is unmarked, with a hot journal
rem -- and so is a first run killed before its first commit, an empty file
rem beside a journal. So the work is judged on a COPY (judge_copy): SQLite
rem does to the copy exactly what it would do to the file, and the copy's
rem owner is the file's. Only a file that would be this program's, or new,
rem once SQLite has done that, is opened; another program's is left, with
rem its journal, byte for byte as it was.
rem The work looked for is the work SQLite will find: beside the file as
rem SQLite names it (sqlite_name$), which through a symbolic link on Linux
rem or a trailing dot on Windows is another name than p$ -- judged by p$,
rem the journal SQLite rolls back was never looked at. A name that is not
rem there is asked too, though asking creates the file: opening it would
rem create it the next moment anyway, and through a link that points at
rem nothing the file created is the link's TARGET -- a journal's name, it
rem may be, which is refused and the empty file taken away again. (SQLite
rem deletes whatever lies beside a file of no pages, and the judge, which
rem would find it new, has nothing to refuse.) And a header that is not a
rem database's does not decide alone while such work lies beside it: a
rem page 1 torn by a power cut is what a rollback journal exists to put
rem back (atomiccommit.html), so that file too is judged on a copy.
rem WITH A SQLite OLDER THAN 3.39.0 (name_safe?) the name of a file that
rem is there cannot be asked without SQLite reading the file, and so
rem acting on the work beside it. Then the work looked for is the work
rem beside p$ as given, and a marked-by-nobody file with none there is
rem judged on a copy of its own bytes all the same: whatever SQLite might
rem find beside it under another name, the file is opened only once its
rem contents are this program's. What an older library loses is the name
rem of a journal found elsewhere in the refusal, and a torn page 1 put back
rem through a link (it is refused as no database).
function may_open_db(p$) local h$, j$, q$, c$
  schema_msg$ = name_refusal$(p$)
  if schema_msg$ <> "" then return 0
  rem From here on every question is asked of the name the OS gives the
  rem file (name_refusal$ found it): an 8.3 alias, a trailing dot or a link
  rem is another spelling of it, and the work SQLite finds lies beside it.
  c$ = canon$
  h$ = file_header$(c$)
  if h$ = "unread" then
    schema_msg$ = "it could not be read (" + hdr_err$ + ")."
    return 0
  end if
  if h$ = "db" then
    if hdr_app = APP_ID then return 1
    if hdr_app <> 0 then
      schema_msg$ = "it belongs to another program (its application id is " + str$(hdr_app) + "), not to " + APP$ + "."
      return 0
    end if
  end if
  if h$ = "missing" or name_safe? = true then
    q$ = sqlite_name$(c$)
    if q$ = "" then
      schema_msg$ = "SQLite could not open it (" + name_err$ + ")."
      return 0
    end if
    if journal_name?(q$) = true then
      if h$ = "missing" and file_getsize(q$) = 0 then file_delete(q$)
      schema_msg$ = "that name leads to " + q$ + ". " + JOURNAL_NAME_MSG$
      return 0
    end if
    j$ = unfinished$(q$)
  else
    q$ = c$
    j$ = unfinished$(c$)
    if j$ = "" and h$ = "db" then return judge_copy(c$, "")
  end if
  if j$ = "" then
    if h$ <> "notdb" then return 1
    schema_msg$ = "it is not a SQLite database."
    return 0
  end if
  return judge_copy(q$, j$)
end function

rem The scratch copy judge_copy works on, and the names SQLite keeps beside
rem it; each is removed by name (never a folder) before and after. The name
rem is this run's own (a GUID, made once): two copies of the program started
rem at the same moment would otherwise judge, and delete, each other's copy.
function check_copy$()
  if check_tag$ = "" then check_tag$ = guidfilename$(0)
  return temppath$() + "phosphor-contacts-check-" + check_tag$ + ".db"
end function

function drop_check_copy() local c$
  c$ = check_copy$()
  if file_exists(c$) = 1 then file_delete(c$)
  if file_exists(c$ + "-journal") = 1 then file_delete(c$ + "-journal")
  if file_exists(c$ + "-wal") = 1 then file_delete(c$ + "-wal")
  if file_exists(c$ + "-shm") = 1 then file_delete(c$ + "-shm")
  return flag(file_exists(c$) = 0 and file_exists(c$ + "-journal") = 0 and file_exists(c$ + "-wal") = 0)
end function

rem p$ -- named as SQLite names it -- is unmarked, or not a database by
rem its header, and j$ beside it is work SQLite would act on (unfinished$):
rem copy the file and what lies beside it, let SQLite open the COPY and do
rem what it does (roll a hot journal back, apply a log, drop a journal
rem beside an empty file, or one that does not begin as a journal does),
rem and ask db_owner$ whose file the result is. 1 when it is this
rem program's or new; else 0 with schema_msg$ saying why -- and speaking
rem of a change in the middle only when j$ shows one: a log, or a journal
rem that begins as a journal does, beside a file with pages. Even then it
rem does not say the program STOPPED: the program may be at work on the
rem file right now (unfinished$ cannot ask its lock), and a person told
rem it crashed might "recover" a live journal.
rem With j$ "" -- an older SQLite, whose name for the file could not be
rem asked (may_open_db) -- the file's own bytes alone are judged on the
rem copy, and the refusal is the owner check's.
function judge_copy(p$, j$) local c$, c@, v, app, ok, why$, pre$, own$
  c$ = check_copy$()
  if j$ = "" then
    pre$ = ""
  elseif right$(j$, 4) = "-wal" then
    pre$ = j$ + " lies beside it: the log of a program that has the file open now, or of one that stopped before writing its changes into the file; SQLite would write them into it"
  elseif file_getsize(p$) <= 0 then
    pre$ = j$ + " lies beside it, which SQLite would delete"
  elseif journal_magic?(j$) = true then
    pre$ = j$ + " lies beside it: the journal of a program changing the file right now, or of one that stopped in the middle of a change; if it stopped, SQLite would roll that change back into the file"
  else
    pre$ = j$ + " lies beside it, which does not begin as a journal does and which SQLite would delete"
  end if
  why$ = ""
  own$ = ""
  if drop_check_copy() <> 1 then
    why$ = "the copy it is checked on first (" + c$ + ") could not be cleared."
  else
    notice("Checking a database before it is opened...")
    ok = 1
    if file_exists(p$) = 1 then ok = file_copy(p$, c$)
    rem A journal or a log is copied only when it holds bytes: SQLite acts
    rem on no empty one, and a FIFO under a journal's name -- which blocks
    rem whoever opens it, forever -- has no size: file_getsize answering it
    rem from the file system (round 9) never opens it, and so neither does
    rem this, nor unfinished$, which reads a journal only when it has bytes.
    if j$ <> "" then
      if ok = 1 and file_getsize(p$ + "-journal") > 0 then ok = file_copy(p$ + "-journal", c$ + "-journal")
      if ok = 1 and file_getsize(p$ + "-wal") > 0 then ok = file_copy(p$ + "-wal", c$ + "-wal")
    end if
    if ok <> 1 then
      why$ = "it could not be copied to " + c$ + " to be checked first."
    else
      sqlite_clearerror()
      c@ = sqlite_open@(c$)
      if sqlite_isopen(c@) <> 1 then
        why$ = "the copy it is checked on first could not be opened (" + sqlite_errormsg$() + ")."
      else
        v = sqlite_scalar(c@, "PRAGMA user_version")
        if sqlite_error() = 0 then app = sqlite_scalar(c@, "PRAGMA application_id")
        if sqlite_error() <> 0 then
          why$ = "on a copy, SQLite could not read it (" + sqlite_errormsg$() + ")."
        elseif db_owner$(c@, v, app) = "" then
          own$ = schema_msg$
        end if
        sqlite_close(c@)
      end if
    end if
    drop_check_copy()
    notice("")
  end if
  if why$ = "" and own$ = "" then
    schema_msg$ = ""
    return 1
  end if
  if j$ = "" then
    schema_msg$ = why$ + own$
  elseif own$ <> "" then
    schema_msg$ = pre$ + " -- and once it has, " + own$ + " The file and " + j$ + " are left as they are."
  else
    schema_msg$ = pre$ + "; " + why$ + " The file and " + j$ + " are left as they are."
  end if
  return 0
end function

rem The start-up could not open its database: offer to pick another file,
rem as often as the person likes, or end. 1 once one is open and showing.
function open_another() local p$
  while ask?("Open another database file instead? No ends the program.") = true
    p$ = choose_file$("SQLite database (*.db)|*.db|All files|*.*")
    if p$ = "" then return 0
    if open_database(p$) = 1 then return 1
  end while
  return 0
end function

rem A small window that says what a long step is doing -- an upgrade of a
rem large database runs at start-up, before any other window shows, and
rem without it the program looks hung. notice("") puts it away. While it
rem shows, the main window takes no clicks: an upgrade is one transaction,
rem and nothing else may run in the middle of it.
function build_notice_form() local f@
  f@ = keep@("notice", form@(APP$, 420, 90))
  control_set@(f@, "Position", "poScreenCenter")
  control_set@(f@, "BorderStyle", "bsDialog")
  keep@("notice.text", lbl@(f@, 20, 30, ""))
  return 0
end function

function notice(msg$)
  if selftest? = true then return 0
  if msg$ = "" then
    form_close@(w@("notice"))
    control_enabled@(w@("main"), 1)
  else
    control_enabled@(w@("main"), 0)
    label_caption@(w@("notice.text"), msg$)
    form_show@(w@("notice"))
    app_processmessages()
  end if
  return 0
end function

rem Called every few thousand rows of an upgrade: lets the notice repaint,
rem so the system does not mark the program "not responding".
function upgrade_progress()
  if selftest? = false then app_processmessages()
  return 0
end function

rem Bring the database d@ to SCHEMA_VERSION; 1 when it is there. The version
rem lives in PRAGMA user_version, and a database already at it is NOT
rem WRITTEN TO: PRAGMA foreign_keys is a setting of the connection, not of
rem the file, so a read-only database with the schema opens for reading.
rem Nothing is written either before db_owner$ has said the file is this
rem program's, or empty: another program's database is refused, not given
rem our tables. An older one of ours is upgraded step by step inside ONE
rem transaction that also sets the new version -- so an upgrade either
rem happened completely or not at all, and running it again on the same
rem file finds nothing to do. On failure schema_msg$ says why.
function create_schema(d@) local v, ok, app
  schema_msg$ = ""
  step_err$ = ""
  sqlite_clearerror()
  if sqlite_exec(d@, "PRAGMA foreign_keys = ON") <> 1 then
    schema_msg$ = sqlite_errormsg$()
    return 0
  end if
  v = sqlite_scalar(d@, "PRAGMA user_version")
  if sqlite_error() = 0 then app = sqlite_scalar(d@, "PRAGMA application_id")
  if sqlite_error() <> 0 then
    schema_msg$ = sqlite_errormsg$()
    return 0
  end if
  if db_owner$(d@, v, app) = "" then return 0
  if v = SCHEMA_VERSION then return 1
  if v > SCHEMA_VERSION then
    schema_msg$ = "it was made by a newer version of this program (its schema is version " + str$(v) + ")."
    return 0
  end if
  rem An upgrade reads and rewrites every row: say so while it runs.
  if v >= 1 then notice("Upgrading the database to this version of the program...")
  ok = sqlite_begin(d@)
  if ok = 1 then ok = upgrade(d@, v)
  if ok = 1 then ok = sqlite_exec(d@, "PRAGMA application_id = " + str$(APP_ID) + "; PRAGMA user_version = " + str$(SCHEMA_VERSION))
  if ok = 1 then ok = sqlite_commit(d@)
  if ok <> 1 then
    if schema_msg$ = "" then schema_msg$ = step_err$
    if schema_msg$ = "" then schema_msg$ = sqlite_errormsg$()
    sqlite_rollback(d@)
    rem A file of an older version is opened by upgrading it, and an upgrade
    rem writes. The program reads keys computed by the CURRENT rule, so it
    rem cannot look at the old file as it is -- it would answer some
    rem sign-ins and searches wrongly -- and says what would work instead.
    if v >= 1 and instr(schema_msg$, "readonly") > 0 then
      schema_msg$ = "it was made by an earlier version of this program (schema version " + str$(v) + "), and opening it means upgrading it, which writes to it -- but the file is read-only. Open a writable copy of it instead: the copy is upgraded, and this file is left as it is."
    end if
  end if
  notice("")
  return ok
end function

rem Whose file this is, before anything is written into it: "ours" or
rem "new" (no table at all, no version, no owner -- what sqlite_open@
rem makes of a name that was not there), else "" with schema_msg$ saying
rem why. (open_database has already asked the file's header the same,
rem without SQLite: may_open_db.) Version 3 marks its files with PRAGMA
rem application_id; versions 1 and 2 set none, so a file of theirs is known
rem by its version AND by having everything version 1 built. A marked file
rem is not trusted on its mark alone either: it must have everything its
rem version has -- every table and column, or the first query of the
rem program fails on a table that is not there, and every index and foreign
rem key (schema_rules@), because the rules the program keeps live there and
rem nowhere else: without ux_users_username_key, josé and JOSÉ are two
rem users again, and nothing else in the program says no. All of it is read
rem from a schema built in memory the way this program builds one --
rem version 1's, or the whole upgrade's for the current version -- not from
rem a list kept by hand. A file of a NEWER version is left to create_schema
rem to refuse.
function db_owner$(d@, v, app) local m@, s@, missing$, n, whole, intact
  if app <> 0 and app <> APP_ID then
    schema_msg$ = "it belongs to another program (its application id is " + str$(app) + "), not to " + APP$ + "."
    return ""
  end if
  if app = APP_ID and v > SCHEMA_VERSION then return "ours"
  n = sqlite_scalar(d@, "SELECT count(*) FROM sqlite_master")
  if n = 0 and v = 0 then return "new"
  missing$ = "?"
  whole = 0
  intact = 0
  if v = 1 or v = 2 or (app = APP_ID and v = SCHEMA_VERSION) then
    missing$ = ""
    m@ = sqlite_open@()
    if v = SCHEMA_VERSION then
      upgrade(m@, 0)
    else
      schema_v1(m@)
    end if
    s@ = sqlite_prepare@(m@, "SELECT m.name AS t, p.name AS c, (p.cid = 0) AS first FROM sqlite_master m, pragma_table_info(m.name) p WHERE m.type = 'table' ORDER BY m.rowid, p.cid")
    rem (whole counts the tables the file has column for column; intact is 1
    rem while the table being read has had every column so far)
    while sqlite_step(s@) = 1
      if sqlite_getn(s@, "first") = 1 then
        whole = whole + intact
        intact = 1
      end if
      if has_column(d@, sqlite_gets$(s@, "t"), sqlite_gets$(s@, "c")) = 0 then
        intact = 0
        if has_column(d@, sqlite_gets$(s@, "t"), "") = 1 then
          if missing$ = "" then missing$ = "the column " + sqlite_gets$(s@, "t") + "." + sqlite_gets$(s@, "c") + " is missing"
        else
          if missing$ = "" then missing$ = "the table " + sqlite_gets$(s@, "t") + " is missing"
        end if
      end if
    end while
    whole = whole + intact
    sqlite_finalize(s@)
    if missing$ = "" then missing$ = rules_missing$(d@, m@, v)
    sqlite_close(m@)
  end if
  if missing$ = "" then return "ours"
  if app = APP_ID then
    if missing$ = "?" then
      schema_msg$ = "it is marked as a " + APP$ + " database, but its schema version (" + str$(v) + ") is not one this program ever wrote -- the file is damaged. Open a backup of it instead."
    else
      schema_msg$ = "it is marked as a " + APP$ + " database, but it is not a complete one: " + missing$ + " -- the file is damaged. Open a backup of it instead."
    end if
    return ""
  end if
  rem Unmarked, at version 1 or 2, with at least one table of that version
  rem column for column: an earlier version's file that has lost a part --
  rem a column, an index, whole tables -- or another program's made to look
  rem like one. The tables it has are this program's own, so the message
  rem names what is missing, not "other tables". Only a file with none of
  rem them whole -- a users table of another program's, say -- is said to
  rem hold other tables.
  if missing$ <> "?" and whole > 0 then
    schema_msg$ = "it holds tables of a database an earlier version of " + APP$ + " made (schema version " + str$(v) + "), but " + missing$ + ": it is a damaged copy of one, or another program's file, and this program does not write into it. Open a backup of it instead."
    return ""
  end if
  schema_msg$ = "it is not a " + APP$ + " database -- it holds other tables (" + sqlite_scalar$(d@, "SELECT group_concat(name, ', ') FROM (SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name LIMIT 6)") + ") -- and this program does not write into another program's file."
  return ""
end function

rem Every index and foreign key of a database's tables, as a dictionary:
rem "the index NAME" or "the foreign key TABLE.COLUMN" -> what it is (its
rem table, whether it is unique and partial, its columns with their
rem collation and order; the table and column it points at, and what a
rem delete does there). Read from SQLite's own pragmas, so an index the
rem column constraints made (sqlite_autoindex_users_1, for username UNIQUE)
rem is one too. (A partial index's WHERE is not compared, only that it has
rem one.) Names are written as SQLite compares them, ignoring the case of
rem A-Z: an index, a table or a column is the same one whatever case it was
rem spelled in, and so is a collation -- nocase is NOCASE (SQLite looks
rem both up with sqlite3StrICmp) -- so every name is lower-cased and every
rem collation upper-cased, the way SQLite reports its built-in ones.
function schema_rules@(x@) local r@, s@, q$
  q$ = "SELECT 'the index ' || lower(il.name) AS k, lower(m.name) || (CASE il." + chr$(34) + "unique" + chr$(34) + " WHEN 1 THEN ' unique' ELSE '' END) || (CASE il.partial WHEN 1 THEN ' partial' ELSE '' END) || ' (' ||"
  q$ = q$ + " (SELECT group_concat(c, ', ') FROM (SELECT coalesce(lower(x.name), '?') || ' ' || upper(x.coll) || (CASE x." + chr$(34) + "desc" + chr$(34) + " WHEN 1 THEN ' desc' ELSE '' END) AS c FROM pragma_index_xinfo(il.name) x WHERE x.key = 1 ORDER BY x.seqno)) || ')' AS s"
  q$ = q$ + " FROM sqlite_master m, pragma_index_list(m.name) il WHERE m.type = 'table'"
  q$ = q$ + " UNION ALL SELECT 'the foreign key ' || lower(m.name) || '.' || lower(f." + chr$(34) + "from" + chr$(34) + "), lower(f." + chr$(34) + "table" + chr$(34) + ") || '.' || coalesce(lower(f." + chr$(34) + "to" + chr$(34) + "), '') || ' on delete ' || f.on_delete"
  q$ = q$ + " FROM sqlite_master m, pragma_foreign_key_list(m.name) f WHERE m.type = 'table'"
  r@ = sdict@()
  s@ = sqlite_prepare@(x@, q$)
  while sqlite_step(s@) = 1
    sdict_set@(r@, sqlite_gets$(s@, "k"), sqlite_gets$(s@, "s"))
  end while
  sqlite_finalize(s@)
  return r@
end function

rem The first index or foreign key of the reference schema m@ that the file
rem d@ does not have as m@ has it -- "the index X is missing", "... is not
rem the one this program builds" -- or "". A file of version v below the
rem current one is upgraded before it is used, and the upgrade builds some
rem of these itself (the unique keys' indexes) and drops one (version 1's
rem ux_companies_tax_id): only what the current version ALSO has, and the
rem upgrade does not build, must be in it already -- else the upgrade would
rem mark a file that the next start refuses as damaged. (For the current
rem version m@ IS the current schema, and everything in it is asked.)
function rules_missing$(d@, m@, v) local ref@, now@, got@, c@, i, k$, sig$, out$
  ref@ = schema_rules@(m@)
  got@ = schema_rules@(d@)
  c@ = sqlite_open@()
  upgrade(c@, 0)
  now@ = schema_rules@(c@)
  sqlite_close(c@)
  out$ = ""
  for i = 1 to dict_count(ref@)
    k$ = dict_key$(ref@, i)
    sig$ = sdict_get$(ref@, k$)
    if out$ = "" then
      if dict_haskey(now@, k$) = 1 and sdict_get$(now@, k$) = sig$ then
        if dict_haskey(got@, k$) = 0 then
          out$ = k$ + " is missing"
        elseif sdict_get$(got@, k$) <> sig$ then
          out$ = k$ + " is not the one this program builds"
        end if
      end if
    end if
  next
  dict_free(ref@)
  dict_free(got@)
  dict_free(now@)
  return out$
end function

rem 1 when table$ has a column col$ -- or, with col$ "", any column at all:
rem whether there is such a table. Both names in any case of A-Z, as SQLite
rem resolves them (NOCASE folds exactly those).
function has_column(d@, table$, col$) local s@, n
  s@ = sqlite_prepare@(d@, "SELECT count(*) FROM pragma_table_info(?1) WHERE name = ?2 COLLATE NOCASE OR ?2 = ''")
  sqlite_bindstr(s@, 1, table$)
  sqlite_bindstr(s@, 2, col$)
  n = 0
  if sqlite_step(s@) = 1 then n = sqlite_getnum(s@, 1)
  sqlite_finalize(s@)
  return flag(n > 0)
end function

rem The steps from version v to SCHEMA_VERSION, inside the caller's
rem transaction; then the keys, computed ONCE for whichever steps ran.
function upgrade(d@, v) local ok
  ok = 1
  if v < 1 then ok = schema_v1(d@)
  if ok = 1 and v < 2 then ok = migrate_v2(d@)
  if ok = 1 and v < 3 then ok = migrate_v3(d@)
  if ok = 1 then ok = rekey_and_check(d@)
  return ok
end function

rem Version 1, the first schema. A new database is built as version 1 and
rem then upgraded like any other, so there is one way to reach the current
rem schema, and the upgrade is exercised by every first run.
function schema_v1(d@) local s$
  s$ = "CREATE TABLE IF NOT EXISTS users ("
  s$ = s$ + " id INTEGER PRIMARY KEY,"
  s$ = s$ + " username TEXT NOT NULL UNIQUE COLLATE NOCASE,"
  s$ = s$ + " full_name TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " password TEXT NOT NULL,"
  s$ = s$ + " role TEXT NOT NULL CHECK (role IN ('admin', 'operator')),"
  s$ = s$ + " active INTEGER NOT NULL DEFAULT 1,"
  s$ = s$ + " created_at TEXT NOT NULL DEFAULT (datetime('now')),"
  s$ = s$ + " last_login TEXT);"
  s$ = s$ + "CREATE TABLE IF NOT EXISTS companies ("
  s$ = s$ + " id INTEGER PRIMARY KEY,"
  s$ = s$ + " kind TEXT NOT NULL CHECK (kind IN ('supplier', 'customer')),"
  s$ = s$ + " name TEXT NOT NULL,"
  s$ = s$ + " trade_name TEXT NOT NULL DEFAULT '', tax_id TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " category TEXT NOT NULL DEFAULT '', phone TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " email TEXT NOT NULL DEFAULT '', website TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " extra TEXT NOT NULL DEFAULT '', payment_terms TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " postal_code TEXT NOT NULL DEFAULT '', address TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " number TEXT NOT NULL DEFAULT '', complement TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " district TEXT NOT NULL DEFAULT '', city TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " state TEXT NOT NULL DEFAULT '', country TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " notes TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " active INTEGER NOT NULL DEFAULT 1,"
  s$ = s$ + " created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,"
  s$ = s$ + " created_at TEXT NOT NULL DEFAULT (datetime('now')),"
  s$ = s$ + " updated_by INTEGER REFERENCES users(id) ON DELETE SET NULL,"
  s$ = s$ + " updated_at TEXT);"
  rem One tax id per kind -- but many companies may leave it blank. (Version
  rem 2 replaces this index: it compared the text as typed.)
  s$ = s$ + "CREATE UNIQUE INDEX IF NOT EXISTS ux_companies_tax_id"
  s$ = s$ + " ON companies(kind, tax_id) WHERE tax_id <> '';"
  s$ = s$ + "CREATE INDEX IF NOT EXISTS ix_companies_name ON companies(kind, name COLLATE NOCASE);"
  s$ = s$ + "CREATE TABLE IF NOT EXISTS contacts ("
  s$ = s$ + " id INTEGER PRIMARY KEY,"
  s$ = s$ + " company_id INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,"
  s$ = s$ + " name TEXT NOT NULL,"
  s$ = s$ + " job_title TEXT NOT NULL DEFAULT '', department TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " email TEXT NOT NULL DEFAULT '', phone TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " mobile TEXT NOT NULL DEFAULT '', whatsapp TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " linkedin TEXT NOT NULL DEFAULT '', instagram TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " other_social TEXT NOT NULL DEFAULT '', birthday TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " notes TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " is_primary INTEGER NOT NULL DEFAULT 0,"
  s$ = s$ + " created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,"
  s$ = s$ + " created_at TEXT NOT NULL DEFAULT (datetime('now')),"
  s$ = s$ + " updated_by INTEGER REFERENCES users(id) ON DELETE SET NULL,"
  s$ = s$ + " updated_at TEXT);"
  s$ = s$ + "CREATE INDEX IF NOT EXISTS ix_contacts_company ON contacts(company_id);"
  s$ = s$ + "CREATE TABLE IF NOT EXISTS product_lines ("
  s$ = s$ + " id INTEGER PRIMARY KEY,"
  s$ = s$ + " name TEXT NOT NULL UNIQUE COLLATE NOCASE,"
  s$ = s$ + " description TEXT NOT NULL DEFAULT '');"
  rem Which product lines a contact serves: many to many.
  s$ = s$ + "CREATE TABLE IF NOT EXISTS contact_lines ("
  s$ = s$ + " contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,"
  s$ = s$ + " line_id INTEGER NOT NULL REFERENCES product_lines(id) ON DELETE CASCADE,"
  s$ = s$ + " PRIMARY KEY (contact_id, line_id));"
  s$ = s$ + "CREATE TABLE IF NOT EXISTS interactions ("
  s$ = s$ + " id INTEGER PRIMARY KEY,"
  s$ = s$ + " contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,"
  s$ = s$ + " happened_on TEXT NOT NULL, kind TEXT NOT NULL,"
  s$ = s$ + " subject TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',"
  s$ = s$ + " user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,"
  s$ = s$ + " created_at TEXT NOT NULL DEFAULT (datetime('now')));"
  s$ = s$ + "CREATE INDEX IF NOT EXISTS ix_interactions_contact ON interactions(contact_id, happened_on);"
  return sqlite_exec(d@, s$)
end function

rem Version 2: the rules that compare text compare a KEY, computed in BASIC
rem and stored beside the text, because SQLite cannot compute it:
rem   - COLLATE NOCASE and LIKE fold the 26 ASCII letters only, so "josé"
rem     and "JOSÉ" were two users and a search for "AÇO" missed "Aço". A key
rem     case-folded with fold$ (all of Unicode) is what user names, product
rem     lines and the search now compare: username_key, name_key, search_key.
rem   - the unique tax id compared the text as typed, so 11.444.777/0001-61
rem     and 11444777000161 were two companies. tax_key is the id upper-cased
rem     with only its letters and digits kept (tax_key$), and the partial
rem     unique index is on (kind, tax_key).
rem This step only adds the columns (when missing) and drops the old index;
rem the keys and their unique indexes come after the last step
rem (rekey_and_check), once, whichever version the file started at.
function migrate_v2(d@)
  if add_column(d@, "users", "username_key") <> 1 then return 0
  if add_column(d@, "product_lines", "name_key") <> 1 then return 0
  if add_column(d@, "companies", "tax_key") <> 1 then return 0
  if add_column(d@, "companies", "search_key") <> 1 then return 0
  if add_column(d@, "contacts", "name_key") <> 1 then return 0
  return sqlite_exec(d@, "DROP INDEX IF EXISTS ux_companies_tax_id")
end function

rem Version 3: version 2 computed its keys with alcase$, which LOWER-cases
rem and does not FOLD -- so ΣΩΚΡΑΤΗΣ and σωκρατης (a final sigma), STRASSE
rem and straße were two names. The keys are recomputed with fold$ (by
rem rekey_and_check, like every upgrade), which may now find two rows the
rem same that were not. And the file gets the table where a backup leaves
rem its identity mark (is_open_db).
function migrate_v3(d@)
  return sqlite_exec(d@, "CREATE TABLE IF NOT EXISTS app_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
end function

rem Compute every key again, then check the rows against the unique rules
rem and put the unique indexes back. The indexes are dropped first, so two
rem rows the new keys make equal are refused BY NAME -- instead of by a
rem constraint error halfway through, or by guessing which to keep. Each
rem check is one grouped pass (GROUP BY ... HAVING), never a count per row:
rem the per-row form made the upgrade of 16,000 companies take 47 s.
function rekey_and_check(d@) local s$, dup$
  s$ = "DROP INDEX IF EXISTS ux_users_username_key;"
  s$ = s$ + "DROP INDEX IF EXISTS ux_product_lines_name_key;"
  s$ = s$ + "DROP INDEX IF EXISTS ux_companies_tax_key;"
  if sqlite_exec(d@, s$) <> 1 then return 0
  if rekey_all(d@) <> 1 then return 0
  rem (an error stays standing until cleared, so one test after the three
  rem queries sees a failure in any of them -- a check that did not run is
  rem not a check that found nothing)
  sqlite_clearerror()
  dup$ = sqlite_scalar$(d@, "SELECT group_concat(name, ' / ') FROM (SELECT username AS name FROM users WHERE username_key IN (SELECT username_key FROM users GROUP BY username_key HAVING count(*) > 1) ORDER BY username_key, id)")
  if dup$ <> "" then
    schema_msg$ = "these user names differ only in upper and lower case, and must be told apart first: " + dup$
    return 0
  end if
  dup$ = sqlite_scalar$(d@, "SELECT group_concat(name, ' / ') FROM (SELECT name FROM product_lines WHERE name_key IN (SELECT name_key FROM product_lines GROUP BY name_key HAVING count(*) > 1) ORDER BY name_key, id)")
  if dup$ <> "" then
    schema_msg$ = "these product lines differ only in upper and lower case, and must be told apart first: " + dup$
    return 0
  end if
  dup$ = sqlite_scalar$(d@, "SELECT group_concat(name || ' (' || tax_id || ')', ' / ') FROM (SELECT name, tax_id FROM companies WHERE tax_key <> '' AND (kind, tax_key) IN (SELECT kind, tax_key FROM companies WHERE tax_key <> '' GROUP BY kind, tax_key HAVING count(*) > 1) ORDER BY kind, tax_key, id)")
  if dup$ <> "" then
    schema_msg$ = "these companies have the same tax id written in different ways, and must be told apart first: " + dup$
    return 0
  end if
  if sqlite_error() <> 0 then
    step_err$ = sqlite_errormsg$()
    return 0
  end if
  s$ = "CREATE UNIQUE INDEX IF NOT EXISTS ux_users_username_key ON users(username_key);"
  s$ = s$ + "CREATE UNIQUE INDEX IF NOT EXISTS ux_product_lines_name_key ON product_lines(name_key);"
  s$ = s$ + "CREATE UNIQUE INDEX IF NOT EXISTS ux_companies_tax_key ON companies(kind, tax_key) WHERE tax_key <> '';"
  return sqlite_exec(d@, s$)
end function

rem Add a text column (default '') unless the table already has it.
function add_column(d@, table$, col$)
  if has_column(d@, table$, col$) = 1 then return 1
  return sqlite_exec(d@, "ALTER TABLE " + table$ + " ADD COLUMN " + col$ + " TEXT NOT NULL DEFAULT ''")
end function

rem Compute every stored key from the text beside it: an upgrade does it for
rem the rows it finds, and the sample data, which is plain SQL, needs it
rem too. 1 on success; on failure step_err$ says why. Each table is read
rem whole first and written after, so no row is updated under a statement
rem still reading the table -- and every statement is checked as it is
rem PREPARED: a SELECT that did not compile steps as no rows at all, and an
rem upgrade once reported success over a table that was not ours that way.
rem The cost is linear: one SELECT and one UPDATE prepared per table, the
rem UPDATE re-run for each row (sqlite_reset).
function rekey_all(d@) local ok
  ok = rekey_names(d@, "SELECT id, username AS k FROM users", "UPDATE users SET username_key = ?2 WHERE id = ?1")
  if ok = 1 then ok = rekey_names(d@, "SELECT id, name AS k FROM product_lines", "UPDATE product_lines SET name_key = ?2 WHERE id = ?1")
  if ok = 1 then ok = rekey_names(d@, "SELECT id, name AS k FROM contacts", "UPDATE contacts SET name_key = ?2 WHERE id = ?1")
  if ok = 1 then ok = rekey_companies(d@)
  return ok
end function

rem One name, one key: id and k from select$, fold$(k) written by update$
rem (?1 the id, ?2 the key).
function rekey_names(d@, select$, update$) local s@, ids@, keys@, i, n, u@, ok
  sqlite_clearerror()
  s@ = sqlite_prepare@(d@, select$)
  if prepare_failed?() = true then return 0
  ids@ = dict@()
  keys@ = sdict@()
  n = 0
  while sqlite_step(s@) = 1
    n = n + 1
    dict_set@(ids@, str$(n), sqlite_getn(s@, "id"))
    sdict_set@(keys@, str$(n), fold$(sqlite_gets$(s@, "k")))
    if n mod 5000 = 0 then upgrade_progress()
  end while
  sqlite_finalize(s@)
  ok = 1
  sqlite_clearerror()
  u@ = sqlite_prepare@(d@, update$)
  if prepare_failed?() = true then ok = 0
  for i = 1 to n
    if ok = 1 then
      sqlite_bindnum(u@, 1, dict_get(ids@, str$(i)))
      sqlite_bindstr(u@, 2, sdict_get$(keys@, str$(i)))
      ok = step_reset_ok(u@)
      if i mod 5000 = 0 then upgrade_progress()
    end if
  next
  sqlite_finalize(u@)
  dict_free(ids@)
  dict_free(keys@)
  return ok
end function

rem Companies have two keys each: the tax id's and the search's.
function rekey_companies(d@) local s@, ids@, tax@, sk@, i, n, u@, ok
  sqlite_clearerror()
  s@ = sqlite_prepare@(d@, "SELECT id, name, trade_name, tax_id, city FROM companies")
  if prepare_failed?() = true then return 0
  ids@ = dict@()
  tax@ = sdict@()
  sk@ = sdict@()
  n = 0
  while sqlite_step(s@) = 1
    n = n + 1
    dict_set@(ids@, str$(n), sqlite_getn(s@, "id"))
    sdict_set@(tax@, str$(n), tax_key$(sqlite_gets$(s@, "tax_id")))
    sdict_set@(sk@, str$(n), search_key$(sqlite_gets$(s@, "name"), sqlite_gets$(s@, "trade_name"), sqlite_gets$(s@, "tax_id"), sqlite_gets$(s@, "city")))
    if n mod 5000 = 0 then upgrade_progress()
  end while
  sqlite_finalize(s@)
  ok = 1
  sqlite_clearerror()
  u@ = sqlite_prepare@(d@, "UPDATE companies SET tax_key = ?2, search_key = ?3 WHERE id = ?1")
  if prepare_failed?() = true then ok = 0
  for i = 1 to n
    if ok = 1 then
      sqlite_bindnum(u@, 1, dict_get(ids@, str$(i)))
      sqlite_bindstr(u@, 2, sdict_get$(tax@, str$(i)))
      sqlite_bindstr(u@, 3, sdict_get$(sk@, str$(i)))
      ok = step_reset_ok(u@)
      if i mod 5000 = 0 then upgrade_progress()
    end if
  next
  sqlite_finalize(u@)
  dict_free(ids@)
  dict_free(tax@)
  dict_free(sk@)
  return ok
end function

rem Asked right after a sqlite_prepare@ that followed sqlite_clearerror():
rem whether the statement did NOT compile, with step_err$ saying why.
function prepare_failed?()
  if sqlite_error() = 0 then return false
  step_err$ = sqlite_errormsg$()
  return true
end function

rem Step a statement that changes rows and rewind it for the next row: 1 on
rem success, else 0 with step_err$ saying why. The statement stays alive.
function step_reset_ok(s@) local ok
  sqlite_clearerror()
  sqlite_step(s@)
  ok = 1
  if sqlite_error() <> 0 then
    ok = 0
    step_err$ = sqlite_errormsg$()
  end if
  sqlite_reset(s@)
  return ok
end function

rem Step a statement that changes rows and finalize it: 1 on success. No
rem message -- the caller decides what a failure means; step_err$ holds it,
rem read before the finalize can say anything else.
function step_ok(s@) local ok
  sqlite_clearerror()
  sqlite_step(s@)
  ok = 1
  step_err$ = ""
  if sqlite_error() <> 0 then
    ok = 0
    step_err$ = sqlite_errormsg$()
  end if
  sqlite_finalize(s@)
  return ok
end function

rem One number out of a query with one text parameter.
function scalar_s(sql$, p$) local s@, v
  s@ = sqlite_prepare@(db@, sql$)
  sqlite_bindstr(s@, 1, p$)
  v = 0
  if sqlite_step(s@) = 1 then v = sqlite_getnum(s@, 1)
  sqlite_finalize(s@)
  return v
end function

rem One number out of a query with one numeric parameter.
function scalar_n(sql$, p) local s@, v
  s@ = sqlite_prepare@(db@, sql$)
  sqlite_bindnum(s@, 1, p)
  v = 0
  if sqlite_step(s@) = 1 then v = sqlite_getnum(s@, 1)
  sqlite_finalize(s@)
  return v
end function

rem Run a prepared statement that changes rows; 1 on success, else the
rem error is shown and 0 comes back. The statement is finalized here.
function finish(s@, what$) local ok
  sqlite_clearerror()
  sqlite_step(s@)
  ok = 1
  if sqlite_error() <> 0 then ok = 0
  if ok = 0 then say("Could not " + what$ + ": " + friendly_error$(sqlite_errormsg$()))
  sqlite_finalize(s@)
  return ok
end function

rem The version-1 column constraints (COLLATE NOCASE) are still in the
rem tables, so a name can be refused by either the column or its key.
function friendly_error$(msg$)
  if instr(msg$, "UNIQUE constraint failed: companies.kind, companies.tax_key") > 0 then return "another company of this kind already has that tax id."
  if instr(msg$, "UNIQUE constraint failed: users.username") > 0 then return "that user name is taken."
  if instr(msg$, "UNIQUE constraint failed: product_lines.name") > 0 then return "a product line with that name already exists."
  if instr(msg$, "attempt to write a readonly database") > 0 then return "this database is read-only; nothing can be changed in it."
  return msg$
end function

rem ===============================================================
rem  Validation
rem ===============================================================

function digits$(s$) local i, c$, out$
  out$ = ""
  for i = 1 to len(s$)
    c$ = mid$(s$, i, 1)
    if c$ >= "0" and c$ <= "9" then out$ = out$ + c$
  next
  return out$
end function

function is_digit?(c$)
  return c$ >= "0" and c$ <= "9"
end function

rem A tax id as the uniqueness rule compares it: upper-cased, with only its
rem ASCII letters and digits kept -- "11.444.777/0001-61", "11444777000161"
rem and "11 444 777 0001 61" are one id. (Tax ids are written in ASCII; a
rem character outside it is dropped like punctuation.)
function tax_key$(s$) local i, c$, u$, out$
  u$ = ucase$(s$)
  out$ = ""
  for i = 1 to len(u$)
    c$ = mid$(u$, i, 1)
    if is_digit?(c$) = true or (c$ >= "A" and c$ <= "Z") then out$ = out$ + c$
  next
  return out$
end function

rem What the Search box is compared with: the company's name, trade name,
rem tax id (as typed and as its key) and city, case-folded with fold$ --
rem all of Unicode, where SQLite's LIKE folds only ASCII -- one per line,
rem so a search cannot match across two of them.
function search_key$(name$, trade$, tax$, city$) local nl$
  nl$ = chr$(10)
  return fold$(name$ + nl$ + trade$ + nl$ + tax$ + nl$ + tax_key$(tax$) + nl$ + city$)
end function

rem Case FOLDING, the comparison Unicode defines for "the same except for
rem case" (CaseFolding.txt, full folding: statuses C and F). alcase$ is
rem simple lower-casing, one character for one, and that is not the same
rem thing: it leaves a final sigma alone, so ΣΩΚΡΑΤΗΣ and σωκρατης were two
rem names, and ß, where folding answers "ss", so STRASSE and straße were two.
rem fold$ is alcase$ and then a table of the characters where the two part,
rem derived from Unicode 15's casefold over every code point -- Python's
rem str.casefold was the oracle, and fold$ was checked against it for all
rem 1,112,062 characters. One differs, and it is chosen (the noncharacters
rem U+FFFE and U+FFFF differed too, until alcase$ stopped turning them into
rem "?" on 2026-10-10): U+0130, the dotted capital I of Turkish, folds to a plain "i" here,
rem where full folding answers "i" + U+0307 (a combining dot). Folding is
rem for MATCHING, and a match should drop the dot the way Unicode's
rem caseless identifier matching drops marks -- with the dot kept, İLKER
rem could not sign in typing ilker or ILKER, and istanbul did not find
rem İSTANBUL. (Version 2's keys, from alcase$, already said "i".) It is
rem replaced before alcase$, which would answer the same "i" on its own
rem today; this way the rule is written here and not left to alcase$. The
rem keys depend on alcase$ all the same: it leaves a byte that is not valid
rem UTF-8 as it is, and a change to that would change the keys of such text.
rem A string alcase$ answers in ASCII has nothing in the table, and
rem neither has one without any of the table's probes (fold_init): those
rem cost an alcase$ and a few instr calls. Only a string that may hold a
rem character of the table is walked a character at a time.
function fold$(s$) local t$, out$, i, j, n, b, w, start, c$, hit
  t$ = alcase$(replacestr$(s$, chr$(304), "i"))
  n = bytelen(t$)
  if n = len(t$) then return t$
  hit = 0
  for i = 1 to dict_count(fold_probe@)
    if hit = 0 then
      if instr(t$, dict_key$(fold_probe@, i)) > 0 then hit = 1
    end if
  next
  if hit = 0 then return t$
  out$ = ""
  start = 1
  i = 1
  while i <= n
    b = byteat(t$, i)
    if b < 128 then
      i = i + 1
    else
      rem the length of a UTF-8 character, from its first byte -- when that
      rem byte can begin one (C2-F4) AND that many continuation bytes
      rem (80-BF) follow it. Anything else is not a character: one byte,
      rem stepped over alone, as alcase$ steps it, so a stray byte cannot
      rem swallow the character after it. (An overlong or surrogate form
      rem that passes this is in no entry of the table, so it is not
      rem folded either.)
      w = 1
      if b >= 194 and b <= 223 then
        w = 2
      elseif b >= 224 and b <= 239 then
        w = 3
      elseif b >= 240 and b <= 244 then
        w = 4
      end if
      if i + w - 1 > n then w = 1
      for j = i + 1 to i + w - 1
        if w > 1 then
          if byteat(t$, j) < 128 or byteat(t$, j) > 191 then w = 1
        end if
      next
      c$ = bytemid$(t$, i, w)
      if w > 1 and dict_haskey(fold_map@, c$) = 1 then
        out$ = out$ + bytemid$(t$, start, i - start) + sdict_get$(fold_map@, c$)
        start = i + w
      end if
      i = i + w
    end if
  end while
  return out$ + bytemid$(t$, start, n - start + 1)
end function

rem fold$'s table, as code points in hex: "DF:73.73" folds U+00DF to "ss",
rem and "AB70-ABBF:13A0" folds a run of consecutive characters onto the run
rem that starts at U+13A0. Built once, at start-up, into fold_map@. Most of
rem it is letters newer than the Unicode tables alcase$ was built from
rem (Georgian Mtavruli, Cherokee small letters, Osage, Adlam...); the rest
rem is where full folding expands a letter: ß, the ligatures, Greek with
rem ypogegrammeni.
function fold_init() local t$, n, i, e$, src$, dst$, a, z, d, j, r$, p
  t$ = "B5:3BC DF:73.73 149:2BC.6E 17F:73 1F0:6A.30C 345:3B9 "
  t$ = t$ + "390:3B9.308.301 3B0:3C5.308.301 3C2:3C3 3D0:3B2 3D1:3B8 3D5:3C6 "
  t$ = t$ + "3D6:3C0 3F0:3BA 3F1:3C1 3F5:3B5 587:565.582 13F8-13FD:13F0 "
  t$ = t$ + "1C80:432 1C81:434 1C82:43E 1C83-1C84:441 1C85:442 1C86:44A "
  t$ = t$ + "1C87:463 1C88:A64B 1C90-1CBA:10D0 1CBD-1CBF:10FD 1E96:68.331 "
  t$ = t$ + "1E97:74.308 1E98:77.30A 1E99:79.30A 1E9A:61.2BE 1E9B:1E61 "
  t$ = t$ + "1F50:3C5.313 1F52:3C5.313.300 1F54:3C5.313.301 1F56:3C5.313.342 "
  t$ = t$ + "1F80:1F00.3B9 1F81:1F01.3B9 1F82:1F02.3B9 1F83:1F03.3B9 "
  t$ = t$ + "1F84:1F04.3B9 1F85:1F05.3B9 1F86:1F06.3B9 1F87:1F07.3B9 "
  t$ = t$ + "1F90:1F20.3B9 1F91:1F21.3B9 1F92:1F22.3B9 1F93:1F23.3B9 "
  t$ = t$ + "1F94:1F24.3B9 1F95:1F25.3B9 1F96:1F26.3B9 1F97:1F27.3B9 "
  t$ = t$ + "1FA0:1F60.3B9 1FA1:1F61.3B9 1FA2:1F62.3B9 1FA3:1F63.3B9 "
  t$ = t$ + "1FA4:1F64.3B9 1FA5:1F65.3B9 1FA6:1F66.3B9 1FA7:1F67.3B9 "
  t$ = t$ + "1FB2:1F70.3B9 1FB3:3B1.3B9 1FB4:3AC.3B9 1FB6:3B1.342 "
  t$ = t$ + "1FB7:3B1.342.3B9 1FBE:3B9 1FC2:1F74.3B9 1FC3:3B7.3B9 "
  t$ = t$ + "1FC4:3AE.3B9 1FC6:3B7.342 1FC7:3B7.342.3B9 1FD2:3B9.308.300 "
  t$ = t$ + "1FD3:3B9.308.301 1FD6:3B9.342 1FD7:3B9.308.342 1FE2:3C5.308.300 "
  t$ = t$ + "1FE3:3C5.308.301 1FE4:3C1.313 1FE6:3C5.342 1FE7:3C5.308.342 "
  t$ = t$ + "1FF2:1F7C.3B9 1FF3:3C9.3B9 1FF4:3CE.3B9 1FF6:3C9.342 "
  t$ = t$ + "1FF7:3C9.342.3B9 2C2F:2C5F A7B8:A7B9 A7BA:A7BB A7BC:A7BD "
  t$ = t$ + "A7BE:A7BF A7C0:A7C1 A7C2:A7C3 A7C4:A794 A7C5:282 A7C6:1D8E "
  t$ = t$ + "A7C7:A7C8 A7C9:A7CA A7D0:A7D1 A7D6:A7D7 A7D8:A7D9 A7F5:A7F6 "
  t$ = t$ + "AB70-ABBF:13A0 FB00:66.66 FB01:66.69 FB02:66.6C FB03:66.66.69 "
  t$ = t$ + "FB04:66.66.6C FB05:73.74 FB06:73.74 FB13:574.576 FB14:574.565 "
  t$ = t$ + "FB15:574.56B FB16:57E.576 FB17:574.56D 10400-10427:10428 "
  t$ = t$ + "104B0-104D3:104D8 10570-1057A:10597 1057C-1058A:105A3 "
  t$ = t$ + "1058C-10592:105B3 10594-10595:105BB 10C80-10CB2:10CC0 "
  t$ = t$ + "118A0-118BF:118C0 16E40-16E5F:16E60 1E900-1E921:1E922"
  n = wordcount(t$, " ")
  for i = 1 to n
    e$ = word$(t$, i, " ")
    p = instr(e$, ":")
    src$ = left$(e$, p - 1)
    dst$ = mid$(e$, p + 1)
    if instr(src$, "-") > 0 then
      a = hexval(word$(src$, 1, "-"))
      z = hexval(word$(src$, 2, "-"))
      d = hexval(dst$)
      for j = a to z
        sdict_set@(fold_map@, chr$(j), chr$(d + j - a))
      next
    else
      r$ = ""
      for j = 1 to wordcount(dst$, ".")
        r$ = r$ + chr$(hexval(word$(dst$, j, ".")))
      next
      sdict_set@(fold_map@, chr$(hexval(src$)), r$)
    end if
  next
  rem The probes fold$ looks for before walking a string: each character of
  rem the table is found by its FIRST BYTE in UTF-8 -- except under the
  rem first bytes C2 and C3, which every accented Latin letter (ç, ã, é)
  rem starts with too, where the table's two characters (µ, ß) are their
  rem own probes. A string with none of them holds nothing to fold.
  for i = 1 to dict_count(fold_map@)
    e$ = dict_key$(fold_map@, i)
    if byteat(e$, 1) = 194 or byteat(e$, 1) = 195 then
      sdict_set@(fold_probe@, e$, "")
    else
      sdict_set@(fold_probe@, bytestr$(byteat(e$, 1)), "")
    end if
  next
  return dict_count(fold_map@)
end function

rem A hexadecimal number written with upper-case digits.
function hexval(h$) local i, v
  v = 0
  for i = 1 to len(h$)
    v = v * 16 + instr("0123456789ABCDEF", mid$(h$, i, 1)) - 1
  next
  return v
end function

rem A LIKE pattern finding s$ anywhere, with s$ taken LITERALLY: "%" and "_"
rem are LIKE's wildcards, so they -- and "\", the escape character the
rem query names with ESCAPE '\' -- are escaped first.
function like_pattern$(s$) local t$
  t$ = replacestr$(s$, "\\", "\\\\")
  t$ = replacestr$(t$, "%", "\\%")
  t$ = replacestr$(t$, "_", "\\_")
  return "%" + t$ + "%"
end function

rem Brazil's CNPJ (14 characters) and CPF (11 digits) both end in two check
rem digits, each a weighted sum mod 11. Since July 2026 a CNPJ may also be
rem ALPHANUMERIC (Receita Federal, IN RFB 2.229/2024): its first 12
rem characters are letters A-Z or digits, its last two still digits, and a
rem character counts as its ASCII code minus 48 -- so a digit counts as
rem itself and "A" as 17 -- under the same weights as before. Other
rem countries' ids are not judged.
function check_digit(d$, weights$) local i, sum, r
  sum = 0
  for i = 1 to count_items(weights$)
    sum = sum + (asc(mid$(d$, i, 1)) - 48) * val(nth$(weights$, i))
  next
  r = sum mod 11
  if r < 2 then return 0
  return 11 - r
end function

rem A Brazilian id may be typed with the dots, slash, hyphen and spaces of
rem its printed form, and nothing else: "CNPJ 11.444.777/0001-61" or a
rem stray "x" is not an id, even when the check digits inside it hold.
function brazil_id_ok?(s$) local i, c$, k$
  for i = 1 to len(s$)
    c$ = mid$(s$, i, 1)
    if is_digit?(c$) = false and instr("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz./- ", c$) = 0 then return false
  next
  k$ = tax_key$(s$)
  if len(k$) = 14 then
    if is_digit?(mid$(k$, 13, 1)) = false or is_digit?(mid$(k$, 14, 1)) = false then return false
    if k$ = string$(14, asc(left$(k$, 1))) then return false
    if check_digit(k$, "5,4,3,2,9,8,7,6,5,4,3,2") <> val(mid$(k$, 13, 1)) then return false
    if check_digit(k$, "6,5,4,3,2,9,8,7,6,5,4,3,2") <> val(mid$(k$, 14, 1)) then return false
    return true
  end if
  if len(k$) = 11 then
    if digits$(k$) <> k$ then return false
    if k$ = string$(11, asc(left$(k$, 1))) then return false
    if check_digit(k$, "10,9,8,7,6,5,4,3,2") <> val(mid$(k$, 10, 1)) then return false
    if check_digit(k$, "11,10,9,8,7,6,5,4,3,2") <> val(mid$(k$, 11, 1)) then return false
    return true
  end if
  return false
end function

rem A birthday is a day and a month, "dd/mm", that some year has (29/02
rem included) -- or nothing at all.
function birthday_ok?(v$) local d, m
  if regex_findpos("^[0-9][0-9]/[0-9][0-9]$", v$) <> 1 then return false
  d = val(left$(v$, 2))
  m = val(mid$(v$, 4, 2))
  if m < 1 or m > 12 then return false
  return d >= 1 and d <= val(nth$("31,29,31,30,31,30,31,31,30,31,30,31", m))
end function

function email_ok?(s$)
  if s$ = "" then return true
  return regex_findpos("^[^@ ]+@[^@ ]+[.][^@ ]+$", s$) = 1
end function

rem ===============================================================
rem  Login
rem ===============================================================

function build_login_form() local f@, p@, t@
  f@ = keep@("login", form@(APP$ + " - sign in", 380, 300))
  control_set@(f@, "Position", "poScreenCenter")
  control_set@(f@, "BorderStyle", "bsDialog")
  form_onclose@(f@, "on_login_close")
  t@ = keep@("login.title", lbl@(f@, 24, 16, "Sign in"))
  control_fontsize@(t@, 14)
  control_bold@(t@, 1)
  keep@("login.hint", lbl@(f@, 24, 44, ""))
  field@("login.user", f@, 24, 70, 330, "User name")
  field@("login.pass", f@, 24, 118, 330, "Password")
  control_set@(w@("login.pass"), "PasswordChar", 42)
  field@("login.confirm", f@, 24, 166, 330, "Repeat the password")
  control_set@(w@("login.confirm"), "PasswordChar", 42)
  keep@("login.msg", lbl@(f@, 24, 222, ""))
  control_fontcolor@(w@("login.msg"), 255)
  button_at@("login.go", f@, 234, 250, 120, "Sign in", "on_login", 0)
  control_set@(w@("login.go"), "Default", true)
  return 0
end function

rem Sign-in mode, or -- when the database has no user yet -- the form
rem that creates the first administrator.
function prepare_login() local n
  n = sqlite_scalar(db@, "SELECT count(*) FROM users")
  first_run? = (n = 0)
  edit_text@(w@("login.pass"), "")
  edit_text@(w@("login.confirm"), "")
  label_caption@(w@("login.msg"), "")
  if first_run? = true then
    label_caption@(w@("login.title"), "Welcome")
    label_caption@(w@("login.hint"), "Create the administrator account for this database.")
    button_caption@(w@("login.go"), "Create")
    edit_text@(w@("login.user"), "admin")
    control_visible@(w@("login.confirm"), 1)
  else
    label_caption@(w@("login.title"), "Sign in")
    label_caption@(w@("login.hint"), dbpath$)
    button_caption@(w@("login.go"), "Sign in")
    control_visible@(w@("login.confirm"), 0)
  end if
  control_setfocus@(w@("login.user"))
  return 0
end function

function on_login(sender@) local u$, p$, s@, rec$, id, ok?
  u$ = trim$(edit_text$(w@("login.user")))
  p$ = edit_text$(w@("login.pass"))
  label_caption@(w@("login.msg"), "")
  if first_run? = true then
    if u$ = "" or len(p$) < 6 then
      label_caption@(w@("login.msg"), "Choose a user name and a password of 6 characters or more.")
      return 0
    end if
    if p$ <> edit_text$(w@("login.confirm")) then
      label_caption@(w@("login.msg"), "The two passwords are different.")
      return 0
    end if
    s@ = sqlite_prepare@(db@, "INSERT INTO users(username, username_key, full_name, password, role) VALUES (?1, ?2, ?3, ?4, 'admin')")
    sqlite_bindstr(s@, 1, u$)
    sqlite_bindstr(s@, 2, fold$(u$))
    sqlite_bindstr(s@, 3, "Administrator")
    sqlite_bindstr(s@, 4, password_hash$(p$, pw_cost))
    if finish(s@, "create the administrator") <> 1 then return 0
    if ask?("Load a few sample suppliers, customers and contacts to look around?") = true then seed_sample_data()
  end if
  rem Look the user up by the name's key -- "José" finds "josé" -- then let
  rem the stored record decide, and call the user by the STORED name.
  s@ = sqlite_prepare@(db@, "SELECT id, username, password, role, active, full_name FROM users WHERE username_key = ?1")
  sqlite_bindstr(s@, 1, fold$(u$))
  id = 0
  ok? = false
  if sqlite_step(s@) = 1 then
    rec$ = sqlite_gets$(s@, "password")
    if sqlite_getn(s@, "active") = 1 then ok? = password_verify?(p$, rec$)
    if ok? = true then
      id = sqlite_getn(s@, "id")
      user_role$ = sqlite_gets$(s@, "role")
      user_name$ = sqlite_gets$(s@, "username")
    end if
  end if
  sqlite_finalize(s@)
  if ok? = false then
    rem The same words for an unknown name and a wrong password: the form
    rem does not tell a stranger which user names exist.
    label_caption@(w@("login.msg"), "User name or password is wrong.")
    edit_text@(w@("login.pass"), "")
    return 0
  end if
  user_id = id
  rem Recording the sign-in is the first write of a session, so it is where
  rem a read-only database shows itself: say so once, and let the person
  rem look around -- every later change is refused with the same words.
  s@ = sqlite_prepare@(db@, "UPDATE users SET last_login = datetime('now') WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if step_ok(s@) <> 1 then
    if instr(step_err$, "readonly") > 0 then
      read_only? = true
      say("This database is read-only: you can look around, but nothing you change will be saved.")
    else
      say("Could not record the sign-in: " + step_err$)
    end if
  end if
  enter_main()
  return 0
end function

function on_login_close(sender@)
  if signing_out? = false and form_visible(w@("main")) = 0 then app_quit()
  return 0
end function

rem ===============================================================
rem  Main window
rem ===============================================================

function build_main_form() local f@, mm@, m@, pc@, k
  f@ = keep@("main", form@(APP$, 1100, 720))
  control_set@(f@, "Position", "poScreenCenter")
  form_onclose@(f@, "on_main_close")

  mm@ = mainmenu@(f@)
  m@ = menuitem@(mm@, "&File")
  menuitem_onclick@(keep@("menu.open", menuitem@(m@, "&Open database...")), "on_open_db")
  menuitem_onclick@(keep@("menu.backup", menuitem@(m@, "&Back up database...")), "on_backup")
  menuitem@(m@, "-")
  menuitem_onclick@(menuitem@(m@, "Export &suppliers to CSV..."), "on_export_suppliers")
  menuitem_onclick@(menuitem@(m@, "Export &customers to CSV..."), "on_export_customers")
  menuitem@(m@, "-")
  menuitem_onclick@(menuitem@(m@, "E&xit"), "on_exit")
  m@ = menuitem@(mm@, "&Account")
  menuitem_onclick@(keep@("menu.password", menuitem@(m@, "&Change my password...")), "on_change_password")
  menuitem_onclick@(keep@("menu.signout", menuitem@(m@, "&Sign out")), "on_sign_out")
  m@ = menuitem@(mm@, "&Help")
  menuitem_onclick@(menuitem@(m@, "&About"), "on_about")

  keep@("status", statusbar@(f@))

  pc@ = keep@("pages", pagecontrol@(f@))
  control_align@(pc@, 5)
  for k = 1 to 2
    build_company_page(k, keep@(pre$(k) + ".page", tabsheet@(pc@, ucase$(left$(kind$(k), 1)) + mid$(kind$(k), 2) + "s")))
  next
  build_lines_page(keep@("lines.page", tabsheet@(pc@, "Product lines")))
  build_users_page(keep@("users.page", tabsheet@(pc@, "Users")))
  return 0
end function

function enter_main()
  busy = busy + 1
  show_users_page()
  rebuild_line_lists()
  refresh_companies(1)
  refresh_companies(2)
  refresh_lines()
  refresh_users()
  pagecontrol_pageindex@(w@("pages"), 1)
  busy = busy - 1
  update_status()
  show(w@("main"))
  hide(w@("login"))
  return 0
end function

rem The Users page is for administrators: shown at sign-in, and again the
rem moment an administrator's own role changes. A page that is hidden while
rem it is the one showing would leave it on screen, so step off it first.
function show_users_page()
  if user_role$ <> "admin" and pagecontrol_pageindex(w@("pages")) = 4 then pagecontrol_pageindex@(w@("pages"), 1)
  control_set@(w@("users.page"), "TabVisible", (user_role$ = "admin"))
  return 0
end function

function update_status() local s$, r$
  r$ = "operator"
  if user_role$ = "admin" then r$ = "administrator"
  if read_only? = true then r$ = r$ + ", read-only"
  s$ = "Signed in as " + user_name$ + " (" + r$ + ")   |   "
  s$ = s$ + str$(scalar_s("SELECT count(*) FROM companies WHERE kind = ?1", "supplier")) + " suppliers, "
  s$ = s$ + str$(scalar_s("SELECT count(*) FROM companies WHERE kind = ?1", "customer")) + " customers, "
  s$ = s$ + str$(sqlite_scalar(db@, "SELECT count(*) FROM contacts")) + " contacts   |   " + extractfilename$(dbpath$)
  status(s$)
  return 0
end function

function on_main_close(sender@)
  if signing_out? = false then app_quit()
  return 0
end function

function on_exit(sender@)
  app_quit()
  return 0
end function

function on_sign_out(sender@)
  signing_out? = true
  forget_user()
  prepare_login()
  show(w@("login"))
  hide(w@("main"))
  signing_out? = false
  return 0
end function

function forget_user()
  user_id = 0
  user_name$ = ""
  user_role$ = ""
  return 0
end function

function on_about(sender@)
  say(APP$ + chr$(10) + chr$(10) + "An example program for Phosphor BASIC " + "-- SQLite, the GUI library and password hashing in one file." + chr$(10) + "Database: " + dbpath$)
  return 0
end function

rem Switch to another database. open_database touches nothing until the new
rem file has proved usable, so a refusal leaves this session where it was;
rem only a switch ends the session, at the new file's login.
function on_open_db(sender@) local p$
  p$ = choose_file$("SQLite database (*.db)|*.db|All files|*.*")
  if p$ = "" then return 0
  if open_database(p$) <> 1 then return 0
  signing_out? = true
  forget_user()
  hide(w@("main"))
  signing_out? = false
  return 0
end function

rem Whether two paths name one file as the OS reads them: each made
rem canonical (path_canonical$ -- links followed, an 8.3 alias, a trailing
rem dot and the case on Windows all resolved), or, where that cannot be
rem answered, made absolute; compared ignoring case on Windows. This can
rem still only say YES -- a hard link, or another case on a Linux mount that
rem ignores case, is the same file under a name of its own. is_open_db is
rem what tells a file apart from the open one.
function same_spelling?(a$, b$) local x$, y$
  x$ = path_canonical$(a$)
  y$ = path_canonical$(b$)
  if x$ = "" or y$ = "" then
    x$ = path_getfullpath$(a$)
    y$ = path_getfullpath$(b$)
  end if
  if os_name$() = "Windows" then
    x$ = alcase$(x$)
    y$ = alcase$(y$)
  end if
  return x$ = y$
end function

rem Whether the file at p$ IS the open database, asked of the files and not
rem of their names: a mark no other file can carry -- a random token -- is
rem committed into the open database, p$ is opened as a SECOND connection
rem that can only read (query_only), and the mark is looked for there. Then
rem it is taken out again. 1 when p$ shows the mark (the same file), 0 when
rem it is proven another file -- it has no such table, it is not a database
rem at all, or it holds no such mark -- and -1 when it cannot be told, with
rem probe_err$ saying why: a read-only session cannot leave a mark, and a
rem file that could not be READ (locked, say) proves nothing.
rem Before any of that, the file's header is read as bytes (file_header$):
rem the open database carries this program's application id -- every file
rem open_database accepts is at the current version, which sets it -- so a
rem file without it is another file, proven without opening it through
rem SQLite. That matters: SQLite would roll a hot journal left beside
rem another program's file back into it, and the person may yet answer No
rem to replacing it.
function is_open_db(p$) local token$, s@, t@, seen$, code, why$, ans, h$
  probe_err$ = ""
  h$ = file_header$(p$)
  if h$ = "unread" then
    probe_err$ = hdr_err$
    return -1
  end if
  if h$ <> "db" or hdr_app <> APP_ID then return 0
  if read_only? = true then
    probe_err$ = "this database is read-only, so it cannot be marked to tell it apart"
    return -1
  end if
  token$ = "probe " + str$(int(rnd() * 1000000000)) + " " + str$(now())
  s@ = sqlite_prepare@(db@, "INSERT OR REPLACE INTO app_meta(key, value) VALUES ('identity_probe', ?1)")
  sqlite_bindstr(s@, 1, token$)
  if step_ok(s@) <> 1 then
    probe_err$ = friendly_error$(step_err$)
    return -1
  end if
  seen$ = ""
  code = 0
  why$ = ""
  t@ = sqlite_open@(p$)
  if sqlite_isopen(t@) = 1 then
    sqlite_exec(t@, "PRAGMA query_only = ON")
    sqlite_clearerror()
    seen$ = sqlite_scalar$(t@, "SELECT value FROM app_meta WHERE key = 'identity_probe'")
    code = sqlite_error()
    why$ = sqlite_errormsg$()
    sqlite_close(t@)
  else
    code = -1
    why$ = sqlite_errormsg$()
  end if
  s@ = sqlite_prepare@(db@, "DELETE FROM app_meta WHERE key = 'identity_probe'")
  step_ok(s@)
  rem SQLITE_NOTADB (26) and "no such table" are answers: the open database
  rem is a database and has the table. Anything else is a failure to look.
  ans = -1
  if code = 0 then
    ans = flag(seen$ = token$)
  elseif code = 26 or instr(why$, "no such table") > 0 then
    ans = 0
  else
    probe_err$ = why$
  end if
  return ans
end function

rem A backup counts as done when the copy opens as a database that passes
rem SQLite's own check and holds what the open one does -- the same users
rem and companies -- and the open database still answers. 1 when so; else 0
rem with probe_err$ saying what was wrong.
function backup_landed(p$) local t@, ok, users, companies
  probe_err$ = ""
  rem (a call that succeeds leaves an older error standing: clear it first)
  sqlite_clearerror()
  users = sqlite_scalar(db@, "SELECT count(*) FROM users")
  companies = sqlite_scalar(db@, "SELECT count(*) FROM companies")
  if sqlite_error() <> 0 then
    probe_err$ = "the open database no longer answers: " + sqlite_errormsg$()
    return 0
  end if
  ok = 0
  t@ = sqlite_open@(p$)
  if sqlite_isopen(t@) = 1 then
    sqlite_exec(t@, "PRAGMA query_only = ON")
    sqlite_clearerror()
    if sqlite_scalar$(t@, "PRAGMA quick_check") = "ok" then
      if sqlite_scalar(t@, "SELECT count(*) FROM users") = users and sqlite_scalar(t@, "SELECT count(*) FROM companies") = companies and sqlite_error() = 0 then ok = 1
    end if
    if ok = 0 then
      probe_err$ = "the copy does not hold what the database does"
      if sqlite_error() <> 0 then probe_err$ = sqlite_errormsg$()
    end if
    sqlite_close(t@)
  else
    probe_err$ = sqlite_errormsg$()
  end if
  return ok
end function

rem A backup is written by SQLite into a NEW file, so a file already at the
rem target is deleted first, once the person agrees. Never the open database
rem itself: Linux would unlink the live file -- the backup "succeeds" into
rem an empty copy and every row is gone -- and Windows would refuse the
rem delete. A name that is not there names no file at all, so it cannot be
rem the open one; a name that IS there is deleted only once is_open_db has
rem PROVEN it another file -- a name spelled like the open database is
rem refused before that, and "cannot tell" is refused too. A delete that
rem fails is said, not ignored, and "Backed up" is said only once the copy
rem has been read back (backup_landed). Before all of it, a name SQLite
rem must not be handed is refused (name_refusal$: a URI, a stream, a device
rem or a pipe, something there that is no file, a name SQLite keeps beside
rem a database under any of its spellings) -- and so, before the backup is
rem written, is a name SQLite resolves to a journal's. Everything after
rem that is done to the name the OS gives the file (canon$): the file a
rem link leads to is the one replaced, and the one written.
rem A file replaced
rem with a journal of its own still beside it is safe: SQLite deletes a
rem journal it finds beside an EMPTY database, which is what the backup
rem starts from.
function on_backup(sender@) local p$, q$, same, why$, c$
  p$ = save_path$("phosphor-contacts-backup.db", "SQLite database (*.db)|*.db")
  if p$ = "" then return 0
  why$ = name_refusal$(p$)
  if why$ <> "" then
    say(why$)
    return 0
  end if
  c$ = canon$
  if same_spelling?(c$, dbpath$) = true then
    say("That is the database you have open. A backup has to go to another file.")
    return 0
  end if
  if file_exists(c$) = 1 then
    same = is_open_db(c$)
    if same = 1 then
      say("That is the database you have open. A backup has to go to another file.")
      return 0
    end if
    if same < 0 then
      say("Could not make sure " + p$ + " is not the database you have open (" + probe_err$ + "), so it was left alone. Back up to a name that does not exist yet.")
      return 0
    end if
    if ask?("Replace " + p$ + "?") = false then return 0
    if file_delete(c$) <> 1 then
      say("Could not replace " + p$ + ": it could not be deleted. Is it open in another program?")
      return 0
    end if
  end if
  rem A link that leads to no file has no canonical name, and name_refusal$
  rem refused it above, on both systems. The name the backup will be
  rem WRITTEN under is still asked of SQLite, which creates the empty file
  rem the backup is about to fill: a journal's name is refused, and that
  rem empty file taken away again.
  q$ = sqlite_name$(c$)
  if q$ <> "" and journal_name?(q$) = true then
    if file_getsize(q$) = 0 then file_delete(q$)
    say("That name leads to " + q$ + ". " + JOURNAL_NAME_MSG$)
    return 0
  end if
  if sqlite_backup(db@, c$) <> 1 then
    say("The backup failed: " + sqlite_errormsg$())
    return 0
  end if
  if backup_landed(c$) = 1 then
    say("Backed up to " + p$)
  else
    say("The backup to " + p$ + " was written but does not read back (" + probe_err$ + "); do not rely on it.")
  end if
  return 0
end function

rem Whether p$ is named the way SQLite names the files it keeps beside a
rem database -- name-journal, name-wal, name-shm. The open database's own
rem are among them (its journal is truncated at its next transaction), and
rem any other is read by SQLite as the unfinished work of the file it sits
rem beside. Asked of the name in any case and without trailing dots and
rem spaces, which Windows drops. It judges a SPELLING, and a file has
rem others -- an 8.3 alias, a link, a stream suffix -- so name_refusal$
rem asks it of the name the OS gives the file (path_canonical$) as well.
function journal_name?(p$) local n$
  n$ = alcase$(p$)
  while right$(n$, 1) = "." or right$(n$, 1) = " "
    n$ = left$(n$, len(n$) - 1)
  end while
  return right$(n$, 8) = "-journal" or right$(n$, 4) = "-wal" or right$(n$, 4) = "-shm"
end function

rem A save dialog -- or, in the self-test, the path it was told to use.
function save_path$(name$, filter$) local d@, p$
  if selftest? = true then return save_as$
  d@ = savedialog@()
  dialog_title@(d@, "Save as")
  dialog_filter@(d@, filter$)
  dialog_filename@(d@, name$)
  p$ = ""
  if dialog_execute(d@) = 1 then p$ = dialog_filename$(d@)
  control_free(d@)
  return p$
end function

rem ===============================================================
rem  Suppliers and customers: one page builder for both kinds
rem ===============================================================

function build_company_page(k, page@) local p$, top@, left@, g@, dp@, t@, x, extra$, cat$
  p$ = pre$(k)

  rem --- the search bar ---
  top@ = panel@(page@)
  control_align@(top@, 1)
  control_height@(top@, 52)
  control_set@(top@, "BevelOuter", "bvNone")
  field@(p$ + ".search", top@, 8, 4, 220, "Search (name, tax id, city, contact)")
  edit_onchange@(w@(p$ + ".search"), "on_company_filter")
  control_tag@(w@(p$ + ".search"), k)
  pick_list@(p$ + ".state", top@, 238, 4, 110, "Show", "Active,Inactive,All")
  combo_onchange@(w@(p$ + ".state"), "on_company_filter")
  control_tag@(w@(p$ + ".state"), k)
  pick_list@(p$ + ".linefilter", top@, 358, 4, 200, "Serving the product line", "")
  combo_onchange@(w@(p$ + ".linefilter"), "on_company_filter")
  control_tag@(w@(p$ + ".linefilter"), k)
  button_at@(p$ + ".new", top@, 580, 20, 110, "New " + kind$(k), "on_company_new", k)
  button_at@(p$ + ".export", top@, 700, 20, 110, "Export CSV...", "on_export_button", k)

  rem --- the list ---
  left@ = panel@(page@)
  control_align@(left@, 3)
  control_width@(left@, 430)
  control_set@(left@, "BevelOuter", "bvNone")
  g@ = record_grid@(p$ + ".grid", left@, "Name,Tax ID,City,State,People", "36,22,22,8,12", 430, "on_company_select", k)
  control_align@(g@, 5)
  control_ondblclick@(g@, "on_company_dblclick")

  rem --- the record: details, contacts, history ---
  dp@ = keep@(p$ + ".detail", pagecontrol@(page@))
  control_align@(dp@, 5)

  t@ = keep@(p$ + ".tab.details", tabsheet@(dp@, "Details"))
  if k = 1 then
    cat$ = "Category (what they supply)"
    extra$ = "Lead time (days)"
  else
    cat$ = "Segment"
    extra$ = "Credit limit"
  end if
  field@(p$ + ".f.name", t@, 10, 8, 330, "Company name *")
  field@(p$ + ".f.trade_name", t@, 350, 8, 290, "Trade name")
  field@(p$ + ".f.tax_id", t@, 10, 56, 160, "Tax ID (CNPJ, EIN, VAT...)")
  field@(p$ + ".f.category", t@, 180, 56, 160, cat$)
  field@(p$ + ".f.phone", t@, 350, 56, 140, "Phone")
  field@(p$ + ".f.email", t@, 500, 56, 140, "E-mail")
  field@(p$ + ".f.website", t@, 10, 104, 330, "Website")
  field@(p$ + ".f.extra", t@, 350, 104, 140, extra$)
  field@(p$ + ".f.payment_terms", t@, 500, 104, 140, "Payment terms")
  field@(p$ + ".f.postal_code", t@, 10, 152, 100, "Postal code")
  field@(p$ + ".f.address", t@, 120, 152, 360, "Address")
  field@(p$ + ".f.number", t@, 490, 152, 60, "Number")
  field@(p$ + ".f.complement", t@, 560, 152, 80, "Complement")
  field@(p$ + ".f.district", t@, 10, 200, 160, "District")
  field@(p$ + ".f.city", t@, 180, 200, 180, "City")
  field@(p$ + ".f.state", t@, 370, 200, 70, "State")
  field@(p$ + ".f.country", t@, 450, 200, 190, "Country")
  memo_field@(p$ + ".f.notes", t@, 10, 248, 630, 90, "Notes")
  keep@(p$ + ".f.active", checkbox@(t@))
  checkbox_caption@(w@(p$ + ".f.active"), "Active")
  control_bounds@(w@(p$ + ".f.active"), 10, 370, 100, 24)
  keep@(p$ + ".f.audit", lbl@(t@, 120, 374, ""))
  control_fontcolor@(w@(p$ + ".f.audit"), 8421504)
  button_at@(p$ + ".save", t@, 410, 410, 110, "Save", "on_company_save", k)
  button_at@(p$ + ".delete", t@, 530, 410, 110, "Delete", "on_company_delete", k)

  t@ = keep@(p$ + ".tab.contacts", tabsheet@(dp@, "Contacts"))
  build_contact_panel(k, t@)
  t@ = keep@(p$ + ".tab.history", tabsheet@(dp@, "History"))
  build_history_panel(k, t@)
  return 0
end function

function by$(name$)
  if name$ = "" then return ""
  return " by " + name$
end function

function company_field@(k, col$)
  return w@(pre$(k) + ".f." + col$)
end function

rem A list is sized ONCE per refresh, from a count taken before it is
rem filled. Growing it a row at a time made the grid re-measure every row
rem it already had at each step -- 7.5 s to list 20,000 companies, on every
rem keystroke in Search. grid_size sets the rows under the header; while
rem filling, grid_room makes room when the fill finds more rows than were
rem counted (another program may add some in between) by doubling, and the
rem refresh ends with the exact count.
function grid_size(g@, n)
  stringgrid_rowcount@(g@, n + 1)
  return n
end function

function grid_room(g@, n, cap)
  if n <= cap then return cap
  return grid_size(g@, n * 2)
end function

function refresh_companies(k) local p$, g@, s@, sql$, where$, q$, st, line, n, cap, keep, found
  p$ = pre$(k)
  g@ = w@(p$ + ".grid")
  keep = cur(p$ + ".company")
  rem The search compares case-folded keys (search_key$), taking what was
  rem typed literally (like_pattern$).
  q$ = fold$(trim$(edit_text$(w@(p$ + ".search"))))
  if q$ <> "" then q$ = like_pattern$(q$)
  st = combo_itemindex(w@(p$ + ".state"))
  line = 0
  if combo_itemindex(w@(p$ + ".linefilter")) > 1 then line = row_id("lines", combo_itemindex(w@(p$ + ".linefilter")) - 1)
  where$ = " FROM companies c WHERE c.kind = ?1"
  where$ = where$ + " AND (?2 = '' OR c.search_key LIKE ?2 ESCAPE '\\'"
  where$ = where$ + "      OR EXISTS (SELECT 1 FROM contacts t WHERE t.company_id = c.id AND t.name_key LIKE ?2 ESCAPE '\\'))"
  where$ = where$ + " AND (?3 = 3 OR c.active = (?3 = 1))"
  where$ = where$ + " AND (?4 = 0 OR EXISTS (SELECT 1 FROM contacts t JOIN contact_lines l ON l.contact_id = t.id"
  where$ = where$ + "      WHERE t.company_id = c.id AND l.line_id = ?4))"
  s@ = sqlite_prepare@(db@, "SELECT count(*)" + where$)
  bind_company_filter(s@, k, q$, st, line)
  cap = 0
  if sqlite_step(s@) = 1 then cap = sqlite_getnum(s@, 1)
  sqlite_finalize(s@)
  sql$ = "SELECT c.id, c.name, c.tax_id, c.city, c.state,"
  sql$ = sql$ + " (SELECT count(*) FROM contacts t WHERE t.company_id = c.id) AS n"
  sql$ = sql$ + where$ + " ORDER BY c.name COLLATE NOCASE"
  s@ = sqlite_prepare@(db@, sql$)
  bind_company_filter(s@, k, q$, st, line)
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  grid_size(g@, cap)
  n = 0
  rows_begin(p$ + ".grid")
  while sqlite_step(s@) = 1
    n = n + 1
    cap = grid_room(g@, n, cap)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "name"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "tax_id"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "city"))
    stringgrid_cell@(g@, 4, n + 1, sqlite_gets$(s@, "state"))
    stringgrid_cell@(g@, 5, n + 1, sqlite_gets$(s@, "n"))
    rows_add(p$ + ".grid", n, sqlite_getn(s@, "id"))
  end while
  sqlite_finalize(s@)
  if n <> cap then grid_size(g@, n)
  size_grid_columns(p$ + ".grid")
  busy = busy - 1
  rem Keep showing the record that was open, if the filter still lists it.
  rem (BASIC's "and" evaluates both sides, so the "if keep" is its own test:
  rem with nothing to keep there is nothing to look for.)
  busy = busy + 1
  found = 0
  if keep <> 0 then found = grid_select(p$ + ".grid", keep)
  if found = 1 then
    busy = busy - 1
    load_company(k, keep)
  elseif n > 0 then
    stringgrid_cursor@(g@, 1, 2)
    busy = busy - 1
    load_company(k, grid_id(p$ + ".grid"))
  else
    busy = busy - 1
    load_company(k, 0)
  end if
  return n
end function

rem The company list's four parameters, bound the same way for its count
rem and for its rows.
function bind_company_filter(s@, k, q$, st, line)
  sqlite_bindstr(s@, 1, kind$(k))
  sqlite_bindstr(s@, 2, q$)
  sqlite_bindnum(s@, 3, st)
  sqlite_bindnum(s@, 4, line)
  return 0
end function

function on_company_filter(sender@)
  if busy > 0 then return 0
  refresh_companies(control_tag(sender@))
  return 0
end function

function on_company_select(sender@) local k, id
  if busy > 0 then return 0
  k = control_tag(sender@)
  id = grid_id(pre$(k) + ".grid")
  if id <> cur(pre$(k) + ".company") then load_company(k, id)
  return 0
end function

rem A double click on a company opens its contacts.
function on_company_dblclick(sender@) local k
  k = control_tag(sender@)
  if cur(pre$(k) + ".company") <> 0 then pagecontrol_pageindex@(w@(pre$(k) + ".detail"), 2)
  return 0
end function

function load_company(k, id) local p$, s@, i, col$, a$
  p$ = pre$(k)
  set_cur(p$ + ".company", id)
  busy = busy + 1
  for i = 1 to count_items(COMPANY_COLS$)
    col$ = nth$(COMPANY_COLS$, i)
    if col$ = "notes" then
      memo_text@(company_field@(k, col$), "")
    else
      edit_text@(company_field@(k, col$), "")
    end if
  next
  checkbox_checked@(company_field@(k, "active"), 1)
  label_caption@(company_field@(k, "audit"), "New record")
  if id <> 0 then
    s@ = sqlite_prepare@(db@, "SELECT c.*, datetime(c.created_at, 'localtime') AS created_local, ifnull(datetime(c.updated_at, 'localtime'), '') AS updated_local, ifnull(uc.username, '') AS created_name, ifnull(uu.username, '') AS updated_name FROM companies c LEFT JOIN users uc ON uc.id = c.created_by LEFT JOIN users uu ON uu.id = c.updated_by WHERE c.id = ?1")
    sqlite_bindnum(s@, 1, id)
    if sqlite_step(s@) = 1 then
      for i = 1 to count_items(COMPANY_COLS$)
        col$ = nth$(COMPANY_COLS$, i)
        if col$ = "notes" then
          memo_text@(company_field@(k, col$), sqlite_gets$(s@, col$))
        else
          edit_text@(company_field@(k, col$), sqlite_gets$(s@, col$))
        end if
      next
      checkbox_checked@(company_field@(k, "active"), sqlite_getn(s@, "active"))
      a$ = "Created " + sqlite_gets$(s@, "created_local") + by$(sqlite_gets$(s@, "created_name"))
      if sqlite_gets$(s@, "updated_local") <> "" then a$ = a$ + ";  changed " + sqlite_gets$(s@, "updated_local") + by$(sqlite_gets$(s@, "updated_name"))
      label_caption@(company_field@(k, "audit"), a$)
    end if
    sqlite_finalize(s@)
  end if
  control_enabled@(w@(p$ + ".delete"), flag(id <> 0))
  control_enabled@(w@(p$ + ".tab.contacts"), flag(id <> 0))
  control_enabled@(w@(p$ + ".tab.history"), flag(id <> 0))
  busy = busy - 1
  refresh_contacts(k)
  return 0
end function

function on_company_new(sender@) local k
  k = control_tag(sender@)
  busy = busy + 1
  stringgrid_cursor@(w@(pre$(k) + ".grid"), 1, 1)
  busy = busy - 1
  load_company(k, 0)
  pagecontrol_pageindex@(w@(pre$(k) + ".detail"), 1)
  control_setfocus@(company_field@(k, "name"))
  return 0
end function

function on_company_save(sender@) local k, p$, id, s@, i, col$, v$, sql$, cols, country$, tax$
  k = control_tag(sender@)
  p$ = pre$(k)
  id = cur(p$ + ".company")
  if trim$(edit_text$(company_field@(k, "name"))) = "" then
    say("The company needs a name.")
    return 0
  end if
  if email_ok?(trim$(edit_text$(company_field@(k, "email")))) = false then
    say("That e-mail address does not look right.")
    return 0
  end if
  country$ = lcase$(trim$(edit_text$(company_field@(k, "country"))))
  tax$ = trim$(edit_text$(company_field@(k, "tax_id")))
  if tax$ <> "" and (country$ = "brazil" or country$ = "brasil") then
    if brazil_id_ok?(tax$) = false then
      say("That is not a valid CNPJ or CPF: it must be 14 characters (a CNPJ, letters allowed in the first 12) or 11 digits (a CPF), written with nothing but dots, a slash, hyphens and spaces between them, and its check digits must match.")
      return 0
    end if
  end if
  rem The columns of the form, then active, then the two keys computed from
  rem them (tax_key$, search_key$): ?3.. for the form, then cols+3.. .
  cols = count_items(COMPANY_COLS$)
  if id = 0 then
    sql$ = "INSERT INTO companies(kind, created_by, " + COMPANY_COLS$ + ", active, tax_key, search_key) VALUES (?1, ?2"
    for i = 1 to cols
      sql$ = sql$ + ", ?" + str$(i + 2)
    next
    sql$ = sql$ + ", ?" + str$(cols + 3) + ", ?" + str$(cols + 4) + ", ?" + str$(cols + 5) + ")"
  else
    sql$ = "UPDATE companies SET kind = ?1, updated_by = ?2, updated_at = datetime('now')"
    for i = 1 to cols
      sql$ = sql$ + ", " + nth$(COMPANY_COLS$, i) + " = ?" + str$(i + 2)
    next
    sql$ = sql$ + ", active = ?" + str$(cols + 3) + ", tax_key = ?" + str$(cols + 4) + ", search_key = ?" + str$(cols + 5)
    sql$ = sql$ + " WHERE id = ?" + str$(cols + 6)
  end if
  s@ = sqlite_prepare@(db@, sql$)
  sqlite_bindstr(s@, 1, kind$(k))
  sqlite_bindnum(s@, 2, user_id)
  for i = 1 to cols
    col$ = nth$(COMPANY_COLS$, i)
    if col$ = "notes" then
      v$ = memo_text$(company_field@(k, col$))
    else
      v$ = trim$(edit_text$(company_field@(k, col$)))
    end if
    sqlite_bindstr(s@, i + 2, v$)
  next
  sqlite_bindnum(s@, cols + 3, checkbox_checked(company_field@(k, "active")))
  sqlite_bindstr(s@, cols + 4, tax_key$(tax$))
  sqlite_bindstr(s@, cols + 5, search_key$(trim$(edit_text$(company_field@(k, "name"))), trim$(edit_text$(company_field@(k, "trade_name"))), tax$, trim$(edit_text$(company_field@(k, "city")))))
  if id <> 0 then sqlite_bindnum(s@, cols + 6, id)
  if finish(s@, "save the " + kind$(k)) <> 1 then return 0
  if id = 0 then set_cur(p$ + ".company", sqlite_lastid(db@))
  refresh_companies(k)
  update_status()
  status("Saved " + trim$(edit_text$(company_field@(k, "name"))) + ".")
  return 0
end function

function on_company_delete(sender@) local k, p$, id, n, name$, s@
  k = control_tag(sender@)
  p$ = pre$(k)
  id = cur(p$ + ".company")
  if id = 0 then return 0
  name$ = trim$(edit_text$(company_field@(k, "name")))
  n = scalar_n("SELECT count(*) FROM contacts WHERE company_id = ?1", id)
  if ask?("Delete " + name$ + " and its " + str$(n) + " contact(s), with their history? This cannot be undone.") = false then return 0
  rem ON DELETE CASCADE takes the contacts, their product lines and their
  rem history with the company -- one statement.
  s@ = sqlite_prepare@(db@, "DELETE FROM companies WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if finish(s@, "delete " + name$) <> 1 then return 0
  set_cur(p$ + ".company", 0)
  refresh_companies(k)
  update_status()
  status("Deleted " + name$ + ".")
  return 0
end function

rem ===============================================================
rem  Contacts of a company
rem ===============================================================

function build_contact_panel(k, t@) local p$, g@, gb@
  p$ = pre$(k)
  g@ = record_grid@(p$ + ".cgrid", t@, "Name,Job title,E-mail,WhatsApp,Primary", "26,22,28,16,8", 640, "on_contact_select", k)
  control_bounds@(g@, 8, 8, 640, 150)
  field@(p$ + ".k.name", t@, 8, 166, 250, "Name *")
  field@(p$ + ".k.job_title", t@, 268, 166, 190, "Job title")
  field@(p$ + ".k.department", t@, 468, 166, 180, "Department")
  field@(p$ + ".k.email", t@, 8, 212, 250, "E-mail")
  field@(p$ + ".k.phone", t@, 268, 212, 120, "Phone")
  field@(p$ + ".k.mobile", t@, 398, 212, 120, "Mobile")
  field@(p$ + ".k.whatsapp", t@, 528, 212, 120, "WhatsApp")
  field@(p$ + ".k.linkedin", t@, 8, 258, 210, "LinkedIn")
  field@(p$ + ".k.instagram", t@, 228, 258, 200, "Instagram")
  field@(p$ + ".k.other_social", t@, 438, 258, 210, "Other social media")
  lbl@(t@, 8, 304, "Birthday (dd/mm)")
  keep@(p$ + ".k.birthday", maskedit@(t@))
  rem A bare "/" in a mask is the system's DATE SEPARATOR, not a slash: it is
  rem "-" on a Linux in the C locale and "." in German. "\/" is a literal
  rem slash (written "\\/" because a BASIC string escapes the backslash).
  maskedit_mask@(w@(p$ + ".k.birthday"), "00\\/00;1;_")
  control_bounds@(w@(p$ + ".k.birthday"), 8, 321, 70, 24)
  keep@(p$ + ".k.primary", checkbox@(t@))
  checkbox_caption@(w@(p$ + ".k.primary"), "Primary contact")
  control_bounds@(w@(p$ + ".k.primary"), 90, 322, 130, 24)
  memo_field@(p$ + ".k.notes", t@, 8, 350, 300, 50, "Notes")
  gb@ = groupbox@(t@)
  groupbox_caption@(gb@, "Product lines served")
  control_bounds@(gb@, 320, 304, 328, 100)
  keep@(p$ + ".k.linebox", gb@)
  button_at@(p$ + ".k.new", t@, 298, 418, 110, "New contact", "on_contact_new", k)
  button_at@(p$ + ".k.save", t@, 418, 418, 110, "Save contact", "on_contact_save", k)
  button_at@(p$ + ".k.delete", t@, 538, 418, 110, "Delete contact", "on_contact_delete", k)
  return 0
end function

function contact_field@(k, col$)
  return w@(pre$(k) + ".k." + col$)
end function

function refresh_contacts(k) local p$, g@, s@, n, n2, company, keep, prim$, cap
  p$ = pre$(k)
  g@ = w@(p$ + ".cgrid")
  company = cur(p$ + ".company")
  keep = cur(p$ + ".contact")
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  cap = grid_size(g@, scalar_n("SELECT count(*) FROM contacts WHERE company_id = ?1", company))
  n = 0
  rows_begin(p$ + ".cgrid")
  s@ = sqlite_prepare@(db@, "SELECT id, name, job_title, email, whatsapp, is_primary FROM contacts WHERE company_id = ?1 ORDER BY is_primary DESC, name COLLATE NOCASE")
  sqlite_bindnum(s@, 1, company)
  while sqlite_step(s@) = 1
    n = n + 1
    cap = grid_room(g@, n, cap)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "name"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "job_title"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "email"))
    stringgrid_cell@(g@, 4, n + 1, sqlite_gets$(s@, "whatsapp"))
    prim$ = ""
    if sqlite_getn(s@, "is_primary") = 1 then prim$ = "yes"
    stringgrid_cell@(g@, 5, n + 1, prim$)
    rows_add(p$ + ".cgrid", n, sqlite_getn(s@, "id"))
  end while
  sqlite_finalize(s@)
  if n <> cap then grid_size(g@, n)
  size_grid_columns(p$ + ".cgrid")
  busy = busy - 1
  busy = busy + 1
  n2 = 0
  if keep <> 0 then n2 = grid_select(p$ + ".cgrid", keep)
  busy = busy - 1
  if n2 = 1 then
    load_contact(k, keep)
  elseif n > 0 then
    busy = busy + 1
    stringgrid_cursor@(g@, 1, 2)
    busy = busy - 1
    load_contact(k, grid_id(p$ + ".cgrid"))
  else
    load_contact(k, 0)
  end if
  return n
end function

function on_contact_select(sender@) local k, id
  if busy > 0 then return 0
  k = control_tag(sender@)
  id = grid_id(pre$(k) + ".cgrid")
  if id <> cur(pre$(k) + ".contact") then load_contact(k, id)
  return 0
end function

function load_contact(k, id) local p$, s@, i, col$, cl@, lines$
  p$ = pre$(k)
  set_cur(p$ + ".contact", id)
  busy = busy + 1
  for i = 1 to count_items(CONTACT_COLS$)
    col$ = nth$(CONTACT_COLS$, i)
    if col$ = "notes" then
      memo_text@(contact_field@(k, col$), "")
    elseif col$ = "birthday" then
      maskedit_text@(contact_field@(k, col$), "")
    else
      edit_text@(contact_field@(k, col$), "")
    end if
  next
  checkbox_checked@(contact_field@(k, "primary"), 0)
  lines$ = ""
  if id <> 0 then
    s@ = sqlite_prepare@(db@, "SELECT * FROM contacts WHERE id = ?1")
    sqlite_bindnum(s@, 1, id)
    if sqlite_step(s@) = 1 then
      for i = 1 to count_items(CONTACT_COLS$)
        col$ = nth$(CONTACT_COLS$, i)
        if col$ = "notes" then
          memo_text@(contact_field@(k, col$), sqlite_gets$(s@, col$))
        elseif col$ = "birthday" then
          maskedit_text@(contact_field@(k, col$), sqlite_gets$(s@, col$))
        else
          edit_text@(contact_field@(k, col$), sqlite_gets$(s@, col$))
        end if
      next
      checkbox_checked@(contact_field@(k, "primary"), sqlite_getn(s@, "is_primary"))
    end if
    sqlite_finalize(s@)
    s@ = sqlite_prepare@(db@, "SELECT line_id FROM contact_lines WHERE contact_id = ?1")
    sqlite_bindnum(s@, 1, id)
    while sqlite_step(s@) = 1
      lines$ = lines$ + "," + sqlite_gets$(s@, "line_id") + ","
    end while
    sqlite_finalize(s@)
  end if
  rem Tick the product lines this contact serves.
  cl@ = w@(p$ + ".k.lines")
  for i = 1 to checklist_count(cl@)
    checklist_checked@(cl@, i, flag(instr(lines$, "," + str$(row_id("lines", i)) + ",") > 0))
  next
  control_enabled@(w@(p$ + ".k.delete"), flag(id <> 0))
  busy = busy - 1
  refresh_history(k)
  return 0
end function

function on_contact_new(sender@) local k
  k = control_tag(sender@)
  busy = busy + 1
  stringgrid_cursor@(w@(pre$(k) + ".cgrid"), 1, 1)
  busy = busy - 1
  load_contact(k, 0)
  control_setfocus@(contact_field@(k, "name"))
  return 0
end function

function on_contact_save(sender@) local k, p$, id, company, s@, i, col$, v$, sql$, cols, cl@, ok, bday$
  k = control_tag(sender@)
  p$ = pre$(k)
  id = cur(p$ + ".contact")
  company = cur(p$ + ".company")
  if company = 0 then return 0
  if trim$(edit_text$(contact_field@(k, "name"))) = "" then
    say("The contact needs a name.")
    return 0
  end if
  if email_ok?(trim$(edit_text$(contact_field@(k, "email")))) = false then
    say("That e-mail address does not look right.")
    return 0
  end if
  rem The mask makes the field read "  /  " when nothing is typed, and keeps
  rem a half-typed "1 /  " as it is: empty is empty, anything else must be a
  rem whole day of a month.
  bday$ = maskedit_text$(contact_field@(k, "birthday"))
  if trim$(replacestr$(replacestr$(bday$, "/", ""), "_", "")) = "" then
    bday$ = ""
  elseif birthday_ok?(bday$) = false then
    say("The birthday must be a day and a month, dd/mm (such as 14/03), or left empty.")
    return 0
  end if
  cols = count_items(CONTACT_COLS$)
  rem The contact, its product lines and the one-primary rule change
  rem together or not at all. The name's key follows the form's columns.
  sqlite_begin(db@)
  if id = 0 then
    sql$ = "INSERT INTO contacts(company_id, created_by, " + CONTACT_COLS$ + ", is_primary, name_key) VALUES (?1, ?2"
    for i = 1 to cols
      sql$ = sql$ + ", ?" + str$(i + 2)
    next
    sql$ = sql$ + ", ?" + str$(cols + 3) + ", ?" + str$(cols + 4) + ")"
  else
    sql$ = "UPDATE contacts SET company_id = ?1, updated_by = ?2, updated_at = datetime('now')"
    for i = 1 to cols
      sql$ = sql$ + ", " + nth$(CONTACT_COLS$, i) + " = ?" + str$(i + 2)
    next
    sql$ = sql$ + ", is_primary = ?" + str$(cols + 3) + ", name_key = ?" + str$(cols + 4) + " WHERE id = ?" + str$(cols + 5)
  end if
  s@ = sqlite_prepare@(db@, sql$)
  sqlite_bindnum(s@, 1, company)
  sqlite_bindnum(s@, 2, user_id)
  for i = 1 to cols
    col$ = nth$(CONTACT_COLS$, i)
    if col$ = "notes" then
      v$ = memo_text$(contact_field@(k, col$))
    elseif col$ = "birthday" then
      v$ = bday$
    else
      v$ = trim$(edit_text$(contact_field@(k, col$)))
    end if
    sqlite_bindstr(s@, i + 2, v$)
  next
  sqlite_bindnum(s@, cols + 3, checkbox_checked(contact_field@(k, "primary")))
  sqlite_bindstr(s@, cols + 4, fold$(trim$(edit_text$(contact_field@(k, "name")))))
  if id <> 0 then sqlite_bindnum(s@, cols + 5, id)
  ok = finish(s@, "save the contact")
  if ok = 1 and id = 0 then id = sqlite_lastid(db@)
  if ok = 1 and checkbox_checked(contact_field@(k, "primary")) = 1 then
    s@ = sqlite_prepare@(db@, "UPDATE contacts SET is_primary = 0 WHERE company_id = ?1 AND id <> ?2")
    sqlite_bindnum(s@, 1, company)
    sqlite_bindnum(s@, 2, id)
    ok = finish(s@, "mark the primary contact")
  end if
  if ok = 1 then
    s@ = sqlite_prepare@(db@, "DELETE FROM contact_lines WHERE contact_id = ?1")
    sqlite_bindnum(s@, 1, id)
    ok = finish(s@, "update the product lines")
  end if
  cl@ = w@(p$ + ".k.lines")
  for i = 1 to checklist_count(cl@)
    if ok = 1 and checklist_checked(cl@, i) = 1 then
      s@ = sqlite_prepare@(db@, "INSERT INTO contact_lines(contact_id, line_id) VALUES (?1, ?2)")
      sqlite_bindnum(s@, 1, id)
      sqlite_bindnum(s@, 2, row_id("lines", i))
      ok = finish(s@, "update the product lines")
    end if
  next
  if ok <> 1 then
    sqlite_rollback(db@)
    return 0
  end if
  sqlite_commit(db@)
  set_cur(p$ + ".contact", id)
  refresh_contacts(k)
  refresh_companies(k)
  update_status()
  status("Saved contact " + trim$(edit_text$(contact_field@(k, "name"))) + ".")
  return 0
end function

function on_contact_delete(sender@) local k, p$, id, s@, name$
  k = control_tag(sender@)
  p$ = pre$(k)
  id = cur(p$ + ".contact")
  if id = 0 then return 0
  name$ = trim$(edit_text$(contact_field@(k, "name")))
  if ask?("Delete the contact " + name$ + " and the history kept with it?") = false then return 0
  s@ = sqlite_prepare@(db@, "DELETE FROM contacts WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if finish(s@, "delete the contact") <> 1 then return 0
  set_cur(p$ + ".contact", 0)
  refresh_contacts(k)
  refresh_companies(k)
  update_status()
  return 0
end function

rem ===============================================================
rem  History: what was said to whom, and when
rem ===============================================================

function build_history_panel(k, t@) local p$, g@
  p$ = pre$(k)
  keep@(p$ + ".h.who", lbl@(t@, 8, 8, ""))
  control_bold@(w@(p$ + ".h.who"), 1)
  g@ = record_grid@(p$ + ".hgrid", t@, "Date,Kind,Subject,By", "16,14,54,16", 640, "on_history_select", k)
  control_bounds@(g@, 8, 30, 640, 160)
  lbl@(t@, 8, 198, "Date")
  keep@(p$ + ".h.date", calendar@(t@))
  control_bounds@(w@(p$ + ".h.date"), 8, 216, 230, 170)
  pick_list@(p$ + ".h.kind", t@, 250, 198, 150, "Kind", INTERACTION_KINDS$)
  field@(p$ + ".h.subject", t@, 250, 246, 398, "Subject *")
  memo_field@(p$ + ".h.notes", t@, 250, 294, 398, 80, "Notes")
  button_at@(p$ + ".h.add", t@, 418, 400, 110, "Add entry", "on_history_add", k)
  button_at@(p$ + ".h.delete", t@, 538, 400, 110, "Delete entry", "on_history_delete", k)
  return 0
end function

rem The list's cursor lands on its first row by itself, while the form under
rem it is cleared for a new entry -- so the cursor is not a choice anybody
rem made. Delete acts only on the entry a person PICKED since the list was
rem last filled: cur(p$ + ".history"), set by on_history_select and
rem forgotten here.
function refresh_history(k) local p$, g@, s@, n, contact, cap
  p$ = pre$(k)
  set_cur(p$ + ".history", 0)
  g@ = w@(p$ + ".hgrid")
  contact = cur(p$ + ".contact")
  if contact = 0 then
    label_caption@(w@(p$ + ".h.who"), "Pick a contact on the Contacts tab to see its history.")
  else
    label_caption@(w@(p$ + ".h.who"), "History with " + trim$(edit_text$(contact_field@(k, "name"))))
  end if
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  cap = grid_size(g@, scalar_n("SELECT count(*) FROM interactions WHERE contact_id = ?1", contact))
  n = 0
  rows_begin(p$ + ".hgrid")
  s@ = sqlite_prepare@(db@, "SELECT i.id, i.happened_on, i.kind, i.subject, u.username FROM interactions i LEFT JOIN users u ON u.id = i.user_id WHERE i.contact_id = ?1 ORDER BY i.happened_on DESC, i.id DESC")
  sqlite_bindnum(s@, 1, contact)
  while sqlite_step(s@) = 1
    n = n + 1
    cap = grid_room(g@, n, cap)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "happened_on"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "kind"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "subject"))
    stringgrid_cell@(g@, 4, n + 1, sqlite_gets$(s@, "username"))
    rows_add(p$ + ".hgrid", n, sqlite_getn(s@, "id"))
  end while
  sqlite_finalize(s@)
  if n <> cap then grid_size(g@, n)
  size_grid_columns(p$ + ".hgrid")
  calendar_date@(w@(p$ + ".h.date"), today())
  edit_text@(w@(p$ + ".h.subject"), "")
  memo_text@(w@(p$ + ".h.notes"), "")
  combo_itemindex@(w@(p$ + ".h.kind"), 1)
  control_enabled@(w@(p$ + ".h.add"), flag(contact <> 0))
  control_enabled@(w@(p$ + ".h.delete"), flag(n > 0))
  busy = busy - 1
  return n
end function

function on_history_select(sender@) local k, s@, id
  if busy > 0 then return 0
  k = control_tag(sender@)
  id = grid_id(pre$(k) + ".hgrid")
  set_cur(pre$(k) + ".history", id)
  if id = 0 then return 0
  s@ = sqlite_prepare@(db@, "SELECT * FROM interactions WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if sqlite_step(s@) = 1 then
    calendar_date@(w@(pre$(k) + ".h.date"), strtodate(sqlite_gets$(s@, "happened_on")))
    edit_text@(w@(pre$(k) + ".h.subject"), sqlite_gets$(s@, "subject"))
    memo_text@(w@(pre$(k) + ".h.notes"), sqlite_gets$(s@, "notes"))
  end if
  sqlite_finalize(s@)
  return 0
end function

function on_history_add(sender@) local k, p$, s@, contact
  k = control_tag(sender@)
  p$ = pre$(k)
  contact = cur(p$ + ".contact")
  if contact = 0 then return 0
  if trim$(edit_text$(w@(p$ + ".h.subject"))) = "" then
    say("Give the entry a subject.")
    return 0
  end if
  s@ = sqlite_prepare@(db@, "INSERT INTO interactions(contact_id, happened_on, kind, subject, notes, user_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
  sqlite_bindnum(s@, 1, contact)
  sqlite_bindstr(s@, 2, datetostr$(calendar_date(w@(p$ + ".h.date"))))
  sqlite_bindstr(s@, 3, combo_text$(w@(p$ + ".h.kind")))
  sqlite_bindstr(s@, 4, trim$(edit_text$(w@(p$ + ".h.subject"))))
  sqlite_bindstr(s@, 5, memo_text$(w@(p$ + ".h.notes")))
  sqlite_bindnum(s@, 6, user_id)
  if finish(s@, "add the entry") <> 1 then return 0
  refresh_history(k)
  return 0
end function

function on_history_delete(sender@) local k, s@, id, what$
  k = control_tag(sender@)
  id = cur(pre$(k) + ".history")
  if id = 0 then
    say("Pick the entry to delete in the list first.")
    return 0
  end if
  rem Name the entry in the question: its date and its subject.
  what$ = ""
  s@ = sqlite_prepare@(db@, "SELECT happened_on, subject FROM interactions WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if sqlite_step(s@) = 1 then what$ = sqlite_gets$(s@, "happened_on") + ", " + chr$(34) + sqlite_gets$(s@, "subject") + chr$(34)
  sqlite_finalize(s@)
  if what$ = "" then return 0
  if ask?("Delete the history entry of " + what$ + "?") = false then return 0
  s@ = sqlite_prepare@(db@, "DELETE FROM interactions WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if finish(s@, "delete the entry") <> 1 then return 0
  refresh_history(k)
  return 0
end function

rem ===============================================================
rem  Product lines
rem ===============================================================

function build_lines_page(t@) local g@
  g@ = record_grid@("lgrid", t@, "Product line,Description,Contacts", "30,56,14", 520, "on_line_select", 0)
  control_bounds@(g@, 8, 8, 520, 600)
  field@("l.name", t@, 545, 8, 330, "Name *")
  memo_field@("l.description", t@, 545, 56, 330, 120, "Description")
  button_at@("l.new", t@, 545, 196, 105, "New line", "on_line_new", 0)
  button_at@("l.save", t@, 657, 196, 105, "Save", "on_line_save", 0)
  button_at@("l.delete", t@, 769, 196, 105, "Delete", "on_line_delete", 0)
  return 0
end function

function refresh_lines() local g@, s@, n, n2, keep, cap
  g@ = w@("lgrid")
  keep = cur("line")
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  cap = grid_size(g@, sqlite_scalar(db@, "SELECT count(*) FROM product_lines"))
  n = 0
  rows_begin("lgrid")
  s@ = sqlite_prepare@(db@, "SELECT p.id, p.name, p.description, (SELECT count(*) FROM contact_lines l WHERE l.line_id = p.id) AS n FROM product_lines p ORDER BY p.name_key")
  while sqlite_step(s@) = 1
    n = n + 1
    cap = grid_room(g@, n, cap)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "name"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "description"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "n"))
    rows_add("lgrid", n, sqlite_getn(s@, "id"))
  end while
  sqlite_finalize(s@)
  if n <> cap then grid_size(g@, n)
  size_grid_columns("lgrid")
  busy = busy - 1
  busy = busy + 1
  n2 = 0
  if keep <> 0 then n2 = grid_select("lgrid", keep)
  busy = busy - 1
  if n2 = 1 then
    load_line(keep)
  elseif n > 0 then
    busy = busy + 1
    stringgrid_cursor@(g@, 1, 2)
    busy = busy - 1
    load_line(grid_id("lgrid"))
  else
    load_line(0)
  end if
  return n
end function

function on_line_select(sender@)
  if busy > 0 then return 0
  load_line(grid_id("lgrid"))
  return 0
end function

function load_line(id) local s@
  set_cur("line", id)
  edit_text@(w@("l.name"), "")
  memo_text@(w@("l.description"), "")
  if id <> 0 then
    s@ = sqlite_prepare@(db@, "SELECT name, description FROM product_lines WHERE id = ?1")
    sqlite_bindnum(s@, 1, id)
    if sqlite_step(s@) = 1 then
      edit_text@(w@("l.name"), sqlite_gets$(s@, "name"))
      memo_text@(w@("l.description"), sqlite_gets$(s@, "description"))
    end if
    sqlite_finalize(s@)
  end if
  control_enabled@(w@("l.delete"), flag(id <> 0))
  return 0
end function

function on_line_new(sender@)
  busy = busy + 1
  stringgrid_cursor@(w@("lgrid"), 1, 1)
  busy = busy - 1
  load_line(0)
  return 0
end function

function on_line_save(sender@) local id, s@, name$
  id = cur("line")
  name$ = trim$(edit_text$(w@("l.name")))
  if name$ = "" then
    say("The product line needs a name.")
    return 0
  end if
  if id = 0 then
    s@ = sqlite_prepare@(db@, "INSERT INTO product_lines(name, description, name_key) VALUES (?1, ?2, ?3)")
  else
    s@ = sqlite_prepare@(db@, "UPDATE product_lines SET name = ?1, description = ?2, name_key = ?3 WHERE id = ?4")
    sqlite_bindnum(s@, 4, id)
  end if
  sqlite_bindstr(s@, 1, name$)
  sqlite_bindstr(s@, 2, memo_text$(w@("l.description")))
  sqlite_bindstr(s@, 3, fold$(name$))
  if finish(s@, "save the product line") <> 1 then return 0
  if id = 0 then set_cur("line", sqlite_lastid(db@))
  refresh_lines()
  rebuild_line_lists()
  return 0
end function

function on_line_delete(sender@) local id, n, s@
  id = cur("line")
  if id = 0 then return 0
  n = scalar_n("SELECT count(*) FROM contact_lines WHERE line_id = ?1", id)
  if ask?("Delete the product line " + trim$(edit_text$(w@("l.name"))) + "? " + str$(n) + " contact(s) serve it; they keep everything else.") = false then return 0
  s@ = sqlite_prepare@(db@, "DELETE FROM product_lines WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if finish(s@, "delete the product line") <> 1 then return 0
  set_cur("line", 0)
  refresh_lines()
  rebuild_line_lists()
  return 0
end function

rem The product lines appear in three more places: each kind's filter and
rem each kind's contact check list, all in one order -- so item i of any of
rem them is row i of the "lines" map (row_id("lines", i)), and the filter's
rem item i + 1, under its "(any)". A check list has no clear, so it is
rem freed and built again inside its group box.
function rebuild_line_lists() local s@, k, p$, cl@, c@, n, name$
  rows_begin("lines")
  s@ = sqlite_prepare@(db@, "SELECT id, name FROM product_lines ORDER BY name_key")
  busy = busy + 1
  for k = 1 to 2
    p$ = pre$(k)
    c@ = w@(p$ + ".linefilter")
    combo_clear@(c@)
    combo_add@(c@, "(any)")
    if dict_haskey(widgets@, p$ + ".k.lines") = 1 then control_free(w@(p$ + ".k.lines"))
    cl@ = checklistbox@(w@(p$ + ".k.linebox"))
    control_align@(cl@, 5)
    rem The same statement, run again from the top for each kind.
    sqlite_reset(s@)
    n = 0
    while sqlite_step(s@) = 1
      n = n + 1
      name$ = sqlite_gets$(s@, "name")
      combo_add@(c@, name$)
      checklist_add@(cl@, name$)
      if k = 1 then rows_add("lines", n, sqlite_getn(s@, "id"))
    end while
    combo_itemindex@(c@, 1)
    keep@(p$ + ".k.lines", cl@)
  next
  sqlite_finalize(s@)
  busy = busy - 1
  rem Put the ticks back for the contacts on screen.
  for k = 1 to 2
    if cur(pre$(k) + ".company") <> 0 then load_contact(k, cur(pre$(k) + ".contact"))
  next
  return n
end function

rem ===============================================================
rem  Users (administrators only)
rem ===============================================================

function build_users_page(t@) local g@
  g@ = record_grid@("ugrid", t@, "User name,Full name,Role,Active,Last sign-in", "18,30,14,10,28", 560, "on_user_select", 0)
  control_bounds@(g@, 8, 8, 560, 600)
  field@("u.username", t@, 585, 8, 300, "User name *")
  field@("u.full_name", t@, 585, 56, 300, "Full name")
  pick_list@("u.role", t@, 585, 104, 140, "Role", "operator,admin")
  keep@("u.active", checkbox@(t@))
  checkbox_caption@(w@("u.active"), "Active (may sign in)")
  control_bounds@(w@("u.active"), 735, 122, 160, 24)
  keep@("u.pwbox", groupbox@(t@))
  groupbox_caption@(w@("u.pwbox"), "Password (leave empty to keep it)")
  control_bounds@(w@("u.pwbox"), 585, 156, 300, 120)
  field@("u.password", w@("u.pwbox"), 10, 4, 270, "New password")
  control_set@(w@("u.password"), "PasswordChar", 42)
  field@("u.confirm", w@("u.pwbox"), 10, 50, 270, "Repeat it")
  control_set@(w@("u.confirm"), "PasswordChar", 42)
  button_at@("u.new", t@, 585, 290, 95, "New user", "on_user_new", 0)
  button_at@("u.save", t@, 688, 290, 95, "Save", "on_user_save", 0)
  button_at@("u.delete", t@, 790, 290, 95, "Delete", "on_user_delete", 0)
  return 0
end function

function refresh_users() local g@, s@, n, n2, keep, a$, cap
  g@ = w@("ugrid")
  keep = cur("user")
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  cap = grid_size(g@, sqlite_scalar(db@, "SELECT count(*) FROM users"))
  n = 0
  rows_begin("ugrid")
  s@ = sqlite_prepare@(db@, "SELECT id, username, full_name, role, active, ifnull(datetime(last_login, 'localtime'), '') AS last FROM users ORDER BY username_key")
  while sqlite_step(s@) = 1
    n = n + 1
    cap = grid_room(g@, n, cap)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "username"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "full_name"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "role"))
    a$ = "no"
    if sqlite_getn(s@, "active") = 1 then a$ = "yes"
    stringgrid_cell@(g@, 4, n + 1, a$)
    stringgrid_cell@(g@, 5, n + 1, sqlite_gets$(s@, "last"))
    rows_add("ugrid", n, sqlite_getn(s@, "id"))
  end while
  sqlite_finalize(s@)
  if n <> cap then grid_size(g@, n)
  size_grid_columns("ugrid")
  busy = busy - 1
  busy = busy + 1
  n2 = 0
  if keep <> 0 then n2 = grid_select("ugrid", keep)
  busy = busy - 1
  if n2 = 1 then
    load_user(keep)
  elseif n > 0 then
    busy = busy + 1
    stringgrid_cursor@(g@, 1, 2)
    busy = busy - 1
    load_user(grid_id("ugrid"))
  else
    load_user(0)
  end if
  return n
end function

function on_user_select(sender@)
  if busy > 0 then return 0
  load_user(grid_id("ugrid"))
  return 0
end function

function load_user(id) local s@
  set_cur("user", id)
  edit_text@(w@("u.username"), "")
  edit_text@(w@("u.full_name"), "")
  edit_text@(w@("u.password"), "")
  edit_text@(w@("u.confirm"), "")
  combo_itemindex@(w@("u.role"), 1)
  checkbox_checked@(w@("u.active"), 1)
  if id <> 0 then
    s@ = sqlite_prepare@(db@, "SELECT username, full_name, role, active FROM users WHERE id = ?1")
    sqlite_bindnum(s@, 1, id)
    if sqlite_step(s@) = 1 then
      edit_text@(w@("u.username"), sqlite_gets$(s@, "username"))
      edit_text@(w@("u.full_name"), sqlite_gets$(s@, "full_name"))
      if sqlite_gets$(s@, "role") = "admin" then combo_itemindex@(w@("u.role"), 2)
      checkbox_checked@(w@("u.active"), sqlite_getn(s@, "active"))
    end if
    sqlite_finalize(s@)
  end if
  control_enabled@(w@("u.delete"), flag(id <> 0 and id <> user_id))
  return 0
end function

function on_user_new(sender@)
  busy = busy + 1
  stringgrid_cursor@(w@("ugrid"), 1, 1)
  busy = busy - 1
  load_user(0)
  return 0
end function

rem How many active administrators there would be if user id had this
rem role and this active flag -- the one rule users cannot break: someone
rem must still be able to manage users.
function admins_after(id, role$, active) local n
  n = scalar_n("SELECT count(*) FROM users WHERE role = 'admin' AND active = 1 AND id <> ?1", id)
  if role$ = "admin" and active = 1 then n = n + 1
  return n
end function

function on_user_save(sender@) local id, s@, u$, p$, role$, active
  if user_role$ <> "admin" then return 0
  id = cur("user")
  u$ = trim$(edit_text$(w@("u.username")))
  p$ = edit_text$(w@("u.password"))
  role$ = combo_text$(w@("u.role"))
  active = checkbox_checked(w@("u.active"))
  if u$ = "" then
    say("The user needs a user name.")
    return 0
  end if
  if p$ <> edit_text$(w@("u.confirm")) then
    say("The two passwords are different.")
    return 0
  end if
  if id = 0 and len(p$) < 6 then
    say("A new user needs a password of 6 characters or more.")
    return 0
  end if
  if p$ <> "" and len(p$) < 6 then
    say("A password needs 6 characters or more.")
    return 0
  end if
  if admins_after(id, role$, active) = 0 then
    say("At least one active administrator must remain.")
    return 0
  end if
  if id = user_id and active = 0 then
    if ask?("You are deactivating your own account: you will be signed out now, and cannot sign in again until another administrator activates it. Go on?") = false then return 0
  end if
  if id = 0 then
    s@ = sqlite_prepare@(db@, "INSERT INTO users(username, username_key, full_name, role, active, password) VALUES (?1, ?7, ?2, ?3, ?4, ?5)")
    sqlite_bindstr(s@, 5, password_hash$(p$, pw_cost))
  elseif p$ = "" then
    s@ = sqlite_prepare@(db@, "UPDATE users SET username = ?1, username_key = ?7, full_name = ?2, role = ?3, active = ?4 WHERE id = ?6")
    sqlite_bindnum(s@, 6, id)
  else
    s@ = sqlite_prepare@(db@, "UPDATE users SET username = ?1, username_key = ?7, full_name = ?2, role = ?3, active = ?4, password = ?5 WHERE id = ?6")
    sqlite_bindstr(s@, 5, password_hash$(p$, pw_cost))
    sqlite_bindnum(s@, 6, id)
  end if
  sqlite_bindstr(s@, 1, u$)
  sqlite_bindstr(s@, 2, trim$(edit_text$(w@("u.full_name"))))
  sqlite_bindstr(s@, 3, role$)
  sqlite_bindnum(s@, 4, active)
  sqlite_bindstr(s@, 7, fold$(u$))
  if finish(s@, "save the user") <> 1 then return 0
  if id = 0 then set_cur("user", sqlite_lastid(db@))
  rem A change to your OWN account takes effect now, not at the next
  rem sign-in: deactivated, you are signed out; demoted, the session is an
  rem operator's from here on and the Users page goes away.
  if id = user_id then
    if active = 0 then
      on_sign_out(sender@)
      return 0
    end if
    user_name$ = u$
    user_role$ = role$
    show_users_page()
  end if
  refresh_users()
  status("Saved user " + u$ + ".")
  return 0
end function

rem Delete a user. The last-administrator guard is not a formality: this
rem session's own administrator may have been demoted or deactivated by
rem ANOTHER program on the same database file, and then the user being
rem deleted can be the last active administrator left.
function on_user_delete(sender@) local id, s@
  if user_role$ <> "admin" then return 0
  id = cur("user")
  if id = 0 or id = user_id then return 0
  if admins_after(id, "operator", 0) = 0 then
    say("At least one active administrator must remain.")
    return 0
  end if
  if ask?("Delete the user " + trim$(edit_text$(w@("u.username"))) + "? The records they created stay.") = false then return 0
  s@ = sqlite_prepare@(db@, "DELETE FROM users WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if finish(s@, "delete the user") <> 1 then return 0
  set_cur("user", 0)
  refresh_users()
  return 0
end function

rem ===============================================================
rem  Change my password: a modal dialog. form_showmodal waits until
rem  the dialog is answered -- Change answers 1 when the new password
rem  was saved, Cancel (a button_modalresult@ of 2) or [X] answers 2.
rem ===============================================================

function build_password_form() local f@
  f@ = keep@("pw", form@(APP$ + " - change password", 340, 260))
  control_set@(f@, "Position", "poScreenCenter")
  control_set@(f@, "BorderStyle", "bsDialog")
  field@("pw.old", f@, 20, 12, 300, "Current password")
  control_set@(w@("pw.old"), "PasswordChar", 42)
  field@("pw.new", f@, 20, 60, 300, "New password")
  control_set@(w@("pw.new"), "PasswordChar", 42)
  field@("pw.confirm", f@, 20, 108, 300, "Repeat the new password")
  control_set@(w@("pw.confirm"), "PasswordChar", 42)
  keep@("pw.msg", lbl@(f@, 20, 162, ""))
  control_fontcolor@(w@("pw.msg"), 255)
  button_at@("pw.ok", f@, 100, 200, 105, "Change", "on_password_ok", 0)
  control_set@(w@("pw.ok"), "Default", true)
  button_at@("pw.cancel", f@, 215, 200, 105, "Cancel", "on_password_cancel", 0)
  control_set@(w@("pw.cancel"), "Cancel", true)
  button_modalresult@(w@("pw.cancel"), 2)
  return 0
end function

function on_change_password(sender@)
  edit_text@(w@("pw.old"), "")
  edit_text@(w@("pw.new"), "")
  edit_text@(w@("pw.confirm"), "")
  label_caption@(w@("pw.msg"), "")
  form_modalresult@(w@("pw"), 0)
  rem The self-test drives the dialog's buttons itself, and form_showmodal
  rem would wait for a person, so only a real run shows it.
  if selftest? = false then
    if form_showmodal(w@("pw")) = 1 then status("Your password was changed.")
  end if
  return 0
end function

function on_password_ok(sender@) local s@, rec$, n$
  n$ = edit_text$(w@("pw.new"))
  rec$ = ""
  s@ = sqlite_prepare@(db@, "SELECT password FROM users WHERE id = ?1")
  sqlite_bindnum(s@, 1, user_id)
  if sqlite_step(s@) = 1 then rec$ = sqlite_gets$(s@, "password")
  sqlite_finalize(s@)
  if password_verify?(edit_text$(w@("pw.old")), rec$) = false then
    label_caption@(w@("pw.msg"), "The current password is wrong.")
    return 0
  end if
  if len(n$) < 6 then
    label_caption@(w@("pw.msg"), "Use 6 characters or more.")
    return 0
  end if
  if n$ <> edit_text$(w@("pw.confirm")) then
    label_caption@(w@("pw.msg"), "The two new passwords are different.")
    return 0
  end if
  s@ = sqlite_prepare@(db@, "UPDATE users SET password = ?1 WHERE id = ?2")
  sqlite_bindstr(s@, 1, password_hash$(n$, pw_cost))
  sqlite_bindnum(s@, 2, user_id)
  if finish(s@, "change the password") <> 1 then return 0
  label_caption@(w@("pw.msg"), "")
  rem Answering the dialog with 1 ends its form_showmodal.
  form_modalresult@(w@("pw"), 1)
  return 0
end function

function on_password_cancel(sender@)
  rem The button's modal result (2) answers the dialog; nothing else to do.
  return 0
end function

rem ===============================================================
rem  CSV export: one row per contact, with its company's columns
rem ===============================================================

function csv$(v$)
  return chr$(34) + replacestr$(v$, chr$(34), chr$(34) + chr$(34)) + chr$(34)
end function

function on_export_suppliers(sender@)
  export_csv(1)
  return 0
end function

function on_export_customers(sender@)
  export_csv(2)
  return 0
end function

function on_export_button(sender@)
  export_csv(control_tag(sender@))
  return 0
end function

rem The export replaces a file only once the person agrees, and never a
rem database (round 11: on Linux a CSV written over the open database
rem destroyed every row and said "Exported"). The name is judged as the
rem backup judges it (name_refusal$: what the OS says is there, and the one
rem name it gives the file -- so a journal, a log, a device, a link that
rem leads nowhere are refused under any spelling), and a file that is there
rem by its BYTES (file_header$): a SQLite database -- the open one under
rem any name, a backup of it, another program's -- is refused, and so is a
rem file that cannot be read to tell. The CSV is written beside the target
rem under a free name and put in its place only once it is all there; the
rem old file is moved aside first and moved back if that fails, so a
rem failure leaves the file that was there as it was.
function export_csv(k) local p$, s@, out$, nl$, i, n, sql$, cols$, lines$, why$, c$, h$, t$, o$
  p$ = save_path$(kind$(k) + "s.csv", "CSV file (*.csv)|*.csv")
  if p$ = "" then return 0
  why$ = name_refusal$(p$)
  if why$ <> "" then
    say(why$)
    return 0
  end if
  c$ = canon$
  if file_exists(c$) = 1 then
    h$ = file_header$(c$)
    if h$ = "unread" then
      say("Could not read " + p$ + " to make sure it is no database (" + hdr_err$ + "), so it was left alone. Export to another file.")
      return 0
    end if
    if h$ = "db" then
      say("That is a SQLite database -- the one you have open, a backup of it, or another program's -- and a CSV written over it would destroy it. Export to another file.")
      return 0
    end if
    if ask?("Replace " + p$ + "?") = false then return 0
  end if
  nl$ = chr$(13) + chr$(10)
  cols$ = "company,trade_name,tax_id,category,phone,email,city,state,country,contact,job_title,contact_email,contact_phone,whatsapp,product_lines"
  out$ = cols$ + nl$
  sql$ = "SELECT c.name AS company, c.trade_name, c.tax_id, c.category, c.phone, c.email, c.city, c.state, c.country,"
  sql$ = sql$ + " ifnull(t.name, '') AS contact, ifnull(t.job_title, '') AS job_title, ifnull(t.email, '') AS contact_email,"
  sql$ = sql$ + " ifnull(t.phone, '') AS contact_phone, ifnull(t.whatsapp, '') AS whatsapp,"
  sql$ = sql$ + " ifnull((SELECT group_concat(p.name, '; ') FROM contact_lines l JOIN product_lines p ON p.id = l.line_id WHERE l.contact_id = t.id), '') AS product_lines"
  sql$ = sql$ + " FROM companies c LEFT JOIN contacts t ON t.company_id = c.id"
  sql$ = sql$ + " WHERE c.kind = ?1 ORDER BY c.name COLLATE NOCASE, t.is_primary DESC, t.name COLLATE NOCASE"
  s@ = sqlite_prepare@(db@, sql$)
  sqlite_bindstr(s@, 1, kind$(k))
  n = 0
  while sqlite_step(s@) = 1
    n = n + 1
    lines$ = ""
    for i = 1 to count_items(cols$)
      if i > 1 then lines$ = lines$ + ","
      lines$ = lines$ + csv$(sqlite_gets$(s@, nth$(cols$, i)))
    next
    out$ = out$ + lines$ + nl$
  end while
  sqlite_finalize(s@)
  t$ = free_name$(c$ + ".part")
  if t$ = "" then
    say("Could not write " + p$ + ": no free name beside it for the file being written.")
    return 0
  end if
  rem (short_write cuts the write short, as a full disk would: self-test)
  if short_write > 0 then
    file_writealltext(t$, bytemid$(out$, 1, short_write))
  else
    file_writealltext(t$, out$)
  end if
  if file_getsize(t$) <> bytelen(out$) then
    if file_exists(t$) = 1 then file_delete(t$)
    say("Could not write " + p$)
    return 0
  end if
  if file_exists(c$) = 1 then
    o$ = free_name$(c$ + ".old")
    i = 0
    if o$ <> "" then i = file_move(c$, o$)
    if i <> 1 then
      file_delete(t$)
      say("Could not replace " + p$ + ": it could not be moved aside. Is it open in another program?")
      return 0
    end if
    if file_move(t$, c$) <> 1 then
      file_delete(t$)
      if file_move(o$, c$) = 1 then
        say("Could not write " + p$)
      else
        say("Could not write " + p$ + ", and the file that was there could not be put back: it is " + o$)
      end if
      return 0
    end if
    file_delete(o$)
  elseif file_move(t$, c$) <> 1 then
    file_delete(t$)
    say("Could not write " + p$)
    return 0
  end if
  status("Exported " + str$(n) + " row(s) to " + p$)
  return n
end function

rem p$, or p$ followed by 2, 3, ... -- the first name nothing is at; ""
rem when none of a hundred is free.
function free_name$(p$) local i, t$
  for i = 1 to 100
    t$ = p$
    if i > 1 then t$ = t$ + str$(i)
    if file_kind$(t$) = "none" then return t$
  next
  return ""
end function

rem ===============================================================
rem  Sample data
rem ===============================================================

function seed_sample_data() local s$
  rem A product line's name key is unique, so each line is written with its
  rem key already computed; the other keys can follow (rekey_all, below).
  s$ = "INSERT INTO product_lines(name, name_key, description) VALUES"
  s$ = s$ + " ('Steel sheets', " + sqlite_quote$(fold$("Steel sheets")) + ", 'Cold and hot rolled sheets'),"
  s$ = s$ + " ('Industrial paint', " + sqlite_quote$(fold$("Industrial paint")) + ", 'Epoxy and polyurethane coatings'),"
  s$ = s$ + " ('Fasteners', " + sqlite_quote$(fold$("Fasteners")) + ", 'Bolts, nuts and rivets'),"
  s$ = s$ + " ('Packaging', " + sqlite_quote$(fold$("Packaging")) + ", 'Boxes, film and pallets');"
  s$ = s$ + "INSERT INTO companies(kind, name, trade_name, tax_id, category, phone, email, website, extra, payment_terms, city, state, country) VALUES"
  s$ = s$ + " ('supplier', 'Aço Forte Siderurgia Ltda.', 'Aço Forte', '11.222.333/0001-81', 'Steel', '+55 11 4000-1000', 'vendas@acoforte.example', 'acoforte.example', '15', '30/60 days', 'São Paulo', 'SP', 'Brazil'),"
  s$ = s$ + " ('supplier', 'Nordic Coatings AB', 'Nordic Coatings', 'SE556677889901', 'Paint', '+46 8 555 0100', 'sales@nordic.example', 'nordic.example', '30', 'Net 45', 'Stockholm', '', 'Sweden'),"
  s$ = s$ + " ('supplier', 'Rivet & Bolt Co.', '', '', 'Fasteners', '+1 312 555 0199', 'orders@rivetbolt.example', '', '7', 'Net 30', 'Chicago', 'IL', 'USA'),"
  s$ = s$ + " ('customer', 'Metalúrgica Horizonte S.A.', 'Horizonte', '', 'Machinery', '+55 31 3333-2000', 'compras@horizonte.example', 'horizonte.example', '250000', '28 days', 'Belo Horizonte', 'MG', 'Brazil'),"
  s$ = s$ + " ('customer', 'Pacific Boxworks Inc.', 'Boxworks', '94-1234567', 'Packaging', '+1 415 555 0142', 'ap@boxworks.example', 'boxworks.example', '80000', 'Net 30', 'San Francisco', 'CA', 'USA');"
  s$ = s$ + "INSERT INTO contacts(company_id, name, job_title, email, phone, whatsapp, linkedin, is_primary) VALUES"
  s$ = s$ + " (1, 'Mariana Souza', 'Sales manager', 'mariana@acoforte.example', '+55 11 4000-1010', '+55 11 98888-1010', 'linkedin.com/in/marianasouza', 1),"
  s$ = s$ + " (1, 'Paulo Lima', 'Technical support', 'paulo@acoforte.example', '+55 11 4000-1020', '+55 11 97777-1020', '', 0),"
  s$ = s$ + " (2, 'Erik Lindqvist', 'Key account', 'erik@nordic.example', '+46 8 555 0110', '+46 70 555 0110', 'linkedin.com/in/eriklindqvist', 1),"
  s$ = s$ + " (3, 'Dana Wright', 'Inside sales', 'dana@rivetbolt.example', '+1 312 555 0101', '', '', 1),"
  s$ = s$ + " (4, 'Carlos Menezes', 'Purchasing', 'carlos@horizonte.example', '+55 31 3333-2010', '+55 31 99999-2010', '', 1),"
  s$ = s$ + " (5, 'Amy Chen', 'Procurement lead', 'amy@boxworks.example', '+1 415 555 0143', '+1 415 555 0144', 'linkedin.com/in/amychen', 1);"
  s$ = s$ + "INSERT INTO contact_lines(contact_id, line_id) VALUES (1, 1), (2, 1), (3, 2), (4, 3), (5, 1), (5, 3), (6, 4);"
  s$ = s$ + "INSERT INTO interactions(contact_id, happened_on, kind, subject, notes) VALUES"
  s$ = s$ + " (1, date('now', '-20 days'), 'Meeting', 'Annual price review', 'Agreed a 3% increase from January.'),"
  s$ = s$ + " (1, date('now', '-3 days'), 'WhatsApp', 'Delivery of order 4471', 'Truck leaves Friday.'),"
  s$ = s$ + " (5, date('now', '-7 days'), 'Call', 'New project quote', 'Wants a quote for 40 t of sheets.');"
  if sqlite_exec(db@, s$) <> 1 then
    say("The sample data could not be loaded: " + sqlite_errormsg$())
    return 0
  end if
  rem Plain SQL cannot compute the keys the search and the unique rules
  rem compare (they are BASIC's fold$ and tax_key$), so they come after.
  if rekey_all(db@) <> 1 then
    say("The sample data could not be indexed: " + step_err$)
    return 0
  end if
  return 1
end function

rem The demonstration (PHOSPHOR_CONTACTS_DEMO=1): a throw-away database in
rem the temp folder with the sample data, signed in as "demo" -- a way to
rem look around without creating anything. Its password is "demo123".
function start_demo() local path$, s@
  path$ = temppath$() + "phosphor-contacts-demo.db"
  if file_exists(path$) = 1 then file_delete(path$)
  if open_database(path$) <> 1 then return 0
  s@ = sqlite_prepare@(db@, "INSERT INTO users(username, username_key, full_name, password, role) VALUES ('demo', 'demo', 'Demo administrator', ?1, 'admin')")
  sqlite_bindstr(s@, 1, password_hash$("demo123", pw_cost))
  if finish(s@, "create the demo user") <> 1 then return 0
  seed_sample_data()
  prepare_login()
  edit_text@(w@("login.user"), "demo")
  edit_text@(w@("login.pass"), "demo123")
  button_click@(w@("login.go"))
  return 1
end function

rem ===============================================================
rem  The self-test (PHOSPHOR_SELFTEST=1): every window is built and
rem  driven, but none is shown and app_run() is never called
rem ===============================================================

function check(ok?, what$)
  if ok? = true then
    passed = passed + 1
  else
    failed = failed + 1
    println "FAIL: " + what$
  end if
  return 0
end function

function type_into(key$, text$)
  edit_text@(w@(key$), text$)
  return 0
end function

function click(key$)
  button_click@(w@(key$))
  return 0
end function

function count_of(sql$)
  return sqlite_scalar(db@, sql$)
end function

function run_selftest() local path$, path2$, path3$, path4$, bad$, bk$, other$, scratch$, kind, blind?, id, s@, n, rec$, csvpath$, text$, nl$, q$, held@, v@, r@, bob, bulk, t0, ms, t1, t2, i, alias$, z$, named$, keep?
  pw_cost = 1000
  path$ = temppath$() + "contact_manager_selftest.db"
  if file_exists(path$) = 1 then file_delete(path$)

  rem --- first run: the login form creates the administrator ---
  open_database(path$)
  check(first_run? = true, "a new database asks for an administrator")
  check(sqlite_scalar(db@, "PRAGMA user_version") = 3 and sqlite_scalar(db@, "PRAGMA application_id") = 1349010253, "it is built at schema version 3, marked as this program's")
  check(button_caption$(w@("login.go")) = "Create", "and the button says so")
  type_into("login.user", "admin")
  type_into("login.pass", "secret1")
  type_into("login.confirm", "secret2")
  click("login.go")
  check(label_caption$(w@("login.msg")) = "The two passwords are different.", "mismatched passwords are refused")
  check(count_of("SELECT count(*) FROM users") = 0, "and no user was written")
  type_into("login.pass", "secret1")
  type_into("login.confirm", "secret1")
  answer? = true
  click("login.go")
  check(count_of("SELECT count(*) FROM users WHERE role = 'admin'") = 1, "the administrator exists")
  rec$ = sqlite_scalar$(db@, "SELECT password FROM users WHERE username = 'admin'")
  check(left$(rec$, 19) = "pbkdf2_sha256$1000$", "its password is kept as a PBKDF2 record")
  check(instr(rec$, "secret1") = 0, "and not as text")
  check(user_name$ = "admin" and user_role$ = "admin", "and it is signed in")
  check(count_of("SELECT count(*) FROM companies") = 5, "the sample data was loaded")
  rem 11.222.333/0001-81 with its punctuation taken out, by hand
  check(count_of("SELECT count(*) FROM companies WHERE tax_key = '11222333000181'") = 1, "with its keys computed")
  check(control_get(w@("users.page"), "TabVisible") = 1, "an administrator sees the Users tab")
  check(instr(statusbar_text$(w@("status")), "3 suppliers, 2 customers, 6 contacts") > 0, "the status bar counts the records")

  rem --- the supplier list and its record ---
  check(stringgrid_rowcount(w@("s.grid")) = 4, "three suppliers listed under a header")
  check(stringgrid_cell$(w@("s.grid"), 1, 2) = "Aço Forte Siderurgia Ltda.", "sorted by name, UTF-8 intact")
  check(edit_text$(w@("s.f.name")) = "Aço Forte Siderurgia Ltda.", "the first row is loaded into the form")
  stringgrid_cursor@(w@("s.grid"), 1, 3)
  check(edit_text$(w@("s.f.city")) = "Stockholm", "picking a row loads that company")
  check(stringgrid_rowcount(w@("s.cgrid")) = 2, "and its one contact")
  check(edit_text$(w@("s.k.name")) = "Erik Lindqvist", "into the contact form")
  check(checklist_checked(w@("s.k.lines"), 2) = 1, "with the product line it serves ticked")

  rem --- search and filters ---
  edit_text@(w@("s.search"), "chicago")
  check(stringgrid_rowcount(w@("s.grid")) = 2, "search finds a company by city")
  edit_text@(w@("s.search"), "Mariana")
  check(stringgrid_cell$(w@("s.grid"), 1, 2) = "Aço Forte Siderurgia Ltda.", "and by the name of a contact")
  rem Case is ignored beyond ASCII: SQLite's LIKE alone folds A-Z only.
  edit_text@(w@("s.search"), "AÇO")
  check(stringgrid_rowcount(w@("s.grid")) = 2 and stringgrid_cell$(w@("s.grid"), 1, 2) = "Aço Forte Siderurgia Ltda.", "AÇO finds Aço: case is ignored beyond ASCII")
  edit_text@(w@("s.search"), "SÃO PAULO")
  check(stringgrid_rowcount(w@("s.grid")) = 2, "and SÃO PAULO finds São Paulo")
  rem "%" and "_" are searched for, not LIKE's wildcards: no sample company
  rem has either, while as wildcards "%" lists them all and "a_o" finds
  rem Aço (a-ç-o) and Chicago (a-g-o).
  edit_text@(w@("s.search"), "%")
  check(stringgrid_rowcount(w@("s.grid")) = 1, "a % in the search is a percent sign, not a wildcard")
  edit_text@(w@("s.search"), "a_o")
  check(stringgrid_rowcount(w@("s.grid")) = 1, "and _ is an underscore")
  edit_text@(w@("s.search"), "11222333")
  check(stringgrid_rowcount(w@("s.grid")) = 2, "a tax id is found without its punctuation")
  edit_text@(w@("s.search"), "")
  choose("s.linefilter", 3)
  check(stringgrid_rowcount(w@("s.grid")) = 2, "the product-line filter keeps the one supplier serving Industrial paint")
  choose("s.linefilter", 1)
  check(stringgrid_rowcount(w@("s.grid")) = 4, "and (any) lists them all again")

  rem --- a new supplier: validation, then insert ---
  click("s.new")
  check(edit_text$(w@("s.f.name")) = "", "New clears the form")
  click("s.save")
  check(last_msg$ = "The company needs a name.", "a nameless company is refused")
  type_into("s.f.name", "Parafusos Brasil Ltda.")
  type_into("s.f.trade_name", "Parafusos 100%")
  type_into("s.f.country", "Brazil")
  type_into("s.f.tax_id", "11.222.333/0001-82")
  click("s.save")
  check(instr(last_msg$, "not a valid CNPJ") > 0, "a CNPJ with a wrong check digit is refused")
  type_into("s.f.tax_id", "11.444.777/0001-61")
  type_into("s.f.email", "not an address")
  click("s.save")
  check(instr(last_msg$, "e-mail") > 0, "a malformed e-mail is refused")
  type_into("s.f.email", "contato@parafusos.example")
  type_into("s.f.city", "Joinville")
  memo_text@(w@("s.f.notes"), "Line one" + chr$(10) + "Line two")
  click("s.save")
  id = cur("s.company")
  check(id > 0, "the new supplier was saved")
  check(stringgrid_rowcount(w@("s.grid")) = 5, "and is listed")
  check(scalar_n("SELECT count(*) FROM companies WHERE id = ?1 AND created_by = 1 AND city = 'Joinville'", id) = 1, "with its fields and who created it")
  check(edit_text$(w@("s.f.name")) = "Parafusos Brasil Ltda.", "and stays selected after the list is rebuilt")
  edit_text@(w@("s.search"), "100%")
  check(stringgrid_rowcount(w@("s.grid")) = 2 and stringgrid_cell$(w@("s.grid"), 1, 2) = "Parafusos Brasil Ltda.", "a search for 100% finds the name with 100% in it")
  edit_text@(w@("s.search"), "")

  rem --- Brazilian tax ids. The alphanumeric CNPJ is the Receita Federal's
  rem own example: with A = 17, B = 18, C = 19, D = 20, E = 21 the two
  rem weighted sums are 459 and 424, so the check digits are 11 - 8 = 3
  rem and 11 - 6 = 5. The CPF's digits: sums 295 and 347, so 2 and 5. The
  rem CPF with an "A" (17) in it has check digits that hold by the same
  rem arithmetic -- sums 315 and 381, so 4 and 4 -- and is refused only
  rem because a CPF is digits. ---
  check(brazil_id_ok?("12.ABC.345/01DE-35") = true, "an alphanumeric CNPJ is accepted")
  check(brazil_id_ok?("12.ABC.345/01DE-36") = false, "and refused with a wrong check digit")
  check(brazil_id_ok?("11.444.777/0001-61!") = false, "a character outside the printed form is refused, even with the digits right")
  check(brazil_id_ok?("CNPJ 11.444.777/0001-61") = false, "and so are words around the number")
  check(brazil_id_ok?("529.982.247-25") = true, "a CPF is accepted")
  check(brazil_id_ok?("529.982.24A-44") = false, "and a CPF is digits only")
  check(tax_key$("11.444.777/0001-61") = "11444777000161", "the tax key keeps the letters and digits")

  rem --- the partial unique index: one tax id per kind, however written ---
  click("s.new")
  type_into("s.f.name", "Copycat Ltda.")
  type_into("s.f.tax_id", "11.444.777/0001-61")
  click("s.save")
  check(instr(last_msg$, "already has that tax id") > 0, "a duplicate tax id is refused with a plain message")
  last_msg$ = ""
  type_into("s.f.tax_id", "11444777000161")
  click("s.save")
  check(instr(last_msg$, "already has that tax id") > 0, "and so is the same id written without punctuation")

  rem --- edit the saved one ---
  grid_select("s.grid", id)
  type_into("s.f.phone", "+55 47 3000-0000")
  click("s.save")
  check(scalar_n("SELECT count(*) FROM companies WHERE id = ?1 AND phone = '+55 47 3000-0000' AND updated_by = 1 AND updated_at IS NOT NULL", id) = 1, "an edit is saved with who changed it")
  check(instr(label_caption$(w@("s.f.audit")), "changed") > 0, "and the form shows the audit line")

  rem --- contacts: two of them, the primary rule, product lines ---
  click("s.k.new")
  type_into("s.k.name", "Rita Alves")
  type_into("s.k.whatsapp", "+55 47 99999-0001")
  type_into("s.k.instagram", "@rita.alves")
  checkbox_checked@(w@("s.k.primary"), 1)
  checklist_checked@(w@("s.k.lines"), 2, 1)
  q$ = "The birthday must be a day and a month, dd/mm (such as 14/03), or left empty."
  maskedit_text@(w@("s.k.birthday"), "99/99")
  click("s.k.save")
  check(last_msg$ = q$, "a birthday that is no day of the year is refused")
  last_msg$ = ""
  maskedit_text@(w@("s.k.birthday"), "1")
  click("s.k.save")
  check(last_msg$ = q$, "and so is a half-typed one")
  last_msg$ = ""
  maskedit_text@(w@("s.k.birthday"), "31/04")
  click("s.k.save")
  check(last_msg$ = q$, "and the 31st of April")
  check(scalar_n("SELECT count(*) FROM contacts WHERE company_id = ?1", id) = 0, "and nothing was saved")
  maskedit_text@(w@("s.k.birthday"), "14/03")
  click("s.k.save")
  n = scalar_n("SELECT count(*) FROM contacts WHERE company_id = ?1", id)
  check(n = 1, "the first contact was saved")
  check(count_of("SELECT count(*) FROM contacts WHERE name = 'Rita Alves' AND birthday = '14/03' AND instagram = '@rita.alves' AND is_primary = 1") = 1, "with its social media, birthday and primary flag")
  check(count_of("SELECT count(*) FROM contact_lines l JOIN contacts t ON t.id = l.contact_id WHERE t.name = 'Rita Alves'") = 1, "and the product line it serves")
  click("s.k.new")
  type_into("s.k.name", "Jorge Prado")
  checkbox_checked@(w@("s.k.primary"), 1)
  click("s.k.save")
  check(count_of("SELECT count(*) FROM contacts WHERE name = 'Rita Alves' AND is_primary = 0") = 1, "a new primary contact takes the flag from the old one")
  check(stringgrid_cell$(w@("s.cgrid"), 1, 2) = "Jorge Prado", "and the primary contact is listed first")
  check(count_of("SELECT count(*) FROM contacts WHERE name = 'Jorge Prado' AND birthday = ''") = 1, "an empty birthday is kept empty")

  rem --- history for the selected contact ---
  click("s.h.add")
  check(last_msg$ = "Give the entry a subject.", "an entry needs a subject")
  calendar_date@(w@("s.h.date"), strtodate("2026-10-01"))
  combo_itemindex@(w@("s.h.kind"), 4)
  type_into("s.h.subject", "Sent the catalogue")
  click("s.h.add")
  check(count_of("SELECT count(*) FROM interactions WHERE subject = 'Sent the catalogue' AND kind = 'WhatsApp' AND happened_on = '2026-10-01' AND user_id = 1") = 1, "the history entry is kept with its date, kind and author")
  check(stringgrid_rowcount(w@("s.hgrid")) = 2, "and listed")
  calendar_date@(w@("s.h.date"), strtodate("2026-10-02"))
  type_into("s.h.subject", "Called back")
  click("s.h.add")
  rem The list now shows "Called back" (the newer) on its first row, where
  rem the cursor lands -- but nobody picked it.
  answer? = true
  click("s.h.delete")
  check(last_msg$ = "Pick the entry to delete in the list first.", "Delete with no entry picked says so")
  check(count_of("SELECT count(*) FROM interactions WHERE subject IN ('Sent the catalogue', 'Called back')") = 2, "and deletes nothing")
  stringgrid_cursor@(w@("s.hgrid"), 1, 3)
  answer? = false
  click("s.h.delete")
  check(last_msg$ = "Delete the history entry of 2026-10-01, " + chr$(34) + "Sent the catalogue" + chr$(34) + "?", "the confirmation names the picked entry")
  answer? = true
  click("s.h.delete")
  check(count_of("SELECT count(*) FROM interactions WHERE subject = 'Sent the catalogue'") = 0 and count_of("SELECT count(*) FROM interactions WHERE subject = 'Called back'") = 1, "and Yes deletes that one, not the first row")

  rem --- a double click on a company opens its contacts ---
  pagecontrol_pageindex@(w@("s.detail"), 1)
  control_dblclick@(w@("s.grid"))
  check(pagecontrol_pageindex(w@("s.detail")) = 2, "a double click opens the Contacts tab")

  rem --- deleting a company takes its contacts and history with it ---
  answer? = false
  click("s.delete")
  check(scalar_n("SELECT count(*) FROM companies WHERE id = ?1", id) = 1, "answering No keeps the company")
  answer? = true
  click("s.delete")
  check(scalar_n("SELECT count(*) FROM companies WHERE id = ?1", id) = 0, "answering Yes deletes it")
  check(count_of("SELECT count(*) FROM contacts WHERE name IN ('Rita Alves', 'Jorge Prado')") = 0, "its contacts went with it (ON DELETE CASCADE)")
  check(count_of("SELECT count(*) FROM interactions WHERE subject = 'Called back'") = 0, "and their history")

  rem --- customers use the same code with their own widgets; the first
  rem listed is Metalúrgica Horizonte, whose sample credit limit is 250000 ---
  check(stringgrid_rowcount(w@("c.grid")) = 3, "two customers listed")
  check(edit_text$(w@("c.f.extra")) = "250000", "the customer form shows the credit limit")
  check(label_caption$(w@("c.f.extra.label")) = "Credit limit", "under its own caption")

  rem --- product lines ---
  pagecontrol_pageindex@(w@("pages"), 3)
  click("l.new")
  type_into("l.name", "fasteners")
  click("l.save")
  check(instr(last_msg$, "already exists") > 0, "product line names are unique, case-insensitively")
  type_into("l.name", "Hydraulics")
  memo_text@(w@("l.description"), "Hoses and fittings")
  click("l.save")
  check(count_of("SELECT count(*) FROM product_lines") = 5, "a new product line is saved")
  check(checklist_count(w@("s.k.lines")) = 5, "and appears in the contact check list")
  check(combo_count(w@("c.linefilter")) = 6, "and in the filters")
  grid_select("lgrid", scalar_s("SELECT id FROM product_lines WHERE name = ?1", "Steel sheets"))
  answer? = true
  click("l.delete")
  check(count_of("SELECT count(*) FROM product_lines WHERE name = 'Steel sheets'") = 0, "a product line can be deleted")
  check(count_of("SELECT count(*) FROM contacts") = 6, "and its contacts stay")
  click("l.new")
  type_into("l.name", "Aço inox")
  click("l.save")
  last_msg$ = ""
  click("l.new")
  type_into("l.name", "AÇO INOX")
  click("l.save")
  check(instr(last_msg$, "already exists") > 0, "and beyond ASCII: AÇO INOX is Aço inox")

  rem --- CSV export: the whole file, as the sample data says it must be --
  rem every value quoted, one row per contact, the customers by name, and
  rem Carlos Menezes left serving Fasteners alone (Steel sheets is gone) ---
  csvpath$ = temppath$() + "contact_manager_selftest.csv"
  if file_exists(csvpath$) = 1 then file_delete(csvpath$)
  save_as$ = csvpath$
  n = export_csv(2)
  check(n = 2, "the customer export writes one row per contact")
  text$ = file_readalltext$(csvpath$)
  check(left$(text$, 22) = "company,trade_name,tax", "under a header row")
  nl$ = chr$(13) + chr$(10)
  q$ = chr$(34)
  rec$ = "company,trade_name,tax_id,category,phone,email,city,state,country,contact,job_title,contact_email,contact_phone,whatsapp,product_lines" + nl$
  rec$ = rec$ + q$ + "Metalúrgica Horizonte S.A." + q$ + "," + q$ + "Horizonte" + q$ + "," + q$ + q$ + "," + q$ + "Machinery" + q$ + "," + q$ + "+55 31 3333-2000" + q$ + "," + q$ + "compras@horizonte.example" + q$ + "," + q$ + "Belo Horizonte" + q$ + "," + q$ + "MG" + q$ + "," + q$ + "Brazil" + q$ + ","
  rec$ = rec$ + q$ + "Carlos Menezes" + q$ + "," + q$ + "Purchasing" + q$ + "," + q$ + "carlos@horizonte.example" + q$ + "," + q$ + "+55 31 3333-2010" + q$ + "," + q$ + "+55 31 99999-2010" + q$ + "," + q$ + "Fasteners" + q$ + nl$
  rec$ = rec$ + q$ + "Pacific Boxworks Inc." + q$ + "," + q$ + "Boxworks" + q$ + "," + q$ + "94-1234567" + q$ + "," + q$ + "Packaging" + q$ + "," + q$ + "+1 415 555 0142" + q$ + "," + q$ + "ap@boxworks.example" + q$ + "," + q$ + "San Francisco" + q$ + "," + q$ + "CA" + q$ + "," + q$ + "USA" + q$ + ","
  rec$ = rec$ + q$ + "Amy Chen" + q$ + "," + q$ + "Procurement lead" + q$ + "," + q$ + "amy@boxworks.example" + q$ + "," + q$ + "+1 415 555 0143" + q$ + "," + q$ + "+1 415 555 0144" + q$ + "," + q$ + "Packaging" + q$ + nl$
  check(text$ = rec$, "with every value of every row quoted")
  file_delete(csvpath$)

  rem --- File > Open database: a file that is not a database changes
  rem nothing; a usable one is switched to, at its own login ---
  bad$ = temppath$() + "contact_manager_selftest_bad.db"
  file_writealltext(bad$, "this is not a SQLite database")
  open_as$ = bad$
  menuitem_click@(w@("menu.open"))
  check(instr(last_msg$, "could not be prepared") > 0 and dbpath$ = path$, "File > Open refuses a file that is not a database")
  check(user_id = 1 and count_of("SELECT count(*) FROM companies") = 5, "and keeps the database and the session it had")
  path2$ = temppath$() + "contact_manager_selftest2.db"
  if file_exists(path2$) = 1 then file_delete(path2$)
  open_as$ = path2$
  menuitem_click@(w@("menu.open"))
  check(dbpath$ = path2$ and user_id = 0 and first_run? = true, "a usable file is switched to, at its own login")
  open_as$ = path$
  menuitem_click@(w@("menu.open"))
  file_delete(path2$)
  type_into("login.user", "admin")
  type_into("login.pass", "secret1")
  click("login.go")

  rem --- a start-up whose database would not open: pick another, or end ---
  answer? = true
  open_as$ = bad$
  check(open_another() = 0 and dbpath$ = path$, "after a refused pick, a cancelled one ends the start-up")
  answer? = false
  check(open_another() = 0, "and so does No")
  answer? = true
  open_as$ = path$
  check(open_another() = 1 and first_run? = false, "a usable pick opens it")
  file_delete(bad$)
  type_into("login.user", "admin")
  type_into("login.pass", "secret1")
  click("login.go")
  rem documentspath$() ends in a separator, and adding another doubled it
  check(instr(default_db_path$(), dirseparator$() + dirseparator$()) = 0 and extractfilename$(default_db_path$()) = "phosphor-contacts.db", "the default database path has no doubled separator")
  check(db_path_in$(temppath$() + "no-such-folder") = path_combine$(homepath$(), "phosphor-contacts.db"), "and is in the home folder when there is no Documents folder")

  rem --- back up: never onto the open database, however its name is spelled,
  rem and a failed delete is said ---
  q$ = "That is the database you have open. A backup has to go to another file."
  save_as$ = path$
  menuitem_click@(w@("menu.backup"))
  check(last_msg$ = q$ and file_exists(path$) = 1, "a backup onto the open database is refused")
  rem Whether a second spelling reaches the same file is a fact of the
  rem FOLDER, not of the operating system: NTFS ignores case and ext4 does
  rem not, but a Linux mount of a Windows drive, a FAT stick or a casefold
  rem folder ignores it too, and Win32 drops a trailing dot. So a scratch
  rem file in the same folder answers it, and the backup must follow: where
  rem the spelling reaches the open database it is refused and the database
  rem keeps its rows; where it does not, it is another file and the backup
  rem is written there.
  scratch$ = temppath$() + "contact_manager_selftest_case.tmp"
  for kind = 1 to 2
    file_writealltext(scratch$, "x")
    blind? = file_exists(spelling$(scratch$, kind)) = 1
    file_delete(scratch$)
    other$ = spelling$(path$, kind)
    rem (a leftover of a run that stopped: here it is ANOTHER file)
    if blind? = false and file_exists(other$) = 1 then file_delete(other$)
    save_as$ = other$
    last_msg$ = ""
    answer? = true
    menuitem_click@(w@("menu.backup"))
    if blind? = true then
      check(last_msg$ = q$ and file_exists(path$) = 1 and count_of("SELECT count(*) FROM companies") = 5, "the open database is refused under another spelling of its name (" + str$(kind) + ") where the folder reads it as the same file")
    else
      check(last_msg$ = "Backed up to " + other$ and file_exists(path$) = 1, "and where the folder reads that spelling (" + str$(kind) + ") as another file, the backup is written there")
      file_delete(other$)
    end if
  next
  rem is_open_db asks the FILES, so it is checked through names that are
  rem not aliases at all: the open database under its own name is itself,
  rem and a backup of it -- another file holding the same rows -- is not,
  rem nor is a file that is not a database, nor an empty one.
  check(is_open_db(path$) = 1 and count_of("SELECT count(*) FROM app_meta") = 0, "the identity check knows the open database by its own name, and takes its mark out again")
  bk$ = temppath$() + "contact_manager_selftest_backup.db"
  if file_exists(bk$) = 1 then file_delete(bk$)
  save_as$ = bk$
  menuitem_click@(w@("menu.backup"))
  check(last_msg$ = "Backed up to " + bk$ and backup_landed(bk$) = 1, "a backup to another file is written, and reads back")
  check(is_open_db(bk$) = 0, "a backup is another file, though it holds the same rows")
  bad$ = temppath$() + "contact_manager_selftest_notdb.db"
  file_writealltext(bad$, "this is not a SQLite database")
  check(is_open_db(bad$) = 0 and backup_landed(bad$) = 0, "a file that is not a database is another file, and is no backup")
  file_delete(bad$)
  file_createempty(bad$)
  check(is_open_db(bad$) = 0 and backup_landed(bad$) = 0, "and so is an empty file")
  file_delete(bad$)
  rem A read-only session cannot leave the mark, so it cannot prove a file
  rem that is there to be another one -- and replaces nothing.
  read_only? = true
  last_msg$ = ""
  menuitem_click@(w@("menu.backup"))
  read_only? = false
  check(left$(last_msg$, 19) = "Could not make sure" and backup_landed(bk$) = 1, "a read-only session will not replace a file it cannot tell apart")
  rem Windows will not delete a file another connection holds open; Linux
  rem will, and the backup then goes ahead.
  held@ = sqlite_open@(bk$)
  sqlite_scalar(held@, "SELECT count(*) FROM companies")
  answer? = true
  last_msg$ = ""
  menuitem_click@(w@("menu.backup"))
  if os_name$() = "Windows" then
    q$ = "Could not replace " + bk$ + ": it could not be deleted. Is it open in another program?"
  else
    q$ = "Backed up to " + bk$
  end if
  check(last_msg$ = q$, "a target that cannot be deleted is reported, not ignored")
  sqlite_close(held@)
  rem --- export: never over a database, under any name it has, nor over
  rem any other file unless the person says so; and a write that fails
  rem leaves the file that was there (round 11: on Linux an export onto the
  rem open database destroyed every row and said "Exported") ---
  q$ = "That is a SQLite database"
  answer? = true
  save_as$ = path$
  last_msg$ = ""
  n = export_csv(1)
  check(n = 0 and left$(last_msg$, len(q$)) = q$ and file_header$(path$) = "db" and count_of("SELECT count(*) FROM companies") = 5, "an export onto the open database is refused, and it keeps its rows")
  for kind = 1 to 2
    file_writealltext(scratch$, "x")
    blind? = file_exists(spelling$(scratch$, kind)) = 1
    file_delete(scratch$)
    other$ = spelling$(path$, kind)
    if blind? = false and file_exists(other$) = 1 then file_delete(other$)
    save_as$ = other$
    last_msg$ = ""
    n = export_csv(1)
    if blind? = true then
      check(n = 0 and left$(last_msg$, len(q$)) = q$ and file_header$(path$) = "db" and count_of("SELECT count(*) FROM companies") = 5, "and under another spelling of its name (" + str$(kind) + ") where the folder reads it as the same file")
    else
      check(n > 0 and left$(file_readalltext$(other$), 8) = "company," and file_header$(path$) = "db", "and where the folder reads that spelling (" + str$(kind) + ") as another file, the export is written there")
      file_delete(other$)
    end if
  next
  rem A name that is no spelling of it at all: on Linux the link
  rem /proc/self/fd/N to the file SQLite holds open; on Windows the folder's
  rem 8.3 alias of it, where the volume keeps one and it is CONTAC~N.DB.
  alias$ = ""
  for i = 0 to 255
    if os_name$() = "Windows" then
      z$ = extractfilepath$(path$) + "CONTAC~" + str$(i) + ".DB"
    else
      z$ = "/proc/self/fd/" + str$(i)
    end if
    if alias$ = "" and i > 0 and (i < 10 or os_name$() <> "Windows") then
      if file_exists(z$) = 1 then
        if alcase$(path_canonical$(z$)) = alcase$(path_canonical$(path$)) then alias$ = z$
      end if
    end if
  next
  save_as$ = alias$
  last_msg$ = ""
  n = 0
  if alias$ <> "" then n = export_csv(1)
  check(n = 0 and (alias$ = "" or left$(last_msg$, len(q$)) = q$) and file_header$(path$) = "db" and count_of("SELECT count(*) FROM companies") = 5, "and through a name that is no spelling of it -- a link to it, its 8.3 alias -- where there is one")
  save_as$ = bk$
  text$ = file_readalltext$(bk$)
  last_msg$ = ""
  n = export_csv(1)
  check(n = 0 and left$(last_msg$, len(q$)) = q$ and file_readalltext$(bk$) = text$, "and so is one onto a backup of it: a database is never written over")
  q$ = "A name ending in -journal"
  save_as$ = path$ + "-journal"
  last_msg$ = ""
  n = export_csv(1)
  i = flag(n = 0 and left$(last_msg$, 25) = q$ and file_exists(path$ + "-journal") = 0)
  save_as$ = path$ + "-WAL."
  last_msg$ = ""
  n = export_csv(1)
  check(i = 1 and n = 0 and left$(last_msg$, 25) = q$ and file_exists(path$ + "-wal") = 0, "an export onto the open database's journal or log is refused, however the name is spelled")
  z$ = temppath$() + "contact_manager_selftest_export.csv"
  if file_exists(z$) = 1 then file_delete(z$)
  save_as$ = z$
  export_csv(1)
  text$ = file_readalltext$(z$)
  file_writealltext(z$, "precious")
  answer? = false
  last_msg$ = ""
  n = export_csv(1)
  check(n = 0 and last_msg$ = "Replace " + z$ + "?" and file_readalltext$(z$) = "precious", "an export onto a file that is there asks first, and No leaves it byte for byte")
  answer? = true
  short_write = 10
  last_msg$ = ""
  n = export_csv(1)
  short_write = 0
  check(n = 0 and last_msg$ = "Could not write " + z$ and file_readalltext$(z$) = "precious" and file_exists(z$ + ".part") = 0 and file_exists(z$ + ".old") = 0, "an export whose write stops part-way leaves the file that was there as it was, and nothing beside it")
  last_msg$ = ""
  n = export_csv(1)
  check(n > 0 and left$(text$, 8) = "company," and last_msg$ = "Replace " + z$ + "?" and file_readalltext$(z$) = text$ and file_exists(z$ + ".part") = 0 and file_exists(z$ + ".old") = 0, "and Yes replaces it with the whole export, with nothing left beside it")
  file_delete(z$)
  file_delete(bk$)
  rem The names SQLite keeps beside a database are no backup: the open
  rem database's journal is cut short by its next transaction, and any
  rem other is read as the unfinished work of the file beside it.
  q$ = "A name ending in -journal"
  save_as$ = path$ + "-journal"
  last_msg$ = ""
  menuitem_click@(w@("menu.backup"))
  n = flag(left$(last_msg$, 25) = q$ and file_exists(path$ + "-journal") = 0)
  save_as$ = path$ + "-WAL."
  last_msg$ = ""
  menuitem_click@(w@("menu.backup"))
  check(n = 1 and left$(last_msg$, 25) = q$ and file_exists(path$ + "-wal") = 0, "a backup onto the open database's journal or log is refused, however the name is spelled")
  rem Another program's file with a HOT journal beside it -- the rollback
  rem journal of a program killed in mid-transaction. Opening it through
  rem SQLite rolls the journal back into the file: the fixture is checked
  rem to do that first, or the checks after it would prove nothing.
  other$ = temppath$() + "contact_manager_selftest_hot.db"
  check(make_hot_db(other$) = 1, "a hot journal can be made")
  text$ = file_readalltext$(other$)
  v@ = sqlite_open@(other$)
  sqlite_exec(v@, "PRAGMA query_only = ON")
  sqlite_scalar(v@, "PRAGMA user_version")
  sqlite_close(v@)
  check(file_readalltext$(other$) <> text$ and file_exists(other$ + "-journal") = 0, "and SQLite rolls it back into its file on a read, deleting it")
  make_hot_db(other$)
  text$ = file_readalltext$(other$)
  check(open_database(other$) = 0 and instr(last_msg$, other$ + "-journal") > 0 and dbpath$ = path$, "another program's file with a hot journal is refused, naming the journal")
  check(file_readalltext$(other$) = text$ and file_getsize(other$ + "-journal") > 0, "and neither the file nor its journal is touched")
  rem The same file reached by a name SQLite resolves to ANOTHER, and
  rem builds the journal's name from that one: on Linux a symbolic link --
  rem /proc/self/fd/N, the one Linux keeps for every file a process holds
  rem open, so no privilege is needed to make it -- and on Windows the name
  rem with a trailing dot, which Windows drops. Beside the name as given
  rem there is no journal at all; the one SQLite would roll back is
  rem other$-journal, and it is the one judged. One pair of checks on each
  rem system, each with the spelling that system has. TWO EXCEPTIONS, said
  rem rather than hidden. Under --sandbox -- the example runners use one --
  rem the SQLite package opens no file through a link at all, so on Linux
  rem there SQLite cannot be asked the name of the link; since round 10 the
  rem program never hands it one (it judges and opens the file's own name,
  rem path_canonical$), so there the pair asks that the journal named is
  rem the one beside the file all the same. And a SQLite older than 3.39.0 is
  rem not asked the name at all (sqlite_name$): there the pair asks that
  rem the file's own bytes were judged instead -- the same count of checks
  rem on every library, so one golden serves them all.
  q$ = file_readalltext$(other$ + "-journal")
  if os_name$() = "Windows" then
    alias$ = spelling$(other$, 2)
  else
    open other$ for input as #8
    alias$ = fd_link$(text$)
  end if
  n = flag(alias$ <> "" and file_exists(alias$) = 1 and file_exists(alias$ + "-journal") = 0)
  named$ = sqlite_name$(alias$)
  if name_safe? = false then
    check(n = 1 and named$ = "" and instr(name_err$, "3.39.0") > 0, "a file can be reached by a name with no journal beside it, and this SQLite is not asked the name it gives it")
    check(open_database(alias$) = 0 and instr(last_msg$, "other tables (ledger)") > 0 and file_readalltext$(other$) = text$ and file_readalltext$(other$ + "-journal") = q$, "another program's file reached that way is judged by its own bytes on a copy, refused, and left with its journal byte for byte")
  elseif named$ = "" and os_name$() <> "Windows" and instr(name_err$, "outside the sandbox root") > 0 then
    check(n = 1, "a file can be reached through a link with no journal beside it")
    check(open_database(alias$) = 0 and instr(last_msg$, sqlite_name$(other$) + "-journal") > 0 and file_readalltext$(other$) = text$ and file_readalltext$(other$ + "-journal") = q$, "under a sandbox SQLite opens nothing through a link -- and is not handed one: the file's own name is judged, naming its journal, and both are left byte for byte")
  else
    check(n = 1 and named$ = sqlite_name$(other$), "a file can be reached by a name that has no journal beside it, though SQLite finds one")
    check(open_database(alias$) = 0 and instr(last_msg$, sqlite_name$(other$) + "-journal") > 0 and file_readalltext$(other$) = text$ and file_readalltext$(other$ + "-journal") = q$, "another program's file reached that way is judged by the journal SQLite would roll back, refused, and left with it byte for byte")
  end if
  rem An older SQLite (before 3.39.0) READS a file to answer the question
  rem sqlite_name$ asks, and reading it rolls a hot journal back -- so with
  rem one, the program must not ask. Every library is made to show that
  rem here, by pretending its age: the version is compared as numbers, the
  rem name of a file that is there is not asked, and another program's
  rem file is still refused and left byte for byte, by the journal beside
  rem the name given or, reached by another name, by its own bytes judged
  rem on a copy.
  keep? = name_safe?
  name_safe? = false
  check(version_at_least?("3.39.0", "3.39.0") = true and version_at_least?("3.38.5", "3.39.0") = false and version_at_least?("3.9.2", "3.39.0") = false and version_at_least?("3.100.0", "3.39.0") = true and version_at_least?("4.0", "3.39.0") = true, "a SQLite version is compared part by part, as numbers")
  check(sqlite_name$(other$) = "" and instr(name_err$, sqlite_version$() + " reads a file to name it") > 0 and file_readalltext$(other$) = text$ and file_readalltext$(other$ + "-journal") = q$, "an older SQLite is not asked the name of a file that is there")
  check(open_database(other$) = 0 and instr(last_msg$, other$ + "-journal lies beside it") > 0 and file_readalltext$(other$) = text$ and file_readalltext$(other$ + "-journal") = q$ and dbpath$ = path$, "with an older SQLite, another program's file with a hot journal is still refused, naming the journal, and left byte for byte")
  check(open_database(alias$) = 0 and instr(last_msg$, "other tables (ledger)") > 0 and file_readalltext$(other$) = text$ and file_readalltext$(other$ + "-journal") = q$, "and reached by another name, it is judged by its own bytes on a copy, refused, and left with its journal")
  name_safe? = keep?
  if os_name$() <> "Windows" then close #8
  rem A name SQLite reads as a URI -- wherever the library reads URIs, as
  rem Ubuntu's does -- names a file nothing has looked at, and ":memory:"
  rem and "" name none: each is refused before SQLite is handed it, on every
  rem system, at both doors.
  check(open_database("file:" + other$) = 0 and instr(last_msg$, "is a URI") > 0 and open_database(":memory:") = 0 and open_database("") = 0 and dbpath$ = path$ and file_readalltext$(other$) = text$ and file_readalltext$(other$ + "-journal") = q$, "a name SQLite reads as a URI, or as no file at all, is not opened, and the file a URI names is left with its journal")
  save_as$ = "file:" + bk$
  last_msg$ = ""
  menuitem_click@(w@("menu.backup"))
  check(instr(last_msg$, "is a URI") > 0 and file_exists(bk$) = 0, "and no backup is written to one")
  rem A name the folder lists that is no file -- a folder here; on Windows
  rem also a symbolic link that leads to no file, which SQLite would write
  rem through without saying where -- is refused.
  z$ = temppath$() + "contact_manager_selftest_dir.db"
  if dir_exists(z$) = 0 then dir_create(z$)
  save_as$ = z$
  last_msg$ = ""
  menuitem_click@(w@("menu.backup"))
  n = flag(left$(last_msg$, 16 + len(z$)) = "Something is at " + z$)
  check(n = 1 and open_database(z$) = 0 and instr(last_msg$, "Something is at " + z$) > 0 and dir_exists(z$) = 1 and dbpath$ = path$, "a name that is listed but is no file is neither backed up to nor opened")
  dir_delete(z$)
  rem WHAT A NAME IS, ASKED OF THE OS (round 10). On Windows name:stream is
  rem a stream inside the file name, and name::$DATA is that file itself:
  rem so x-journal:bk dies with x-journal, and x-wal::$DATA IS x-wal -- each
  rem past every check of how the name ends. On Linux a colon is a
  rem character of a file name like any other, and both are files.
  z$ = path$ + "-journal:bk"
  bad$ = path$ + "-wal::$DATA"
  if os_name$() = "Windows" then
    save_as$ = z$
    last_msg$ = ""
    menuitem_click@(w@("menu.backup"))
    n = flag(left$(last_msg$, 21) = "That name is a stream" and file_exists(path$ + "-journal") = 0)
    check(n = 1 and open_database(bad$) = 0 and instr(last_msg$, "is a stream inside a file") > 0 and dbpath$ = path$ and file_exists(path$ + "-wal") = 0, "a stream of a file -- of a journal, or a log's own stream spelled out -- is neither backed up to nor opened")
  else
    check(name_refusal$(z$) = "" and name_refusal$(bad$) = "", "a colon in a name is a character like any other where the system says so")
  end if
  rem A device is no file -- CON on Windows, /dev/null on Linux -- and the
  rem console is read by waiting for a person: SQLite blocked opening CON,
  rem past every execution limit.
  if os_name$() = "Windows" then z$ = "CON" else z$ = "/dev/null"
  save_as$ = z$
  last_msg$ = ""
  menuitem_click@(w@("menu.backup"))
  n = flag(last_msg$ <> "" and left$(last_msg$, 9) <> "Backed up")
  check(n = 1 and open_database(z$) = 0 and dbpath$ = path$ and file_header$(z$) <> "empty", "a device is neither backed up to nor opened, nor read as an empty file, and nothing waits on it")
  rem SQLite reads a URI only from "file:" and a database with no file only
  rem from ":memory:", both in lower case (sqlite3ParseUri, a memcmp; a
  rem strcmp): "FILE:..." is a file on Linux, a stream on Windows -- either
  rem way it is not refused as a URI.
  check(instr(name_refusal$("FILE:" + bk$), "is a URI") = 0 and instr(name_refusal$(":MEMORY:"), "is a URI") = 0 and instr(name_refusal$("file:" + bk$), "is a URI") > 0, "only what SQLite reads as a URI, or as no file, is refused as one: file: and :memory: as SQLite spells them")
  rem A file shorter than the sixteen bytes the header test reads: `or`
  rem evaluates every operand, and byteat past its end ended the program.
  z$ = temppath$() + "contact_manager_selftest_short.db"
  file_writealltext(z$, "short")
  check(file_header$(z$) = "notdb" and is_open_db(z$) = 0 and open_database(z$) = 0 and instr(last_msg$, "not a SQLite database") > 0 and dbpath$ = path$, "a file of a few bytes is no database, and is refused as one")
  file_delete(z$)
  rem A journal whose program is still AT WORK on the file: SQLite would
  rem leave it (pager.c, hasHotJournal, asks the writer's lock first), and
  rem the program cannot ask that lock -- so it refuses the file, and does
  rem not say the program stopped. Here the writer is another connection,
  rem in the middle of a transaction whose pages have spilled into the file;
  rem it commits afterwards.
  z$ = temppath$() + "contact_manager_selftest_live.db"
  if file_exists(z$) = 1 then file_delete(z$)
  v@ = sqlite_open@(z$)
  sqlite_exec(v@, "CREATE TABLE ledger (x); INSERT INTO ledger WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000) SELECT i FROM n")
  hot_begin(v@)
  sqlite_exec(v@, "UPDATE ledger SET x = x + 1000000")
  n = flag(file_getsize(z$ + "-journal") > 0 and journal_magic?(z$ + "-journal") = true)
  check(n = 1 and open_database(z$) = 0 and instr(last_msg$, "the journal of a program changing the file right now, or of one that stopped in the middle of a change") > 0 and instr(last_msg$, "a program stopped") = 0 and sqlite_commit(v@) = 1 and sqlite_scalar(v@, "SELECT min(x) FROM ledger") = 1000001, "a journal whose program may still be at work is not called a crash, and that program commits afterwards")
  sqlite_close(v@)
  file_delete(z$)
  rem Real symbolic links, which a BASIC program cannot make: with
  rem PHOSPHOR_SELFTEST_LINKS naming a folder that holds tojournal.db ->
  rem other.db-journal and tohot.db -> hot.db, neither leading to a file
  rem yet, six checks more run here, and one more further on (toown.db).
  rem The folder holds more for those (round 10): truncvictim.db-journal,
  rem an empty journal; longlinkname.database -> victim.db-journal, which
  rem leads to no file; toown.db -> own.db; on Linux tojrn.db ->
  rem truncvictim.db-journal and a FIFO, pipe.db. On Windows the short
  rem names TRUNCV~1.DB- and LONGLI~1.DAT are the folder's own 8.3 aliases
  rem of the first two, which the block checks dir /x gives. Block AI of
  rem scripts/test.ps1 and scripts/test.sh makes all of it and runs this
  rem without a sandbox, on each system, and expects the golden's count
  rem and these seven.
  z$ = environ$("PHOSPHOR_SELFTEST_LINKS")
  if z$ <> "" then
    alias$ = path_combine$(z$, "tojournal.db")
    q$ = path_combine$(z$, "other.db-journal")
    rem A link that leads to no file is SOMETHING there with no canonical
    rem name (path_canonical$), on both systems: refused before SQLite,
    rem which would create the file it leads to, is handed it.
    named$ = "Something is at " + alias$
    save_as$ = alias$
    answer? = true
    last_msg$ = ""
    menuitem_click@(w@("menu.backup"))
    check(instr(last_msg$, named$) > 0 and file_exists(q$) = 0, "a backup through a link that leads to a journal's name is refused, and nothing is written there")
    check(open_database(alias$) = 0 and instr(last_msg$, named$) > 0 and file_exists(q$) = 0 and dbpath$ = path$, "and so is opening a database there")
    alias$ = path_combine$(z$, "tohot.db")
    q$ = path_combine$(z$, "hot.db")
    make_hot_db(q$)
    text$ = file_readalltext$(q$)
    named$ = file_readalltext$(q$ + "-journal")
    rem The journal judged is the one beside the link's TARGET, on both
    rem systems and with every library: the name judged is the one the OS
    rem gives the file (path_canonical$), and it is the one SQLite is
    rem handed. (On Windows SQLite names a link's journal after the LINK,
    rem and until round 10 hot.db-journal was never looked at.)
    n = flag(open_database(alias$) = 0 and instr(last_msg$, path_canonical$(q$) + "-journal lies beside it") > 0)
    check(n = 1 and file_readalltext$(q$) = text$ and file_readalltext$(q$ + "-journal") = named$ and dbpath$ = path$, "another program's file reached through a real link is refused, and it and its journal are left byte for byte")
    file_delete(q$ + "-journal")
    file_delete(q$)
    rem ANOTHER SPELLING OF A JOURNAL'S NAME (round 10): on Windows its 8.3
    rem alias, on Linux a link to it. truncvictim.db-journal is the empty
    rem journal a database in TRUNCATE mode leaves; a database written into
    rem it was deleted at that database's next read.
    q$ = path_combine$(z$, "truncvictim.db-journal")
    if os_name$() = "Windows" then
      alias$ = path_combine$(z$, "TRUNCV~1.DB-")
    else
      alias$ = path_combine$(z$, "tojrn.db")
    end if
    named$ = "That name leads to " + path_canonical$(q$) + "."
    save_as$ = alias$
    last_msg$ = ""
    menuitem_click@(w@("menu.backup"))
    n = flag(instr(last_msg$, named$) > 0 and file_exists(q$) = 1 and file_getsize(q$) = 0)
    check(n = 1 and open_database(alias$) = 0 and instr(last_msg$, named$) > 0 and file_getsize(q$) = 0 and dbpath$ = path$, "another spelling of a journal's name -- an 8.3 alias, a link -- is neither backed up to nor opened, and the journal is left empty")
    rem A link that leads to no file, under its 8.3 alias on Windows: the
    rem round-9 refusal read the long name only, and LONGLI~1.DAT wrote the
    rem backup into victim.db-journal.
    q$ = path_combine$(z$, "victim.db-journal")
    if os_name$() = "Windows" then
      alias$ = path_combine$(z$, "LONGLI~1.DAT")
    else
      alias$ = path_combine$(z$, "longlinkname.database")
    end if
    named$ = "Something is at " + alias$
    save_as$ = alias$
    last_msg$ = ""
    menuitem_click@(w@("menu.backup"))
    n = flag(instr(last_msg$, named$) > 0 and file_exists(q$) = 0)
    check(n = 1 and open_database(alias$) = 0 and instr(last_msg$, named$) > 0 and file_exists(q$) = 0 and dbpath$ = path$, "a link that leads to no file is refused under any of its names, at both doors")
    rem A pipe: on Linux a FIFO, whose open blocks until a writer comes --
    rem the program hung at both doors; on Windows a named pipe's name.
    if os_name$() = "Windows" then
      alias$ = chr$(92) + chr$(92) + "." + chr$(92) + "pipe" + chr$(92) + "phosphor-selftest-none"
    else
      alias$ = path_combine$(z$, "pipe.db")
    end if
    save_as$ = alias$
    last_msg$ = ""
    menuitem_click@(w@("menu.backup"))
    n = flag(instr(last_msg$, "a device or a pipe") > 0)
    check(n = 1 and open_database(alias$) = 0 and instr(last_msg$, "a device or a pipe") > 0 and dbpath$ = path$ and file_header$(alias$) <> "db", "a pipe is neither backed up to nor opened nor read, and nothing waits on it")
  end if
  save_as$ = other$
  answer? = false
  last_msg$ = ""
  menuitem_click@(w@("menu.backup"))
  check(last_msg$ = "Replace " + other$ + "?" and file_readalltext$(other$) = text$ and file_getsize(other$ + "-journal") > 0, "a backup onto it asks first, and No leaves the file and its journal as they were")
  answer? = true
  menuitem_click@(w@("menu.backup"))
  check(last_msg$ = "Backed up to " + other$ and file_exists(other$ + "-journal") = 0, "and Yes replaces it with a backup that reads back, its old journal gone")
  file_delete(other$)

  rem --- users: an operator, the last-administrator rule ---
  pagecontrol_pageindex@(w@("pages"), 4)
  click("u.new")
  type_into("u.username", "olivia")
  type_into("u.full_name", "Olivia Operator")
  type_into("u.password", "123")
  type_into("u.confirm", "123")
  click("u.save")
  check(instr(last_msg$, "6 characters") > 0, "a short password is refused")
  type_into("u.password", "olivia-pw")
  type_into("u.confirm", "olivia-pw")
  click("u.save")
  check(count_of("SELECT count(*) FROM users WHERE username = 'olivia' AND role = 'operator'") = 1, "an operator is created")
  click("u.new")
  type_into("u.username", "josé")
  type_into("u.password", "jose-pw1")
  type_into("u.confirm", "jose-pw1")
  click("u.save")
  click("u.new")
  type_into("u.username", "JOSÉ")
  type_into("u.password", "jose-pw2")
  type_into("u.confirm", "jose-pw2")
  click("u.save")
  check(count_of("SELECT count(*) FROM users WHERE username = 'josé'") = 1 and instr(last_msg$, "user name is taken") > 0, "a user name beyond ASCII is created, and JOSÉ is the same name")
  rem A row is loaded when the cursor MOVES onto it, so step off and back.
  grid_select("ugrid", scalar_s("SELECT id FROM users WHERE username = ?1", "olivia"))
  grid_select("ugrid", 1)
  combo_itemindex@(w@("u.role"), 1)
  click("u.save")
  check(last_msg$ = "At least one active administrator must remain.", "the last administrator cannot be demoted")
  check(control_enabled(w@("u.delete")) = 0, "your own account has no Delete")
  type_into("u.username", "OLIVIA")
  combo_itemindex@(w@("u.role"), 2)
  click("u.save")
  check(instr(last_msg$, "user name is taken") > 0, "user names are unique, case-insensitively")

  rem --- my password ---
  menuitem_click@(w@("menu.password"))
  type_into("pw.old", "wrong")
  type_into("pw.new", "secret9")
  type_into("pw.confirm", "secret9")
  click("pw.ok")
  check(label_caption$(w@("pw.msg")) = "The current password is wrong.", "changing a password asks for the current one")
  type_into("pw.old", "secret1")
  click("pw.ok")
  check(form_modalresult(w@("pw")) = 1, "the dialog is answered 1 once the password is changed")
  check(password_verify?("secret9", sqlite_scalar$(db@, "SELECT password FROM users WHERE id = 1")) = true, "the new password is the one kept")

  rem --- a second administrator, and the guard on deleting one. This
  rem session's administrator can only delete ANOTHER user, so the guard
  rem fires when another program has demoted this one meanwhile: then bob
  rem is the last active administrator left ---
  click("u.new")
  type_into("u.username", "bob")
  type_into("u.password", "bob-pw-1")
  type_into("u.confirm", "bob-pw-1")
  combo_itemindex@(w@("u.role"), 2)
  click("u.save")
  bob = scalar_s("SELECT id FROM users WHERE username = ?1 AND role = 'admin'", "bob")
  sqlite_exec(db@, "UPDATE users SET role = 'operator' WHERE id = 1")
  grid_select("ugrid", bob)
  answer? = true
  last_msg$ = ""
  click("u.delete")
  check(bob > 0 and last_msg$ = "At least one active administrator must remain." and scalar_n("SELECT count(*) FROM users WHERE id = ?1", bob) = 1, "nor can the last active administrator be deleted")
  sqlite_exec(db@, "UPDATE users SET role = 'admin' WHERE id = 1")

  rem --- your own account: a change takes effect at once ---
  grid_select("ugrid", 1)
  combo_itemindex@(w@("u.role"), 1)
  click("u.save")
  check(user_role$ = "operator" and control_get(w@("users.page"), "TabVisible") = 0, "demoting yourself makes the session an operator's, without the Users tab")
  check(count_of("SELECT count(*) FROM users WHERE id = 1 AND role = 'operator'") = 1, "and is saved")
  menuitem_click@(w@("menu.signout"))
  type_into("login.user", "bob")
  type_into("login.pass", "bob-pw-1")
  click("login.go")
  check(user_name$ = "bob" and user_role$ = "admin", "the other administrator signs in")
  pagecontrol_pageindex@(w@("pages"), 4)
  grid_select("ugrid", bob)
  grid_select("ugrid", 1)
  combo_itemindex@(w@("u.role"), 2)
  click("u.save")
  grid_select("ugrid", bob)
  checkbox_checked@(w@("u.active"), 0)
  answer? = false
  click("u.save")
  check(user_id = bob and scalar_n("SELECT count(*) FROM users WHERE id = ?1 AND active = 1", bob) = 1, "deactivating yourself asks first, and No changes nothing")
  answer? = true
  click("u.save")
  check(user_id = 0 and scalar_n("SELECT count(*) FROM users WHERE id = ?1 AND active = 0", bob) = 1, "and Yes saves it and signs you out")

  rem --- an operator signs in ---
  type_into("login.user", "olivia")
  type_into("login.pass", "wrong-password")
  click("login.go")
  check(label_caption$(w@("login.msg")) = "User name or password is wrong.", "a wrong password is refused")
  check(edit_text$(w@("login.pass")) = "", "and the password field is emptied")
  type_into("login.user", "nobody")
  type_into("login.pass", "olivia-pw")
  click("login.go")
  check(label_caption$(w@("login.msg")) = "User name or password is wrong.", "an unknown user gets the same words")
  type_into("login.user", "Olivia")
  type_into("login.pass", "olivia-pw")
  click("login.go")
  check(user_name$ = "olivia" and user_role$ = "operator", "the operator signs in, user name in any case, called by the stored name")
  check(instr(statusbar_text$(w@("status")), "Signed in as olivia (operator)") > 0, "and the status bar says so")
  check(control_get(w@("users.page"), "TabVisible") = 0, "and does not see the Users tab")
  check(count_of("SELECT count(*) FROM users WHERE username = 'olivia' AND last_login IS NOT NULL") = 1, "the sign-in is recorded")
  menuitem_click@(w@("menu.signout"))
  type_into("login.user", "JOSÉ")
  type_into("login.pass", "jose-pw1")
  click("login.go")
  check(user_name$ = "josé", "JOSÉ signs in as josé")

  rem --- an inactive user cannot sign in ---
  sqlite_exec(db@, "UPDATE users SET active = 0 WHERE username = 'olivia'")
  menuitem_click@(w@("menu.signout"))
  type_into("login.user", "olivia")
  type_into("login.pass", "olivia-pw")
  click("login.go")
  check(user_id = 0, "an inactive user cannot sign in")

  rem --- case FOLDING, not lower-casing. The expected keys are
  rem CaseFolding.txt's: U+03C2 (final sigma) folds to U+03C3, status C;
  rem U+00DF (ß) and U+1E9E (capital ß) fold to "ss", status F; U+FB01 (the
  rem fi ligature) to "fi", status F; and U+AB70, a Cherokee small letter,
  rem folds to its CAPITAL U+13A0, status C -- folding is not lower-casing.
  rem U+0130 (dotted capital I) is the one departure, on purpose: status F
  rem says "i" + U+0307, and this program's rule says a plain "i" (fold$) ---
  check(fold$("ΣΩΚΡΑΤΗΣ") = "σωκρατη" + chr$(963) and fold$("σωκρατης") = "σωκρατη" + chr$(963), "a final sigma folds like any sigma")
  check(fold$("straße") = "strasse" and fold$("STRASSE") = "strasse" and fold$(chr$(7838)) = "ss", "ß and capital ß fold to ss")
  check(fold$(chr$(64257) + "LE") = "file" and fold$(chr$(43888)) = chr$(5024), "a ligature and Cherokee fold as CaseFolding.txt says")
  check(fold$(chr$(304) + "STANBUL") = "istanbul" and fold$(chr$(304)) = fold$("I") and fold$(chr$(304)) = fold$("i"), "the dotted capital I folds to a plain i, the key I and i have")
  check(fold$("Aço Forte") = "aço forte", "and an accented Latin name folds as it lower-cases")
  rem A byte that is not UTF-8 is one ill-formed unit and nothing more
  rem (Unicode chapter 3, "maximal subpart"): 80 is a lone continuation
  rem byte, E2 a lead with no continuation after it, F0 one followed by an
  rem ASCII A. Each stays as it is -- alcase$ leaves it so -- and the ß
  rem after it (C3 9F, well-formed) still folds to "ss", the A to "a".
  check(fold$(bytestr$(128) + "ß") = bytestr$(128) + "ss" and fold$(bytestr$(226) + "ß") = bytestr$(226) + "ss" and fold$(bytestr$(240) + "Aß") = bytestr$(240) + "ass", "a stray byte does not hide the character after it from the fold")
  check(fold$("ß" + bytestr$(128)) = "ss" + bytestr$(128) and fold$("ß" + bytestr$(226)) = "ss" + bytestr$(226) and fold$(bytestr$(195)) = bytestr$(195), "nor one after a character, or at the end of the text")
  type_into("login.user", "admin")
  type_into("login.pass", "secret9")
  click("login.go")
  pagecontrol_pageindex@(w@("pages"), 4)
  click("u.new")
  type_into("u.username", "ΣΩΚΡΑΤΗΣ")
  type_into("u.password", "sokrates1")
  type_into("u.confirm", "sokrates1")
  click("u.save")
  last_msg$ = ""
  click("u.new")
  type_into("u.username", "σωκρατης")
  type_into("u.password", "sokrates2")
  type_into("u.confirm", "sokrates2")
  click("u.save")
  check(instr(last_msg$, "user name is taken") > 0 and count_of("SELECT count(*) FROM users WHERE username_key = 'σωκρατη" + chr$(963) + "'") = 1, "ΣΩΚΡΑΤΗΣ and σωκρατης are one user name")
  click("u.new")
  type_into("u.username", "STRASSE")
  type_into("u.password", "strasse1")
  type_into("u.confirm", "strasse1")
  click("u.save")
  last_msg$ = ""
  click("u.new")
  type_into("u.username", "straße")
  type_into("u.password", "strasse2")
  type_into("u.confirm", "strasse2")
  click("u.save")
  check(instr(last_msg$, "user name is taken") > 0 and count_of("SELECT count(*) FROM users WHERE username_key = 'strasse'") = 1, "and STRASSE and straße are one")
  menuitem_click@(w@("menu.signout"))
  type_into("login.user", "σωκρατης")
  type_into("login.pass", "sokrates1")
  click("login.go")
  check(user_name$ = "ΣΩΚΡΑΤΗΣ", "ΣΩΚΡΑΤΗΣ signs in typing σωκρατης, the way Greek is written in lower case")
  click("c.new")
  type_into("c.f.name", "ΟΔΥΣΣΕΥΣ Α.Ε.")
  type_into("c.f.trade_name", "Weiß Hellas")
  click("c.save")
  id = cur("c.company")
  edit_text@(w@("c.search"), "οδυσσευς")
  check(stringgrid_rowcount(w@("c.grid")) = 2 and stringgrid_cell$(w@("c.grid"), 1, 2) = "ΟΔΥΣΣΕΥΣ Α.Ε.", "a search for οδυσσευς finds ΟΔΥΣΣΕΥΣ")
  edit_text@(w@("c.search"), "WEISS")
  check(stringgrid_rowcount(w@("c.grid")) = 2, "and WEISS finds Weiß")
  edit_text@(w@("c.search"), "")
  grid_select("c.grid", id)
  answer? = true
  click("c.delete")
  menuitem_click@(w@("menu.signout"))

  rem --- a long list. A refresh first looked its rows up by walking an
  rem "id,id,id" string (17 s at 2,000 rows), then grew its grid a row at a
  rem time, which made the grid re-measure every row it had at each step
  rem (7.5 s at 20,000 rows). Both are quadratic, and no bound in seconds
  rem tells that apart from a slow machine -- so what is checked is the
  rem SHAPE: eight times the rows must cost about eight times as long, not
  rem up to sixty-four. Measured on Windows: 2,500 rows in 62 ms and 20,000
  rem in 505 ms, a ratio of 8; growing a row at a time made it 39 (173 ms
  rem and 6,800 ms). The bound, 20, is two and a half times the linear ratio
  rem and half the quadratic one. The small list is timed twice and the
  rem faster run kept; the large one is timed again only if it looks slow,
  rem so one stall of the machine does not decide the check ---
  sqlite_exec(db@, "INSERT INTO companies(kind, name, search_key) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2500) SELECT 'supplier', 'Bulk ' || printf('%05d', i), 'bulk ' || printf('%05d', i) FROM n")
  set_cur("s.company", 0)
  t1 = best_refresh_ms(1, 0)
  sqlite_exec(db@, "INSERT INTO companies(kind, name, search_key) WITH RECURSIVE n(i) AS (SELECT 2501 UNION ALL SELECT i + 1 FROM n WHERE i < 20000) SELECT 'supplier', 'Bulk ' || printf('%05d', i), 'bulk ' || printf('%05d', i) FROM n")
  if t1 < 1 then t1 = 1
  t2 = best_refresh_ms(1, 20 * t1)
  check(stringgrid_rowcount(w@("s.grid")) = 20004 and t2 < 20 * t1, "a refresh of 20,000 suppliers costs about 8 times one of 2,500, not 64 (" + str$(t1) + " ms, " + str$(t2) + " ms)")
  bulk = scalar_s("SELECT id FROM companies WHERE name = ?1", "Bulk 15000")
  check(grid_select("s.grid", bulk) = 1 and edit_text$(w@("s.f.name")) = "Bulk 15000", "and one of them is found by its id")
  refresh_companies(1)
  check(edit_text$(w@("s.f.name")) = "Bulk 15000" and stringgrid_cell$(w@("s.grid"), 1, 20004) = "Rivet & Bolt Co.", "a refresh keeps it selected, and fills the last row")
  sqlite_exec(db@, "DELETE FROM companies WHERE name LIKE 'Bulk %'")
  refresh_companies(1)
  check(stringgrid_rowcount(w@("s.grid")) = 4, "and a shorter list shrinks the grid to its rows")

  rem --- the schema upgrade, version 1 to 3, on a database built the way
  rem version 1 built it ---
  path3$ = temppath$() + "contact_manager_selftest_v1.db"
  if file_exists(path3$) = 1 then file_delete(path3$)
  v@ = sqlite_open@(path3$)
  schema_v1(v@)
  sqlite_exec(v@, "PRAGMA user_version = 1; INSERT INTO users(username, password, role) VALUES ('Ana', 'x', 'admin'); INSERT INTO companies(kind, name, tax_id, city) VALUES ('supplier', 'Old Steel', '11.444.777/0001-61', 'Curitiba'), ('customer', 'Old Buyer', '11444777000161', ''); INSERT INTO product_lines(name) VALUES ('Ação')")
  sqlite_close(v@)
  check(open_database(path3$) = 1 and sqlite_scalar(db@, "PRAGMA user_version") = 3 and sqlite_scalar(db@, "PRAGMA application_id") = 1349010253, "a version-1 database is upgraded to version 3, and marked as this program's")
  check(count_of("SELECT count(*) FROM users WHERE username_key = 'ana'") = 1 and count_of("SELECT count(*) FROM companies WHERE tax_key = '11444777000161'") = 2 and count_of("SELECT count(*) FROM product_lines WHERE name_key = 'ação'") = 1, "with the keys of the rows it had")
  check(count_of("SELECT count(*) FROM sqlite_master WHERE name = 'ux_companies_tax_id'") = 0 and count_of("SELECT count(*) FROM sqlite_master WHERE name = 'ux_companies_tax_key'") = 1, "and the tax-id index replaced by the key's")
  check(db_owner$(db@, 3, APP_ID) = "ours", "and the file the upgrade made passes the damage check, indexes and foreign keys included")
  sqlite_begin(db@)
  check(upgrade(db@, 1) = 1, "the upgrade's steps can run again and find nothing to do")
  sqlite_rollback(db@)
  rem Two suppliers with one id, written two ways: version 1 let them in.
  path4$ = temppath$() + "contact_manager_selftest_v1b.db"
  if file_exists(path4$) = 1 then file_delete(path4$)
  v@ = sqlite_open@(path4$)
  schema_v1(v@)
  sqlite_exec(v@, "PRAGMA user_version = 1; INSERT INTO companies(kind, name, tax_id) VALUES ('supplier', 'First', '11.444.777/0001-61'), ('supplier', 'Second', '11444777000161')")
  sqlite_close(v@)
  check(open_database(path4$) = 0 and instr(last_msg$, "same tax id written in different ways") > 0 and instr(last_msg$, "Second (11444777000161)") > 0, "an upgrade the old rows would break is refused, naming them")
  v@ = sqlite_open@(path4$)
  check(sqlite_scalar(v@, "PRAGMA user_version") = 1 and sqlite_scalar(v@, "SELECT count(*) FROM pragma_table_info('companies') WHERE name = 'tax_key'") = 0, "and the database is left as it was")
  rem A read-only file of an older version cannot be upgraded, and is not
  rem looked at as it is (its keys follow the old rule): it is refused,
  rem saying to open a writable copy. query_only refuses every write the
  rem way a read-only file does.
  sqlite_exec(v@, "UPDATE companies SET tax_id = '' WHERE name = 'Second'; PRAGMA query_only = ON")
  check(create_schema(v@) = 0 and instr(schema_msg$, "read-only") > 0 and instr(schema_msg$, "writable copy") > 0 and sqlite_scalar(v@, "PRAGMA user_version") = 1, "a read-only database of an older version is refused, saying to open a writable copy")
  sqlite_close(v@)
  file_delete(path4$)

  rem --- version 2 to 3, on a database built the way version 2 built it:
  rem the same columns, with keys LOWER-cased by alcase$ ---
  v@ = sqlite_open@(path4$)
  schema_v1(v@)
  migrate_v2(v@)
  sqlite_exec(v@, "INSERT INTO users(username, username_key, password, role) VALUES ('Σωκράτης', " + sqlite_quote$(alcase$("Σωκράτης")) + ", 'x', 'admin')")
  sqlite_exec(v@, "INSERT INTO companies(kind, name, search_key) VALUES ('supplier', 'Straße Bau', " + sqlite_quote$(alcase$("Straße Bau")) + ")")
  sqlite_exec(v@, "INSERT INTO product_lines(name, name_key) VALUES ('Weiß', " + sqlite_quote$(alcase$("Weiß")) + ")")
  sqlite_exec(v@, "CREATE UNIQUE INDEX ux_users_username_key ON users(username_key); CREATE UNIQUE INDEX ux_product_lines_name_key ON product_lines(name_key); CREATE UNIQUE INDEX ux_companies_tax_key ON companies(kind, tax_key) WHERE tax_key <> ''; PRAGMA user_version = 2")
  sqlite_close(v@)
  check(open_database(path4$) = 1 and sqlite_scalar(db@, "PRAGMA user_version") = 3 and sqlite_scalar(db@, "PRAGMA application_id") = 1349010253, "a version-2 database is upgraded to version 3")
  check(count_of("SELECT count(*) FROM users WHERE username_key = 'σωκράτη" + chr$(963) + "'") = 1 and count_of("SELECT count(*) FROM companies WHERE search_key LIKE 'strasse bau%'") = 1 and count_of("SELECT count(*) FROM product_lines WHERE name_key = 'weiss'") = 1, "with its keys folded again")
  check(count_of("SELECT count(*) FROM sqlite_master WHERE name IN ('ux_users_username_key', 'ux_product_lines_name_key', 'ux_companies_tax_key')") = 3, "and its unique indexes back")
  sqlite_close(db@)
  file_delete(path4$)
  rem Version 2 kept STRASSE and straße apart; folded, they are one name.
  v@ = sqlite_open@(path4$)
  schema_v1(v@)
  migrate_v2(v@)
  sqlite_exec(v@, "INSERT INTO users(username, username_key, password, role) VALUES ('STRASSE', 'strasse', 'x', 'admin'), ('straße', " + sqlite_quote$(alcase$("straße")) + ", 'y', 'operator'); CREATE UNIQUE INDEX ux_users_username_key ON users(username_key); PRAGMA user_version = 2")
  sqlite_close(v@)
  check(open_database(path4$) = 0 and instr(last_msg$, "differ only in upper and lower case") > 0 and instr(last_msg$, "STRASSE / straße") > 0, "an upgrade that folds two user names into one is refused, naming them")
  v@ = sqlite_open@(path4$)
  check(sqlite_scalar(v@, "PRAGMA user_version") = 2 and sqlite_scalar(v@, "SELECT count(*) FROM users WHERE username_key = 'strasse'") = 1, "and the version-2 database is left as it was")
  sqlite_close(v@)
  file_delete(path4$)
  rem Turkish: version 2 keyed İLKER as alcase$ does. Folded, U+0130 is a
  rem plain "i" (fold$), so the key after the upgrade is "ilker" -- the key
  rem of ilker and of ILKER -- and İSTANBUL TİCARET is searched as
  rem "istanbul ticaret". Kept with its dot, neither would be found.
  v@ = sqlite_open@(path4$)
  schema_v1(v@)
  migrate_v2(v@)
  sqlite_exec(v@, "INSERT INTO users(username, username_key, password, role) VALUES ('İLKER', " + sqlite_quote$(alcase$("İLKER")) + ", " + sqlite_quote$(password_hash$("ilker-pw", pw_cost)) + ", 'admin')")
  sqlite_exec(v@, "INSERT INTO companies(kind, name, search_key) VALUES ('supplier', 'İSTANBUL TİCARET A.Ş.', " + sqlite_quote$(alcase$("İSTANBUL TİCARET A.Ş.")) + ")")
  sqlite_exec(v@, "CREATE UNIQUE INDEX ux_users_username_key ON users(username_key); CREATE UNIQUE INDEX ux_product_lines_name_key ON product_lines(name_key); CREATE UNIQUE INDEX ux_companies_tax_key ON companies(kind, tax_key) WHERE tax_key <> ''; PRAGMA user_version = 2")
  sqlite_close(v@)
  check(open_database(path4$) = 1 and count_of("SELECT count(*) FROM users WHERE username_key = 'ilker'") = 1, "a version-2 user İLKER is upgraded to the key ilker")
  type_into("login.user", "ilker")
  type_into("login.pass", "ilker-pw")
  click("login.go")
  check(user_name$ = "İLKER", "and signs in typing ilker")
  edit_text@(w@("s.search"), "istanbul")
  check(stringgrid_rowcount(w@("s.grid")) = 2 and stringgrid_cell$(w@("s.grid"), 1, 2) = "İSTANBUL TİCARET A.Ş.", "a search for istanbul finds İSTANBUL TİCARET")
  edit_text@(w@("s.search"), "")
  menuitem_click@(w@("menu.signout"))
  sqlite_close(db@)
  file_delete(path4$)

  rem --- an upgrade is linear in its rows. Its duplicate check once counted
  rem every company of the same kind and tax id FOR EACH company: 8,000 took
  rem 10 s and 16,000 took 47 s. The same SHAPE check as the list's: 16,000
  rem companies must cost about 8 times 2,000. Measured on Windows: 450 ms
  rem and 3,500 ms, a ratio of 8, where the per-row count made it 57 (800 ms
  rem and 45 s; 37 on Linux). Bound: 20, timed the same way ---
  t1 = upgrade_ms(path4$, 2000, 0)
  if t1 < 1 then t1 = 1
  t2 = upgrade_ms(path4$, 16000, 20 * t1)
  check(t1 > 0 and t2 > 0 and t2 < 20 * t1, "upgrading 16,000 companies costs about 8 times 2,000, not 64 (" + str$(t1) + " ms, " + str$(t2) + " ms)")

  rem --- another program's SQLite file is not written into: before anything
  rem is created or upgraded the file must be empty, or carry this
  rem program's application id, or be a version-1 or -2 file with every
  rem table and column version 1 built ---
  v@ = sqlite_open@(path4$)
  sqlite_exec(v@, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes(body) VALUES ('mine')")
  sqlite_close(v@)
  rem "Nothing written" is asked of the file's BYTES: counting its tables
  rem again could not see a write that changed no count.
  text$ = file_readalltext$(path4$)
  check(open_database(path4$) = 0 and instr(last_msg$, "not a Contact Manager database") > 0 and instr(last_msg$, "notes") > 0, "another program's database is refused, naming its tables")
  check(bytelen(text$) > 0 and file_readalltext$(path4$) = text$, "and nothing was written into it")
  file_delete(path4$)
  rem A users table of its own, at a version number that looks like ours.
  v@ = sqlite_open@(path4$)
  sqlite_exec(v@, "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT); INSERT INTO users(email) VALUES ('a@b.example'); PRAGMA user_version = 2")
  sqlite_close(v@)
  text$ = file_readalltext$(path4$)
  check(open_database(path4$) = 0 and instr(last_msg$, "not a Contact Manager database") > 0, "so is one with a users table of its own")
  check(bytelen(text$) > 0 and file_readalltext$(path4$) = text$, "and its table is not altered")
  file_delete(path4$)
  v@ = sqlite_open@(path4$)
  sqlite_exec(v@, "PRAGMA application_id = 123")
  sqlite_close(v@)
  text$ = file_readalltext$(path4$)
  check(open_database(path4$) = 0 and instr(last_msg$, "belongs to another program") > 0 and file_readalltext$(path4$) = text$, "and so is a file another program has marked as its own")
  file_delete(path4$)
  rem This program's mark is not trusted alone: a file carrying it at the
  rem current version, but without the tables that version has, is damaged
  rem -- opened, its first query would fail on a table that is not there.
  rem The first table this program builds is users (schema_v1).
  v@ = sqlite_open@(path4$)
  sqlite_exec(v@, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT); PRAGMA application_id = " + str$(APP_ID) + "; PRAGMA user_version = " + str$(SCHEMA_VERSION))
  sqlite_close(v@)
  text$ = file_readalltext$(path4$)
  check(open_database(path4$) = 0 and instr(last_msg$, "not a complete one: the table users is missing") > 0 and file_readalltext$(path4$) = text$, "a file with this program's mark but not its tables is refused as damaged, and left alone")
  file_delete(path4$)
  rem And one that has every table but has lost a column of one.
  v@ = sqlite_open@(path4$)
  upgrade(v@, 0)
  sqlite_exec(v@, "ALTER TABLE companies DROP COLUMN search_key; PRAGMA application_id = " + str$(APP_ID) + "; PRAGMA user_version = " + str$(SCHEMA_VERSION))
  sqlite_close(v@)
  check(open_database(path4$) = 0 and instr(last_msg$, "the column companies.search_key is missing") > 0, "and so is one that lost a column")
  file_delete(path4$)
  rem The program's uniqueness rules live in its indexes, and nowhere else
  rem (on_user_save has no other check), and its deletes in its foreign
  rem keys: a marked file without them is as damaged as one without a
  rem column. The rules are read as SQLite reports them -- the expected
  rem text is the DDL of schema_v1 and rekey_and_check: username_key has no
  rem COLLATE, so BINARY; username is declared UNIQUE COLLATE NOCASE, which
  rem SQLite builds as sqlite_autoindex_users_1; contacts.company_id
  rem references companies(id) ON DELETE CASCADE.
  v@ = sqlite_open@()
  upgrade(v@, 0)
  r@ = schema_rules@(v@)
  check(sdict_get$(r@, "the index ux_users_username_key") = "users unique (username_key BINARY)" and sdict_get$(r@, "the index ux_companies_tax_key") = "companies unique partial (kind BINARY, tax_key BINARY)" and sdict_get$(r@, "the index sqlite_autoindex_users_1") = "users unique (username NOCASE)" and sdict_get$(r@, "the foreign key contacts.company_id") = "companies.id on delete CASCADE", "a schema's indexes and foreign keys are read as SQLite built them")
  dict_free(r@)
  sqlite_close(v@)
  v@ = sqlite_open@(path4$)
  upgrade(v@, 0)
  sqlite_exec(v@, "DROP INDEX ux_users_username_key; PRAGMA application_id = " + str$(APP_ID) + "; PRAGMA user_version = " + str$(SCHEMA_VERSION))
  sqlite_close(v@)
  text$ = file_readalltext$(path4$)
  check(open_database(path4$) = 0 and instr(last_msg$, "not a complete one: the index ux_users_username_key is missing -- the file is damaged") > 0 and file_readalltext$(path4$) = text$, "and so is one that lost the unique index on user names, and it is left alone")
  file_delete(path4$)
  v@ = sqlite_open@(path4$)
  upgrade(v@, 0)
  sqlite_exec(v@, "DROP INDEX ux_companies_tax_key; CREATE INDEX ux_companies_tax_key ON companies(kind, tax_key) WHERE tax_key <> ''; PRAGMA application_id = " + str$(APP_ID) + "; PRAGMA user_version = " + str$(SCHEMA_VERSION))
  sqlite_close(v@)
  check(open_database(path4$) = 0 and instr(last_msg$, "the index ux_companies_tax_key is not the one this program builds") > 0, "and one whose tax-id index of that name is no longer unique")
  file_delete(path4$)
  v@ = sqlite_open@(path4$)
  upgrade(v@, 0)
  sqlite_exec(v@, "DROP TABLE interactions; CREATE TABLE interactions (id INTEGER PRIMARY KEY, contact_id INTEGER NOT NULL, happened_on TEXT NOT NULL, kind TEXT NOT NULL, subject TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '', user_id INTEGER REFERENCES users(id) ON DELETE SET NULL, created_at TEXT NOT NULL DEFAULT (datetime('now'))); CREATE INDEX ix_interactions_contact ON interactions(contact_id, happened_on); PRAGMA application_id = " + str$(APP_ID) + "; PRAGMA user_version = " + str$(SCHEMA_VERSION))
  sqlite_close(v@)
  check(open_database(path4$) = 0 and instr(last_msg$, "the foreign key interactions.contact_id is missing") > 0, "and one whose history no longer goes with its contact")
  file_delete(path4$)
  rem But a name in a schema is SQLite's to compare, and SQLite ignores the
  rem case of A-Z in every one: an index spelled in capitals is the same
  rem index, nocase is the NOCASE collation, a column renamed in capitals is
  rem the same column (and the index over it the same index). A file that
  rem differs from this program's only so is this program's.
  v@ = sqlite_open@(path4$)
  upgrade(v@, 0)
  sqlite_exec(v@, "DROP INDEX ux_users_username_key; CREATE UNIQUE INDEX UX_USERS_USERNAME_KEY ON users(username_key); PRAGMA application_id = " + str$(APP_ID) + "; PRAGMA user_version = " + str$(SCHEMA_VERSION))
  sqlite_close(v@)
  check(open_database(path4$) = 1, "a file whose unique index on user names is spelled in capitals is this program's")
  sqlite_close(db@)
  file_delete(path4$)
  v@ = sqlite_open@(path4$)
  upgrade(v@, 0)
  sqlite_exec(v@, "DROP INDEX ix_companies_name; CREATE INDEX ix_companies_name ON companies(kind, name COLLATE nocase); PRAGMA application_id = " + str$(APP_ID) + "; PRAGMA user_version = " + str$(SCHEMA_VERSION))
  sqlite_close(v@)
  check(open_database(path4$) = 1, "and so is one whose collation is spelled nocase")
  sqlite_close(db@)
  file_delete(path4$)
  v@ = sqlite_open@(path4$)
  upgrade(v@, 0)
  sqlite_exec(v@, "ALTER TABLE companies RENAME COLUMN tax_key TO TAX_KEY; PRAGMA application_id = " + str$(APP_ID) + "; PRAGMA user_version = " + str$(SCHEMA_VERSION))
  sqlite_close(v@)
  check(open_database(path4$) = 1, "and one whose indexed column companies.tax_key is spelled in capitals")
  sqlite_close(db@)
  file_delete(path4$)
  rem An unmarked file of an earlier version is upgraded, and the upgrade
  rem builds the unique keys' indexes but not ix_companies_name: a version-1
  rem file without it would be upgraded, marked, and refused at the next
  rem start. And an earlier version's file that has lost a part -- a column,
  rem or a whole table -- is named for what it lost: the tables it has are
  rem this program's own, and not "other tables".
  v@ = sqlite_open@(path4$)
  schema_v1(v@)
  sqlite_exec(v@, "DROP INDEX ix_companies_name; PRAGMA user_version = 1")
  sqlite_close(v@)
  check(open_database(path4$) = 0 and instr(last_msg$, "the index ix_companies_name is missing") > 0 and file_header$(path4$) = "db" and hdr_version = 1 and hdr_app = 0, "a version-1 file without an index the upgrade does not build is refused, not upgraded")
  file_delete(path4$)
  v@ = sqlite_open@(path4$)
  schema_v1(v@)
  sqlite_exec(v@, "INSERT INTO users(username, password, role) VALUES ('Ana', 'x', 'admin'); ALTER TABLE companies DROP COLUMN notes; PRAGMA user_version = 1")
  sqlite_close(v@)
  text$ = file_readalltext$(path4$)
  check(open_database(path4$) = 0 and instr(last_msg$, "an earlier version of Contact Manager made (schema version 1), but the column companies.notes is missing") > 0 and instr(last_msg$, "other tables") = 0 and file_readalltext$(path4$) = text$, "an earlier version's file that lost a column is named for that, not for holding other tables")
  file_delete(path4$)
  v@ = make_v2@(path4$, 5)
  sqlite_exec(v@, "DROP TABLE interactions")
  sqlite_close(v@)
  text$ = file_readalltext$(path4$)
  check(open_database(path4$) = 0 and instr(last_msg$, "an earlier version of Contact Manager made (schema version 2), but the table interactions is missing") > 0 and instr(last_msg$, "other tables") = 0 and file_readalltext$(path4$) = text$, "and so is one that lost a whole table: the tables it has are this program's")
  file_delete(path4$)
  rem An empty file is a database with nothing in it yet: a new one.
  file_createempty(path4$)
  check(open_database(path4$) = 1 and first_run? = true and sqlite_scalar(db@, "PRAGMA application_id") = 1349010253, "an empty file is made a new database")
  sqlite_close(db@)
  file_delete(path4$)
  rem --- this program's own files, left unfinished. An upgrade marks the
  rem file only as its last statement, so a version-2 file killed in the
  rem middle of its upgrade is UNMARKED, with a hot journal beside it -- the
  rem program's likeliest crash. It is judged on a copy, which SQLite rolls
  rem back exactly as it would roll back the file: a clean version 2, which
  rem is then opened and upgraded again ---
  q$ = path4$ + ".src"
  v@ = make_v2@(q$, 2000)
  hot_begin(v@)
  n = upgrade(v@, 2)
  check(n = 1 and hot_end(v@, q$, path4$) = 1 and file_header$(path4$) = "db" and hdr_version = 2 and hdr_app = 0, "a version-2 file killed in mid-upgrade is unmarked, with a journal beside it")
  check(open_database(path4$) = 1 and sqlite_scalar(db@, "PRAGMA user_version") = 3 and sqlite_scalar(db@, "PRAGMA application_id") = APP_ID and count_of("SELECT count(*) FROM companies WHERE tax_key <> ''") = 2000 and file_exists(path4$ + "-journal") = 0, "and it opens: SQLite rolls the change back, and the upgrade runs again")
  check(file_exists(check_copy$()) = 0 and file_exists(check_copy$() + "-journal") = 0, "and the copy it was judged on is gone")
  sqlite_close(db@)
  file_delete(path4$)
  rem A first run killed before its first commit: an empty file beside a
  rem journal. Beside a file of no pages SQLite rolls nothing back; it
  rem deletes the journal (sqlite.org/atomiccommit.html, a hot journal
  rem needs a database that is not empty).
  if file_exists(q$) = 1 then file_delete(q$)
  v@ = sqlite_open@(q$)
  sqlite_begin(v@)
  n = upgrade(v@, 0)
  check(n = 1 and hot_end(v@, q$, path4$) = 1 and file_exists(path4$) = 1 and file_getsize(path4$) = 0, "a first run killed before its first commit leaves an empty file beside a journal")
  check(open_database(path4$) = 1 and first_run? = true and sqlite_scalar(db@, "PRAGMA application_id") = APP_ID and file_exists(path4$ + "-journal") = 0, "and it is opened as the new database it was")
  sqlite_close(db@)
  file_delete(path4$)
  rem A journal another tool left in PERSIST mode: its header zeroed, so
  rem it holds nothing to roll back (atomiccommit.html again) and the
  rem change it was for stays committed.
  v@ = make_v2@(path4$, 20)
  sqlite_exec(v@, "PRAGMA journal_mode = PERSIST")
  sqlite_exec(v@, "UPDATE companies SET notes = 'kept'")
  sqlite_close(v@)
  check(file_getsize(path4$ + "-journal") > 0 and file_header$(path4$) = "db" and hdr_app = 0, "a version-2 file can be left with a spent journal beside it")
  check(open_database(path4$) = 1 and sqlite_scalar(db@, "PRAGMA user_version") = 3 and count_of("SELECT count(*) FROM companies WHERE notes = 'kept'") = 20, "and it opens, its committed change kept")
  sqlite_close(db@)
  if file_exists(path4$ + "-journal") = 1 then file_delete(path4$ + "-journal")
  file_delete(path4$)
  rem And another program's file whose last change is still in its
  rem write-ahead log: the copy is judged WITH the log, as SQLite would
  rem read the file, and the file and its log are left byte for byte.
  if file_exists(q$) = 1 then file_delete(q$)
  v@ = sqlite_open@(q$)
  sqlite_exec(v@, "PRAGMA journal_mode = WAL")
  sqlite_exec(v@, "CREATE TABLE ledger (x); INSERT INTO ledger VALUES (1)")
  file_copy(q$, path4$)
  file_copy(q$ + "-wal", path4$ + "-wal")
  sqlite_close(v@)
  file_delete(q$)
  text$ = file_readalltext$(path4$)
  q$ = file_readalltext$(path4$ + "-wal")
  check(bytelen(q$) > 0 and open_database(path4$) = 0 and instr(last_msg$, path4$ + "-wal") > 0 and instr(last_msg$, "other tables (ledger)") > 0, "another program's file with a write-ahead log is judged with its log, and refused")
  check(file_readalltext$(path4$) = text$ and file_readalltext$(path4$ + "-wal") = q$ and file_exists(path4$ + "-shm") = 0, "and the file and its log are left as they were")
  file_delete(path4$ + "-wal")
  file_delete(path4$)
  rem Another program's file beside a journal it FINISHED with, in PERSIST
  rem mode: the header is zeroed, which is how PERSIST commits, so the
  rem journal is not hot -- nothing was interrupted, and SQLite rolls
  rem nothing back (fileformat.html, 3.0). It is refused as another
  rem program's file, with no word of an interrupted change.
  v@ = sqlite_open@(path4$)
  sqlite_exec(v@, "PRAGMA journal_mode = PERSIST")
  sqlite_exec(v@, "CREATE TABLE ledger (x); INSERT INTO ledger VALUES (1)")
  sqlite_close(v@)
  text$ = file_readalltext$(path4$)
  q$ = file_readalltext$(path4$ + "-journal")
  check(bytelen(q$) > 0 and byteat(q$, 1) = 0 and open_database(path4$) = 0 and instr(last_msg$, "other tables (ledger)") > 0 and instr(last_msg$, "stopped") = 0 and instr(last_msg$, "-journal") = 0, "another program's file beside a journal it finished with is refused as its file, with no word of an interrupted change")
  check(file_readalltext$(path4$) = text$ and file_readalltext$(path4$ + "-journal") = q$, "and the file and that journal are left as they were")
  rem A journal beside it that does not begin as a journal does is one
  rem SQLite takes for a hot journal by its first byte, finds nothing in,
  rem and deletes: it is judged on a copy, and named for what it is.
  file_writealltext(path4$ + "-journal", "not a journal" + space$(500))
  q$ = file_readalltext$(path4$ + "-journal")
  check(open_database(path4$) = 0 and instr(last_msg$, sqlite_name$(path4$) + "-journal lies beside it, which does not begin as a journal does and which SQLite would delete -- and once it has, it is not a Contact Manager database") > 0 and instr(last_msg$, "stopped") = 0 and file_readalltext$(path4$) = text$ and file_readalltext$(path4$ + "-journal") = q$, "one beside a file that is not a journal is judged on a copy and named for what it is, and both are left")
  file_delete(path4$ + "-journal")
  file_delete(path4$)
  rem This program's own version-2 file killed in mid-upgrade, its page 1
  rem then torn by a power cut -- the first 100 bytes zero. By its header
  rem it is no database at all, but its journal holds page 1 as it was, and
  rem putting such a page back is what a rollback journal is for
  rem (atomiccommit.html): it is judged on a copy, and opens.
  q$ = path4$ + ".src"
  v@ = make_v2@(q$, 2000)
  hot_begin(v@)
  n = upgrade(v@, 2)
  n = n + hot_end(v@, q$, path4$)
  text$ = file_readalltext$(path4$)
  z$ = ""
  for i = 1 to 100
    z$ = z$ + chr$(0)
  next
  file_writealltext(path4$, z$ + bytemid$(text$, 101, bytelen(text$) - 100))
  check(n = 2 and file_header$(path4$) = "notdb" and file_getsize(path4$) = bytelen(text$), "a file killed in mid-upgrade can have its first page torn as well")
  check(open_database(path4$) = 1 and sqlite_scalar(db@, "PRAGMA user_version") = 3 and sqlite_scalar(db@, "PRAGMA application_id") = APP_ID and count_of("SELECT count(*) FROM companies WHERE tax_key <> ''") = 2000 and sqlite_scalar$(db@, "PRAGMA integrity_check") = "ok" and file_exists(path4$ + "-journal") = 0, "and it opens all the same: SQLite puts page 1 back, and the upgrade runs again")
  sqlite_close(db@)
  rem This program's own file, killed in the middle of a change and reached
  rem through a real link (block AI, toown.db -> own.db). SQLite rolls back
  rem the journal beside the name it is HANDED, and on Windows its name of a
  rem link is the link's own: handed the link, it read the half-written
  rem file as whole and never looked at own.db-journal (round 10). It is
  rem handed the file's own name, and the change is rolled back.
  z$ = environ$("PHOSPHOR_SELFTEST_LINKS")
  if z$ <> "" then
    alias$ = path_combine$(z$, "toown.db")
    q$ = path_combine$(z$, "own.db")
    bad$ = q$ + ".src"
    if file_exists(bad$) = 1 then file_delete(bad$)
    n = file_copy(path4$, bad$)
    v@ = sqlite_open@(bad$)
    hot_begin(v@)
    sqlite_exec(v@, "UPDATE companies SET notes = 'torn'")
    n = n + hot_end(v@, bad$, q$)
    n = n + flag(file_header$(q$) = "db" and hdr_app = APP_ID)
    check(n = 3 and open_database(alias$) = 1 and count_of("SELECT count(*) FROM companies WHERE notes = 'torn'") = 0 and count_of("SELECT count(*) FROM companies") = 2000 and sqlite_scalar$(db@, "PRAGMA integrity_check") = "ok" and file_exists(q$ + "-journal") = 0, "this program's own file, killed mid-change and reached through a link, opens whole: its journal is rolled back")
    sqlite_close(db@)
    file_delete(q$)
  end if
  file_delete(path4$)
  rem A key that cannot be computed fails the upgrade instead of passing it:
  rem a SELECT that does not compile used to step as zero rows.
  v@ = sqlite_open@()
  sqlite_exec(v@, "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)")
  step_err$ = ""
  check(rekey_all(v@) = 0 and instr(step_err$, "username") > 0, "a table without the columns its key needs fails the rekey, saying why")
  sqlite_close(v@)
  file_delete(path3$)

  rem --- the database survives a reopen, and opens read-only too ---
  open_database(path$)
  check(first_run? = false, "a database with users asks to sign in, not to create one")
  check(count_of("SELECT count(*) FROM companies") = 5, "and everything is still there")
  rem query_only makes this connection refuse every write the way a
  rem read-only file does ("attempt to write a readonly database").
  sqlite_exec(db@, "PRAGMA query_only = ON")
  check(create_schema(db@) = 1, "a database at the current version is prepared without a write")
  type_into("login.user", "admin")
  type_into("login.pass", "secret9")
  click("login.go")
  check(user_id = 1 and read_only? = true and instr(last_msg$, "read-only") > 0, "a read-only database signs in for reading, and says so")
  sqlite_close(db@)
  file_delete(path$)

  println "passed: " + str$(passed)
  println "failed: " + str$(failed)
  return 0
end function

rem How long a refresh of page k's list takes. With slow = 0 it is the
rem faster of two runs; otherwise a second run is made only when the first
rem took slow ms or more -- so a passing check pays for one run, and one
rem stall of the machine does not fail it.
function best_refresh_ms(k, slow) local t0, a, b
  t0 = now()
  refresh_companies(k)
  a = millisecondsbetween(now(), t0)
  if slow > 0 and a < slow then return a
  t0 = now()
  refresh_companies(k)
  b = millisecondsbetween(now(), t0)
  if b < a then a = b
  return a
end function

rem How long open_database takes to upgrade a version-1 file of n
rem companies, each with its own tax id, run as best_refresh_ms runs a
rem refresh; -1 when the upgrade fails.
function upgrade_ms(path$, n, slow) local a, b
  a = upgrade_once_ms(path$, n)
  if a < 0 or (slow > 0 and a < slow) then return a
  b = upgrade_once_ms(path$, n)
  if b >= 0 and b < a then a = b
  return a
end function

function upgrade_once_ms(path$, n) local v@, t0, ms
  if file_exists(path$) = 1 then file_delete(path$)
  v@ = sqlite_open@(path$)
  schema_v1(v@)
  sqlite_exec(v@, "PRAGMA user_version = 1; INSERT INTO users(username, password, role) VALUES ('Ana', 'x', 'admin')")
  sqlite_exec(v@, "INSERT INTO companies(kind, name, tax_id, city) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < " + str$(n) + ") SELECT 'supplier', 'Empresa ' || printf('%06d', i), printf('%014d', i), 'São Paulo' FROM n")
  sqlite_close(v@)
  t0 = now()
  if open_database(path$) <> 1 then return -1
  ms = millisecondsbetween(now(), t0)
  sqlite_close(db@)
  file_delete(path$)
  return ms
end function

rem Leave at p$ another program's SQLite file with a HOT journal beside it,
rem the way a program killed in the middle of a transaction leaves one: a
rem table of 2,000 rows is changed inside a transaction with a cache of
rem one page (hot_begin), so the changed pages are written into the file
rem before the commit, with their old contents in the journal -- and the
rem file and the journal are copied at that moment (hot_end). 1 when the
rem journal holds something.
function make_hot_db(p$) local src$, v@
  src$ = p$ + ".src"
  if file_exists(src$) = 1 then file_delete(src$)
  v@ = sqlite_open@(src$)
  sqlite_exec(v@, "CREATE TABLE ledger (x); INSERT INTO ledger WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000) SELECT i FROM n")
  hot_begin(v@)
  sqlite_exec(v@, "UPDATE ledger SET x = x + 1000000")
  return hot_end(v@, src$, p$)
end function

rem On Linux, the symbolic link /proc/self/fd/N to a file this process
rem holds open on a channel: the one among its open files whose bytes are
rem text$ (only one of the right size is read). "" when none is.
function fd_link$(text$) local i, f$
  for i = 0 to 255
    f$ = "/proc/self/fd/" + str$(i)
    if file_exists(f$) = 1 then
      if file_getsize(f$) = bytelen(text$) then
        if file_readalltext$(f$) = text$ then return f$
      end if
    end if
  next
  return ""
end function

rem Begin a transaction on v@ whose changed pages spill into the file
rem before any commit: a rollback journal, and a cache of one page.
function hot_begin(v@)
  sqlite_exec(v@, "PRAGMA journal_mode = DELETE")
  sqlite_exec(v@, "PRAGMA cache_size = 1")
  return sqlite_begin(v@)
end function

rem In the middle of v@'s transaction on src$: copy src$ and its journal
rem to p$ -- what a crash at that moment leaves -- then roll back, close,
rem and remove src$. 1 when the journal copied holds something.
function hot_end(v@, src$, p$)
  if file_exists(p$) = 1 then file_delete(p$)
  if file_exists(p$ + "-journal") = 1 then file_delete(p$ + "-journal")
  file_copy(src$, p$)
  file_copy(src$ + "-journal", p$ + "-journal")
  sqlite_rollback(v@)
  sqlite_close(v@)
  file_delete(src$)
  return flag(file_getsize(p$ + "-journal") > 0)
end function

rem A database at p$ as version 2 left it, with n companies (each its own
rem tax id) and one administrator; answered OPEN, at version 2.
function make_v2@(p$, n) local v@
  if file_exists(p$) = 1 then file_delete(p$)
  v@ = sqlite_open@(p$)
  schema_v1(v@)
  migrate_v2(v@)
  sqlite_exec(v@, "INSERT INTO users(username, username_key, password, role) VALUES ('Ana', 'ana', 'x', 'admin')")
  sqlite_exec(v@, "INSERT INTO companies(kind, name, tax_id, tax_key, city) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < " + str$(n) + ") SELECT 'supplier', 'Empresa ' || printf('%06d', i), printf('%014d', i), printf('%014d', i), 'São Paulo' FROM n")
  sqlite_exec(v@, "CREATE UNIQUE INDEX ux_users_username_key ON users(username_key); CREATE UNIQUE INDEX ux_product_lines_name_key ON product_lines(name_key); CREATE UNIQUE INDEX ux_companies_tax_key ON companies(kind, tax_key) WHERE tax_key <> ''; PRAGMA user_version = 2")
  return v@
end function

rem The second spelling of path$ the backup checks use: kind 1 is the file
rem name upper-cased, kind 2 the name with a trailing dot.
function spelling$(path$, kind)
  if kind = 1 then return extractfilepath$(path$) + ucase$(extractfilename$(path$))
  return path$ + "."
end function

rem A person picking a filter: combo_itemindex@ does not fire the change
rem event (only a person's choice does), so the handler the event would
rem have run is called with the combo as its sender.
function choose(key$, index)
  combo_itemindex@(w@(key$), index)
  on_company_filter(w@(key$))
  return 0
end function
