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
rem The database is phosphor-contacts.db in your Documents folder, or the
rem file PHOSPHOR_CONTACTS_DB names; File > Open database... picks another
rem one. The first run asks for an administrator account and offers to
rem load sample data. PHOSPHOR_CONTACTS_DEMO=1 skips all of that: a
rem throw-away database with the samples, signed in as "demo".
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

selftest? = false
if environ$("PHOSPHOR_SELFTEST") = "1" then selftest? = true

rem --- state shared by the handlers (an undeclared name inside a function
rem     is a GLOBAL in Phosphor, which is exactly what these are) ---------------
db@ = sqlite_open@()
sqlite_close(db@)
dbpath$ = ""
widgets@ = pdict@()        rem every control worth finding again, by name
rowids@ = sdict@()         rem grid name -> "id,id,id" in row order
current@ = dict@()         rem "s.company", "c.contact", "user", "line" -> id
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
  endif
  end
endif

build_login_form()
build_main_form()
build_password_form()

if selftest? = true then
  run_selftest()
  end
endif

if environ$("PHOSPHOR_CONTACTS_DEMO") = "1" then
  start_demo()
elseif environ$("PHOSPHOR_CONTACTS_DB") <> "" then
  open_database(environ$("PHOSPHOR_CONTACTS_DB"))
else
  open_database(documentspath$() + dirseparator$() + "phosphor-contacts.db")
endif
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
endfunction

rem How many items a comma list holds.
function count_items(list$) local n, i
  if list$ = "" then return 0
  n = 1
  for i = 1 to len(list$)
    if mid$(list$, i, 1) = "," then n = n + 1
  next
  return n
endfunction

function kind$(k)
  return nth$(KINDS$, k)
endfunction

rem 1 or 0 from a condition, for the setters that take a number.
function flag(ok?)
  if ok? = true then return 1
  return 0
endfunction

rem "s" for suppliers, "c" for customers: the prefix of their widget names.
function pre$(k)
  return left$(kind$(k), 1)
endfunction

function w@(key$)
  return pdict_get@(widgets@, key$)
endfunction

function keep@(key$, h@)
  pdict_set@(widgets@, key$, h@)
  return h@
endfunction

function cur(key$)
  return dict_getdef(current@, key$, 0)
endfunction

function set_cur(key$, id)
  dict_set@(current@, key$, id)
  return id
endfunction

rem --- dialogs, routed through one place so the self-test can answer them ---
function say(msg$)
  last_msg$ = msg$
  if selftest? = false then msgbox(msg$, APP$)
  return 0
endfunction

function ask?(msg$)
  last_msg$ = msg$
  if selftest? = true then return answer?
  return msgbox_confirm(msg$) = 1
endfunction

function show(f@)
  if selftest? = false then form_show@(f@)
  return 0
endfunction

function hide(f@)
  if selftest? = false then form_close@(f@)
  return 0
endfunction

function status(msg$)
  statusbar_text@(w@("status"), msg$)
  return 0
endfunction

rem --- building blocks for the forms ------------------------------------------
function lbl@(parent@, x, y, text$) local l@
  l@ = label@(parent@, text$)
  control_move@(l@, x, y)
  return l@
endfunction

rem A label with an edit under it, both kept: the edit as key$.
function field@(key$, parent@, x, y, wd, caption$) local e@
  lbl@(parent@, x, y, caption$)
  e@ = edit@(parent@)
  control_bounds@(e@, x, y + 17, wd, 24)
  return keep@(key$, e@)
endfunction

function memo_field@(key$, parent@, x, y, wd, ht, caption$) local m@
  lbl@(parent@, x, y, caption$)
  m@ = memo@(parent@)
  control_bounds@(m@, x, y + 17, wd, ht)
  control_set@(m@, "ScrollBars", "ssAutoVertical")
  return keep@(key$, m@)
endfunction

function button_at@(key$, parent@, x, y, wd, caption$, handler$, tag) local b@
  b@ = button@(parent@)
  button_caption@(b@, caption$)
  control_bounds@(b@, x, y, wd, 30)
  control_tag@(b@, tag)
  button_onclick@(b@, handler$)
  return keep@(key$, b@)
endfunction

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
endfunction

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
  sdict_set@(rowids@, key$, "")
  sdict_set@(rowids@, key$ + ".widths", widths$)
  sdict_set@(rowids@, key$ + ".px", str$(px))
  stringgrid_onselect@(g@, handler$)
  return keep@(key$, g@)
endfunction

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
endfunction

rem The id of the record shown on the grid's current row; 0 when none.
function grid_id(key$) local g@, row
  g@ = w@(key$)
  row = stringgrid_row(g@) - 1
  if row < 1 then return 0
  return val(nth$(sdict_get$(rowids@, key$), row))
endfunction

rem Put the cursor on the row showing record id (no event while busy).
function grid_select(key$, id) local ids$, i, n
  ids$ = sdict_get$(rowids@, key$)
  n = count_items(ids$)
  for i = 1 to n
    if val(nth$(ids$, i)) = id then
      stringgrid_cursor@(w@(key$), 1, i + 1)
      return 1
    endif
  next
  return 0
endfunction

rem ===============================================================
rem  Database
rem ===============================================================

function open_database(path$) local ok
  if sqlite_isopen(db@) = 1 then sqlite_close(db@)
  db@ = sqlite_open@(path$)
  if sqlite_isopen(db@) <> 1 then
    say("Could not open the database " + path$ + ": " + sqlite_errormsg$())
    return 0
  endif
  dbpath$ = path$
  ok = create_schema()
  if ok <> 1 then
    say("The database could not be prepared: " + sqlite_errormsg$())
    return 0
  endif
  prepare_login()
  show(w@("login"))
  return 1
endfunction

function create_schema() local s$
  if sqlite_exec(db@, "PRAGMA foreign_keys = ON") <> 1 then return 0
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
  rem One tax id per kind -- but many companies may leave it blank.
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
  s$ = s$ + "PRAGMA user_version = 1;"
  return sqlite_exec(db@, s$)
endfunction

rem One number out of a query with one text parameter.
function scalar_s(sql$, p$) local s@, v
  s@ = sqlite_prepare@(db@, sql$)
  sqlite_bindstr(s@, 1, p$)
  v = 0
  if sqlite_step(s@) = 1 then v = sqlite_getnum(s@, 1)
  sqlite_finalize(s@)
  return v
