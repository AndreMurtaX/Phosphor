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
rem create_schema): 1 was the first, 2 added the normalized keys.
const SCHEMA_VERSION = 2

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
step_err$ = ""             rem what the last step_ok failed with
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

build_login_form()
build_main_form()
build_password_form()

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
  new@ = sqlite_open@(path$)
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

rem Bring the database d@ to SCHEMA_VERSION; 1 when it is there. The version
rem lives in PRAGMA user_version, and a database already at it is NOT
rem WRITTEN TO: PRAGMA foreign_keys is a setting of the connection, not of
rem the file, so a read-only database with the schema opens for reading.
rem An older one is upgraded step by step inside ONE transaction that also
rem sets the new version -- so an upgrade either happened completely or not
rem at all, and running it again on the same file finds nothing to do. On
rem failure schema_msg$ says why.
function create_schema(d@) local v, ok
  schema_msg$ = ""
  step_err$ = ""
  sqlite_clearerror()
  if sqlite_exec(d@, "PRAGMA foreign_keys = ON") <> 1 then
    schema_msg$ = sqlite_errormsg$()
    return 0
  end if
  v = sqlite_scalar(d@, "PRAGMA user_version")
  if sqlite_error() <> 0 then
    schema_msg$ = sqlite_errormsg$()
    return 0
  end if
  if v = SCHEMA_VERSION then return 1
  if v > SCHEMA_VERSION then
    schema_msg$ = "it was made by a newer version of this program (its schema is version " + str$(v) + ")."
    return 0
  end if
  ok = sqlite_begin(d@)
  if ok = 1 and v < 1 then ok = schema_v1(d@)
  if ok = 1 and v < 2 then ok = migrate_v2(d@)
  if ok = 1 then ok = sqlite_exec(d@, "PRAGMA user_version = " + str$(SCHEMA_VERSION))
  if ok = 1 then ok = sqlite_commit(d@)
  if ok <> 1 then
    if schema_msg$ = "" then schema_msg$ = step_err$
    if schema_msg$ = "" then schema_msg$ = sqlite_errormsg$()
    sqlite_rollback(d@)
  end if
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

rem Version 2: the rules that compare text compare a KEY, computed here in
rem BASIC and stored beside the text, because SQLite cannot compute it:
rem   - COLLATE NOCASE and LIKE fold the 26 ASCII letters only, so "josé"
rem     and "JOSÉ" were two users and a search for "AÇO" missed "Aço". A key
rem     lower-cased with alcase$ (all of Unicode) is what user names, product
rem     lines and the search now compare: username_key, name_key, search_key.
rem   - the unique tax id compared the text as typed, so 11.444.777/0001-61
rem     and 11444777000161 were two companies. tax_key is the id upper-cased
rem     with only its letters and digits kept (tax_key$), and the partial
rem     unique index is on (kind, tax_key).
rem The columns are added only when missing, the keys are computed for the
rem rows already there, and if those rows already break the new rules the
rem upgrade is refused -- naming them -- instead of guessing which to keep.
function migrate_v2(d@) local s$, dup$
  if add_column(d@, "users", "username_key") <> 1 then return 0
  if add_column(d@, "product_lines", "name_key") <> 1 then return 0
  if add_column(d@, "companies", "tax_key") <> 1 then return 0
  if add_column(d@, "companies", "search_key") <> 1 then return 0
  if add_column(d@, "contacts", "name_key") <> 1 then return 0
  if sqlite_exec(d@, "DROP INDEX IF EXISTS ux_companies_tax_id") <> 1 then return 0
  if rekey_all(d@) <> 1 then return 0
  dup$ = sqlite_scalar$(d@, "SELECT group_concat(name, ' / ') FROM (SELECT username AS name FROM users WHERE username_key IN (SELECT username_key FROM users GROUP BY username_key HAVING count(*) > 1))")
  if dup$ <> "" then
    schema_msg$ = "these user names differ only in upper and lower case, and must be told apart first: " + dup$
    return 0
  end if
  dup$ = sqlite_scalar$(d@, "SELECT group_concat(name, ' / ') FROM (SELECT name FROM product_lines WHERE name_key IN (SELECT name_key FROM product_lines GROUP BY name_key HAVING count(*) > 1))")
  if dup$ <> "" then
    schema_msg$ = "these product lines differ only in upper and lower case, and must be told apart first: " + dup$
    return 0
  end if
  dup$ = sqlite_scalar$(d@, "SELECT group_concat(name || ' (' || tax_id || ')', ' / ') FROM (SELECT name, tax_id FROM companies c WHERE tax_key <> '' AND (SELECT count(*) FROM companies o WHERE o.kind = c.kind AND o.tax_key = c.tax_key) > 1)")
  if dup$ <> "" then
    schema_msg$ = "these companies have the same tax id written in different ways, and must be told apart first: " + dup$
    return 0
  end if
  s$ = "CREATE UNIQUE INDEX IF NOT EXISTS ux_users_username_key ON users(username_key);"
  s$ = s$ + "CREATE UNIQUE INDEX IF NOT EXISTS ux_product_lines_name_key ON product_lines(name_key);"
  s$ = s$ + "CREATE UNIQUE INDEX IF NOT EXISTS ux_companies_tax_key ON companies(kind, tax_key) WHERE tax_key <> '';"
  return sqlite_exec(d@, s$)
