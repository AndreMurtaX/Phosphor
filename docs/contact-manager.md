# Contact Manager — a whole application in Phosphor BASIC

[`examples/contact_manager.bas`](../examples/contact_manager.bas) is a desktop
program for the people a company buys from and sells to: suppliers and
customers, the contacts at each one, the product lines those contacts serve,
and a dated history of what was said to whom. It keeps everything in SQLite,
behind a login with users, roles and hashed passwords, and it is one file of
BASIC — about 2,900 lines, a fifth of them the self-test.

It is here for two reasons: to show what the language and its libraries add up
to, and because writing it was this project's first real use. It found five
things the test suites had not, listed at the end.

![The suppliers page: a searchable list on the left, the selected company's record on the right](images/contact-manager-suppliers.png)

## Run it

It needs the SQLite runtime: `sqlite3.dll` beside `phosphor.exe` on Windows
(the 64-bit DLL from [sqlite.org](https://www.sqlite.org/download.html)), or
`libsqlite3` on Linux, which most distributions install already.

```bash
phosphor examples/contact_manager.bas
```

The first run asks you to create the administrator account and offers to load
a few sample companies.

![The first run: create the administrator account](images/contact-manager-first-run.png)

The data lives in `phosphor-contacts.db` in your Documents folder — or in your
home folder where there is no Documents folder, as on a Linux without
`~/Documents`. **File > Open database...** opens another one, and so does
naming it on the command line (`phosphor examples/contact_manager.bas my.db`)
or in the environment variable `PHOSPHOR_CONTACTS_DB`. A file that cannot be
used — not a database, in a folder that does not exist, made by a newer version
of the program — is refused with the reason: at start-up the program then
offers to pick another file or to end, and from **File > Open database...** it
keeps the database you had open, and your session with it. A read-only
database opens for looking: the sign-in says so, and every change is refused.

To look around without creating anything, start it with
`PHOSPHOR_CONTACTS_DEMO=1`: it opens a throw-away database in the temp folder
with the sample data, signed in as `demo` (password `demo123`).

```bash
PHOSPHOR_CONTACTS_DEMO=1 phosphor examples/contact_manager.bas
```

```powershell
$env:PHOSPHOR_CONTACTS_DEMO = '1'; phosphor examples\contact_manager.bas
```

## What it does

| page | what is on it |
| --- | --- |
| **Suppliers**, **Customers** | a list you can search by name, tax id (with or without its punctuation), city or the name of a contact — ignoring case in any alphabet (`AÇO` finds `Aço`), and taking `%` and `_` as the characters they are — and filter by active state and by the product line a contact serves. The selected company's **Details** (address, tax id, category or segment, lead time or credit limit, payment terms, notes, active flag, who created and changed it), its **Contacts**, and the **History** of the selected contact. A double click on a company opens its contacts. For a Brazilian company the tax id must be a valid CNPJ — numeric or, since July 2026, alphanumeric — or CPF |
| Contacts | name, job title, department, e-mail, phone, mobile, WhatsApp, LinkedIn, Instagram and other social media, birthday (a real day and month, `dd/mm`, or empty), notes, a primary-contact flag (one per company), and the product lines the contact serves |
| History | dated entries per contact — a call, a meeting, an e-mail, a WhatsApp message, a visit — with a subject, notes and who wrote it. **Delete entry** acts on the entry you picked in the list, and its question names it |
| **Product lines** | the lines your contacts serve, used by the contacts' check list and by the filters |
| **Users** | administrators only: users, their role (administrator or operator), whether they may sign in, and their passwords |

The **File** menu exports suppliers or customers to CSV (one row per contact,
with the product lines it serves) and backs the database up — to any file but
the open database itself, which it refuses; **Account** changes your own
password and signs out.

![A company's contacts, with the product lines each one serves](images/contact-manager-contacts.png)

![The history kept with a contact](images/contact-manager-history.png)

## How it is built

### SQLite carries the rules

The schema (`create_schema` in the program) makes the database refuse what the
program should never write, so a bug in the BASIC cannot corrupt it:

- **Foreign keys with `ON DELETE CASCADE`.** Deleting a company deletes its
  contacts, their product-line links and their history in one statement.
  `PRAGMA foreign_keys = ON` is run on every open, because SQLite leaves it off.
- **`ON DELETE SET NULL`** on "who created this": deleting a user keeps their
  records.
- **A partial unique index** — one tax id per kind of company, while many may
  leave it blank: `CREATE UNIQUE INDEX ... ON companies(kind, tax_key) WHERE tax_key <> ''`.
  `tax_key` is the id upper-cased with only its letters and digits kept, so
  `11.444.777/0001-61` and `11444777000161` are one id.
- **Unique keys that ignore case in any alphabet.** SQLite's `COLLATE NOCASE`
  and `LIKE` fold the 26 ASCII letters only, which made `josé` and `JOSÉ` two
  users. So each name that must be unique regardless of case is stored beside
  a key lower-cased by BASIC's `alcase$`, which knows all of Unicode — user
  names (`username_key`), product lines (`name_key`) — and the unique index is
  on the key: `Olivia` and `olivia`, `José` and `josé` are the same user. The
  search compares keys made the same way, with `LIKE ... ESCAPE '\'`.
- **A transaction** around saving a contact, its primary flag and its product
  lines: all of it or none of it.
- **A schema version**, kept in `PRAGMA user_version`. A database already at
  the current version is not written to when it is opened — which is what lets
  a read-only one open. An older one is upgraded inside one transaction that
  also sets the new version: version 1 to 2 added the keys above, computed them
  for the rows already there, and replaced the tax-id index. If those rows
  already break the new rules — two users whose names differ only in case, one
  tax id written two ways — the upgrade is refused with their names and the
  file is left as it was.

And **every value is bound**, never pasted into SQL — `?1`, `?2` and
`sqlite_bindstr` / `sqlite_bindnum` — so a company called `O'Brien; DROP TABLE`
is just a name:

```basic
s@ = sqlite_prepare@(db@, "SELECT id, username, password, role, active FROM users WHERE username_key = ?1")
sqlite_bindstr(s@, 1, alcase$(u$))
if sqlite_step(s@) = 1 then rec$ = sqlite_gets$(s@, "password")
sqlite_finalize(s@)
```

### Passwords are never stored

A password becomes a salted PBKDF2 record with `password_hash$`, and the login
asks `password_verify?` whether a typed password matches it
([libraries/crypto.md](libraries/crypto.md)). An unknown user name and a wrong
password get the same message, so the login does not tell a stranger which
names exist. The last active administrator cannot be demoted, deactivated or
deleted, so someone can always manage the users — a rule checked against the
database at each change, because another copy of the program on the same file
may have changed the users meanwhile. A change to your own account takes
effect at once: demote yourself and the Users page goes; deactivate yourself
and, after a confirmation, you are signed out.

### The windows

Every window is built in code: `form@`, a `mainmenu@`, a `statusbar@`, a
`pagecontrol@` with `tabsheet@` pages, and on them panels and group boxes,
`edit@` (with `PasswordChar` for passwords), a `maskedit@` for the birthday,
`memo@`, `combobox@` in drop-down-list style, a `checklistbox@` of product lines,
`checkbox@`, a `calendar@` and `button@`. The lists are `stringgrid@`s used as
record lists — whole-row selection, `stringgrid_onselect@` to load the picked
record, `stringgrid_colwidth@` for the columns, `control_ondblclick@` on the
company list. Messages, confirmations and the open and save dialogs are the
library's own.

Handlers are ordinary functions bound by name, and one handler serves both the
supplier and the customer page: each control carries the page's number in its
tag, and the handler reads `control_tag(sender@)`.

```basic
f@ = form@("Suppliers")
save@ = button@(f@)
button_caption@(save@, "Save")
control_tag@(save@, 1)          rem 1 = the suppliers page, 2 = the customers page
button_onclick@(save@, "on_company_save")

function on_company_save(sender@) local k
  k = control_tag(sender@)
  println "saving a record on page " + str$(k)
  return 0
end function
```

**Change my password** is a modal dialog: `form_showmodal` waits until it is
answered, its **Change** button answers `1` with `form_modalresult@` once the
new password is saved, and **Cancel** answers `2` through `button_modalresult@`.

### It tests itself

With `PHOSPHOR_SELFTEST=1` the program builds every window **without showing
one**, and drives them as a person would — typing with `edit_text@`, clicking
with `button_click@` and `menuitem_click@`, picking rows with
`stringgrid_cursor@`, double-clicking with `control_dblclick@` — against a
throw-away database, then checks what landed in SQLite: 133 checks, from the
first-run administrator to a cascade delete, the whole CSV file, an operator
who cannot see the Users page, the upgrade of a version-1 database and a
refresh of 2,000 rows. Its message, confirmation and file boxes go through
functions the test answers. `scripts/test-examples` runs it that way on Windows
and on Linux (under `xvfb-run`).

A check is only worth having if it can fail. An adversarial review found three
that could not — the CSV check looked at one quoted name, the credit-limit check
accepted any value, and the last-administrator check on deleting a user never
reached the rule it named — so they were rewritten, and each of them, and each
check added with the fixes of that review, was **seen to fail** in a copy of the
program with its rule reverted.

## What writing it changed in Phosphor

A real program finds what a test suite written by the same people does not:

- **The engine had no hash at all.** The crypto library
  ([libraries/crypto.md](libraries/crypto.md)) came from this program's login.
- **A grid could not say which row was picked**, nothing could take a double
  click, and every column had one width: `stringgrid_row` / `stringgrid_col` /
  `stringgrid_cursor@` / `stringgrid_onselect@`, `control_ondblclick@` /
  `control_dblclick@` and `stringgrid_colwidth@` came from its lists.
- **A `/` in an edit mask is not a slash.** The birthday field showed `14/03` on
  Windows and `14-  ` on Linux: the LCL reads `/` as the system's date
  separator. [libraries/gui-edit.md](libraries/gui-edit.md) now says so; `\/`
  is a slash everywhere.
- **A program could not read command-line arguments** — `phosphor run app.bas x`
  was refused — which is why this one took its switches from the environment.
  It can now (`paramstr$`, [libraries/sys.md](libraries/sys.md)), and the
  database can be named on the command line; the self-test and the demo stay
  environment switches, because `test-examples` sets them for a program it does
  not otherwise configure.
- **There were no modal forms**, so the password window first disabled the main
  one by hand. `form_showmodal`, `form_modalresult@` and `button_modalresult@`
  came from it.