endfunction

rem One number out of a query with one numeric parameter.
function scalar_n(sql$, p) local s@, v
  s@ = sqlite_prepare@(db@, sql$)
  sqlite_bindnum(s@, 1, p)
  v = 0
  if sqlite_step(s@) = 1 then v = sqlite_getnum(s@, 1)
  sqlite_finalize(s@)
  return v
endfunction

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
endfunction

function friendly_error$(msg$)
  if instr(msg$, "UNIQUE constraint failed: companies.kind, companies.tax_id") > 0 then return "another company of this kind already has that tax id."
  if instr(msg$, "UNIQUE constraint failed: users.username") > 0 then return "that user name is taken."
  if instr(msg$, "UNIQUE constraint failed: product_lines.name") > 0 then return "a product line with that name already exists."
  return msg$
endfunction

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
endfunction

rem Brazil's CNPJ (14 digits) and CPF (11): both end in two check digits,
rem each a weighted sum mod 11. Other countries' ids are not judged.
function check_digit(d$, weights$) local i, sum, r
  sum = 0
  for i = 1 to count_items(weights$)
    sum = sum + val(mid$(d$, i, 1)) * val(nth$(weights$, i))
  next
  r = sum mod 11
  if r < 2 then return 0
  return 11 - r
endfunction

function brazil_id_ok?(s$) local d$
  d$ = digits$(s$)
  if d$ = "" then return false
  if d$ = string$(len(d$), asc(left$(d$, 1))) then return false
  if len(d$) = 14 then
    if check_digit(d$, "5,4,3,2,9,8,7,6,5,4,3,2") <> val(mid$(d$, 13, 1)) then return false
    if check_digit(d$, "6,5,4,3,2,9,8,7,6,5,4,3,2") <> val(mid$(d$, 14, 1)) then return false
    return true
  endif
  if len(d$) = 11 then
    if check_digit(d$, "10,9,8,7,6,5,4,3,2") <> val(mid$(d$, 10, 1)) then return false
    if check_digit(d$, "11,10,9,8,7,6,5,4,3,2") <> val(mid$(d$, 11, 1)) then return false
    return true
  endif
  return false
endfunction

function email_ok?(s$)
  if s$ = "" then return true
  return regex_findpos("^[^@ ]+@[^@ ]+[.][^@ ]+$", s$) = 1
endfunction

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
endfunction

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
  endif
  control_setfocus@(w@("login.user"))
  return 0
endfunction

