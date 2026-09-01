{******************************************************************************
  Phosphor BASIC -- on-disk bytecode (.pbc) reader and writer

  MIT License. Copyright (c) 2026 Andre Murta.

  Serializes a compiled TProgram to a stream and reads it back, so a script can be
  compiled once (`phosphor compile a.bas a.pbc`) and run later without the lexer or
  compiler. The format is EXPLICITLY little-endian (NtoLE/LEToN), with a fixed 8-byte
  Double, so the same .pbc runs on the Windows and Linux x86-64 targets alike.

  Frozen decisions (decisions.md, "On-disk bytecode") honoured here:
    * Opcodes carry explicit append-only numbers -- so a stored opcode byte means
      the same instruction on load. The header records the FORMAT VERSION and the
      highest opcode number; a mismatch on either is REFUSED OUT LOUD, never
      executed as the wrong opcodes.
    * TInstr stores Op/A/B/Line only (its run-time proc is derived, never written).
    * The constant pool is an explicit indexable structure (consts serialize in
      index order and reload to the same indices).

  This unit does no file I/O of its own -- it works on a TStream the host provides
  (a TFileStream for a .pbc, a TBytesStream in memory) -- and stays host-agnostic;
  the boundary check passes.
******************************************************************************}
unit PhosphorBytecode;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  Classes, SysUtils, PhosphorValue, PhosphorOpcodes;

const
  PBC_MAGIC   = 'PBC';   // 3 bytes at the start of every .pbc stream
  PBC_VERSION = 1;       // bump whenever the format or opcode meaning changes

{ Write AProg to AStream in the .pbc format. }
procedure WriteProgram(AStream: TStream; AProg: TProgram);
{ Read a program from AStream. False (with AErr set) on a bad magic, an
  unsupported version, an opcode-set mismatch, or a truncated/corrupt stream. }
function ReadProgram(AStream: TStream; out AProg: TProgram; out AErr: String): Boolean;

implementation

// --- little-endian primitives -----------------------------------------------
procedure WU8(S: TStream; B: Byte);            begin S.WriteBuffer(B, 1); end;
function  RU8(S: TStream): Byte;               begin S.ReadBuffer(Result, 1); end;
procedure WI32(S: TStream; V: LongInt);        begin V := NtoLE(V); S.WriteBuffer(V, 4); end;
function  RI32(S: TStream): LongInt;           begin S.ReadBuffer(Result, 4); Result := LEToN(Result); end;
procedure WI64(S: TStream; V: Int64);          begin V := NtoLE(V); S.WriteBuffer(V, 8); end;
function  RI64(S: TStream): Int64;             begin S.ReadBuffer(Result, 8); Result := LEToN(Result); end;
procedure WDbl(S: TStream; const V: Double);   begin WI64(S, PInt64(@V)^); end;   // bit pattern, LE
function  RDbl(S: TStream): Double;            var q: Int64; begin q := RI64(S); Result := PDouble(@q)^; end;

procedure WStr(S: TStream; const V: String);
begin
  WI32(S, Length(V));
  if Length(V) > 0 then S.WriteBuffer(V[1], Length(V));
end;
function RStr(S: TStream): String;
var n: LongInt;
begin
  n := RI32(S);
  SetLength(Result, n);
  if n > 0 then S.ReadBuffer(Result[1], n);
end;

procedure WVal(S: TStream; const V: TValue);
begin
  WU8(S, Ord(V.Kind));
  case V.Kind of
    vkDouble: WDbl(S, V.Num);
    vkInt:    WI64(S, V.Int);
    vkHandle: WI64(S, V.Hnd);
    vkBool:   WU8(S, Ord(V.Bl));
    vkString: WStr(S, V.Str);
  end;
end;
function RVal(S: TStream): TValue;
var k: TValueKind;
begin
  k := TValueKind(RU8(S));
  case k of
    vkDouble: Result := ValDouble(RDbl(S));
    vkInt:    Result := ValInt(RI64(S));
    vkHandle: Result := ValHandle(RI64(S));
    vkBool:   Result := ValBool(RU8(S) <> 0);
    vkString: Result := ValStr(RStr(S));
  else
    Result := Default(TValue);
  end;
end;

// --- the program -------------------------------------------------------------
procedure WriteProgram(AStream: TStream; AProg: TProgram);
var
  i, j: Integer;
  ins: TInstr;
