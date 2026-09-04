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
******************************************************************************}
unit PhosphorSqliteLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, fpjson, SQLite3Dyn,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorJsonLib;

procedure RegisterSqliteFuncs(Reg: TPhosphorRegistry);

implementation

var
  GReady: Boolean = False;   // the SQLite runtime library loaded at unit init
  GLastErr: Integer = 0;     // module-level last-error, the ioerror/valcode pattern
  GLastMsg: String = '';

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
  rc := sqlite3_exec(ADb.DbPtr, PAnsiChar(ASql), nil, nil, @msg);
  if msg <> nil then sqlite3_free(msg);
  Result := (rc = SQLITE_OK);
  if not Result then SetErrFromDb(ADb);
end;

function PrepareStmt(ADb: TSqliteDb; const ASql: String; out AStmt: psqlite3_stmt): Boolean;
var rc: Integer;
begin
  AStmt := nil;
  if (ADb = nil) or (ADb.DbPtr = nil) then Exit(False);
  rc := sqlite3_prepare_v2(ADb.DbPtr, PAnsiChar(ASql), -1, @AStmt, nil);
  Result := (rc = SQLITE_OK) and (AStmt <> nil);
  if not Result then
  begin
    SetErrFromDb(ADb);
    if AStmt <> nil then begin sqlite3_finalize(AStmt); AStmt := nil; end;
  end;
end;

{ Register a freshly prepared statement as a child of its database. }
function RegisterStmt(AOwner: TSqliteDb; AStmt: psqlite3_stmt): TValue;
var s: TSqliteStmt;
begin
  s := TSqliteStmt.Create(AOwner, AStmt);
  s.HandleId := RegisterHandle(s);
  AOwner.Children.Add(s);
  Result := ValHandle(s.HandleId);
end;

{ Step, tracking the on-row / stepped state. Returns 1 for a row, 0 otherwise. }
function DoStep(AStmt: TSqliteStmt): Integer;
var rc: Integer;
begin
  AStmt.Stepped := True;
  rc := sqlite3_step(AStmt.StmtPtr);
  if rc = SQLITE_ROW then
  begin
    AStmt.OnRow := True;
    Result := 1;
  end
  else
  begin
    AStmt.OnRow := False;
    Result := 0;
    if rc <> SQLITE_DONE then
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
      Result.Add(nm, PtrStr(sqlite3_column_text(AStmt.StmtPtr, i)));
    end;
  end;
end;

function OpenDatabase(const APath: String): TValue;
var p: psqlite3; rc: Integer;
begin
  Result := ValHandle(0);
  if not GReady then Exit;
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
  Result := ValHandle(RegisterHandle(TSqliteDb.Create(p, APath)));
end;

// --- connection -------------------------------------------------------------
function f_available(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(GReady)); end;

function f_open_mem(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := OpenDatabase(':memory:'); end;

function f_open(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := OpenDatabase(Args[0].Str); end;

function f_close(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
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
  if sqlite3_step(st) = SQLITE_ROW then Result := ValStr(PtrStr(sqlite3_column_text(st, 0)));
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
  while sqlite3_step(st) = SQLITE_ROW do
  begin
    row := '';
    cnt := sqlite3_column_count(st);
    for i := 0 to cnt - 1 do
    begin
      if i > 0 then row := row + #9;
      row := row + PtrStr(sqlite3_column_text(st, i));
    end;
    r := r + row + #10;
  end;
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
      arr.Add(PtrStr(sqlite3_column_text(st, 0)));
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
      o.Add('name', PtrStr(sqlite3_column_text(st, 1)));
      o.Add('type', PtrStr(sqlite3_column_text(st, 2)));
      o.Add('notnull', sqlite3_column_int64(st, 3));
      o.Add('pk', sqlite3_column_int64(st, 5));
      arr.Add(o);
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
begin
  Err := NoError();
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
  sqlite3_bind_text(s.StmtPtr, Round(AsDouble(Args[1])), PAnsiChar(v), Length(v),
    sqlite3_destructor_type(SQLITE_TRANSIENT));
  Result := ValInt(1);
end;

function f_bindnum(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; p: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  p := Round(AsDouble(Args[1]));
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
  sqlite3_bind_null(s.StmtPtr, Round(AsDouble(Args[1])));
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
  c := Round(AsDouble(Args[1])) - 1;
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
  c := Round(AsDouble(Args[1])) - 1;
  if s.OnRow and (c >= 0) and (c < sqlite3_column_count(s.StmtPtr)) then
    Result := ValInt(sqlite3_column_type(s.StmtPtr, c));
end;

function f_coltypename(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  case Round(AsDouble(Args[0])) of
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
  c := Round(AsDouble(Args[1])) - 1;
  if s.OnRow and (c >= 0) and (c < sqlite3_column_count(s.StmtPtr)) then
    Result := ValStr(PtrStr(sqlite3_column_text(s.StmtPtr, c)));
end;

function f_getnum(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: TSqliteStmt; c: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetStmt(Args[0].Hnd, s) then Exit;
  c := Round(AsDouble(Args[1])) - 1;
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
  if s.OnRow and (c >= 0) then Result := ValStr(PtrStr(sqlite3_column_text(s.StmtPtr, c)));
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
  c := Round(AsDouble(Args[1])) - 1;
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
  c := Round(AsDouble(Args[1])) - 1;
  if s.OnRow and (c >= 0) and (c < sqlite3_column_count(s.StmtPtr)) then
    Result := ValInt(Ord(sqlite3_column_type(s.StmtPtr, c) = SQLITE_BLOB));
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
  while s.OnRow do
  begin
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
  if GReady then Result := ValStr(PtrStr(sqlite3_errstr(Round(AsDouble(Args[0])))))
  else Result := ValStr('');
end;

function f_clearerror(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); GLastErr := 0; GLastMsg := ''; Result := ValInt(0); end;

// --- maintenance ------------------------------------------------------------
function f_backup(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
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
  // Load the SQLite runtime library once. On a box without it (this Windows dev
  // machine) TryInitializeSqlite returns -1 without raising: GReady stays False,
  // sqlite_available() answers 0, and the package test skips. We do NOT release
  // it at finalization -- the OS reclaims it at process exit, and releasing early
  // would unload the library before PhosphorHandles frees any lingering database
  // (whose destructor calls sqlite3_close).
  GReady := TryInitializeSqlite('') > 0;

end.