function on_login(sender@) local u$, p$, s@, rec$, id, ok?
  u$ = trim$(edit_text$(w@("login.user")))
  p$ = edit_text$(w@("login.pass"))
  label_caption@(w@("login.msg"), "")
  if first_run? = true then
    if u$ = "" or len(p$) < 6 then
      label_caption@(w@("login.msg"), "Choose a user name and a password of 6 characters or more.")
      return 0
    endif
    if p$ <> edit_text$(w@("login.confirm")) then
      label_caption@(w@("login.msg"), "The two passwords are different.")
      return 0
    endif
    s@ = sqlite_prepare@(db@, "INSERT INTO users(username, full_name, password, role) VALUES (?1, ?2, ?3, 'admin')")
    sqlite_bindstr(s@, 1, u$)
    sqlite_bindstr(s@, 2, "Administrator")
    sqlite_bindstr(s@, 3, password_hash$(p$, pw_cost))
    if finish(s@, "create the administrator") <> 1 then return 0
    if ask?("Load a few sample suppliers, customers and contacts to look around?") = true then seed_sample_data()
  endif
  rem Look the user up, then let the stored record decide.
  s@ = sqlite_prepare@(db@, "SELECT id, password, role, active, full_name FROM users WHERE username = ?1")
  sqlite_bindstr(s@, 1, u$)
  id = 0
  ok? = false
  if sqlite_step(s@) = 1 then
    rec$ = sqlite_gets$(s@, "password")
    if sqlite_getn(s@, "active") = 1 then ok? = password_verify?(p$, rec$)
    if ok? = true then
      id = sqlite_getn(s@, "id")
      user_role$ = sqlite_gets$(s@, "role")
      user_name$ = u$
    endif
  endif
  sqlite_finalize(s@)
  if ok? = false then
    rem The same words for an unknown name and a wrong password: the form
    rem does not tell a stranger which user names exist.
    label_caption@(w@("login.msg"), "User name or password is wrong.")
    edit_text@(w@("login.pass"), "")
    return 0
  endif
  user_id = id
  s@ = sqlite_prepare@(db@, "UPDATE users SET last_login = datetime('now') WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  finish(s@, "record the sign-in")
  enter_main()
  return 0
endfunction

function on_login_close(sender@)
  if signing_out? = false and form_visible(w@("main")) = 0 then app_quit()
  return 0
endfunction

rem ===============================================================
rem  Main window
rem ===============================================================

function build_main_form() local f@, mm@, m@, pc@, k
  f@ = keep@("main", form@(APP$, 1100, 720))
  control_set@(f@, "Position", "poScreenCenter")
  form_onclose@(f@, "on_main_close")

  mm@ = mainmenu@(f@)
  m@ = menuitem@(mm@, "&File")
  menuitem_onclick@(menuitem@(m@, "&Open database..."), "on_open_db")
  menuitem_onclick@(menuitem@(m@, "&Back up database..."), "on_backup")
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
endfunction

function enter_main()
  busy = busy + 1
  control_set@(w@("users.page"), "TabVisible", (user_role$ = "admin"))
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
endfunction

function update_status() local s$, r$
  r$ = "operator"
  if user_role$ = "admin" then r$ = "administrator"
  s$ = "Signed in as " + user_name$ + " (" + r$ + ")   |   "
  s$ = s$ + str$(scalar_s("SELECT count(*) FROM companies WHERE kind = ?1", "supplier")) + " suppliers, "
  s$ = s$ + str$(scalar_s("SELECT count(*) FROM companies WHERE kind = ?1", "customer")) + " customers, "
  s$ = s$ + str$(sqlite_scalar(db@, "SELECT count(*) FROM contacts")) + " contacts   |   " + dbpath$
  status(s$)
  return 0
endfunction

function on_main_close(sender@)
  if signing_out? = false then app_quit()
  return 0
endfunction

function on_exit(sender@)
  app_quit()
  return 0
endfunction

function on_sign_out(sender@)
  signing_out? = true
  user_id = 0
  user_name$ = ""
  user_role$ = ""
  prepare_login()
  show(w@("login"))
  hide(w@("main"))
  signing_out? = false
  return 0
endfunction

function on_about(sender@)
  say(APP$ + chr$(10) + chr$(10) + "An example program for Phosphor BASIC " + "-- SQLite, the GUI library and password hashing in one file." + chr$(10) + "Database: " + dbpath$)
  return 0
endfunction

function on_open_db(sender@) local p$
  p$ = openfile$("SQLite database (*.db)|*.db|All files|*.*")
  if p$ = "" then return 0
  signing_out? = true
  open_database(p$)
  hide(w@("main"))
  signing_out? = false
  return 0
endfunction

function on_backup(sender@) local p$
  p$ = save_path$("phosphor-contacts-backup.db", "SQLite database (*.db)|*.db")
  if p$ = "" then return 0
  if file_exists(p$) = 1 then
    if ask?("Replace " + p$ + "?") = false then return 0
    file_delete(p$)
  endif
  if sqlite_backup(db@, p$) = 1 then
    say("Backed up to " + p$)
  else
    say("The backup failed: " + sqlite_errormsg$())
  endif
  return 0
endfunction

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
endfunction

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
  endif
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
endfunction

function by$(name$)
  if name$ = "" then return ""
  return " by " + name$
endfunction

function company_field@(k, col$)
  return w@(pre$(k) + ".f." + col$)
endfunction

function refresh_companies(k) local p$, g@, s@, sql$, q$, st, line, n, ids$, keep
  p$ = pre$(k)
  g@ = w@(p$ + ".grid")
  keep = cur(p$ + ".company")
  q$ = trim$(edit_text$(w@(p$ + ".search")))
  if q$ <> "" then q$ = "%" + q$ + "%"
  st = combo_itemindex(w@(p$ + ".state"))
  line = 0
  if combo_itemindex(w@(p$ + ".linefilter")) > 1 then line = val(nth$(sdict_get$(rowids@, "linefilter.ids"), combo_itemindex(w@(p$ + ".linefilter")) - 1))
  sql$ = "SELECT c.id, c.name, c.tax_id, c.city, c.state,"
  sql$ = sql$ + " (SELECT count(*) FROM contacts t WHERE t.company_id = c.id) AS n"
  sql$ = sql$ + " FROM companies c WHERE c.kind = ?1"
  sql$ = sql$ + " AND (?2 = '' OR c.name LIKE ?2 OR c.trade_name LIKE ?2 OR c.tax_id LIKE ?2"
  sql$ = sql$ + "      OR c.city LIKE ?2 OR EXISTS (SELECT 1 FROM contacts t WHERE t.company_id = c.id AND t.name LIKE ?2))"
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
  ids$ = ""
  while sqlite_step(s@) = 1
    n = n + 1
    stringgrid_rowcount@(g@, n + 1)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "name"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "tax_id"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "city"))
    stringgrid_cell@(g@, 4, n + 1, sqlite_gets$(s@, "state"))
    stringgrid_cell@(g@, 5, n + 1, sqlite_gets$(s@, "n"))
    if ids$ <> "" then ids$ = ids$ + ","
    ids$ = ids$ + sqlite_gets$(s@, "id")
  endwhile
  sqlite_finalize(s@)
  sdict_set@(rowids@, p$ + ".grid", ids$)
  size_grid_columns(p$ + ".grid")
  busy = busy - 1
  rem Keep showing the record that was open, if the filter still lists it.
  busy = busy + 1
  if keep <> 0 and grid_select(p$ + ".grid", keep) = 1 then
    busy = busy - 1
    load_company(k, keep)
  elseif n > 0 then
    stringgrid_cursor@(g@, 1, 2)
    busy = busy - 1
    load_company(k, grid_id(p$ + ".grid"))
  else
    busy = busy - 1
    load_company(k, 0)
  endif
  return n
endfunction

function on_company_filter(sender@)
  if busy > 0 then return 0
  refresh_companies(control_tag(sender@))
  return 0
endfunction

function on_company_select(sender@) local k, id
  if busy > 0 then return 0
  k = control_tag(sender@)
  id = grid_id(pre$(k) + ".grid")
  if id <> cur(pre$(k) + ".company") then load_company(k, id)
  return 0
endfunction

rem A double click on a company opens its contacts.
function on_company_dblclick(sender@) local k
  k = control_tag(sender@)
  if cur(pre$(k) + ".company") <> 0 then pagecontrol_pageindex@(w@(pre$(k) + ".detail"), 2)
  return 0
endfunction

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
    endif
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
        endif
      next
      checkbox_checked@(company_field@(k, "active"), sqlite_getn(s@, "active"))
      a$ = "Created " + sqlite_gets$(s@, "created_local") + by$(sqlite_gets$(s@, "created_name"))
      if sqlite_gets$(s@, "updated_local") <> "" then a$ = a$ + ";  changed " + sqlite_gets$(s@, "updated_local") + by$(sqlite_gets$(s@, "updated_name"))
      label_caption@(company_field@(k, "audit"), a$)
    endif
    sqlite_finalize(s@)
  endif
  control_enabled@(w@(p$ + ".delete"), flag(id <> 0))
  control_enabled@(w@(p$ + ".tab.contacts"), flag(id <> 0))
  control_enabled@(w@(p$ + ".tab.history"), flag(id <> 0))
  busy = busy - 1
  refresh_contacts(k)
  return 0
endfunction

function on_company_new(sender@) local k
  k = control_tag(sender@)
  busy = busy + 1
  stringgrid_cursor@(w@(pre$(k) + ".grid"), 1, 1)
  busy = busy - 1
  load_company(k, 0)
  pagecontrol_pageindex@(w@(pre$(k) + ".detail"), 1)
  control_setfocus@(company_field@(k, "name"))
  return 0
endfunction