begin
  AStream.WriteBuffer(PBC_MAGIC[1], 3);
  WU8(AStream, PBC_VERSION);
  WU8(AStream, Ord(High(TOpcode)));   // opcode-set guard

  WI32(AStream, AProg.VarCount);
  for i := 0 to AProg.VarCount - 1 do WU8(AStream, Ord(AProg.VarTypes[i]));

  WI32(AStream, AProg.Count);
  for i := 0 to AProg.Count - 1 do
  begin
    ins := AProg.Instr(i);
    WU8(AStream, Ord(ins.Op)); WI32(AStream, ins.A); WI32(AStream, ins.B); WI32(AStream, ins.Line);
  end;

  WI32(AStream, AProg.Consts.Count);
  for i := 0 to AProg.Consts.Count - 1 do WVal(AStream, AProg.Consts.Get(i));

  WI32(AStream, AProg.UserFuncCount);
  for i := 0 to AProg.UserFuncCount - 1 do
  begin
    WStr(AStream, AProg.UserFuncs[i].Name);
    WI32(AStream, AProg.UserFuncs[i].Entry);
    WI32(AStream, AProg.UserFuncs[i].ParamCount);
    WI32(AStream, Length(AProg.UserFuncs[i].LocalTypes));
    for j := 0 to High(AProg.UserFuncs[i].LocalTypes) do WU8(AStream, Ord(AProg.UserFuncs[i].LocalTypes[j]));
    WU8(AStream, Ord(AProg.UserFuncs[i].RetType));
  end;

  WI32(AStream, AProg.DataCount);
  for i := 0 to AProg.DataCount - 1 do WVal(AStream, AProg.DataPool[i]);
end;

function ReadProgram(AStream: TStream; out AProg: TProgram; out AErr: String): Boolean;
var
  magic: array[0..2] of Char;
  ver, maxop: Byte;
  i, j, n, vc, ltc: Integer;
  op: TOpcode;
  a, b, ln: LongInt;
  fname: String;
  entry, pcount: LongInt;
  lts: array of TVarType;
  rt: TVarType;
begin
  AProg := nil;
  AErr := '';
  Result := False;
  try
    if AStream.Read(magic[0], 3) <> 3 then begin AErr := 'not a Phosphor bytecode file (too short)'; Exit; end;
    if (magic[0] <> 'P') or (magic[1] <> 'B') or (magic[2] <> 'C') then
    begin AErr := 'not a Phosphor bytecode file (bad magic)'; Exit; end;
    ver := RU8(AStream);
    if ver <> PBC_VERSION then
    begin AErr := Format('unsupported .pbc format version %d (this build reads version %d)', [ver, PBC_VERSION]); Exit; end;
    maxop := RU8(AStream);
    if maxop <> Ord(High(TOpcode)) then
    begin AErr := Format('this .pbc was built for a different opcode set (%d vs %d) -- recompile it', [maxop, Ord(High(TOpcode))]); Exit; end;

    AProg := TProgram.Create;

    vc := RI32(AStream);
    AProg.VarCount := vc;
    SetLength(AProg.VarTypes, vc);
    for i := 0 to vc - 1 do AProg.VarTypes[i] := TVarType(RU8(AStream));

    n := RI32(AStream);
    for i := 0 to n - 1 do
    begin
      op := TOpcode(RU8(AStream)); a := RI32(AStream); b := RI32(AStream); ln := RI32(AStream);
      AProg.Emit(op, a, b, ln);
    end;

    n := RI32(AStream);
    for i := 0 to n - 1 do AProg.Consts.Add(RVal(AStream));

    n := RI32(AStream);
    for i := 0 to n - 1 do
    begin
      fname := RStr(AStream);
      entry := RI32(AStream);
      pcount := RI32(AStream);
      ltc := RI32(AStream);
      SetLength(lts, ltc);
      for j := 0 to ltc - 1 do lts[j] := TVarType(RU8(AStream));
      rt := TVarType(RU8(AStream));
      AProg.AddUserFunc(fname, entry, pcount, lts, rt);
    end;

    n := RI32(AStream);
    for i := 0 to n - 1 do AProg.AddData(RVal(AStream));

    Result := True;
  except
    on E: Exception do
    begin
      AErr := 'corrupt or truncated .pbc (' + E.Message + ')';
      if AProg <> nil then begin AProg.Free; AProg := nil; end;
      Result := False;
    end;
  end;
end;

end.