end function

rem Add a text column (default '') unless the table already has it.
function add_column(d@, table$, col$) local s@, n
  s@ = sqlite_prepare@(d@, "SELECT count(*) FROM pragma_table_info(?1) WHERE name = ?2")
  sqlite_bindstr(s@, 1, table$)
  sqlite_bindstr(s@, 2, col$)
  n = 0
  if sqlite_step(s@) = 1 then n = sqlite_getnum(s@, 1)
  sqlite_finalize(s@)
  if n > 0 then return 1
  return sqlite_exec(d@, "ALTER TABLE " + table$ + " ADD COLUMN " + col$ + " TEXT NOT NULL DEFAULT ''")
end function

rem Compute every stored key from the text beside it: the upgrade does it
rem for the rows it finds, and the sample data, which is plain SQL, needs it
rem too. Each table is read whole first and written after, so no row is
rem updated under a statement still reading the table. 1 on success.
function rekey_all(d@) local s@, u@, rows@, more@, i, id$, ok
  ok = 1
  rem users and product lines: one name, one key
  rows@ = dict@()
  s@ = sqlite_prepare@(d@, "SELECT id, username FROM users")
  while sqlite_step(s@) = 1
    dict_set@(rows@, sqlite_gets$(s@, "id"), alcase$(sqlite_gets$(s@, "username")))
  end while
  sqlite_finalize(s@)
  ok = rekey_table(d@, rows@, "UPDATE users SET username_key = ?2 WHERE id = ?1")
  dict_free(rows@)
  rows@ = dict@()
  s@ = sqlite_prepare@(d@, "SELECT id, name FROM product_lines")
  while sqlite_step(s@) = 1
    dict_set@(rows@, sqlite_gets$(s@, "id"), alcase$(sqlite_gets$(s@, "name")))
  end while
  sqlite_finalize(s@)
  if ok = 1 then ok = rekey_table(d@, rows@, "UPDATE product_lines SET name_key = ?2 WHERE id = ?1")
  dict_free(rows@)
  rows@ = dict@()
  s@ = sqlite_prepare@(d@, "SELECT id, name FROM contacts")
  while sqlite_step(s@) = 1
    dict_set@(rows@, sqlite_gets$(s@, "id"), alcase$(sqlite_gets$(s@, "name")))
  end while
  sqlite_finalize(s@)
  if ok = 1 then ok = rekey_table(d@, rows@, "UPDATE contacts SET name_key = ?2 WHERE id = ?1")
  dict_free(rows@)
  rem companies: two keys each, the tax id's in rows@, the search's in more@
  rows@ = dict@()
  more@ = dict@()
  s@ = sqlite_prepare@(d@, "SELECT id, name, trade_name, tax_id, city FROM companies")
  while sqlite_step(s@) = 1
    id$ = sqlite_gets$(s@, "id")
    dict_set@(rows@, id$, tax_key$(sqlite_gets$(s@, "tax_id")))
    dict_set@(more@, id$, search_key$(sqlite_gets$(s@, "name"), sqlite_gets$(s@, "trade_name"), sqlite_gets$(s@, "tax_id"), sqlite_gets$(s@, "city")))
  end while
  sqlite_finalize(s@)
  for i = 1 to dict_count(rows@)
    if ok = 1 then
      id$ = dict_key$(rows@, i)
      u@ = sqlite_prepare@(d@, "UPDATE companies SET tax_key = ?2, search_key = ?3 WHERE id = ?1")
      sqlite_bindnum(u@, 1, val(id$))
      sqlite_bindstr(u@, 2, dict_get$(rows@, id$))
      sqlite_bindstr(u@, 3, dict_get$(more@, id$))
      ok = step_ok(u@)
    end if
  next
  dict_free(rows@)
  dict_free(more@)
  return ok
