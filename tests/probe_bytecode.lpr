{******************************************************************************
  probe_bytecode -- a Pascal test of the .pbc on-disk bytecode (phase-3 step 4)

  Compiles a source to bytecode in memory, reads it back, and asserts that running
  the bytecode produces BYTE-IDENTICAL output to running the source directly -- the
  proof that serialization loses nothing. Then it corrupts the version byte and the
  magic and asserts each is REFUSED OUT LOUD (a non-zero result with a message), the
  guard the frozen format exists to provide.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail to
  corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_bytecode;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  Classes, SysUtils,
  PhosphorValue, PhosphorErrors, PhosphorOpcodes, PhosphorCompiler,
  PhosphorBytecode, PhosphorEngine;

type
  TCollector = class
    Text: String;
    procedure Output(const AText: String);
  end;

procedure TCollector.Output(const AText: String);
begin
  Text := Text + AText;
end;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

{ Compile ASource and serialize it to a rewound byte stream. }
function CompileToBytes(const ASource: String): TBytesStream;
var
  comp: TPhosphorCompiler;
  prog: TProgram;
begin
  Result := nil;
  comp := TPhosphorCompiler.Create();
  try
    if not comp.Compile(ASource, prog) then Exit;
  finally
    comp.Free;
  end;
  Result := TBytesStream.Create();
  WriteProgram(Result, prog);
  prog.Free;
  Result.Position := 0;
end;

function RunSource(const ASource: String): String;
var eng: TPhosphorEngine; col: TCollector;
begin
  eng := TPhosphorEngine.Create();
  col := TCollector.Create();
  try
    eng.OnOutput := @col.Output;
    eng.Run(ASource);
    Result := col.Text;
  finally
    eng.Free; col.Free;
  end;
end;

function RunBytes(AStream: TStream; out ARc: Integer; out AMsg: String): String;
var eng: TPhosphorEngine; col: TCollector;
begin
  eng := TPhosphorEngine.Create();
  col := TCollector.Create();
  try
    eng.OnOutput := @col.Output;
    AStream.Position := 0;
    ARc := eng.RunBytecode(AStream);
    AMsg := eng.ErrorMessage;
    Result := col.Text;
  finally
    eng.Free; col.Free;
  end;
end;

procedure CheckRoundTrip(const AName, ASource: String);
var bytes: TBytesStream; fromSrc, fromBc, msg: String; rc: Integer;
begin
  fromSrc := RunSource(ASource);
  bytes := CompileToBytes(ASource);
  if bytes = nil then begin Report(False, AName + ' (compiled)'); Exit; end;
  try
    fromBc := RunBytes(bytes, rc, msg);
    Report((rc = 0) and (Length(fromSrc) > 0) and (fromSrc = fromBc) and (not ProveFail), AName);
  finally
    bytes.Free;
  end;
end;

procedure CheckRefusal(const AName, ASource: String; ACorruptAt: Integer; ANewByte: Byte);
var bytes: TBytesStream; msg, dummy: String; rc: Integer;
begin
  bytes := CompileToBytes(ASource);
  if bytes = nil then begin Report(False, AName + ' (compiled)'); Exit; end;
  try
    bytes.Bytes[ACorruptAt] := ANewByte;   // sabotage one header byte
    dummy := RunBytes(bytes, rc, msg);
    // refused (non-zero) with a message, and no output was produced
    Report((rc <> 0) and (Length(msg) > 0) and (dummy = ''), AName);
  finally
    bytes.Free;
  end;
end;

const
  Rich =
    'data 10, 20, 30'                                          + #10 +
    'function dbl(n)'                                          + #10 +
    '  return n * 2'                                           + #10 +
    'end function'                                             + #10 +
    'for i = 1 to 3'                                           + #10 +
    '  read v'                                                 + #10 +
    '  println "item " + str$(i) + " = " + str$(dbl(v))'       + #10 +
    'next'                                                     + #10 +
    'println "done: " + str$(2 + 3 * 4)'                       + #10;
  Simple = 'println "hello"' + #10 + 'println 42 * 10' + #10;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  CheckRoundTrip('round-trip: a rich program (data/read/func/for/strings)', Rich);
  CheckRoundTrip('round-trip: a simple program', Simple);

  // The header is 3 magic bytes, then version (index 3), then the opcode-set byte.
  CheckRefusal('refuse: a wrong version byte',  Simple, 3, 99);
  CheckRefusal('refuse: a bad magic byte',      Simple, 0, Ord('X'));

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