function on_company_save(sender@) local k, p$, id, s@, i, col$, v$, sql$, cols, country$, tax$
  k = control_tag(sender@)
  p$ = pre$(k)
  id = cur(p$ + ".company")
  if trim$(edit_text$(company_field@(k, "name"))) = "" then
    say("The company needs a name.")
    return 0
  endif
  if email_ok?(trim$(edit_text$(company_field@(k, "email")))) = false then
    say("That e-mail address does not look right.")
    return 0
  endif
  country$ = lcase$(trim$(edit_text$(company_field@(k, "country"))))
  tax$ = trim$(edit_text$(company_field@(k, "tax_id")))
  if tax$ <> "" and (country$ = "brazil" or country$ = "brasil") then
    if brazil_id_ok?(tax$) = false then
      say("That is not a valid CNPJ or CPF: its check digits do not match.")
      return 0
    endif
  endif
  cols = count_items(COMPANY_COLS$)
  if id = 0 then
    sql$ = "INSERT INTO companies(kind, created_by, " + COMPANY_COLS$ + ", active) VALUES (?1, ?2"
    for i = 1 to cols
      sql$ = sql$ + ", ?" + str$(i + 2)
    next
    sql$ = sql$ + ", ?" + str$(cols + 3) + ")"
  else
    sql$ = "UPDATE companies SET kind = ?1, updated_by = ?2, updated_at = datetime('now')"
    for i = 1 to cols
      sql$ = sql$ + ", " + nth$(COMPANY_COLS$, i) + " = ?" + str$(i + 2)
    next
    sql$ = sql$ + ", active = ?" + str$(cols + 3) + " WHERE id = ?" + str$(cols + 4)
  endif
  s@ = sqlite_prepare@(db@, sql$)
  sqlite_bindstr(s@, 1, kind$(k))
  sqlite_bindnum(s@, 2, user_id)
  for i = 1 to cols
    col$ = nth$(COMPANY_COLS$, i)
    if col$ = "notes" then
      v$ = memo_text$(company_field@(k, col$))
    else
      v$ = trim$(edit_text$(company_field@(k, col$)))
    endif
    sqlite_bindstr(s@, i + 2, v$)
  next
  sqlite_bindnum(s@, cols + 3, checkbox_checked(company_field@(k, "active")))
  if id <> 0 then sqlite_bindnum(s@, cols + 4, id)
  if finish(s@, "save the " + kind$(k)) <> 1 then return 0
  if id = 0 then set_cur(p$ + ".company", sqlite_lastid(db@))
  refresh_companies(k)
  update_status()
  status("Saved " + trim$(edit_text$(company_field@(k, "name"))) + ".")
  return 0
endfunction

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
endfunction

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
  maskedit_mask@(w@(p$ + ".k.birthday"), "00/00;1;_")
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
endfunction

function contact_field@(k, col$)
  return w@(pre$(k) + ".k." + col$)
endfunction

function refresh_contacts(k) local p$, g@, s@, n, n2, ids$, company, keep, prim$
  p$ = pre$(k)
  g@ = w@(p$ + ".cgrid")
  company = cur(p$ + ".company")
  keep = cur(p$ + ".contact")
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  n = 0
  ids$ = ""
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
    if ids$ <> "" then ids$ = ids$ + ","
    ids$ = ids$ + sqlite_gets$(s@, "id")
  endwhile
  sqlite_finalize(s@)
  sdict_set@(rowids@, p$ + ".cgrid", ids$)
  size_grid_columns(p$ + ".cgrid")
  busy = busy - 1
  busy = busy + 1
  n2 = grid_select(p$ + ".cgrid", keep)
  busy = busy - 1
  if keep <> 0 and n2 = 1 then
    load_contact(k, keep)
  elseif n > 0 then
    busy = busy + 1
    stringgrid_cursor@(g@, 1, 2)
    busy = busy - 1
    load_contact(k, grid_id(p$ + ".cgrid"))
  else
    load_contact(k, 0)
  endif
  return n
endfunction

function on_contact_select(sender@) local k, id
  if busy > 0 then return 0
  k = control_tag(sender@)
  id = grid_id(pre$(k) + ".cgrid")
  if id <> cur(pre$(k) + ".contact") then load_contact(k, id)
  return 0
endfunction

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
    endif
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
        endif
      next
      checkbox_checked@(contact_field@(k, "primary"), sqlite_getn(s@, "is_primary"))
    endif
    sqlite_finalize(s@)
    s@ = sqlite_prepare@(db@, "SELECT line_id FROM contact_lines WHERE contact_id = ?1")
    sqlite_bindnum(s@, 1, id)
    while sqlite_step(s@) = 1
      lines$ = lines$ + "," + sqlite_gets$(s@, "line_id") + ","
    endwhile
    sqlite_finalize(s@)
  endif
  rem Tick the product lines this contact serves.
  cl@ = w@(p$ + ".k.lines")
  for i = 1 to checklist_count(cl@)
    checklist_checked@(cl@, i, flag(instr(lines$, "," + nth$(sdict_get$(rowids@, "lines.all"), i) + ",") > 0))
  next
  control_enabled@(w@(p$ + ".k.delete"), flag(id <> 0))
  busy = busy - 1
  refresh_history(k)
  return 0
endfunction

function on_contact_new(sender@) local k
  k = control_tag(sender@)
  busy = busy + 1
  stringgrid_cursor@(w@(pre$(k) + ".cgrid"), 1, 1)
  busy = busy - 1
  load_contact(k, 0)
  control_setfocus@(contact_field@(k, "name"))
  return 0
endfunction

