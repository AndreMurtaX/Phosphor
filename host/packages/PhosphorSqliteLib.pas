{******************************************************************************
  Phosphor BASIC -- SQLite (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  An opt-in package (host/packages/, RegisterSqliteFuncs) over the raw sqlite3 C
  API through FPC's dynamic binding (SQLite3Dyn). Unlike base64/zip it needs an
  EXTERNAL runtime library (sqlite3.dll on Windows, libsqlite3.so on Linux); the
  binding loads it at RUNTIME, so the unit always compiles, but the functions
  only work where the library is installed -- sqlite_available() reports whether
  it loaded, and the package test suite skips this package where it did not.

  Why the raw binding and not SQLdb: this is the full statement-level surface
  (prepare -> step -> reset -> finalize, per-parameter binding, per-column type
  and value access, a JSON row bridge). sqlite3_prepare_v2/bind/step/column map
  to it one-for-one; SQLdb's TSQLQuery would have been a second layer to fight.
  There is ONE API here -- a handle from sqlite_open@ serves every function,
  simple and statement-level alike -- never two half-APIs on two drivers.

  Indices are 1-BASED, like everything else in Phosphor (strings, arrays, JSON,
  string lists). A bind parameter and a column are both addressed from 1; the
  package maps that onto SQLite's own convention (bind params are 1-based, result
  columns 0-based) so the BASIC side stays uniformly 1-based. This is a deliberate
  divergence from the reference, whose SQL indices were 0-based.

  A statement (prepared or cursor) is a handle too, validated through
  PhosphorHandles exactly like the database handle. No cursor may outlive its
  connection: closing a database FINALIZES and INVALIDATES every statement opened
  on it (FreeHandle nils each statement's registry slot), so a stale statement id
  is refused by IsHandle, never dereferenced into a freed sqlite3_stmt.

    sqlite_available()              1 if the SQLite library loaded, else 0
    sqlite_open@()                  open an in-memory database          -> handle
    sqlite_open@(path$)             open a file (":memory:" too)        -> handle
    sqlite_isopen(db@)              1 while the handle is an open database
    sqlite_path$(db@)               the file the database was opened on
    sqlite_version$()               the SQLite library version
    sqlite_close(db@)               close and free the database (and its cursors)

    sqlite_exec(db@, sql$)          run a non-query statement           -> 1/0
    sqlite_scalar$(db@, sql$)       first column of the first row, as text
    sqlite_scalar(db@, sql$)        ... as a number
    sqlite_query$(db@, sql$)        all rows: columns tab-joined, rows newline-joined

    sqlite_changes(db@)             rows the last statement changed
    sqlite_totalchanges(db@)        rows changed this session
    sqlite_lastid(db@)              last inserted row id

    sqlite_tableexists(db@, t$)     1 if table t exists
    sqlite_tables@(db@)             a JSON array of the user table names
    sqlite_columns@(db@, t$)        a JSON array of (name,type,notnull,pk) per column

    sqlite_prepare@(db@, sql$)      a prepared statement                -> handle
    sqlite_query@(db@, sql$)        a cursor (a prepared SELECT)        -> handle
    sqlite_step(s@)                 1 if it landed on a row, 0 at the end
    sqlite_eof(s@)                  1 unless the cursor is on a row
    sqlite_reset(s@)                re-run the statement from the top
    sqlite_clearbind(s@)            drop every bound value
    sqlite_finalize(s@)             finish and free the statement

    sqlite_bindstr(s@, i, v$)       bind a string   to parameter i (1-based)
    sqlite_bindnum(s@, i, v)        bind a number   to parameter i
    sqlite_bindnull(s@, i)          bind SQL NULL   to parameter i
    sqlite_bindjson(s@, obj@)       bind a JSON object's members BY NAME (:key)

    sqlite_colcount(s@)             how many columns the result has
    sqlite_colname$(s@, i)          the name of column i (1-based)
    sqlite_colindex(s@, name$)      the 1-based index of a column by name (0 if none)
    sqlite_coltype(s@, i)           the SQLite type code of column i in this row
    sqlite_coltypename$(code)       the name of a type code (integer/float/text/...)

    sqlite_getstr$(s@, i)           column i as text     (by position)
    sqlite_getnum(s@, i)            column i as a number (by position)
    sqlite_gets$(s@, name$)         a column as text     (by name)
    sqlite_getn(s@, name$)          a column as a number (by name)
    sqlite_isnull(s@, i)            1 if column i is NULL (by position)
    sqlite_isn(s@, name$)           1 if a column is NULL (by name)
    sqlite_isblob(s@, i)            1 if column i is a blob

    sqlite_row@(s@)                 the current row as a JSON object
    sqlite_fetchone@(s@)            step, then the new current row as a JSON object
    sqlite_fetchall@(s@)            every remaining row as a JSON array

    sqlite_insertjson(db@, t$, o@)  insert a JSON object as a row        -> rows
    sqlite_updatejson(db@, t$, o@, where$)  update rows from a JSON object -> rows

    sqlite_begin(db@)               BEGIN a transaction
    sqlite_commit(db@)              COMMIT it
    sqlite_rollback(db@)            ROLL it back
    sqlite_intrans(db@)             1 while a transaction is open

    sqlite_escape$(s$)              double every apostrophe
    sqlite_quote$(s$)               escape and wrap in apostrophes

    sqlite_error()                  the last SQLite error code (0 = none)
    sqlite_errormsg$()              the last error message
    sqlite_strerror$(code)          the English name of an error code
    sqlite_clearerror()             reset the last-error code and message

    sqlite_backup(db@, path$)       write a standalone copy of the database
    sqlite_vacuum(db@)              compact the database

  THE SANDBOX, AND THE PATHS THAT ARRIVE INSIDE A STRING.

  Two of these functions take a path -- sqlite_open@(path$) and
  sqlite_backup(db@, path$) -- and both ask PhosphorSandbox.SandboxAllows before
  acting. That is the easy half, and it is not enough, because SQL NAMES FILES OF
  ITS OWN:

    sqlite_exec(db@, "attach database '/etc/passwd' as x")   reads AND writes
    sqlite_exec(db@, "vacuum into 'C:/elsewhere/copy.db'")   writes a full copy

  The path there is not an argument -- it is a few characters inside a query --
  so a gate on the arguments never sees it. A confined script used that to read
  any database on the disk and to drop complete copies of its own outside the
  root, while file_writealltext to the same directory was refused.

  Parsing the SQL would be the wrong answer: SQL has too many spellings and the
  parser would be wrong for ever. SQLite already has the mechanism -- the
  AUTHORIZER (sqlite3_set_authorizer), which its own parser consults for every
  statement -- so this unit installs one on every connection, in-memory ones
  included, and answers the file questions there. Measured on SQLite 3.49.1 and
  3.48.0 rather than assumed:

    ATTACH DATABASE 'p' AS x  -> SQLITE_ATTACH with 'p'   (any spelling, any
                                 case, comments and newlines between the tokens)
    ATTACH DATABASE ? AS x    -> SQLITE_ATTACH with NULL  (a name we cannot see)
    VACUUM INTO 'p'           -> SQLITE_ATTACH with 'p', BEFORE the file is made
    VACUUM                    -> SQLITE_ATTACH with ''    (sqlite's own scratch)

  So VACUUM INTO -- the one that carries a path but is not an ATTACH statement --
  arrives at the same door, and denying it costs nothing else. What a sandboxed
  program loses: an ATTACH or a VACUUM INTO naming a path outside the root, a
  filename given as a BOUND PARAMETER (the authorizer is handed NULL for it, and
  a name the gate cannot read is a name it must not approve -- inline it with
  sqlite_quote$ instead), a 'file:' URI, PRAGMA temp_store_directory /
  data_store_directory pointed out of the root, and PRAGMA data_store_directory
  moved between preparing an ATTACH and stepping it. Everything inside the root
  still works: ATTACH, VACUUM INTO, sqlite_backup, plain VACUUM, ':memory:',
  and relative names of all three.

  THE SAME BASE, AND THE SAME MOMENT. A gate that answers about a different file
  from the one SQLite opens is no gate at all, and there are two ways for them to
  drift apart. Both were live escapes; both are closed here rather than argued
  about, because each was measured against the shipped library:

    THE BASE. SandboxAllows resolves a relative name with ExpandFileName, which
    is arithmetic over the PROCESS's current directory. SQLite resolves it through
    its VFS, which on Windows prefers the sqlite3_data_directory global when that
    is set -- and PRAGMA data_store_directory sets it, for the whole process, on
    any connection. A script that stepped one level down and pointed the pragma
    back at the root made '../x.db' mean root/x.db to the gate and root/../x.db to
    SQLite. So every script-supplied database name is now resolved by SQLITE'S OWN
    RESOLVER first -- sqlite3_vfs_find(nil)^.xFullPathname, the very call the pager
    makes on its way to the file -- and the gate judges what comes back. With no
    data directory set that answer is exactly ExpandFileName's, measured, so
    nothing legitimate moves.

    THE MOMENT. ATTACH is authorized when the statement is PREPARED and opens its
    file when the statement is STEPPED; VACUUM INTO is authorized at step. Between
    a prepare and a step a script can chdir, or move the data directory, and the
    name the authorizer approved then names a different file -- measured: the file
    landed one directory above where the callback had been told. So an ATTACH
    filename approved under a root is REMEMBERED with its statement and asked
    again at every step, against the base in force then. Which door is answered
    when:

      sqlite_exec / sqlite_scalar / sqlite_query   prepare and step in one call,
                                                   no script runs between them
      sqlite_prepare@ + sqlite_step, ATTACH        prepare AND step
      sqlite_prepare@ + sqlite_step, VACUUM INTO   step (its callback arrives there)
      sqlite_open@ / sqlite_backup                 their own argument, before the call

  A build with SQLITE_OMIT_AUTHORIZATION does not export sqlite3_set_authorizer
  (one is installed on this machine). There the promise cannot be kept, so a
  SANDBOXED host is refused the connection outright rather than handed one whose
  SQL is ungoverned; an unsandboxed host is unaffected and behaves exactly as it
  always did. The same rule covers a build with no sqlite3_vfs_find to ask: under
  a root an unresolvable name is refused, never guessed at.
******************************************************************************}
unit PhosphorSqliteLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, ctypes, fpjson, SQLite3Dyn,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorJsonLib,
  PhosphorSandbox, PhosphorBudget;

{ WHETHER THE RUNTIME LIBRARY LOADED, asked rather than guessed.

  A test runner has to decide whether to run this package's corpus or skip it,
  and the honest question is "can THIS binary load SQLite" -- not "does a file
  called sqlite3.dll sit in one of the two places I thought of". The runner used
  to guess by path and got it wrong on the machine this was written on: three
  corpora, 169 assertions, skipped behind a yellow SKIP line that reads like
  ordinary output, while PACKAGES OK was printed anyway. The OpenSSL gate in the
  same runner already asked its binary; this makes the two consistent.

  phosphorpkgtest --sqlite-check exits 0 when this answers True. }
function SqliteAvailable: Boolean;

procedure RegisterSqliteFuncs(Reg: TPhosphorRegistry);

implementation

var
  GReady: Boolean = False;   // the SQLite runtime library loaded at unit init
  GLastErr: Integer = 0;     // module-level last-error, the ioerror/valcode pattern
  GLastMsg: String = '';
  { Set by the authorizer when IT refused, so exec/prepare/step can report the
    package's own words instead of sqlite's "not authorized". Cleared
    immediately before each call that can prepare or step a statement. }
  GAuthDenied: Boolean = False;
  { The ATTACH filename the authorizer APPROVED while preparing, so the statement
    can carry it and be asked again at step -- see DoStep. '' when there was none
    (or no sandbox, where there is nothing to re-check). }
  GAuthPath: String = '';

type
  TSqliteStmt = class;

  { A database handle: the sqlite3 connection plus every statement opened on it.
    The children are finalized (and their handle ids invalidated) when the db is
    freed, so no cursor can outlive its connection. }
  TSqliteDb = class
    DbPtr: psqlite3;
    Path: String;
    Children: TFPList;   // of TSqliteStmt
    constructor Create(ADb: psqlite3; const APath: String);
    destructor Destroy; override;
  end;

  { A prepared statement / cursor handle. It knows its owner and its own registry
    id so the owner can revoke it on close. }
  TSqliteStmt = class
    StmtPtr: psqlite3_stmt;
    Owner: TSqliteDb;
    HandleId: Int64;
    OnRow: Boolean;      // the most recent step landed on a row
    Stepped: Boolean;    // step has been called at least once
    Done: Boolean;       // a step has reported the end; only sqlite_reset re-opens it
    { The ATTACH filename this statement was authorized with, under a sandbox.
      SQLite opens that file when the statement is STEPPED, not when it was
      prepared, and the base a relative name resolves against can move in
      between -- so the question is asked again there. '' = nothing to re-ask. }
    AuthPath: String;
    { The declared type of each column AS THE ROW ARRIVED. sqlite3_column_type
      reports the CURRENT representation, and reading a column as text converts it
      in place -- so sqlite_coltype answered BLOB before a sqlite_getstr$ and TEXT
      after it, for the same row, with no step in between. Captured once per row so
      the answer depends on the data rather than on the order the program asked. }
    RowTypes: array of Integer;
    constructor Create(AOwner: TSqliteDb; AStmt: psqlite3_stmt);
    destructor Destroy; override;
  end;

constructor TSqliteDb.Create(ADb: psqlite3; const APath: String);
begin
  inherited Create();
  DbPtr := ADb;
  Path := APath;
  Children := TFPList.Create();
end;

destructor TSqliteDb.Destroy;
begin
  // Finalize and invalidate every child statement FIRST. FreeHandle frees the
  // TSqliteStmt (its destructor calls sqlite3_finalize) and nils its registry
  // slot, so a stale statement id afterwards is rejected by IsHandle rather than
  // dereferenced into a freed sqlite3_stmt. Each child removes itself from the
  // list as it is freed, so always take the last.
  if Children <> nil then
  begin
    while Children.Count > 0 do
      FreeHandle(TSqliteStmt(Children[Children.Count - 1]).HandleId);
    Children.Free;
    Children := nil;
  end;
  if DbPtr <> nil then
  begin
    sqlite3_close(DbPtr);   // every statement is finalized, so this cannot be BUSY
    DbPtr := nil;
  end;
  inherited Destroy();
end;

constructor TSqliteStmt.Create(AOwner: TSqliteDb; AStmt: psqlite3_stmt);
begin
  inherited Create();
  Owner := AOwner;
  StmtPtr := AStmt;
  OnRow := False;
  Stepped := False;
  Done := False;
  HandleId := 0;
end;

destructor TSqliteStmt.Destroy;
begin
  if StmtPtr <> nil then
  begin
    sqlite3_finalize(StmtPtr);
    StmtPtr := nil;
  end;
  if (Owner <> nil) and (Owner.Children <> nil) then
    Owner.Children.Remove(Self);
  inherited Destroy();
end;

// --- helpers ----------------------------------------------------------------
function PtrStr(P: PAnsiChar): String;
begin
  if P = nil then Result := '' else Result := P;
end;

{ A column's text, all of it.

  PtrStr treats the pointer as a C string and stops at the first NUL, so a text or
  blob column holding an embedded zero came back TRUNCATED: `length(b)` reported 4
  for x'41004243' while every reader here returned 1 byte. SQLite says how many
  bytes there are; ask it. (PtrStr stays for the genuinely NUL-terminated things --
  an error message, a column name.) }
function ColStr(AStmt: psqlite3_stmt; ACol: Integer): String;
var p: PAnsiChar; n: Integer;
begin
  p := PAnsiChar(sqlite3_column_text(AStmt, ACol));
  if p = nil then Exit('');
  n := sqlite3_column_bytes(AStmt, ACol);
  if n <= 0 then Exit('');
  SetLength(Result, n);
  Move(p^, Result[1], n);
end;

function GetDb(AId: Int64; out ADb: TSqliteDb): Boolean;
var o: TObject;
begin
  o := HandleObj(AId);
  Result := o is TSqliteDb;
  if Result then ADb := TSqliteDb(o) else ADb := nil;
end;

function GetStmt(AId: Int64; out AStmt: TSqliteStmt): Boolean;
var o: TObject;
begin
  o := HandleObj(AId);
  Result := o is TSqliteStmt;
  if Result then AStmt := TSqliteStmt(o) else AStmt := nil;
end;

{ ONE REFUSAL, WHATEVER DOOR IT CAME THROUGH. sqlite_open@ has answered these
  words since the day a confined run created a database in C:\Dev; a path refused
  inside a query, or as sqlite_backup's argument, is the same refusal and says the
  same thing. SQLITE_CANTOPEN is the code sqlite_open@ already reports, so
  sqlite_error() reads alike at all four. }
procedure RefusePath;
begin
  GLastErr := 14;   // SQLITE_CANTOPEN
  GLastMsg := 'refused: the path is outside the sandbox root';
end;

{ RESOLVE THE NAME THE WAY SQLITE IS ABOUT TO RESOLVE IT.

  SandboxAllows expands a relative name against the PROCESS's current directory.
  SQLite expands it through its VFS, which on Windows prefers the
  sqlite3_data_directory global when that is set. PRAGMA data_store_directory
  sets that global -- process-wide, from any connection, measured -- so the two
  bases can be made to differ, and then the same '../x.db' is inside the root for
  the gate and one level above it for SQLite. That was a live escape.

  xFullPathname is the function the pager itself calls on the way to opening a
  database file, so asking it removes the disagreement by construction rather
  than by modelling SQLite's rules here and keeping the model right for ever.
  FPC's binding is a second reason to ask rather than read: sqlite3.inc declares
  sqlite3_data_directory inside an "ifndef win32", so on Windows the global cannot
  be read from Pascal at all.

  Measured on 3.48.0, with no data directory set, against a working directory
  A: 'x.db' -> A\x.db, '../up.db' -> the parent, 'x/../y.db' -> A\y.db -- the
  same answers ExpandFileName gives, so nothing legitimate moves. With one set,
  the answer is the data directory, which is the whole point.

  False when there is nothing to ask (no sqlite3_vfs_find in this build, or the
  call failed): the caller turns that into a refusal under a root.

  The buffer is a fixed local rather than a dynamic array on purpose. Its size is
  SQLite's, not a script's -- mxPathname is 1040 on the win32 VFS and 512 on the
  unix one -- and nOut is capped at what the buffer holds, so a VFS claiming an
  absurd mxPathname makes xFullPathname REFUSE rather than write past the end.
  It also keeps a gate consulted once per statement off the heap. }
function SqlFullPath(const AName: String; out AFull: String): Boolean;
var
  vfs: psqlite3_vfs;
  buf: array[0..4095] of AnsiChar;
  n: Integer;
begin
  AFull := '';
  Result := False;
  if not Assigned(sqlite3_vfs_find) then Exit;
  vfs := sqlite3_vfs_find(nil);
  if (vfs = nil) or (not Assigned(vfs^.FullPathname)) then Exit;
  n := vfs^.mxPathname + 1;             // what SQLite's own callers pass
  if n > High(buf) then n := High(buf); // never more than there is room for
  if n < 2 then Exit;
  FillChar(buf[0], SizeOf(buf), 0);
  if vfs^.FullPathname(vfs, PAnsiChar(AName), n, @buf[0]) <> SQLITE_OK then Exit;
  AFull := PtrStr(PAnsiChar(@buf[0]));
  Result := AFull <> '';
end;

{ THE FILE A NAME MEANS, for the gate to judge -- one rule, three doors.

  Result False: the name must not be approved at all. AFull '' with Result True:
  the name is no file (':memory:', SQLite's anonymous scratch, or a name that
  cannot be read where there is no root to bound it), so there is nothing to
  judge. Otherwise AFull is the file SQLite will open.

  Why the answer is handed back instead of judged here: each door asks
  SandboxAllows in ITS OWN body. scripts/check-sandbox.py reads routine bodies
  and cannot follow a call, so a door whose guard has moved into a helper reads
  to that gate as a door with no guard -- and it is the check that catches this
  entire class. The hard half, resolution, stays in one place; the visible half
  stays where the primitive is.

  APresent is False when SQLite handed the authorizer NULL -- an ATTACH whose
  filename is a bound parameter, resolved after the callback has answered. A name
  that cannot be read cannot be judged, and under a root an unjudged name must
  not be approved; with no root there is nothing to bound, so it passes as it
  always has. }
function SqlTarget(const AName: String; APresent: Boolean; out AFull: String): Boolean;
begin
  AFull := '';
  if not APresent then Exit(not SandboxActive);
  { '' is SQLite's own anonymous scratch database -- what plain VACUUM attaches,
    and what `ATTACH '' AS x` makes: a private temporary file with a name nobody
    chose. ':memory:' is no file at all. Neither is a path a script steered, and
    IsPerilousPath would refuse the first of them. }
  if (AName = '') or (AName = ':memory:') then Exit(True);
  if not SandboxActive then
  begin
    { With no root there is nothing to escape from, and the name is judged exactly
      as it always was: an unsandboxed host is not asked a new question. }
    AFull := AName;
    Exit(True);
  end;
  { A URI filename resolves by rules the gate does not model (a query string can
    move the file, name a VFS, or reopen it read-write). URI filenames are OFF
    unless the library was compiled with SQLITE_USE_URI -- measured: 'file:...'
    came back "unable to open database" -- but a host drops its own sqlite3 in
    beside the binary, so under a root they are refused rather than guessed at. }
  if (Length(AName) >= 5) and SameText(Copy(AName, 1, 5), 'file:') then Exit(False);
  Result := SqlFullPath(AName, AFull);
end;

{ The gate, asked about a filename SQLite found inside a statement. }
function SqlPathAllowed(const AName: String; APresent: Boolean): Boolean;
var full: String;
begin
  Result := SqlTarget(AName, APresent, full);
  if Result and (full <> '') then Result := SandboxAllows(full, puWrite);
end;

{ SQLite's own parser, telling us every file its statements are about to name.
  Installed on every connection by OpenDatabase.

  Everything not about a file answers SQLITE_OK: this is a path gate, not a
  policy on what SQL may do. It must not raise -- it is called from C, where a
  Pascal exception has nowhere to go -- so the body is wrapped and an unexpected
  failure DENIES. }
function SandboxAuthorizer(pUserData: Pointer; code: cint;
                           s1, s2, s3, s4: PAnsiChar): cint; cdecl;
var nm: String;
begin
  Result := SQLITE_OK;
  try
    case code of
      SQLITE_ATTACH:
        { ATTACH DATABASE '<file>', and VACUUM INTO '<file>', which SQLite
          implements as one: arg1 is the filename, and the callback runs BEFORE
          the file is opened or created.

          An APPROVED name is remembered as well as approved. For an ATTACH this
          callback arrives while the statement is PREPARED and the file is opened
          when it is STEPPED, so the answer is only as good as the base still
          being what it was; DoStep asks again with the name kept here. (VACUUM
          INTO's callback arrives at step already -- measured -- so its answer
          needs no repeat, and it costs nothing to remember it anyway.) }
        begin
          nm := PtrStr(s1);
          if not SqlPathAllowed(nm, s1 <> nil) then
          begin
            GAuthDenied := True;
            Result := SQLITE_DENY;
          end
          else if SandboxActive and (s1 <> nil) and (nm <> '') and (nm <> ':memory:') then
            GAuthPath := nm;
        end;
      SQLITE_PRAGMA:
        { Two pragmas take a directory, and this bounds the DIRECTORY: neither may
          point outside the root. arg2 nil is a query rather than a set, and ''
          restores the default.

          It is no longer load-bearing against the desync, and that is deliberate.
          Round one gated the pragma and believed the base could then not move --
          but an inside-the-root directory moves it just as far, and the escape
          survived. Pointing it anywhere inside the root is now HARMLESS, because
          the gate resolves through the base rather than assuming one: SqlTarget
          asks SQLite where the file goes, and DoStep asks again at the moment it
          goes there. What is left here is an ordinary path rule on an ordinary
          path argument -- temp_store_directory has never been anything else. }
        if SandboxActive and (s2 <> nil) and (PtrStr(s2) <> '') then
        begin
          nm := LowerCase(PtrStr(s1));
          if ((nm = 'temp_store_directory') or (nm = 'data_store_directory'))
             and (not SandboxAllows(PtrStr(s2), puWrite)) then
          begin
            GAuthDenied := True;
            Result := SQLITE_DENY;
          end;
        end;
      SQLITE_FUNCTION:
        { load_extension() names a file and then RUNS it. Nothing here calls
          sqlite3_enable_load_extension, so SQLite already refuses it -- measured
          -- but a default someone else chose is not a guarantee this package
          made, and it is the same class: a path inside a statement. }
        if SandboxActive and (s2 <> nil) and SameText(PtrStr(s2), 'load_extension') then
        begin
          GAuthDenied := True;
          Result := SQLITE_DENY;
        end;
    end;
  except
    GAuthDenied := True;
    Result := SQLITE_DENY;
  end;
end;

{ True when the connection may be handed to a script. A build without the
  authorizer (SQLITE_OMIT_AUTHORIZATION does not export it) can still serve an
  UNSANDBOXED host exactly as before; a sandboxed one it cannot serve at all,
  and saying so is better than a cage with a door in the back. }
function InstallAuthorizer(ADb: psqlite3): Boolean;
begin
  Result := False;
  if Assigned(sqlite3_set_authorizer) then
    Result := sqlite3_set_authorizer(ADb, @SandboxAuthorizer, nil) = SQLITE_OK;
  if not Result then Result := not SandboxActive;
end;

procedure SetErrFromDb(ADb: TSqliteDb);
begin
  if (ADb <> nil) and (ADb.DbPtr <> nil) then
  begin
    GLastErr := sqlite3_errcode(ADb.DbPtr);
    GLastMsg := PtrStr(sqlite3_errmsg(ADb.DbPtr));
  end;
end;

{ Run a non-query statement (or several, ';'-separated). Records the error on
  failure. Autocommit is on unless a BEGIN opened a transaction. }
function ExecSql(ADb: TSqliteDb; const ASql: String): Boolean;
var rc: Integer; msg: PAnsiChar;
begin
  Result := False;
  if (ADb = nil) or (ADb.DbPtr = nil) then Exit;
  msg := nil;
  GAuthDenied := False;
  GAuthPath := '';
  rc := sqlite3_exec(ADb.DbPtr, PAnsiChar(ASql), nil, nil, @msg);
  if msg <> nil then sqlite3_free(msg);
  Result := (rc = SQLITE_OK);
  // A path refused inside the SQL says so in this package's words, not sqlite's.
  if not Result then
    if GAuthDenied then RefusePath else SetErrFromDb(ADb);
end;

function PrepareStmt(ADb: TSqliteDb; const ASql: String; out AStmt: psqlite3_stmt): Boolean;
var rc: Integer;
begin
  AStmt := nil;
  if (ADb = nil) or (ADb.DbPtr = nil) then Exit(False);
  GAuthDenied := False;
  GAuthPath := '';
  rc := sqlite3_prepare_v2(ADb.DbPtr, PAnsiChar(ASql), -1, @AStmt, nil);
  Result := (rc = SQLITE_OK) and (AStmt <> nil);
  if not Result then
  begin
    if GAuthDenied then RefusePath else SetErrFromDb(ADb);
    if AStmt <> nil then begin sqlite3_finalize(AStmt); AStmt := nil; end;
  end;
end;

{ Register a freshly prepared statement as a child of its database. The filename
  the authorizer approved during THAT prepare travels with it; only a statement
  handed back to a script needs it, because only there can script code run --
  a chdir, a pragma -- between the prepare and the step. }
function RegisterStmt(AOwner: TSqliteDb; AStmt: psqlite3_stmt): TValue;
var s: TSqliteStmt;
begin
  s := TSqliteStmt.Create(AOwner, AStmt);
  s.AuthPath := GAuthPath;
  s.HandleId := RegisterHandle(s);
  AOwner.Children.Add(s);
  Result := ValHandle(s.HandleId);
end;

{ Step, tracking the on-row / stepped state. Returns 1 for a row, 0 otherwise. }
function DoStep(AStmt: TSqliteStmt): Integer;
var rc, i: Integer;
begin
  { AN EXHAUSTED CURSOR STAYS EXHAUSTED, EVERY SUBSEQUENT TIME.

    sqlite3_prepare_v2 gives sqlite3_step an automatic reset: stepping again after
    SQLITE_DONE silently RE-RUNS the statement from the top. This asked sqlite3
    and believed the answer, so step 4 of a two-row result handed back row 1 again
    and sqlite_eof dropped from 1 back to 0. A drain loop still terminated, which
    is why no suite saw it -- but a second pass over the same handle double-counted
    every row, a defensive `if sqlite_step(c@) = 1` re-read a result already
    consumed, and a loop that re-checks an exhausted cursor never ended at all.
    sqlite_reset is the documented way to "re-run the statement from the top", and
    it is now the only way; it clears this latch.

    Latched on SQLITE_DONE ONLY. An rc that is neither ROW nor DONE -- SQLITE_BUSY
    above all -- is a step the caller may legitimately retry, and latching that
    would answer 0 forever for a cursor that was never finished: a new wrong
    answer in place of the old one. }
  if AStmt.Done then
  begin
    AStmt.OnRow := False;
    SetLength(AStmt.RowTypes, 0);
    Exit(0);
  end;
  { THE AUTHORIZER ANSWERED AT PREPARE. SQLITE OPENS THE FILE HERE.

    For an ATTACH those are two different moments, and between them a script may
    move either base a relative name resolves against -- dir_setcurrent, or
    PRAGMA data_store_directory, which is a process-wide global. Measured on
    3.48.0: prepared in A\sub, stepped from A, `attach '../q2.db'` was authorized
    as A\q2.db and created the file one directory ABOVE A. So the same question is
    asked again now, against the base in force now, before the step that would
    create anything. Empty unless a sandbox was active at prepare, so an
    unsandboxed run and every ordinary cursor pay nothing. }
  if (AStmt.AuthPath <> '') and (not SqlPathAllowed(AStmt.AuthPath, True)) then
  begin
    RefusePath();
    AStmt.OnRow := False;
    SetLength(AStmt.RowTypes, 0);
    Exit(0);
  end;
  AStmt.Stepped := True;
  { VACUUM INTO's callback arrives HERE rather than at prepare, so a refusal can
    land on the step -- and did, reported as sqlite's own "authorization denied"
    (23) instead of this package's words. Cleared before, read after. }
  GAuthDenied := False;
  rc := sqlite3_step(AStmt.StmtPtr);
  SetLength(AStmt.RowTypes, 0);
  if rc = SQLITE_ROW then
  begin
    AStmt.OnRow := True;
    // The types are captured HERE, the moment the row arrives. Reading a column as
    // text converts it in place, so asking afterwards reports the conversion's type
    // rather than the row's -- sqlite_isblob answered 1 before a sqlite_getstr$ and
    // 0 after it, for the same row, with no step in between.
    SetLength(AStmt.RowTypes, sqlite3_column_count(AStmt.StmtPtr));
    for i := 0 to High(AStmt.RowTypes) do
      AStmt.RowTypes[i] := sqlite3_column_type(AStmt.StmtPtr, i);
    Result := 1;
  end
  else
  begin
    AStmt.OnRow := False;
    Result := 0;
    if rc = SQLITE_DONE then
      AStmt.Done := True
    else if GAuthDenied then
      RefusePath()
    else
    begin
      GLastErr := rc;
      SetErrFromDb(AStmt.Owner);
    end;
  end;
end;

{ A column value as a Phosphor number: an integer stays an integer. }
function ColNum(AStmt: TSqliteStmt; ACol: Integer): TValue;
begin
  if sqlite3_column_type(AStmt.StmtPtr, ACol) = SQLITE_INTEGER then
    Result := ValInt(sqlite3_column_int64(AStmt.StmtPtr, ACol))
  else
    Result := ValDouble(sqlite3_column_double(AStmt.StmtPtr, ACol));
end;

{ The 0-based C column index for a 1-based BASIC name lookup, or -1 if absent. }
function FindCol(AStmt: TSqliteStmt; const AName: String): Integer;
var i, cnt: Integer;
begin
  Result := -1;
  cnt := sqlite3_column_count(AStmt.StmtPtr);
  for i := 0 to cnt - 1 do
    if SameText(PtrStr(sqlite3_column_name(AStmt.StmtPtr, i)), AName) then
      Exit(i);
end;

{ Double-quote-wrap a SQL identifier (a table name), doubling internal quotes. }
function QuoteIdent(const AName: String): String;
begin
  Result := '"' + StringReplace(AName, '"', '""', [rfReplaceAll]) + '"';
end;

function EscapeSql(const S: String): String;
begin
  Result := StringReplace(S, '''', '''''', [rfReplaceAll]);
end;

{ Bind one fpjson node to a 1-based sqlite parameter. }
procedure BindNode(AStmt: psqlite3_stmt; AParam: Integer; ANode: TJSONData);
var s: String;
begin
  case ANode.JSONType of
    jtNumber:
      if TJSONNumber(ANode).NumberType = ntInteger then
        sqlite3_bind_int64(AStmt, AParam, ANode.AsInt64)
      else
        sqlite3_bind_double(AStmt, AParam, ANode.AsFloat);
    jtNull:
      sqlite3_bind_null(AStmt, AParam);
    jtBoolean:
      sqlite3_bind_int64(AStmt, AParam, Ord(ANode.AsBoolean));
  else
    begin
      s := ANode.AsString;
      sqlite3_bind_text(AStmt, AParam, PAnsiChar(s), Length(s),
        sqlite3_destructor_type(SQLITE_TRANSIENT));
    end;
  end;
end;

{ The current row as a fresh JSON object (empty when the cursor is not on a row). }
function BuildRowObject(AStmt: TSqliteStmt): TJSONObject;
var i, cnt: Integer; nm: String;
begin
  Result := TJSONObject.Create();
  if not AStmt.OnRow then Exit;
  cnt := sqlite3_column_count(AStmt.StmtPtr);
  for i := 0 to cnt - 1 do
  begin
    nm := PtrStr(sqlite3_column_name(AStmt.StmtPtr, i));
    case sqlite3_column_type(AStmt.StmtPtr, i) of
      SQLITE_INTEGER: Result.Add(nm, sqlite3_column_int64(AStmt.StmtPtr, i));
      SQLITE_FLOAT:   Result.Add(nm, sqlite3_column_double(AStmt.StmtPtr, i));
      SQLITE_NULL:    Result.Add(nm, TJSONNull.Create());
    else
      Result.Add(nm, ColStr(AStmt.StmtPtr, i));
    end;
  end;
end;

function OpenDatabase(const APath: String): TValue;
var p: psqlite3; rc: Integer; full: String;
begin
  Result := ValHandle(0);
  if not GReady then Exit;
  { THE GUARD LIVES HERE, not only in the registered function, so every caller is
    covered including any added later. ':memory:' is not a path -- sqlite reads it
    as "no file at all" -- so it is the one name that bypasses the check without
    touching a disk.

    It asks the SAME question the authorizer asks, through the same resolver, and
    for the same reason: sqlite3_open resolves a relative name through the VFS
    too, so a data directory pointed back at the root turned sqlite_open@'s own
    argument into a file one level outside it. Judging the name the process's
    working directory spells was never judging the file that gets created.

    '' is refused here where SQL allows it: inside a statement it names SQLite's
    anonymous scratch database, but as an ARGUMENT it is a path a program
    computed by accident, and IsPerilousPath has refused it since the day a
    confined run wrote into C:\Dev. }
  if (APath <> ':memory:') and
     ((APath = '') or (not SqlTarget(APath, True, full))
                   or (not SandboxAllows(full, puWrite))) then
  begin
    RefusePath();
    Exit;
  end;
  p := nil;
  rc := sqlite3_open(PAnsiChar(APath), @p);
  if (rc <> SQLITE_OK) or (p = nil) then
  begin
    GLastErr := rc;
    if p <> nil then
    begin
      GLastMsg := PtrStr(sqlite3_errmsg(p));
      sqlite3_close(p);
    end;
    Exit;
  end;
  { AND THE SECOND DOOR, BEFORE ANY SQL CAN RUN. The check above bounds the file
    this handle is opened ON; every other file it can reach is named inside a
    statement -- ATTACH, VACUUM INTO -- where an argument gate never looks. The
    authorizer is SQLite's own parser answering that question, so it goes on here,
    on EVERY connection including ':memory:' (the escape that was reported began
    at sqlite_open@() with no argument at all). }
  if not InstallAuthorizer(p) then
  begin
    sqlite3_close(p);
    GLastErr := 14;   // SQLITE_CANTOPEN
    GLastMsg := 'refused: this SQLite build has no authorizer, so a sandboxed ' +
                'host cannot bound the files SQL names';
    Exit;
  end;
  Result := ValHandle(RegisterHandle(TSqliteDb.Create(p, APath)));
end;

// --- connection -------------------------------------------------------------
function f_available(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(GReady)); end;

function f_open_mem(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := OpenDatabase(':memory:'); end;

{ A DATABASE IS A FILE. This package asked the gate nowhere, and
  check-sandbox.py could not see it: sqlite3_open is a C call, not one of the
  Pascal primitives the gate scans for. A run confined by --sandbox created an
  8KB database in C:\Dev on 2026-09-06 while an ordinary write to the same
  directory was refused.

  puWrite, not puRead: sqlite3_open CREATES the file when it is not there, so a
  read-only-looking call is a write. sqlite_open@ with no argument opens an
  in-memory database and touches nothing, which is why only this arity is
  guarded. }
function f_open(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := OpenDatabase(Args[0].Str);   // which asks the gate
end;

function f_close(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  // TYPE-CHECKED before freeing. This used to free whatever the handle named, so
  // sqlite_close(o@) on a JSON object returned 1 and destroyed it -- a
  // use-after-free waiting for the next read of o@. Lenient about a stale handle
  // (0, like every other free), strict about freeing something it does not own.
  if not GetDb(Args[0].Hnd, db) then Exit(ValInt(0));
  Result := ValInt(Ord(FreeHandle(Args[0].Hnd)));   // the destructor closes the db
end;

function f_isopen(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(Ord(GetDb(Args[0].Hnd, db)));
end;

function f_path(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValStr('');
  if GetDb(Args[0].Hnd, db) then Result := ValStr(db.Path);
end;

function f_version(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if GReady then Result := ValStr(PtrStr(sqlite3_libversion())) else Result := ValStr('');
end;

// --- simple query -----------------------------------------------------------
function f_exec(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  Result := ValInt(Ord(ExecSql(db, Args[1].Str)));
end;

function f_scalar_str(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; st: psqlite3_stmt;
begin
  Err := NoError();
  Result := ValStr('');
  if not GetDb(Args[0].Hnd, db) then Exit;
  if not PrepareStmt(db, Args[1].Str, st) then Exit;
  if sqlite3_step(st) = SQLITE_ROW then Result := ValStr(ColStr(st, 0));
  { A path refused inside the SQL can be refused at the STEP rather than at the
    prepare -- VACUUM INTO's callback arrives there -- and this route reported
    nothing at all for it: no code, no message, an empty answer. PrepareStmt
    cleared the flag just above, and only the refusal is recorded, so an ordinary
    step failure still answers exactly what it always answered. }
  if GAuthDenied then RefusePath();
  sqlite3_finalize(st);
end;

function f_scalar_num(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; st: psqlite3_stmt;
begin
  Err := NoError();
  Result := ValDouble(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  if not PrepareStmt(db, Args[1].Str, st) then Exit;
  if sqlite3_step(st) = SQLITE_ROW then Result := ValDouble(sqlite3_column_double(st, 0));
  { A path refused inside the SQL can be refused at the STEP rather than at the
    prepare -- VACUUM INTO's callback arrives there -- and this route reported
    nothing at all for it: no code, no message, an empty answer. PrepareStmt
    cleared the flag just above, and only the refusal is recorded, so an ordinary
    step failure still answers exactly what it always answered. }
  if GAuthDenied then RefusePath();
  sqlite3_finalize(st);
end;

function f_query_str(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; st: psqlite3_stmt; r, row: String; i, cnt: Integer;
begin
  Err := NoError();
  Result := ValStr('');
  if not GetDb(Args[0].Hnd, db) then Exit;
  if not PrepareStmt(db, Args[1].Str, st) then Exit;
  r := '';
  { A RESULT SET IS A LOOP WITH NO ARGUMENT ON IT. "select * from big" steps a
    row at a time inside one opCall, and neither the SQL text nor anything else in
    hand says how many rows that is -- RULE 2, so each row is charged and the loop
    stops when the run's budget does. (A single sqlite3_step over a
    non-indexed join can itself run for minutes and is NOT interruptible through
    this binding: sqlite3_progress_handler is not among the entry points
    SQLite3Dyn imports. That is stated in scripts/check-budget.py rather than
    left to be discovered.) }
  while sqlite3_step(st) = SQLITE_ROW do
  begin
    row := '';
    cnt := sqlite3_column_count(st);
    for i := 0 to cnt - 1 do
    begin
      if i > 0 then row := row + #9;
      row := row + ColStr(st, i);
    end;
    r := r + row + #10;
    if not BudgetCharge(Int64(1) + Length(row)) then
    begin
      sqlite3_finalize(st);
      Err := BudgetRefusal('sqlite_query$');
      Exit(ValStr(''));
    end;
  end;
  { A path refused inside the SQL can be refused at the STEP rather than at the
    prepare -- VACUUM INTO's callback arrives there -- and this route reported
    nothing at all for it: no code, no message, an empty answer. PrepareStmt
    cleared the flag above and only the first failing step can set it, so the
    loop has already ended by the time this is read. }
  if GAuthDenied then RefusePath();
  sqlite3_finalize(st);
  Result := ValStr(r);
end;

// --- bookkeeping ------------------------------------------------------------
function f_changes(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(0);
  if GetDb(Args[0].Hnd, db) then Result := ValInt(sqlite3_changes(db.DbPtr));
end;

function f_totalchanges(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(0);
  if GetDb(Args[0].Hnd, db) then Result := ValInt(sqlite3_total_changes(db.DbPtr));
end;

function f_lastid(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(0);
  if GetDb(Args[0].Hnd, db) then Result := ValInt(sqlite3_last_insert_rowid(db.DbPtr));
end;

// --- introspection ----------------------------------------------------------
function f_tableexists(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; st: psqlite3_stmt; nm: String;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  if not PrepareStmt(db, 'SELECT 1 FROM sqlite_master WHERE type=''table'' AND name=?', st) then Exit;
  nm := Args[1].Str;
  sqlite3_bind_text(st, 1, PAnsiChar(nm), Length(nm), sqlite3_destructor_type(SQLITE_TRANSIENT));
  if sqlite3_step(st) = SQLITE_ROW then Result := ValInt(1);
  sqlite3_finalize(st);
end;

function f_tables(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; st: psqlite3_stmt; arr: TJSONArray;
begin
  Err := NoError();
  Result := ValHandle(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  arr := TJSONArray.Create();
  if PrepareStmt(db, 'SELECT name FROM sqlite_master WHERE type=''table'' AND ' +
    'name NOT LIKE ''sqlite_%'' ORDER BY name', st) then
  begin
    while sqlite3_step(st) = SQLITE_ROW do
    begin
      // Add(TJSONData): the plain-string array overload re-encodes any byte >= $80,
      // so a table holding accented text came back mojibake.
      arr.Add(TJSONString.Create(ColStr(st, 0)));
      if not BudgetCharge(BudgetUnitsPerStep) then
      begin
        sqlite3_finalize(st);
        Err := BudgetRefusal('sqlite_tables@');
        Exit(ValHandle(JsonRegisterNode(arr, True)));
      end;
    end;
    sqlite3_finalize(st);
  end;
  Result := ValHandle(JsonRegisterNode(arr, True));
end;

function f_columns(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; st: psqlite3_stmt; arr: TJSONArray; o: TJSONObject;
begin
  Err := NoError();
  Result := ValHandle(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  arr := TJSONArray.Create();
  if PrepareStmt(db, 'PRAGMA table_info(' + QuoteIdent(Args[1].Str) + ')', st) then
  begin
    while sqlite3_step(st) = SQLITE_ROW do
    begin
      o := TJSONObject.Create();
      o.Add('name', ColStr(st, 1));
      o.Add('type', ColStr(st, 2));
      o.Add('notnull', sqlite3_column_int64(st, 3));
      o.Add('pk', sqlite3_column_int64(st, 5));
      arr.Add(o);
      if not BudgetCharge(BudgetUnitsPerStep) then
      begin
        sqlite3_finalize(st);
        Err := BudgetRefusal('sqlite_columns@');
        Exit(ValHandle(JsonRegisterNode(arr, True)));
      end;
    end;
    sqlite3_finalize(st);
  end;
  Result := ValHandle(JsonRegisterNode(arr, True));
end;

// --- prepared statements ----------------------------------------------------
function f_prepare(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; st: psqlite3_stmt;
begin
  Err := NoError();
  Result := ValHandle(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  if PrepareStmt(db, Args[1].Str, st) then Result := RegisterStmt(db, st);
end;

function f_step(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt;
begin
  Err := NoError();
  Result := ValInt(0);
  if GetStmt(Args[0].Hnd, s) then Result := ValInt(DoStep(s));
end;

function f_eof(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt;
begin
  Err := NoError();
  Result := ValInt(1);
  if GetStmt(Args[0].Hnd, s) then Result := ValInt(Ord(not s.OnRow));
end;

function f_reset(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  sqlite3_reset(s.StmtPtr);
  s.OnRow := False;
  s.Stepped := False;
  s.Done := False;     // the one call that re-opens an exhausted cursor -- see DoStep
  Result := ValInt(1);
end;

function f_clearbind(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  sqlite3_clear_bindings(s.StmtPtr);
  Result := ValInt(1);
end;

function f_finalize(const Args: array of TValue; out Err: TPhosphorError): TValue;
var st: TSqliteStmt;
begin
  Err := NoError();
  if not GetStmt(Args[0].Hnd, st) then Exit(ValInt(0));   // frees only a statement
  Result := ValInt(Ord(FreeHandle(Args[0].Hnd)));   // frees + revokes the statement id
end;

// --- binding (parameters are 1-based) ---------------------------------------
function f_bindstr(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; v: String;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  v := Args[2].Str;
  sqlite3_bind_text(s.StmtPtr, ArgI32(Args[1]), PAnsiChar(v), Length(v),
    sqlite3_destructor_type(SQLITE_TRANSIENT));
  Result := ValInt(1);
end;

function f_bindnum(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; p: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  p := ArgI32(Args[1]);
  if Args[2].Kind = vkInt then
    sqlite3_bind_int64(s.StmtPtr, p, Args[2].Int)
  else
    sqlite3_bind_double(s.StmtPtr, p, AsDouble(Args[2]));
  Result := ValInt(1);
end;

function f_bindnull(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  sqlite3_bind_null(s.StmtPtr, ArgI32(Args[1]));
  Result := ValInt(1);
end;

function f_bindjson(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; node: TJSONData; obj: TJSONObject; i, p: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  if not JsonNodeFromHandle(Args[1].Hnd, node) then Exit;
  if not (node is TJSONObject) then Exit;
  obj := TJSONObject(node);
  for i := 0 to obj.Count - 1 do
  begin
    // Match by name: a parameter written :key. A key with no such parameter is
    // skipped, exactly as the reference documents.
    p := sqlite3_bind_parameter_index(s.StmtPtr, PAnsiChar(':' + obj.Names[i]));
    if p > 0 then BindNode(s.StmtPtr, p, obj.Items[i]);
  end;
  Result := ValInt(1);
end;

// --- column metadata (columns are 1-based) ----------------------------------
function f_colcount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt;
begin
  Err := NoError();
  Result := ValInt(0);
  if GetStmt(Args[0].Hnd, s) then Result := ValInt(sqlite3_column_count(s.StmtPtr));
end;

function f_colname(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValStr('');
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := ArgI32(Args[1]) - 1;
  if (c >= 0) and (c < sqlite3_column_count(s.StmtPtr)) then
    Result := ValStr(PtrStr(sqlite3_column_name(s.StmtPtr, c)));
end;

function f_colindex(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValInt(0);   // 0 = not found (1-based indices start at 1)
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := FindCol(s, Args[1].Str);
  if c >= 0 then Result := ValInt(c + 1);
end;

function f_coltype(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValInt(SQLITE_NULL);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := ArgI32(Args[1]) - 1;
  if s.OnRow and (c >= 0) and (c < sqlite3_column_count(s.StmtPtr)) then
    if (c >= 0) and (c <= High(s.RowTypes)) then Result := ValInt(s.RowTypes[c])
    else Result := ValInt(sqlite3_column_type(s.StmtPtr, c));
end;

function f_coltypename(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  case ArgI32(Args[0]) of
    SQLITE_INTEGER: Result := ValStr('integer');
    SQLITE_FLOAT:   Result := ValStr('float');
    SQLITE_TEXT:    Result := ValStr('text');
    SQLITE_BLOB:    Result := ValStr('blob');
    SQLITE_NULL:    Result := ValStr('null');
  else
    Result := ValStr('unknown');
  end;
end;

// --- row getters ------------------------------------------------------------
function f_getstr(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValStr('');
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := ArgI32(Args[1]) - 1;
  if s.OnRow and (c >= 0) and (c < sqlite3_column_count(s.StmtPtr)) then
    Result := ValStr(ColStr(s.StmtPtr, c));
end;

function f_getnum(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := ArgI32(Args[1]) - 1;
  if s.OnRow and (c >= 0) and (c < sqlite3_column_count(s.StmtPtr)) then
    Result := ColNum(s, c);
end;

function f_gets(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValStr('');
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := FindCol(s, Args[1].Str);
  if s.OnRow and (c >= 0) then Result := ValStr(ColStr(s.StmtPtr, c));
end;

function f_getn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := FindCol(s, Args[1].Str);
  if s.OnRow and (c >= 0) then Result := ColNum(s, c);
end;

function f_isnull(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValInt(1);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := ArgI32(Args[1]) - 1;
  if s.OnRow and (c >= 0) and (c < sqlite3_column_count(s.StmtPtr)) then
    Result := ValInt(Ord(sqlite3_column_type(s.StmtPtr, c) = SQLITE_NULL));
end;

function f_isn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValInt(1);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := FindCol(s, Args[1].Str);
  if s.OnRow and (c >= 0) then
    Result := ValInt(Ord(sqlite3_column_type(s.StmtPtr, c) = SQLITE_NULL));
end;

function f_isblob(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := ArgI32(Args[1]) - 1;
  if s.OnRow and (c >= 0) and (c < sqlite3_column_count(s.StmtPtr)) then
    if (c >= 0) and (c <= High(s.RowTypes)) then
      Result := ValInt(Ord(s.RowTypes[c] = SQLITE_BLOB))
    else Result := ValInt(Ord(sqlite3_column_type(s.StmtPtr, c) = SQLITE_BLOB));
end;

// --- rows as JSON -----------------------------------------------------------
function f_row(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt;
begin
  Err := NoError();
  Result := ValHandle(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  Result := ValHandle(JsonRegisterNode(BuildRowObject(s), True));
end;

function f_fetchone(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt;
begin
  Err := NoError();
  Result := ValHandle(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  DoStep(s);   // advance, then hand back the new current row (empty object at end)
  Result := ValHandle(JsonRegisterNode(BuildRowObject(s), True));
end;

function f_fetchall(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; arr: TJSONArray;
begin
  Err := NoError();
  Result := ValHandle(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  arr := TJSONArray.Create();
  if not s.Stepped then DoStep(s);   // a fresh cursor: land on the first row
  // CHARGED PER ROW, like sqlite_query$ and sqlite_tables@ beside it. This loop
  // was the one member of the family left out: it accumulates EVERY row of a
  // query into a JSON array inside one opCall, so a select over a large table
  // built the whole answer with no ceiling able to look at it. The refusal is
  // reported rather than swallowed, because a short array is a wrong answer.
  while s.OnRow do
  begin
    if not BudgetCharge(BudgetUnitsPerStep) then
    begin
      arr.Free;
      Err := BudgetRefusal('sqlite_fetchall@');
      Exit(ValHandle(0));
    end;
    arr.Add(BuildRowObject(s));
    DoStep(s);
  end;
  Result := ValHandle(JsonRegisterNode(arr, True));
end;

// --- JSON write path --------------------------------------------------------
function f_insertjson(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; node: TJSONData; obj: TJSONObject; st: psqlite3_stmt;
    cols, vals, sql: String; i: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  if not JsonNodeFromHandle(Args[2].Hnd, node) then Exit;
  if not (node is TJSONObject) then Exit;
  obj := TJSONObject(node);
  if obj.Count = 0 then Exit;
  cols := '';
  vals := '';
  for i := 0 to obj.Count - 1 do
  begin
    if i > 0 then begin cols := cols + ', '; vals := vals + ', '; end;
    cols := cols + QuoteIdent(obj.Names[i]);
    vals := vals + '?';
  end;
  sql := 'INSERT INTO ' + QuoteIdent(Args[1].Str) + ' (' + cols + ') VALUES (' + vals + ')';
  if not PrepareStmt(db, sql, st) then Exit;
  for i := 0 to obj.Count - 1 do
    BindNode(st, i + 1, obj.Items[i]);
  if sqlite3_step(st) = SQLITE_DONE then Result := ValInt(sqlite3_changes(db.DbPtr))
  else SetErrFromDb(db);
  sqlite3_finalize(st);
end;

function f_updatejson(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; node: TJSONData; obj: TJSONObject; st: psqlite3_stmt;
    sets, sql, where: String; i: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  if not JsonNodeFromHandle(Args[2].Hnd, node) then Exit;
  if not (node is TJSONObject) then Exit;
  obj := TJSONObject(node);
  if obj.Count = 0 then Exit;
  sets := '';
  for i := 0 to obj.Count - 1 do
  begin
    if i > 0 then sets := sets + ', ';
    sets := sets + QuoteIdent(obj.Names[i]) + ' = ?';
  end;
  where := Args[3].Str;
  sql := 'UPDATE ' + QuoteIdent(Args[1].Str) + ' SET ' + sets;
  if where <> '' then sql := sql + ' WHERE ' + where;
  if not PrepareStmt(db, sql, st) then Exit;
  for i := 0 to obj.Count - 1 do
    BindNode(st, i + 1, obj.Items[i]);
  if sqlite3_step(st) = SQLITE_DONE then Result := ValInt(sqlite3_changes(db.DbPtr))
  else SetErrFromDb(db);
  sqlite3_finalize(st);
end;

// --- transactions -----------------------------------------------------------
function f_begin(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(0);
  if GetDb(Args[0].Hnd, db) then Result := ValInt(Ord(ExecSql(db, 'BEGIN')));
end;

function f_commit(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(0);
  if GetDb(Args[0].Hnd, db) then Result := ValInt(Ord(ExecSql(db, 'COMMIT')));
end;

function f_rollback(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(0);
  if GetDb(Args[0].Hnd, db) then Result := ValInt(Ord(ExecSql(db, 'ROLLBACK')));
end;

function f_intrans(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(0);
  if GetDb(Args[0].Hnd, db) then
    Result := ValInt(Ord(sqlite3_get_autocommit(db.DbPtr) = 0));
end;

// --- text helpers -----------------------------------------------------------
function f_escape(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(EscapeSql(Args[0].Str)); end;

function f_quote(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr('''' + EscapeSql(Args[0].Str) + ''''); end;

// --- errors -----------------------------------------------------------------
function f_error(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(GLastErr); end;

function f_errormsg(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(GLastMsg); end;

function f_strerror(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if GReady then Result := ValStr(PtrStr(sqlite3_errstr(ArgI32(Args[0]))))
  else Result := ValStr('');
end;

function f_clearerror(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); GLastErr := 0; GLastMsg := ''; Result := ValInt(0); end;

// --- maintenance ------------------------------------------------------------
function f_backup(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; full: String;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  { A PATH ARGUMENT IS A PATH ARGUMENT, whichever language spends it. This one
    was pasted into VACUUM INTO with no gate at all, so a confined script wrote a
    complete copy of its database -- every row -- anywhere on the disk, while
    file_writealltext to the same directory answered 0. The authorizer would
    catch it now as well (VACUUM INTO reaches it as SQLITE_ATTACH), but the
    argument is checked here too, where sqlite_open@ checks its own: an
    argument-shaped hole gets an argument-shaped guard, and the refusal then
    carries this package's words rather than sqlite's.

    Nothing automatic will notice if this line is deleted. check-sandbox.py
    scans for OS primitives and its only SQLite one is the literal string
    'sqlite3_open'; this routine contains no primitive at all, so the gate does
    not even consider it and reports clean either way. That is what
    tests/packages/10_sqlite_sandbox.bas is for.

    Resolved through the shared rule before it is judged: the destination goes
    into VACUUM INTO, which SQLite resolves through its VFS, so a gate that
    resolved it against the process's working directory instead answered about a
    different file the moment a data directory was set -- measured, 8192 bytes
    outside the root. '' is refused here for the reason OpenDatabase gives. }
  if (Args[1].Str = '') or (not SqlTarget(Args[1].Str, True, full))
                        or (not SandboxAllows(full, puWrite)) then
  begin
    RefusePath();
    Exit;
  end;
  // VACUUM INTO writes a fresh, self-contained copy of the whole database.
  Result := ValInt(Ord(ExecSql(db, 'VACUUM INTO ''' + EscapeSql(Args[1].Str) + '''')));
end;

function f_vacuum(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(0);
  if GetDb(Args[0].Hnd, db) then Result := ValInt(Ord(ExecSql(db, 'VACUUM')));
end;

function SqliteAvailable: Boolean;
begin
  Result := GReady;
end;

procedure RegisterSqliteFuncs(Reg: TPhosphorRegistry);
begin
  // connection
  Reg.Add('sqlite_available:',      @f_available);
  Reg.Add('sqlite_open@:',          @f_open_mem);
  Reg.Add('sqlite_open@:$',         @f_open);
  Reg.Add('sqlite_close:@',         @f_close);
  Reg.Add('sqlite_isopen:@',        @f_isopen);
  Reg.Add('sqlite_path$:@',         @f_path);
  Reg.Add('sqlite_version$:',       @f_version);
  // simple query
  Reg.Add('sqlite_exec:@$',         @f_exec);
  Reg.Add('sqlite_scalar$:@$',      @f_scalar_str);
  Reg.Add('sqlite_scalar:@$',       @f_scalar_num);
  Reg.Add('sqlite_query$:@$',       @f_query_str);
  // bookkeeping
  Reg.Add('sqlite_changes:@',       @f_changes);
  Reg.Add('sqlite_totalchanges:@',  @f_totalchanges);
  Reg.Add('sqlite_lastid:@',        @f_lastid);
  // introspection
  Reg.Add('sqlite_tableexists:@$',  @f_tableexists);
  Reg.Add('sqlite_tables@:@',       @f_tables);
  Reg.Add('sqlite_columns@:@$',     @f_columns);
  // prepared statements / cursors
  Reg.Add('sqlite_prepare@:@$',     @f_prepare);
  Reg.Add('sqlite_query@:@$',       @f_prepare);   // a cursor is a prepared SELECT
  Reg.Add('sqlite_step:@',          @f_step);
  Reg.Add('sqlite_eof:@',           @f_eof);
  Reg.Add('sqlite_reset:@',         @f_reset);
  Reg.Add('sqlite_clearbind:@',     @f_clearbind);
  Reg.Add('sqlite_finalize:@',      @f_finalize);
  // binding (parameters 1-based)
  Reg.Add('sqlite_bindstr:@n$',     @f_bindstr);
  Reg.Add('sqlite_bindnum:@nn',     @f_bindnum);
  Reg.Add('sqlite_bindnull:@n',     @f_bindnull);
  Reg.Add('sqlite_bindjson:@@',     @f_bindjson);
  // column metadata (columns 1-based)
  Reg.Add('sqlite_colcount:@',      @f_colcount);
  Reg.Add('sqlite_colname$:@n',     @f_colname);
  Reg.Add('sqlite_colindex:@$',     @f_colindex);
  Reg.Add('sqlite_coltype:@n',      @f_coltype);
  Reg.Add('sqlite_coltypename$:n',  @f_coltypename);
  // row getters
  Reg.Add('sqlite_getstr$:@n',      @f_getstr);
  Reg.Add('sqlite_getnum:@n',       @f_getnum);
  Reg.Add('sqlite_gets$:@$',        @f_gets);
  Reg.Add('sqlite_getn:@$',         @f_getn);
  Reg.Add('sqlite_isnull:@n',       @f_isnull);
  Reg.Add('sqlite_isn:@$',          @f_isn);
  Reg.Add('sqlite_isblob:@n',       @f_isblob);
  // rows as JSON
  Reg.Add('sqlite_row@:@',          @f_row);
  Reg.Add('sqlite_fetchone@:@',     @f_fetchone);
  Reg.Add('sqlite_fetchall@:@',     @f_fetchall);
  // JSON write path
  Reg.Add('sqlite_insertjson:@$@',  @f_insertjson);
  Reg.Add('sqlite_updatejson:@$@$', @f_updatejson);
  // transactions
  Reg.Add('sqlite_begin:@',         @f_begin);
  Reg.Add('sqlite_commit:@',        @f_commit);
  Reg.Add('sqlite_rollback:@',      @f_rollback);
  Reg.Add('sqlite_intrans:@',       @f_intrans);
  // text helpers
  Reg.Add('sqlite_escape$:$',       @f_escape);
  Reg.Add('sqlite_quote$:$',        @f_quote);
  // errors
  Reg.Add('sqlite_error:',          @f_error);
  Reg.Add('sqlite_errormsg$:',      @f_errormsg);
  Reg.Add('sqlite_strerror$:n',     @f_strerror);
  Reg.Add('sqlite_clearerror:',     @f_clearerror);
  // maintenance
  Reg.Add('sqlite_backup:@$',       @f_backup);
  Reg.Add('sqlite_vacuum:@',        @f_vacuum);
end;

initialization
  // Load the SQLite runtime library once. On a box without it TryInitializeSqlite
  // returns -1 without raising: GReady stays False,
  // sqlite_available() answers 0, and the package test skips. (This comment used
  // to name "this Windows dev machine" as such a box. It is not one -- the loader
  // finds a sqlite3.dll on the PATH here, and the RUNNER's path guess was what
  // could not see it.) We do NOT release
  // it at finalization -- the OS reclaims it at process exit, and releasing early
  // would unload the library before PhosphorHandles frees any lingering database
  // (whose destructor calls sqlite3_close).
  GReady := TryInitializeSqlite('') > 0;

end.