end function

rem Write each id -> key pair of rows@ with update$ (?1 the id, ?2 the key).
function rekey_table(d@, rows@, update$) local u@, i, ok
  ok = 1
  for i = 1 to dict_count(rows@)
    if ok = 1 then
      u@ = sqlite_prepare@(d@, update$)
      sqlite_bindnum(u@, 1, val(dict_key$(rows@, i)))
      sqlite_bindstr(u@, 2, dict_get$(rows@, dict_key$(rows@, i)))
      ok = step_ok(u@)
    end if
  next
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
rem tax id (as typed and as its key) and city, lower-cased with alcase$ --
rem all of Unicode, where SQLite's LIKE folds only ASCII -- one per line,
rem so a search cannot match across two of them.
function search_key$(name$, trade$, tax$, city$) local nl$
  nl$ = chr$(10)
  return alcase$(name$ + nl$ + trade$ + nl$ + tax$ + nl$ + tax_key$(tax$) + nl$ + city$)
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
    sqlite_bindstr(s@, 2, alcase$(u$))
    sqlite_bindstr(s@, 3, "Administrator")
    sqlite_bindstr(s@, 4, password_hash$(p$, pw_cost))
    if finish(s@, "create the administrator") <> 1 then return 0
    if ask?("Load a few sample suppliers, customers and contacts to look around?") = true then seed_sample_data()
  end if
  rem Look the user up by the name's key -- "José" finds "josé" -- then let
  rem the stored record decide, and call the user by the STORED name.
  s@ = sqlite_prepare@(db@, "SELECT id, username, password, role, active, full_name FROM users WHERE username_key = ?1")
  sqlite_bindstr(s@, 1, alcase$(u$))
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

rem Whether two paths name the same file, as far as their text can say: both
rem made absolute, and compared ignoring case on Windows, whose file names
rem do. (A link or a second name for the same file is not seen through.)
function same_file?(a$, b$) local x$, y$
  x$ = path_getfullpath$(a$)
  y$ = path_getfullpath$(b$)
  if os_name$() = "Windows" then
    x$ = alcase$(x$)
    y$ = alcase$(y$)
  end if
  return x$ = y$
end function

rem A backup is written by SQLite into a NEW file, so a file already at the
rem target is deleted first, once the person agrees. Never the open database
rem itself: Linux would unlink the live file -- the backup "succeeds" and
rem every later save fails, read-only -- and Windows would refuse the delete.
rem And a delete that fails is said, not ignored.
function on_backup(sender@) local p$
  p$ = save_path$("phosphor-contacts-backup.db", "SQLite database (*.db)|*.db")
  if p$ = "" then return 0
  if same_file?(p$, dbpath$) = true then
    say("That is the database you have open. A backup has to go to another file.")
    return 0
  end if
  if file_exists(p$) = 1 then
    if ask?("Replace " + p$ + "?") = false then return 0
    if file_delete(p$) <> 1 then
      say("Could not replace " + p$ + ": it could not be deleted. Is it open in another program?")
      return 0
    end if
  end if
  if sqlite_backup(db@, p$) = 1 then
    say("Backed up to " + p$)
  else
    say("The backup failed: " + sqlite_errormsg$())
  end if
  return 0
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