function on_contact_save(sender@) local k, p$, id, company, s@, i, col$, v$, sql$, cols, cl@, ok
  k = control_tag(sender@)
  p$ = pre$(k)
  id = cur(p$ + ".contact")
  company = cur(p$ + ".company")
  if company = 0 then return 0
  if trim$(edit_text$(contact_field@(k, "name"))) = "" then
    say("The contact needs a name.")
    return 0
  endif
  if email_ok?(trim$(edit_text$(contact_field@(k, "email")))) = false then
    say("That e-mail address does not look right.")
    return 0
  endif
  cols = count_items(CONTACT_COLS$)
  rem The contact, its product lines and the one-primary rule change
  rem together or not at all.
  sqlite_begin(db@)
  if id = 0 then
    sql$ = "INSERT INTO contacts(company_id, created_by, " + CONTACT_COLS$ + ", is_primary) VALUES (?1, ?2"
    for i = 1 to cols
      sql$ = sql$ + ", ?" + str$(i + 2)
    next
    sql$ = sql$ + ", ?" + str$(cols + 3) + ")"
  else
    sql$ = "UPDATE contacts SET company_id = ?1, updated_by = ?2, updated_at = datetime('now')"
    for i = 1 to cols
      sql$ = sql$ + ", " + nth$(CONTACT_COLS$, i) + " = ?" + str$(i + 2)
    next
    sql$ = sql$ + ", is_primary = ?" + str$(cols + 3) + " WHERE id = ?" + str$(cols + 4)
  endif
  s@ = sqlite_prepare@(db@, sql$)
  sqlite_bindnum(s@, 1, company)
  sqlite_bindnum(s@, 2, user_id)
  for i = 1 to cols
    col$ = nth$(CONTACT_COLS$, i)
    if col$ = "notes" then
      v$ = memo_text$(contact_field@(k, col$))
    elseif col$ = "birthday" then
      v$ = maskedit_text$(contact_field@(k, col$))
      if digits$(v$) = "" then v$ = ""
    else
      v$ = trim$(edit_text$(contact_field@(k, col$)))
    endif
    sqlite_bindstr(s@, i + 2, v$)
  next
  sqlite_bindnum(s@, cols + 3, checkbox_checked(contact_field@(k, "primary")))
  if id <> 0 then sqlite_bindnum(s@, cols + 4, id)
  ok = finish(s@, "save the contact")
  if ok = 1 and id = 0 then id = sqlite_lastid(db@)
  if ok = 1 and checkbox_checked(contact_field@(k, "primary")) = 1 then
    s@ = sqlite_prepare@(db@, "UPDATE contacts SET is_primary = 0 WHERE company_id = ?1 AND id <> ?2")
    sqlite_bindnum(s@, 1, company)
    sqlite_bindnum(s@, 2, id)
    ok = finish(s@, "mark the primary contact")
  endif
  if ok = 1 then
    s@ = sqlite_prepare@(db@, "DELETE FROM contact_lines WHERE contact_id = ?1")
    sqlite_bindnum(s@, 1, id)
    ok = finish(s@, "update the product lines")
  endif
  cl@ = w@(p$ + ".k.lines")
  for i = 1 to checklist_count(cl@)
    if ok = 1 and checklist_checked(cl@, i) = 1 then
      s@ = sqlite_prepare@(db@, "INSERT INTO contact_lines(contact_id, line_id) VALUES (?1, ?2)")
      sqlite_bindnum(s@, 1, id)
      sqlite_bindnum(s@, 2, val(nth$(sdict_get$(rowids@, "lines.all"), i)))
      ok = finish(s@, "update the product lines")
    endif
  next
  if ok <> 1 then
    sqlite_rollback(db@)
    return 0
  endif
  sqlite_commit(db@)
  set_cur(p$ + ".contact", id)
  refresh_contacts(k)
  refresh_companies(k)
  update_status()
  status("Saved contact " + trim$(edit_text$(contact_field@(k, "name"))) + ".")
  return 0
endfunction

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
endfunction

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
endfunction

function refresh_history(k) local p$, g@, s@, n, ids$, contact
  p$ = pre$(k)
  g@ = w@(p$ + ".hgrid")
  contact = cur(p$ + ".contact")
  if contact = 0 then
    label_caption@(w@(p$ + ".h.who"), "Pick a contact on the Contacts tab to see its history.")
  else
    label_caption@(w@(p$ + ".h.who"), "History with " + trim$(edit_text$(contact_field@(k, "name"))))
  endif
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  n = 0
  ids$ = ""
  s@ = sqlite_prepare@(db@, "SELECT i.id, i.happened_on, i.kind, i.subject, u.username FROM interactions i LEFT JOIN users u ON u.id = i.user_id WHERE i.contact_id = ?1 ORDER BY i.happened_on DESC, i.id DESC")
  sqlite_bindnum(s@, 1, contact)
  while sqlite_step(s@) = 1
    n = n + 1
    stringgrid_rowcount@(g@, n + 1)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "happened_on"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "kind"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "subject"))
    stringgrid_cell@(g@, 4, n + 1, sqlite_gets$(s@, "username"))
    if ids$ <> "" then ids$ = ids$ + ","
    ids$ = ids$ + sqlite_gets$(s@, "id")
  endwhile
  sqlite_finalize(s@)
  sdict_set@(rowids@, p$ + ".hgrid", ids$)
  size_grid_columns(p$ + ".hgrid")
  calendar_date@(w@(p$ + ".h.date"), today())
  edit_text@(w@(p$ + ".h.subject"), "")
  memo_text@(w@(p$ + ".h.notes"), "")
  combo_itemindex@(w@(p$ + ".h.kind"), 1)
  control_enabled@(w@(p$ + ".h.add"), flag(contact <> 0))
  control_enabled@(w@(p$ + ".h.delete"), flag(n > 0))
  busy = busy - 1
  return n
endfunction

