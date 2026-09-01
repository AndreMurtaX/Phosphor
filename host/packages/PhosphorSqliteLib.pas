{******************************************************************************
  Phosphor BASIC -- SQLite (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  An opt-in package (host/packages/, RegisterSqliteFuncs) over FPC's SQLdb SQLite
  driver. Unlike base64/zip it needs an EXTERNAL runtime library (sqlite3.dll on
  Windows, libsqlite3.so on Linux); the FPC units compile everywhere, so the
  package is always buildable, but the functions only work where the library is
  installed -- sqlite_available() reports whether it is, and the test suite skips
  this package where it is not.

    sqlite_available()             1 if the SQLite library loaded, else 0
    sqlite_open@(path$)            open a database (":memory:" for in-memory) -> handle
    sqlite_exec(db@, sql$)         run a non-query statement (CREATE/INSERT/...) -> 1/0
    sqlite_scalar$(db@, sql$)      the first column of the first row, as text
    sqlite_scalar(db@, sql$)       ... as a number
    sqlite_query$(db@, sql$)       all rows: columns tab-joined, rows newline-joined
    sqlite_close(db@)              close and free the database

  A cursor never escapes to BASIC, so there is no multi-handle lifetime to manage:
  each query opens a private result set, reads it, and frees it inside the call.
******************************************************************************}
unit PhosphorSqliteLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, DB, SQLDB, SQLite3Conn,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

procedure RegisterSqliteFuncs(Reg: TPhosphorRegistry);

implementation

type
  { A database handle: the connection and its transaction, freed together. }
  TSqliteDb = class
    Conn: TSQLite3Connection;
    Trans: TSQLTransaction;
    constructor Open(const APath: String);
    destructor Destroy; override;
  end;

constructor TSqliteDb.Open(const APath: String);
begin
  Conn := TSQLite3Connection.Create(nil);
  Trans := TSQLTransaction.Create(nil);
  Conn.Transaction := Trans;
  Conn.DatabaseName := APath;
  Conn.Open;
end;

destructor TSqliteDb.Destroy;
begin
  try if Conn.Connected then Conn.Close; except end;
  Trans.Free;
  Conn.Free;
  inherited Destroy;
end;

function GetDb(AId: Int64; out ADb: TSqliteDb): Boolean;
var o: TObject;
begin
  o := HandleObj(AId);
  Result := o is TSqliteDb;
  if Result then ADb := TSqliteDb(o) else ADb := nil;
end;

function NewQuery(ADb: TSqliteDb; const ASql: String): TSQLQuery;
begin
  Result := TSQLQuery.Create(nil);
  Result.DataBase := ADb.Conn;
  Result.Transaction := ADb.Trans;
  Result.SQL.Text := ASql;
end;

function f_available(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError;
  try
    db := TSqliteDb.Open(':memory:');
    db.Free;
    Result := ValInt(1);
  except
    Result := ValInt(0);   // the SQLite library is not installed
  end;
end;

function f_open(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  try
    Result := ValHandle(RegisterHandle(TSqliteDb.Open(Args[0].Str)));
  except
    Result := ValHandle(0);
  end;
end;

function f_exec(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb;
begin
  Err := NoError;
  Result := ValInt(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  try
    if not db.Trans.Active then db.Trans.StartTransaction;
    db.Conn.ExecuteDirect(Args[1].Str);
    db.Trans.Commit;
    Result := ValInt(1);
  except
    Result := ValInt(0);
  end;
end;

function f_scalar_str(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; q: TSQLQuery;
begin
  Err := NoError;
  Result := ValStr('');
  if not GetDb(Args[0].Hnd, db) then Exit;
  q := NewQuery(db, Args[1].Str);
  try
    try q.Open; if not q.EOF then Result := ValStr(q.Fields[0].AsString); q.Close; except end;
  finally
    q.Free;
  end;
end;

function f_scalar_num(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; q: TSQLQuery;
begin
  Err := NoError;
  Result := ValDouble(0);
  if not GetDb(Args[0].Hnd, db) then Exit;
  q := NewQuery(db, Args[1].Str);
  try
    try q.Open; if not q.EOF then Result := ValDouble(q.Fields[0].AsFloat); q.Close; except end;
  finally
    q.Free;
  end;
end;

function f_query_str(const Args: array of TValue; out Err: TPhosphorError): TValue;
var db: TSqliteDb; q: TSQLQuery; r, row: String; i: Integer;
begin
  Err := NoError;
  Result := ValStr('');
  if not GetDb(Args[0].Hnd, db) then Exit;
  q := NewQuery(db, Args[1].Str);
  try
    try
      q.Open;
      r := '';
      while not q.EOF do
      begin
        row := '';
        for i := 0 to q.Fields.Count - 1 do
        begin
          if i > 0 then row := row + #9;
          row := row + q.Fields[i].AsString;
        end;
        r := r + row + #10;
        q.Next;
      end;
      q.Close;
      Result := ValStr(r);
    except end;
  finally
    q.Free;
  end;
end;

function f_close(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValInt(Ord(FreeHandle(Args[0].Hnd)));   // the destructor closes the db
end;

procedure RegisterSqliteFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('sqlite_available:',  @f_available);
  Reg.Add('sqlite_open@:$',     @f_open);
  Reg.Add('sqlite_exec:@$',     @f_exec);
  Reg.Add('sqlite_scalar$:@$',  @f_scalar_str);
  Reg.Add('sqlite_scalar:@$',   @f_scalar_num);
  Reg.Add('sqlite_query$:@$',   @f_query_str);
  Reg.Add('sqlite_close:@',     @f_close);
end;

end.