function refresh_companies(k) local p$, g@, s@, sql$, q$, st, line, n, keep, found
  p$ = pre$(k)
  g@ = w@(p$ + ".grid")
  keep = cur(p$ + ".company")
  rem The search compares lower-cased keys (search_key$), taking what was
  rem typed literally (like_pattern$).
  q$ = alcase$(trim$(edit_text$(w@(p$ + ".search"))))
  if q$ <> "" then q$ = like_pattern$(q$)
  st = combo_itemindex(w@(p$ + ".state"))
  line = 0
  if combo_itemindex(w@(p$ + ".linefilter")) > 1 then line = row_id("lines", combo_itemindex(w@(p$ + ".linefilter")) - 1)
  sql$ = "SELECT c.id, c.name, c.tax_id, c.city, c.state,"
  sql$ = sql$ + " (SELECT count(*) FROM contacts t WHERE t.company_id = c.id) AS n"
  sql$ = sql$ + " FROM companies c WHERE c.kind = ?1"
  sql$ = sql$ + " AND (?2 = '' OR c.search_key LIKE ?2 ESCAPE '\\'"
  sql$ = sql$ + "      OR EXISTS (SELECT 1 FROM contacts t WHERE t.company_id = c.id AND t.name_key LIKE ?2 ESCAPE '\\'))"
  sql$ = sql$ + " AND (?3 = 3 OR c.active = (?3 = 1))"
  sql$ = sql$ + " AND (?4 = 0 OR EXISTS (SELECT 1 FROM contacts t JOIN contact_lines l ON l.contact_id = t.id"
  sql$ = sql$ + "      WHERE t.company_id = c.id AND l.line_id = ?4))"
  sql$ = sql$ + " ORDER BY c.name COLLATE NOCASE"
  s@ = sqlite_prepare@(db@, sql$)
  sqlite_bindstr(s@, 1, kind$(k))
  sqlite_bindstr(s@, 2, q$)
  sqlite_bindnum(s@, 3, st)
  sqlite_bindnum(s@, 4, line)
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  n = 0
  rows_begin(p$ + ".grid")
  while sqlite_step(s@) = 1
    n = n + 1
    stringgrid_rowcount@(g@, n + 1)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "name"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "tax_id"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "city"))
    stringgrid_cell@(g@, 4, n + 1, sqlite_gets$(s@, "state"))
    stringgrid_cell@(g@, 5, n + 1, sqlite_gets$(s@, "n"))
    rows_add(p$ + ".grid", n, sqlite_getn(s@, "id"))
  end while
  sqlite_finalize(s@)
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

function refresh_contacts(k) local p$, g@, s@, n, n2, company, keep, prim$
  p$ = pre$(k)
  g@ = w@(p$ + ".cgrid")
  company = cur(p$ + ".company")
  keep = cur(p$ + ".contact")
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  n = 0
  rows_begin(p$ + ".cgrid")
  s@ = sqlite_prepare@(db@, "SELECT id, name, job_title, email, whatsapp, is_primary FROM contacts WHERE company_id = ?1 ORDER BY is_primary DESC, name COLLATE NOCASE")
  sqlite_bindnum(s@, 1, company)
  while sqlite_step(s@) = 1
    n = n + 1
    stringgrid_rowcount@(g@, n + 1)
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
  sqlite_bindstr(s@, cols + 4, alcase$(trim$(edit_text$(contact_field@(k, "name")))))
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
function refresh_history(k) local p$, g@, s@, n, contact
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
  n = 0
  rows_begin(p$ + ".hgrid")
  s@ = sqlite_prepare@(db@, "SELECT i.id, i.happened_on, i.kind, i.subject, u.username FROM interactions i LEFT JOIN users u ON u.id = i.user_id WHERE i.contact_id = ?1 ORDER BY i.happened_on DESC, i.id DESC")
  sqlite_bindnum(s@, 1, contact)
  while sqlite_step(s@) = 1
    n = n + 1
    stringgrid_rowcount@(g@, n + 1)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "happened_on"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "kind"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "subject"))
    stringgrid_cell@(g@, 4, n + 1, sqlite_gets$(s@, "username"))
    rows_add(p$ + ".hgrid", n, sqlite_getn(s@, "id"))
  end while
  sqlite_finalize(s@)
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