function on_history_select(sender@) local k, s@, id
  if busy > 0 then return 0
  k = control_tag(sender@)
  id = grid_id(pre$(k) + ".hgrid")
  if id = 0 then return 0
  s@ = sqlite_prepare@(db@, "SELECT * FROM interactions WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if sqlite_step(s@) = 1 then
    calendar_date@(w@(pre$(k) + ".h.date"), strtodate(sqlite_gets$(s@, "happened_on")))
    edit_text@(w@(pre$(k) + ".h.subject"), sqlite_gets$(s@, "subject"))
    memo_text@(w@(pre$(k) + ".h.notes"), sqlite_gets$(s@, "notes"))
  endif
  sqlite_finalize(s@)
  return 0
endfunction

function on_history_add(sender@) local k, p$, s@, contact
  k = control_tag(sender@)
  p$ = pre$(k)
  contact = cur(p$ + ".contact")
  if contact = 0 then return 0
  if trim$(edit_text$(w@(p$ + ".h.subject"))) = "" then
    say("Give the entry a subject.")
    return 0
  endif
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
endfunction

function on_history_delete(sender@) local k, s@, id
  k = control_tag(sender@)
  id = grid_id(pre$(k) + ".hgrid")
  if id = 0 then return 0
  if ask?("Delete this history entry?") = false then return 0
  s@ = sqlite_prepare@(db@, "DELETE FROM interactions WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if finish(s@, "delete the entry") <> 1 then return 0
  refresh_history(k)
  return 0
endfunction

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
endfunction

function refresh_lines() local g@, s@, n, n2, ids$, keep
  g@ = w@("lgrid")
  keep = cur("line")
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  n = 0
  ids$ = ""
  s@ = sqlite_prepare@(db@, "SELECT p.id, p.name, p.description, (SELECT count(*) FROM contact_lines l WHERE l.line_id = p.id) AS n FROM product_lines p ORDER BY p.name COLLATE NOCASE")
  while sqlite_step(s@) = 1
    n = n + 1
    stringgrid_rowcount@(g@, n + 1)
    stringgrid_cell@(g@, 1, n + 1, sqlite_gets$(s@, "name"))
    stringgrid_cell@(g@, 2, n + 1, sqlite_gets$(s@, "description"))
    stringgrid_cell@(g@, 3, n + 1, sqlite_gets$(s@, "n"))
    if ids$ <> "" then ids$ = ids$ + ","
    ids$ = ids$ + sqlite_gets$(s@, "id")
  endwhile
  sqlite_finalize(s@)
  sdict_set@(rowids@, "lgrid", ids$)
  size_grid_columns("lgrid")
  busy = busy - 1
  busy = busy + 1
  n2 = grid_select("lgrid", keep)
  busy = busy - 1
  if keep <> 0 and n2 = 1 then
    load_line(keep)
  elseif n > 0 then
    busy = busy + 1
    stringgrid_cursor@(g@, 1, 2)
    busy = busy - 1
    load_line(grid_id("lgrid"))
  else
    load_line(0)
  endif
  return n
endfunction

function on_line_select(sender@)
  if busy > 0 then return 0
  load_line(grid_id("lgrid"))
  return 0
endfunction

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
    endif
    sqlite_finalize(s@)
  endif
  control_enabled@(w@("l.delete"), flag(id <> 0))
  return 0
endfunction

function on_line_new(sender@)
  busy = busy + 1
  stringgrid_cursor@(w@("lgrid"), 1, 1)
  busy = busy - 1
  load_line(0)
  return 0
endfunction

function on_line_save(sender@) local id, s@, name$
  id = cur("line")
  name$ = trim$(edit_text$(w@("l.name")))
  if name$ = "" then
    say("The product line needs a name.")
    return 0
  endif
  if id = 0 then
    s@ = sqlite_prepare@(db@, "INSERT INTO product_lines(name, description) VALUES (?1, ?2)")
  else
    s@ = sqlite_prepare@(db@, "UPDATE product_lines SET name = ?1, description = ?2 WHERE id = ?3")
    sqlite_bindnum(s@, 3, id)
  endif
  sqlite_bindstr(s@, 1, name$)
  sqlite_bindstr(s@, 2, memo_text$(w@("l.description")))
  if finish(s@, "save the product line") <> 1 then return 0
  if id = 0 then set_cur("line", sqlite_lastid(db@))
  refresh_lines()
  rebuild_line_lists()
  return 0
endfunction

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
endfunction

rem The product lines appear in three more places: each kind's filter and
rem each kind's contact check list. A check list has no clear, so it is
rem freed and built again inside its group box.
function rebuild_line_lists() local s@, k, p$, cl@, c@, names$, ids$, i, n
  names$ = ""
  ids$ = ""
  n = 0
  s@ = sqlite_prepare@(db@, "SELECT id, name FROM product_lines ORDER BY name COLLATE NOCASE")
  while sqlite_step(s@) = 1
    n = n + 1
    if n > 1 then
      names$ = names$ + ","
      ids$ = ids$ + ","
    endif
    names$ = names$ + replacestr$(sqlite_gets$(s@, "name"), ",", " ")
    ids$ = ids$ + sqlite_gets$(s@, "id")
  endwhile
  sqlite_finalize(s@)
  sdict_set@(rowids@, "lines.all", ids$)
  sdict_set@(rowids@, "linefilter.ids", ids$)
  busy = busy + 1
  for k = 1 to 2
    p$ = pre$(k)
    c@ = w@(p$ + ".linefilter")
    combo_clear@(c@)
    combo_add@(c@, "(any)")
    for i = 1 to n
      combo_add@(c@, nth$(names$, i))
    next
    combo_itemindex@(c@, 1)
    if dict_haskey(widgets@, p$ + ".k.lines") = 1 then control_free(w@(p$ + ".k.lines"))
    cl@ = checklistbox@(w@(p$ + ".k.linebox"))
    control_align@(cl@, 5)
    for i = 1 to n
      checklist_add@(cl@, nth$(names$, i))
    next
    keep@(p$ + ".k.lines", cl@)
  next
  busy = busy - 1
  rem Put the ticks back for the contacts on screen.
  for k = 1 to 2
    if cur(pre$(k) + ".company") <> 0 then load_contact(k, cur(pre$(k) + ".contact"))
  next
  return n
endfunction

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
endfunction

function refresh_users() local g@, s@, n, n2, ids$, keep, a$
  g@ = w@("ugrid")
  keep = cur("user")
  busy = busy + 1
  stringgrid_rowcount@(g@, 1)
  n = 0
  ids$ = ""
  s@ = sqlite_prepare@(db@, "SELECT id, username, full_name, role, active, ifnull(datetime(last_login, 'localtime'), '') AS last FROM users ORDER BY username COLLATE NOCASE")
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
    if ids$ <> "" then ids$ = ids$ + ","
    ids$ = ids$ + sqlite_gets$(s@, "id")
  endwhile
  sqlite_finalize(s@)
  sdict_set@(rowids@, "ugrid", ids$)
  size_grid_columns("ugrid")
  busy = busy - 1
  busy = busy + 1
  n2 = grid_select("ugrid", keep)
  busy = busy - 1
  if keep <> 0 and n2 = 1 then
    load_user(keep)
  elseif n > 0 then
    busy = busy + 1
    stringgrid_cursor@(g@, 1, 2)
    busy = busy - 1
    load_user(grid_id("ugrid"))
  else
    load_user(0)
  endif
  return n
endfunction

function on_user_select(sender@)
  if busy > 0 then return 0
  load_user(grid_id("ugrid"))
  return 0
endfunction

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
    endif
    sqlite_finalize(s@)
  endif
  control_enabled@(w@("u.delete"), flag(id <> 0 and id <> user_id))
  return 0
endfunction

function on_user_new(sender@)
  busy = busy + 1
  stringgrid_cursor@(w@("ugrid"), 1, 1)
  busy = busy - 1
  load_user(0)
  return 0
endfunction

rem How many active administrators there would be if user id had this
rem role and this active flag -- the one rule users cannot break: someone
rem must still be able to manage users.
function admins_after(id, role$, active) local n
  n = scalar_n("SELECT count(*) FROM users WHERE role = 'admin' AND active = 1 AND id <> ?1", id)
  if role$ = "admin" and active = 1 then n = n + 1
  return n
endfunction

function on_user_save(sender@) local id, s@, u$, p$, role$, active
  id = cur("user")
  u$ = trim$(edit_text$(w@("u.username")))
  p$ = edit_text$(w@("u.password"))
  role$ = combo_text$(w@("u.role"))
  active = checkbox_checked(w@("u.active"))
  if u$ = "" then
    say("The user needs a user name.")
    return 0
  endif
  if p$ <> edit_text$(w@("u.confirm")) then
    say("The two passwords are different.")
    return 0
  endif
  if id = 0 and len(p$) < 6 then
    say("A new user needs a password of 6 characters or more.")
    return 0
  endif
  if p$ <> "" and len(p$) < 6 then
    say("A password needs 6 characters or more.")
    return 0
  endif
  if admins_after(id, role$, active) = 0 then
    say("At least one active administrator must remain.")
    return 0
  endif
  if id = 0 then
    s@ = sqlite_prepare@(db@, "INSERT INTO users(username, full_name, role, active, password) VALUES (?1, ?2, ?3, ?4, ?5)")
    sqlite_bindstr(s@, 5, password_hash$(p$, pw_cost))
  elseif p$ = "" then
    s@ = sqlite_prepare@(db@, "UPDATE users SET username = ?1, full_name = ?2, role = ?3, active = ?4 WHERE id = ?6")
    sqlite_bindnum(s@, 6, id)
  else
    s@ = sqlite_prepare@(db@, "UPDATE users SET username = ?1, full_name = ?2, role = ?3, active = ?4, password = ?5 WHERE id = ?6")
    sqlite_bindstr(s@, 5, password_hash$(p$, pw_cost))
    sqlite_bindnum(s@, 6, id)
  endif
  sqlite_bindstr(s@, 1, u$)
  sqlite_bindstr(s@, 2, trim$(edit_text$(w@("u.full_name"))))
  sqlite_bindstr(s@, 3, role$)
  sqlite_bindnum(s@, 4, active)
  if finish(s@, "save the user") <> 1 then return 0
  if id = 0 then set_cur("user", sqlite_lastid(db@))
  refresh_users()
  status("Saved user " + u$ + ".")
  return 0
endfunction

function on_user_delete(sender@) local id, s@
  id = cur("user")
  if id = 0 or id = user_id then return 0
  if admins_after(id, "operator", 0) = 0 then
    say("At least one active administrator must remain.")
    return 0
  endif
  if ask?("Delete the user " + trim$(edit_text$(w@("u.username"))) + "? The records they created stay.") = false then return 0
  s@ = sqlite_prepare@(db@, "DELETE FROM users WHERE id = ?1")
  sqlite_bindnum(s@, 1, id)
  if finish(s@, "delete the user") <> 1 then return 0
  set_cur("user", 0)
  refresh_users()
  return 0
endfunction

rem ===============================================================
rem  Change my password: a small window that keeps the main one
rem  disabled while it is open (Phosphor has no modal forms of its own)
rem ===============================================================

function build_password_form() local f@
  f@ = keep@("pw", form@(APP$ + " - change password", 340, 260))
  control_set@(f@, "Position", "poScreenCenter")
  control_set@(f@, "BorderStyle", "bsDialog")
  form_onclose@(f@, "on_password_close")
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
  return 0
endfunction

function on_change_password(sender@)
  edit_text@(w@("pw.old"), "")
  edit_text@(w@("pw.new"), "")
  edit_text@(w@("pw.confirm"), "")
  label_caption@(w@("pw.msg"), "")
  control_enabled@(w@("main"), 0)
  show(w@("pw"))
  return 0
endfunction

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
  endif
  if len(n$) < 6 then
    label_caption@(w@("pw.msg"), "Use 6 characters or more.")
    return 0
  endif
  if n$ <> edit_text$(w@("pw.confirm")) then
    label_caption@(w@("pw.msg"), "The two new passwords are different.")
    return 0
  endif
  s@ = sqlite_prepare@(db@, "UPDATE users SET password = ?1 WHERE id = ?2")
  sqlite_bindstr(s@, 1, password_hash$(n$, pw_cost))
  sqlite_bindnum(s@, 2, user_id)
  if finish(s@, "change the password") <> 1 then return 0
  label_caption@(w@("pw.msg"), "")
  close_password_form()
  status("Your password was changed.")
  return 0
endfunction

function on_password_cancel(sender@)
  close_password_form()
  return 0
endfunction

function close_password_form()
  control_enabled@(w@("main"), 1)
  hide(w@("pw"))
  return 0
endfunction

function on_password_close(sender@)
  control_enabled@(w@("main"), 1)
  return 0
endfunction

rem ===============================================================
rem  CSV export: one row per contact, with its company's columns
rem ===============================================================

function csv$(v$)
  return chr$(34) + replacestr$(v$, chr$(34), chr$(34) + chr$(34)) + chr$(34)
endfunction

function on_export_suppliers(sender@)
  export_csv(1)
  return 0
endfunction

function on_export_customers(sender@)
  export_csv(2)
  return 0
endfunction

function on_export_button(sender@)
  export_csv(control_tag(sender@))
  return 0
endfunction

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
  endwhile
  sqlite_finalize(s@)
  if file_writealltext(p$, out$) = 1 then
    status("Exported " + str$(n) + " row(s) to " + p$)
  else
    say("Could not write " + p$)
  endif
  return n
endfunction

rem ===============================================================
rem  Sample data
rem ===============================================================

function seed_sample_data() local s$
  s$ = "INSERT INTO product_lines(name, description) VALUES"
  s$ = s$ + " ('Steel sheets', 'Cold and hot rolled sheets'),"
  s$ = s$ + " ('Industrial paint', 'Epoxy and polyurethane coatings'),"
  s$ = s$ + " ('Fasteners', 'Bolts, nuts and rivets'),"
  s$ = s$ + " ('Packaging', 'Boxes, film and pallets');"
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
  endif
  return 1
endfunction

rem The demonstration (PHOSPHOR_CONTACTS_DEMO=1): a throw-away database in
rem the temp folder with the sample data, signed in as "demo" -- a way to
rem look around without creating anything. Its password is "demo123".
function start_demo() local path$, s@
  path$ = temppath$() + "phosphor-contacts-demo.db"
  if file_exists(path$) = 1 then file_delete(path$)
  if open_database(path$) <> 1 then return 0
  s@ = sqlite_prepare@(db@, "INSERT INTO users(username, full_name, password, role) VALUES ('demo', 'Demo administrator', ?1, 'admin')")
  sqlite_bindstr(s@, 1, password_hash$("demo123", pw_cost))
  if finish(s@, "create the demo user") <> 1 then return 0
  seed_sample_data()
  prepare_login()
  edit_text@(w@("login.user"), "demo")
  edit_text@(w@("login.pass"), "demo123")
  button_click@(w@("login.go"))
  return 1
endfunction

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
  endif
  return 0
endfunction

function type_into(key$, text$)
  edit_text@(w@(key$), text$)
  return 0
endfunction

function click(key$)
  button_click@(w@(key$))
  return 0
endfunction

function count_of(sql$)
  return sqlite_scalar(db@, sql$)
endfunction

function run_selftest() local path$, id, s@, n, rec$, csvpath$, text$
  pw_cost = 1000
  path$ = temppath$() + "contact_manager_selftest.db"
  if file_exists(path$) = 1 then file_delete(path$)

  rem --- first run: the login form creates the administrator ---
  open_database(path$)
  check(first_run? = true, "a new database asks for an administrator")
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

  rem --- the partial unique index: one tax id per kind ---
  click("s.new")
  type_into("s.f.name", "Copycat Ltda.")
  type_into("s.f.tax_id", "11.444.777/0001-61")
  click("s.save")
  check(instr(last_msg$, "already has that tax id") > 0, "a duplicate tax id is refused with a plain message")

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
  maskedit_text@(w@("s.k.birthday"), "14/03")
  checkbox_checked@(w@("s.k.primary"), 1)
  checklist_checked@(w@("s.k.lines"), 2, 1)
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

  rem --- history for the selected contact ---
  click("s.h.add")
  check(last_msg$ = "Give the entry a subject.", "an entry needs a subject")
  calendar_date@(w@("s.h.date"), strtodate("2026-10-01"))
  combo_itemindex@(w@("s.h.kind"), 4)
  type_into("s.h.subject", "Sent the catalogue")
  click("s.h.add")
  check(count_of("SELECT count(*) FROM interactions WHERE subject = 'Sent the catalogue' AND kind = 'WhatsApp' AND happened_on = '2026-10-01' AND user_id = 1") = 1, "the history entry is kept with its date, kind and author")
  check(stringgrid_rowcount(w@("s.hgrid")) = 2, "and listed")

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
  check(count_of("SELECT count(*) FROM interactions WHERE subject = 'Sent the catalogue'") = 0, "and their history")

  rem --- customers use the same code with their own widgets ---
  check(stringgrid_rowcount(w@("c.grid")) = 3, "two customers listed")
  check(edit_text$(w@("c.f.extra")) <> "" , "the customer form shows the credit limit")

  rem --- product lines ---
  pagecontrol_pageindex@(w@("pages"), 3)
  click("l.new")
  type_into("l.name", "Fasteners")
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

  rem --- CSV export ---
  csvpath$ = temppath$() + "contact_manager_selftest.csv"
  if file_exists(csvpath$) = 1 then file_delete(csvpath$)
  save_as$ = csvpath$
  n = export_csv(2)
  check(n = 2, "the customer export writes one row per contact")
  text$ = file_readalltext$(csvpath$)
  check(left$(text$, 22) = "company,trade_name,tax", "under a header row")
  check(instr(text$, chr$(34) + "Metalúrgica Horizonte S.A." + chr$(34)) > 0, "with every value quoted")
  file_delete(csvpath$)

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
  grid_select("ugrid", 1)
  combo_itemindex@(w@("u.role"), 1)
  click("u.save")
  check(last_msg$ = "At least one active administrator must remain.", "the last administrator cannot be demoted")
  check(control_enabled(w@("u.delete")) = 0, "nor deleted: you cannot delete yourself")
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
  check(control_enabled(w@("main")) = 1, "the main window is usable again after the change")
  check(password_verify?("secret9", sqlite_scalar$(db@, "SELECT password FROM users WHERE id = 1")) = true, "the new password is the one kept")

  rem --- sign out, and an operator signs in ---
  menuitem_click@(w@("menu.signout"))
  check(user_id = 0, "signing out forgets the user")
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
  check(user_name$ = "Olivia" and user_role$ = "operator", "the operator signs in, user name in any case")
  check(control_get(w@("users.page"), "TabVisible") = 0, "and does not see the Users tab")
  check(count_of("SELECT count(*) FROM users WHERE username = 'olivia' AND last_login IS NOT NULL") = 1, "the sign-in is recorded")

  rem --- an inactive user cannot sign in ---
  sqlite_exec(db@, "UPDATE users SET active = 0 WHERE username = 'olivia'")
  menuitem_click@(w@("menu.signout"))
  type_into("login.user", "olivia")
  type_into("login.pass", "olivia-pw")
  click("login.go")
  check(user_id = 0, "an inactive user cannot sign in")

  rem --- the database survives a reopen ---
  sqlite_close(db@)
  open_database(path$)
  check(first_run? = false, "a database with users asks to sign in, not to create one")
  check(count_of("SELECT count(*) FROM companies") = 5, "and everything is still there")
  sqlite_close(db@)
  file_delete(path$)

  println "passed: " + str$(passed)
  println "failed: " + str$(failed)
  return 0
endfunction

rem A person picking a filter: combo_itemindex@ does not fire the change
rem event (only a person's choice does), so the handler the event would
rem have run is called with the combo as its sender.
function choose(key$, index)
  combo_itemindex@(w@(key$), index)
  on_company_filter(w@(key$))
  return 0
endfunction