function refresh_lines() local g@, s@, n, n2, keep
  g@ = w@("lgrid")
  keep = cur("line")
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  n = 0
  rows_begin("lgrid")
  s@ = sqlite_prepare@(db@, "SELECT p.id, p.name, p.description, (SELECT count(*) FROM contact_lines l WHERE l.line_id = p.id) AS n FROM product_lines p ORDER BY p.name_key")
  while sqlite_step(s@) = 1
    n = n + 1
    stringgrid_rowcount@(g@, n + 1)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "name"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "description"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "n"))
    rows_add("lgrid", n, sqlite_getn(s@, "id"))
  end while
  sqlite_finalize(s@)
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
  sqlite_bindstr(s@, 3, alcase$(name$))
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

function refresh_users() local g@, s@, n, n2, keep, a$
  g@ = w@("ugrid")
  keep = cur("user")
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  n = 0
  rows_begin("ugrid")
  s@ = sqlite_prepare@(db@, "SELECT id, username, full_name, role, active, ifnull(datetime(last_login, 'localtime'), '') AS last FROM users ORDER BY username_key")
  while sqlite_step(s@) = 1
    n = n + 1
    stringgrid_rowcount@(g@, n + 1)
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
  sqlite_bindstr(s@, 7, alcase$(u$))
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

function export_csv(k) local p$, s@, out$, nl$, i, n, sql$, cols$, lines$
  p$ = save_path$(kind$(k) + "s.csv", "CSV file (*.csv)|*.csv")
  if p$ = "" then return 0
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
  if file_writealltext(p$, out$) = 1 then
    status("Exported " + str$(n) + " row(s) to " + p$)
  else
    say("Could not write " + p$)
  end if
  return n
end function

rem ===============================================================
rem  Sample data
rem ===============================================================

function seed_sample_data() local s$
  rem A product line's name key is unique, so each line is written with its
  rem key already computed; the other keys can follow (rekey_all, below).
  s$ = "INSERT INTO product_lines(name, name_key, description) VALUES"
  s$ = s$ + " ('Steel sheets', " + sqlite_quote$(alcase$("Steel sheets")) + ", 'Cold and hot rolled sheets'),"
  s$ = s$ + " ('Industrial paint', " + sqlite_quote$(alcase$("Industrial paint")) + ", 'Epoxy and polyurethane coatings'),"
  s$ = s$ + " ('Fasteners', " + sqlite_quote$(alcase$("Fasteners")) + ", 'Bolts, nuts and rivets'),"
  s$ = s$ + " ('Packaging', " + sqlite_quote$(alcase$("Packaging")) + ", 'Boxes, film and pallets');"
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
  rem compare (they are BASIC's alcase$ and tax_key$), so they come after.
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

function run_selftest() local path$, path2$, path3$, path4$, bad$, bk$, other$, id, s@, n, rec$, csvpath$, text$, nl$, q$, held@, v@, bob, bulk, t0, ms
  pw_cost = 1000
  path$ = temppath$() + "contact_manager_selftest.db"
  if file_exists(path$) = 1 then file_delete(path$)

  rem --- first run: the login form creates the administrator ---
  open_database(path$)
  check(first_run? = true, "a new database asks for an administrator")
  check(sqlite_scalar(db@, "PRAGMA user_version") = 2, "it is built at schema version 2")
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

  rem --- back up: never onto the open database, and a failed delete is said ---
  q$ = "That is the database you have open. A backup has to go to another file."
  save_as$ = path$
  menuitem_click@(w@("menu.backup"))
  check(last_msg$ = q$, "a backup onto the open database is refused")
  rem The same file under another case is the same file on Windows only;
  rem elsewhere it is another file, and the backup is written there.
  other$ = extractfilepath$(path$) + ucase$(extractfilename$(path$))
  save_as$ = other$
  last_msg$ = ""
  menuitem_click@(w@("menu.backup"))
  check((last_msg$ = q$) = (os_name$() = "Windows"), "on Windows the open database is also seen under another case")
  if os_name$() <> "Windows" then file_delete(other$)
  bk$ = temppath$() + "contact_manager_selftest_backup.db"
  if file_exists(bk$) = 1 then file_delete(bk$)
  save_as$ = bk$
  menuitem_click@(w@("menu.backup"))
  check(last_msg$ = "Backed up to " + bk$ and file_exists(bk$) = 1, "a backup to another file is written")
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
  file_delete(bk$)

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

  rem --- a long list. A refresh used to look its rows up by walking an
  rem "id,id,id" string, which took seconds at 2,000 rows (17 s measured)
  rem against a tenth of a second for the query and the grid together; a
  rem refresh now is linear in its rows, so 3 s is a bound with room on a
  rem slow machine and none for the old walk ---
  sqlite_exec(db@, "INSERT INTO companies(kind, name, search_key) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000) SELECT 'supplier', 'Bulk ' || printf('%04d', i), 'bulk ' || printf('%04d', i) FROM n")
  set_cur("s.company", 0)
  t0 = now()
  n = refresh_companies(1)
  ms = millisecondsbetween(now(), t0)
  check(n = 2003 and ms < 3000, "2,000 more suppliers are listed in under 3 s")
  bulk = scalar_s("SELECT id FROM companies WHERE name = ?1", "Bulk 1500")
  check(grid_select("s.grid", bulk) = 1 and edit_text$(w@("s.f.name")) = "Bulk 1500", "and one of them is found by its id")
  t0 = now()
  refresh_companies(1)
  ms = millisecondsbetween(now(), t0)
  check(ms < 3000 and edit_text$(w@("s.f.name")) = "Bulk 1500", "a refresh keeps it selected, as fast")
  sqlite_exec(db@, "DELETE FROM companies WHERE name LIKE 'Bulk %'")

  rem --- the schema upgrade, version 1 to 2, on a database built the way
  rem version 1 built it ---
  path3$ = temppath$() + "contact_manager_selftest_v1.db"
  if file_exists(path3$) = 1 then file_delete(path3$)
  v@ = sqlite_open@(path3$)
  schema_v1(v@)
  sqlite_exec(v@, "PRAGMA user_version = 1; INSERT INTO users(username, password, role) VALUES ('Ana', 'x', 'admin'); INSERT INTO companies(kind, name, tax_id, city) VALUES ('supplier', 'Old Steel', '11.444.777/0001-61', 'Curitiba'), ('customer', 'Old Buyer', '11444777000161', ''); INSERT INTO product_lines(name) VALUES ('Ação')")
  sqlite_close(v@)
  check(open_database(path3$) = 1 and sqlite_scalar(db@, "PRAGMA user_version") = 2, "a version-1 database is upgraded to version 2")
  check(count_of("SELECT count(*) FROM users WHERE username_key = 'ana'") = 1 and count_of("SELECT count(*) FROM companies WHERE tax_key = '11444777000161'") = 2 and count_of("SELECT count(*) FROM product_lines WHERE name_key = 'ação'") = 1, "with the keys of the rows it had")
  check(count_of("SELECT count(*) FROM sqlite_master WHERE name = 'ux_companies_tax_id'") = 0 and count_of("SELECT count(*) FROM sqlite_master WHERE name = 'ux_companies_tax_key'") = 1, "and the tax-id index replaced by the key's")
  sqlite_begin(db@)
  check(migrate_v2(db@) = 1, "the upgrade's steps can run again and find nothing to do")
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
  sqlite_close(v@)
  sqlite_close(db@)
  file_delete(path3$)
  file_delete(path4$)

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

rem A person picking a filter: combo_itemindex@ does not fire the change
rem event (only a person's choice does), so the handler the event would
rem have run is called with the combo as its sender.
function choose(key$, index)
  combo_itemindex@(w@(key$), index)
  on_company_filter(w@(key$))
  return 0
end function
