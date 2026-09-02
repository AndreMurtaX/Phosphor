{******************************************************************************
  Phosphor BASIC -- the stack VM

  MIT License. Copyright (c) 2026 Andre Murta.

  Executes a TProgram over a stack of TValue. Calls are resolved from the actual
  runtime kinds of their arguments through the registry (int% widens to an 'n'
  slot, an exact '%' slot is preferred). Arithmetic and call errors are RETURNED
  as engine error state, never raised. All output leaves through OnOutput.
******************************************************************************}
unit PhosphorVM;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, PhosphorValue, PhosphorErrors, PhosphorOpcodes, PhosphorRegistry;

const
  { Classic file-I/O channel numbers run 1..MaxChannel (#0 is not used). The cap
    keeps the channel table a fixed, cheap array; classic BASICs cap far lower. }
  MaxChannel = 255;

type
  { One activation of a user function: its local frame (parameters first, then
    declared locals), the function it belongs to, and where to resume. }
  TCallFrame = record
    Locals: array of TValue;
    FuncIndex: Integer;
    ReturnAddr: Integer;
  end;

  { An open file channel for classic I/O (OPEN ... AS #n). INPUT mode reads the
    whole file into Buf once and walks a 1-based cursor over it (so INPUT#, LINE
    INPUT#, EOF and LOC are cheap and need no re-seeking); OUTPUT/APPEND write
    straight through Stream and flush on CLOSE. }
  TChannelMode = (cmInput, cmOutput, cmAppend);
  TFileChannel = record
    Open: Boolean;
    Mode: TChannelMode;
    Stream: TFileStream;   // OUTPUT / APPEND
    Buf: String;           // INPUT: the whole file
    Pos: Integer;          // INPUT: 1-based read cursor into Buf
  end;

  TPhosphorVM = class
  private
    FStack: array of TValue;
    FSP: Integer;    // points one past the top
    FVars: array of TValue;
    FCallStack: array of Integer;   // GOSUB return addresses
    FCSP: Integer;
    FFrames: array of TCallFrame;   // user-function activation frames
    FFrameSP: Integer;
    FDataPtr: Integer;              // READ position in the DATA pool
    FProg: TProgram;                // the running program (reachable during a call)
    // ON ERROR state. FErrHandler is the handler pc, or -1 when none is installed.
    // opStmt keeps FStmt* pointing at the current clean statement boundary; on a
    // caught error those are copied to FErrStmt* (the resume point) before the
    // handler runs and moves FStmt* on. FInHandler blocks re-entry until a resume.
    FErrHandler: Integer;
    FErrHandlerSP, FErrHandlerFrameSP: Integer;
    FErrHandlerMode: Integer;    // 0 = goto a label, 1 = call a function
    FErrHandlerFuncIdx: Integer; // const-pool index of the function name (call mode)
    FInHandler: Boolean;
    FErrCode: Integer;              // last caught error: code / message / line
    FErrMsg: String;
    FErrLine: Integer;
    FStmtPC, FStmtSP, FStmtFrameSP: Integer;          // current statement boundary
    FErrStmtPC, FErrStmtSP, FErrStmtFrameSP: Integer; // the failing statement, for resume
    // Execution limits (set from the engine before Run; 0 = unlimited). Counters
    // are reset per Run. A limit is FATAL -- it aborts with peLimit and cannot be
    // caught by ON ERROR, so a script cannot escape its own ceiling.
    FSteps: Int64;
    FOutputBytes: Int64;
    FStartTick: QWord;
    // Debug tracing, set by the TRACE statement (opTrace). BREAKPOINT reports the
    // frame through OnBreakpoint only while this is on; off, it is a pure no-op.
    FTrace: Boolean;
    // Classic-I/O state, all per-Run. FChannels[n] is the file on #n. The console
    // INPUT buffer holds the last line read for INPUT/LINE INPUT; the console char
    // buffer feeds INPUT$(n) from a line-based host, keeping any unread remainder.
    FChannels: array[1..MaxChannel] of TFileChannel;
    FInBuf: String;         // console INPUT: the current line
    FInPos: Integer;        // console INPUT: 1-based cursor into FInBuf
    FCharBuf: String;       // console INPUT$: buffered characters not yet consumed
    FCharPos: Integer;      // console INPUT$: 1-based cursor into FCharBuf
    procedure Push(const V: TValue);
    function Pop: TValue;
    procedure CloseAllChannels;
    function ValidChannel(ANum: Integer): Boolean;
    // Classic-I/O primitives. Each returns an engine error (NoError on success) so
    // the opcode handlers can route a failure through Fault (ON ERROR-catchable).
    function ChanOpen(ANum, AMode: Integer; const APath: String): TPhosphorError;
    function ChanClose(ANum: Integer): TPhosphorError;
    function ChanWrite(ANum: Integer; const S: String): TPhosphorError;
    function ChanField(ANum, ATypeCode: Integer; out V: TValue): TPhosphorError;
    function ChanLine(ANum: Integer; out S: String): TPhosphorError;
    function ChanChars(ANum, ACount: Integer; out S: String): TPhosphorError;
    function ChanEof(ANum: Integer; out B: Boolean): TPhosphorError;
    function ChanLof(ANum: Integer; out N: Int64): TPhosphorError;
    function ChanLoc(ANum: Integer; out N: Int64): TPhosphorError;
    // Console INPUT primitives (over the OnInput seam). INPUT / LINE INPUT and
    // INPUT$ share one console buffer (FCharBuf/FCharPos), so char reads and line
    // reads consume the same stream in order, as a classic BASIC console does.
    function PullLine: Boolean;                       // append one host line; False at EOF
    function ReadInputLine: Boolean;                  // fill FInBuf; False at EOF
    function InputField(ATypeCode: Integer; out V: TValue): TPhosphorError;
    function InputChars(ACount: Integer): String;
    { The fetch-decode-execute loop. Runs from AStartPC until the program halts
      (or its instructions run out) OR a user-function return brings the frame
      stack back down to AStopFrameSP -- the bound that lets CallUserFunc invoke
      one BASIC routine re-entrantly and hand control back. The top-level Run uses
      AStopFrameSP = -1, a level the frame stack never reaches, so it runs to end. }
    function ExecFrom(AStartPC, AStopFrameSP: Integer): Boolean;
  public
    OnOutput: TPhosphorOutputProc;
    { The INPUT seam, nil by default (a headless host installs none). The VM asks
      the host for the next console line through it; with none installed, INPUT
      reads as empty. Wired like OnOutput -- the engine only offers the seam. }
    OnInput: TPhosphorInputProc;
    { The BREAKPOINT seam, nil by default (a headless host installs none). The VM
      calls it -- and only while tracing is on -- to REPORT a breakpoint's frame,
      then continues unconditionally. It must never block; see the opBreakpoint
      handler. }
    OnBreakpoint: TPhosphorBreakpointProc;
    { The host-services seam, all-nil by default (a headless host installs none).
      Library functions ask the host for an event pump or the clipboard through
      it; with a field unset they get the empty answer, never a fault. Wired like
      OnOutput/OnBreakpoint -- the engine only ever offers the seam, the platform
      work belongs to a host. }
    HostServices: THostServices;
    Registry: TPhosphorRegistry;
    LastError: TPhosphorError;
    ErrorLine: Integer;
    // Host-set execution ceilings; 0 = unlimited (the default, zero cost).
    MaxSteps: Int64;        // instruction budget (the answer to an infinite loop)
    MaxOutputBytes: Int64;  // total bytes emitted through OnOutput
    TimeoutMs: Int64;       // wall-clock ceiling in milliseconds
    constructor Create;
    destructor Destroy; override;   // closes any file channels left open
    function Run(AProg: TProgram): Boolean;  // False on error (LastError/ErrorLine set)
    { Call a BASIC user function by name, re-entrantly, over the SAME globals and
      handles as the running program. This is the host callback seam: an event
      dispatcher (or the callfunc primitive) runs a BASIC routine and gets its
      return value back. Err is set (and the result is a default value) if the
      function is unknown or the routine fails. }
    function CallUserFunc(const AName: String; const Args: array of TValue;
                          out Err: TPhosphorError): TValue;
    { The last error caught by an ON ERROR handler -- what err()/errmsg$()/erl()
      read. Set on each fault; persists until the next fault. }
    property ErrCode: Integer read FErrCode;
    property ErrMessage: String read FErrMsg;
    property ErrLine: Integer read FErrLine;
    procedure ClearError;   // reset err()/errmsg$()/erl() to "no error"
  end;

implementation

constructor TPhosphorVM.Create;
begin
  inherited Create;
  SetLength(FStack, 64);
  FSP := 0;
  LastError := NoError;
  ErrorLine := 0;
end;

procedure TPhosphorVM.Push(const V: TValue);
begin
  if FSP = Length(FStack) then
    SetLength(FStack, Length(FStack) * 2);
  FStack[FSP] := V;
  Inc(FSP);
end;

function TPhosphorVM.Pop: TValue;
begin
  if FSP = 0 then
  begin
    Result := Default(TValue);
    Exit;
  end;
  Dec(FSP);
  Result := FStack[FSP];
end;

destructor TPhosphorVM.Destroy;
begin
  CloseAllChannels;
  inherited Destroy;
end;

procedure TPhosphorVM.CloseAllChannels;
var i: Integer;
begin
  for i := 1 to MaxChannel do
    if FChannels[i].Open then
    begin
      FChannels[i].Stream.Free;   // nil-safe (INPUT channels keep Stream nil)
      FChannels[i].Stream := nil;
      FChannels[i].Buf := '';
      FChannels[i].Open := False;
    end;
end;

function TPhosphorVM.ValidChannel(ANum: Integer): Boolean;
begin
  Result := (ANum >= 1) and (ANum <= MaxChannel);
end;

{ --- classic-I/O field parsing (shared by console INPUT and INPUT#) ------------
  Take the next delimited field from Buf starting at Pos (1-based), advancing Pos
  past it and one trailing comma. In file mode leading blanks and newlines are
  skipped and an unquoted field ends at a comma OR any whitespace/newline; on the
  console a field ends only at a comma (interior spaces are kept). A leading double
  quote reads a quoted string, with "" meaning a literal quote. }
function NextFieldStr(const Buf: String; var Pos: Integer; AFileMode: Boolean): String;
var
  n, k: Integer;
  r: RawByteString;
begin
  Result := '';
  n := Length(Buf);
  if AFileMode then
    while (Pos <= n) and ((Buf[Pos] = ' ') or (Buf[Pos] = #9) or
                          (Buf[Pos] = #13) or (Buf[Pos] = #10)) do Inc(Pos);
  // The field is built by INDEXED writes into a RawByteString (its length can
  // never exceed the rest of the buffer). Appending byte by byte to a String
  // re-encodes any byte >= 128 through the UTF-8 codepage and lands it as '?',
  // which silently destroyed binary and Latin-1 fields.
  if n - Pos + 1 > 0 then SetLength(r, n - Pos + 1) else SetLength(r, 0);
  k := 0;
  if (Pos <= n) and (Buf[Pos] = '"') then
  begin
    Inc(Pos);   // opening quote
    while Pos <= n do
    begin
      if Buf[Pos] = '"' then
      begin
        if (Pos < n) and (Buf[Pos + 1] = '"') then
          begin Inc(k); r[k] := '"'; Inc(Pos, 2); end      // "" -> a literal quote
        else
          begin Inc(Pos); Break; end;                       // closing quote
      end
      else
        begin Inc(k); r[k] := Buf[Pos]; Inc(Pos); end;
    end;
  end
  else
  begin
    while Pos <= n do
    begin
      if Buf[Pos] = ',' then Break;
      if AFileMode and ((Buf[Pos] = ' ') or (Buf[Pos] = #9) or
                        (Buf[Pos] = #13) or (Buf[Pos] = #10)) then Break;
      Inc(k); r[k] := Buf[Pos];
      Inc(Pos);
    end;
    if not AFileMode then
      while (k > 0) and (r[k] = ' ') do Dec(k);   // trim trailing blanks
  end;
  SetLength(r, k);
  Result := r;
  // consume a single trailing separator comma (skip blanks before it in file mode)
  if AFileMode then
    while (Pos <= n) and ((Buf[Pos] = ' ') or (Buf[Pos] = #9) or
                          (Buf[Pos] = #13) or (Buf[Pos] = #10)) do Inc(Pos);
  if (Pos <= n) and (Buf[Pos] = ',') then Inc(Pos);
end;

{ Coerce a raw input field to a variable's type. Type code: 0 number, 1 string,
  2 int, 3 bool. An empty field takes the type's default; a non-empty field that
  will not parse is a catchable runtime error. }
function CoerceField(const AField: String; ATypeCode: Integer; out V: TValue): TPhosphorError;
var
  iv: Int64;
  dv: Double;
  fs: TFormatSettings;
  low: String;
begin
  Result := NoError;
  V := Default(TValue);
  case ATypeCode of
    1: V := ValStr(AField);
    0, 2:
      begin
        if AField = '' then
        begin
          if ATypeCode = 2 then V := ValInt(0) else V := ValInt(0);
          Exit;
        end;
        if TryStrToInt64(AField, iv) then
        begin
          if ATypeCode = 2 then V := ValInt(iv)
          else V := ValInt(iv);   // vtNumber holds an int% happily
          Exit;
        end;
        fs := DefaultFormatSettings;
        fs.DecimalSeparator := '.';
        fs.ThousandSeparator := #0;
        if TryStrToFloat(AField, dv, fs) then
        begin
          if ATypeCode = 2 then
          begin
            if InI64Range(dv) then V := ValInt(Round(dv))
            else Result := MakeError(peRuntime, '"' + AField + '" is out of integer range');
          end
          else V := ValDouble(dv);
        end
        else
          Result := MakeError(peRuntime, '"' + AField + '" is not a number');
      end;
    3:
      begin
        low := LowerCase(AField);
        if (low = 'true') or (low = '1') or (low = 'yes') then V := ValBool(True)
        else if (low = 'false') or (low = '0') or (low = 'no') or (low = '') then V := ValBool(False)
        else Result := MakeError(peRuntime, '"' + AField + '" is not true/false');
      end;
  else
    Result := MakeError(peTypeMismatch, 'cannot read input into this variable');
  end;
end;

{ A crash-proof Double -> Int32 for the classic-I/O opcodes (file numbers, byte
  counts). Out-of-range or NaN values never reach Round (which would raise): a huge
  magnitude clamps to the Int32 extreme -- for a file number that lands outside
  1..MaxChannel so the channel op reports "out of range", and for a byte count it
  simply means "as many as there are". }
function SafeI32(const V: TValue): Integer;
var d: Double;
begin
  d := AsDouble(V);
  if d <> d then Result := 0                        // NaN
  else if d >= 2147483647.0 then Result := High(Integer)
  else if d <= -2147483648.0 then Result := Low(Integer)
  else Result := Round(d);
end;

// --- console INPUT -----------------------------------------------------------
function TPhosphorVM.PullLine: Boolean;
var line: String;
begin
  Result := Assigned(OnInput) and OnInput(line);
  if Result then FCharBuf := FCharBuf + line + #10;   // the stripped newline is significant
end;

function TPhosphorVM.ReadInputLine: Boolean;
var nl, i: Integer;
begin
  // Take the next line out of the shared console buffer, pulling host lines until
  // a newline (or the input) runs out. INPUT$ reads from the same cursor, so a
  // mid-line INPUT$ leaves the rest of the line for the next LINE INPUT.
  nl := 0;
  while nl = 0 do
  begin
    for i := FCharPos to Length(FCharBuf) do
      if FCharBuf[i] = #10 then begin nl := i; Break; end;
    if nl > 0 then Break;
    if not PullLine then Break;
  end;
  if (nl = 0) and (FCharPos > Length(FCharBuf)) then
  begin
    FInBuf := ''; FInPos := 1;
    Exit(False);   // no input remains
  end;
  if nl = 0 then nl := Length(FCharBuf) + 1;   // a final line with no trailing newline
  FInBuf := Copy(FCharBuf, FCharPos, nl - FCharPos);
  if (Length(FInBuf) > 0) and (FInBuf[Length(FInBuf)] = #13) then
    SetLength(FInBuf, Length(FInBuf) - 1);      // drop a CR from a CRLF line
  FInPos := 1;
  FCharPos := nl + 1;
  if FCharPos > Length(FCharBuf) then begin FCharBuf := ''; FCharPos := 1; end;
  Result := True;
end;

function TPhosphorVM.InputField(ATypeCode: Integer; out V: TValue): TPhosphorError;
var field: String;
begin
  field := NextFieldStr(FInBuf, FInPos, False);
  Result := CoerceField(field, ATypeCode, V);
end;

function TPhosphorVM.InputChars(ACount: Integer): String;
begin
  Result := '';
  if ACount <= 0 then Exit;
  while (Length(FCharBuf) - FCharPos + 1) < ACount do
    if not PullLine then Break;   // EOF: hand back whatever is buffered
  if FCharPos > Length(FCharBuf) then Exit;
  Result := Copy(FCharBuf, FCharPos, ACount);
  Inc(FCharPos, Length(Result));
  if FCharPos > Length(FCharBuf) then begin FCharBuf := ''; FCharPos := 1; end;
end;

// --- file channels -----------------------------------------------------------
function TPhosphorVM.ChanOpen(ANum, AMode: Integer; const APath: String): TPhosphorError;
var
  fmode: TChannelMode;
  ss: TStringStream;
  fs: TFileStream;
begin
  Result := NoError;
  if not ValidChannel(ANum) then
    Exit(MakeError(peRuntime, 'file number #' + IntToStr(ANum) + ' is out of range (1..' + IntToStr(MaxChannel) + ')'));
  if FChannels[ANum].Open then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is already open'));
  case AMode of
    0: fmode := cmInput;
    1: fmode := cmOutput;
    2: fmode := cmAppend;
  else
    Exit(MakeError(peRuntime, 'bad OPEN mode'));
  end;
  try
    FillChar(FChannels[ANum], SizeOf(FChannels[ANum]), 0);
    FChannels[ANum].Mode := fmode;
    if fmode = cmInput then
    begin
      if not FileExists(APath) then
        Exit(MakeError(peRuntime, 'cannot open "' + APath + '" for input: no such file'));
      ss := TStringStream.Create('');
      fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
      try
        ss.CopyFrom(fs, 0);
      finally
        fs.Free;
      end;
      FChannels[ANum].Buf := ss.DataString;
      ss.Free;
      FChannels[ANum].Pos := 1;
      FChannels[ANum].Stream := nil;
    end
    else if fmode = cmOutput then
      FChannels[ANum].Stream := TFileStream.Create(APath, fmCreate)
    else // append
    begin
      if FileExists(APath) then
      begin
        FChannels[ANum].Stream := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyWrite);
        FChannels[ANum].Stream.Seek(0, soEnd);
      end
      else
        FChannels[ANum].Stream := TFileStream.Create(APath, fmCreate);
    end;
    FChannels[ANum].Open := True;
  except
    on E: Exception do
      Result := MakeError(peRuntime, 'cannot open "' + APath + '": ' + E.Message);
  end;
end;

function TPhosphorVM.ChanClose(ANum: Integer): TPhosphorError;
begin
  Result := NoError;
  if ANum < 0 then begin CloseAllChannels; Exit; end;
  if not ValidChannel(ANum) then
    Exit(MakeError(peRuntime, 'file number #' + IntToStr(ANum) + ' is out of range'));
  if not FChannels[ANum].Open then Exit;   // closing an unopened channel is a no-op
  FChannels[ANum].Stream.Free;
  FChannels[ANum].Stream := nil;
  FChannels[ANum].Buf := '';
  FChannels[ANum].Open := False;
end;

function TPhosphorVM.ChanWrite(ANum: Integer; const S: String): TPhosphorError;
begin
  Result := NoError;
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  if FChannels[ANum].Mode = cmInput then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is open for input, not output'));
  if Length(S) > 0 then
    FChannels[ANum].Stream.WriteBuffer(S[1], Length(S));
end;

function TPhosphorVM.ChanField(ANum, ATypeCode: Integer; out V: TValue): TPhosphorError;
var field: String;
begin
  V := Default(TValue);
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  if FChannels[ANum].Mode <> cmInput then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open for input'));
  field := NextFieldStr(FChannels[ANum].Buf, FChannels[ANum].Pos, True);
  Result := CoerceField(field, ATypeCode, V);
end;

function TPhosphorVM.ChanLine(ANum: Integer; out S: String): TPhosphorError;
var buf: String; p, n, start: Integer;
begin
  S := '';
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  if FChannels[ANum].Mode <> cmInput then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open for input'));
  Result := NoError;
  buf := FChannels[ANum].Buf;
  n := Length(buf);
  p := FChannels[ANum].Pos;
  start := p;
  // Scan to the terminator, then take the run with ONE Copy. Appending byte by
  // byte (S := S + buf[p]) re-encodes any byte >= 128 through the UTF-8 codepage
  // and lands it as '?', silently destroying binary and Latin-1 data.
  while (p <= n) and (buf[p] <> #10) and (buf[p] <> #13) do Inc(p);
  S := Copy(buf, start, p - start);
  // step over the line terminator (CR, LF, or CRLF)
  if (p <= n) and (buf[p] = #13) then Inc(p);
  if (p <= n) and (buf[p] = #10) then Inc(p);
  FChannels[ANum].Pos := p;
end;

function TPhosphorVM.ChanChars(ANum, ACount: Integer; out S: String): TPhosphorError;
var buf: String; avail: Integer;
begin
  S := '';
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  if FChannels[ANum].Mode <> cmInput then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open for input'));
  Result := NoError;
  if ACount <= 0 then Exit;
  buf := FChannels[ANum].Buf;
  avail := Length(buf) - FChannels[ANum].Pos + 1;
  if avail <= 0 then Exit;
  if ACount > avail then ACount := avail;
  S := Copy(buf, FChannels[ANum].Pos, ACount);
  Inc(FChannels[ANum].Pos, ACount);
end;

function TPhosphorVM.ChanEof(ANum: Integer; out B: Boolean): TPhosphorError;
begin
  B := True;
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  if FChannels[ANum].Mode <> cmInput then
    Exit(MakeError(peRuntime, 'eof() needs a file open for input'));
  Result := NoError;
  B := FChannels[ANum].Pos > Length(FChannels[ANum].Buf);
end;

function TPhosphorVM.ChanLof(ANum: Integer; out N: Int64): TPhosphorError;
begin
  N := 0;
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  Result := NoError;
  if FChannels[ANum].Mode = cmInput then
    N := Length(FChannels[ANum].Buf)
  else
    N := FChannels[ANum].Stream.Size;
end;

function TPhosphorVM.ChanLoc(ANum: Integer; out N: Int64): TPhosphorError;
begin
  N := 0;
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  Result := NoError;
  if FChannels[ANum].Mode = cmInput then
    N := FChannels[ANum].Pos - 1     // bytes consumed so far
  else
    N := FChannels[ANum].Stream.Position;
end;

// --- PRINT USING formatter ---------------------------------------------------
// A classic-BASIC subset: numeric fields of '#' digit positions with optional
// '.' decimals, ',' grouping, a leading '+' or '$$'/'**', and a trailing '+'/'-';
// string fields '&' (whole), '!' (first char) and '\ \' (fixed width); '_' escapes
// the next literal character. Values fill fields left to right; if values remain
// after the format ends and it held at least one field, the format repeats.
function GroupThousands(const Digits: String): String;
var i, c: Integer;
begin
  Result := '';
  c := 0;
  for i := Length(Digits) downto 1 do
  begin
    Result := Digits[i] + Result;
    Inc(c);
    if (c mod 3 = 0) and (i > 1) then Result := ',' + Result;
  end;
end;

function FormatNumericField(const Spec: String; const V: TValue): String;
var
  s, core, intPartStr, fracPartStr, numText, leftSign, trailSignStr, dollarStr, intField: String;
  fracDigits, width, pad, dotPos2, i: Integer;
  grouping, signLead, trailPlus, trailMinus, dollar, starFill, neg: Boolean;
  dotPos: Integer;
  av: Double;
  fs: TFormatSettings;
  padChar: Char;
begin
  s := Spec;
  dollar := False; starFill := False; signLead := False;
  trailPlus := False; trailMinus := False;
  if (Length(s) >= 2) and (s[1] = '$') and (s[2] = '$') then begin dollar := True; Delete(s, 1, 2); end
  else if (Length(s) >= 2) and (s[1] = '*') and (s[2] = '*') then begin starFill := True; Delete(s, 1, 2); end;
  if (Length(s) >= 1) and (s[1] = '+') then begin signLead := True; Delete(s, 1, 1); end;
  if (Length(s) >= 1) and (s[Length(s)] = '+') then begin trailPlus := True; SetLength(s, Length(s) - 1); end
  else if (Length(s) >= 1) and (s[Length(s)] = '-') then begin trailMinus := True; SetLength(s, Length(s) - 1); end;
  grouping := Pos(',', s) > 0;
  dotPos := Pos('.', s);
  fracDigits := 0;
  if dotPos > 0 then
    for i := dotPos + 1 to Length(s) do if s[i] = '#' then Inc(fracDigits);
  // The integer field width is the count of positions the spec devotes to the
  // integer part -- including any leading '$$'/'**'/'+' and grouping commas, but
  // not a trailing sign -- so the sign or floating '$' occupies a real column.
  begin
    core := Spec;
    if (Length(core) >= 1) and (core[Length(core)] in ['+', '-']) then
      SetLength(core, Length(core) - 1);
    dotPos2 := Pos('.', core);
    if dotPos2 > 0 then width := dotPos2 - 1 else width := Length(core);
  end;

  av := AsDouble(V);
  neg := av < 0;
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;
  numText := FloatToStrF(Abs(av), ffFixed, 18, fracDigits, fs);
  dotPos2 := Pos('.', numText);
  if dotPos2 = 0 then begin intPartStr := numText; fracPartStr := ''; end
  else begin intPartStr := Copy(numText, 1, dotPos2 - 1); fracPartStr := Copy(numText, dotPos2 + 1, MaxInt); end;
  if grouping then intPartStr := GroupThousands(intPartStr);

  leftSign := ''; trailSignStr := '';
  if trailPlus then begin if neg then trailSignStr := '-' else trailSignStr := '+'; end
  else if trailMinus then begin if neg then trailSignStr := '-' else trailSignStr := ' '; end
  else if signLead then begin if neg then leftSign := '-' else leftSign := '+'; end
  else if neg then leftSign := '-';
  if dollar then dollarStr := '$' else dollarStr := '';

  core := dollarStr + leftSign + intPartStr;
  if starFill then padChar := '*' else padChar := ' ';
  pad := width - Length(core);
  if pad >= 0 then intField := StringOfChar(padChar, pad) + core
  else intField := '%' + core;   // overflow: the classic leading '%'

  Result := intField;
  if dotPos > 0 then Result := Result + '.' + fracPartStr;
  Result := Result + trailSignStr;
end;

function ValFieldStr(const V: TValue): String;
begin
  if V.Kind = vkString then Result := V.Str else Result := ValToStr(V);
end;

function FormatUsing(const Fmt: String; const Vals: array of TValue): String;
var
  i, j, n, vi: Integer;
  spec, sv: String;
  width: Integer;
  fieldSeen: Boolean;

  function NextVal: TValue;
  begin
    if vi <= High(Vals) then begin Result := Vals[vi]; Inc(vi); end
    else begin Result := ValInt(0); Inc(vi); end;
  end;

begin
  Result := '';
  n := Length(Fmt);
  vi := 0;
  fieldSeen := False;
  i := 1;
  while i <= n do
  begin
    // numeric field?
    if (Fmt[i] = '#') or
       ((Fmt[i] = '+') and (i < n) and (Fmt[i + 1] in ['#', '.', '$', '*'])) or
       ((Fmt[i] = '$') and (i < n) and (Fmt[i + 1] = '$')) or
       ((Fmt[i] = '*') and (i < n) and (Fmt[i + 1] = '*')) then
    begin
      j := i;
      if (Fmt[j] = '$') and (j < n) and (Fmt[j + 1] = '$') then Inc(j, 2)
      else if (Fmt[j] = '*') and (j < n) and (Fmt[j + 1] = '*') then Inc(j, 2);
      if (j <= n) and (Fmt[j] = '+') then Inc(j);
      while (j <= n) and (Fmt[j] in ['#', ',', '.']) do Inc(j);
      if (j <= n) and (Fmt[j] in ['+', '-']) then Inc(j);
      spec := Copy(Fmt, i, j - i);
      Result := Result + FormatNumericField(spec, NextVal);
      fieldSeen := True;
      i := j;
    end
    else if Fmt[i] = '&' then
    begin
      Result := Result + ValFieldStr(NextVal);
      fieldSeen := True;
      Inc(i);
    end
    else if Fmt[i] = '!' then
    begin
      sv := ValFieldStr(NextVal);
      if Length(sv) > 0 then Result := Result + sv[1] else Result := Result + ' ';
      fieldSeen := True;
      Inc(i);
    end
    else if Fmt[i] = '\' then
    begin
      // '\' ... '\' -- a fixed-width string field of (2 + inner spaces) columns.
      j := i + 1;
      while (j <= n) and (Fmt[j] <> '\') do Inc(j);
      if j <= n then
      begin
        width := j - i + 1;
        sv := ValFieldStr(NextVal);
        if Length(sv) >= width then sv := Copy(sv, 1, width)
        else sv := sv + StringOfChar(' ', width - Length(sv));
        Result := Result + sv;
        fieldSeen := True;
        i := j + 1;
      end
      else
        begin Result := Result + Fmt[i]; Inc(i); end;   // an unpaired '\' is literal
    end
    else if (Fmt[i] = '_') and (i < n) then
    begin
      Result := Result + Fmt[i + 1];   // '_' escapes the next character literally
      Inc(i, 2);
    end
    else
    begin
      Result := Result + Fmt[i];
      Inc(i);
    end;
    // reached the end with values to spare and fields to reuse: repeat the format
    if (i > n) and fieldSeen and (vi <= High(Vals)) then
      i := 1;
  end;
end;

function SignatureOf(const AName: String; const AArgs: array of TValue): String;
var
  i: Integer;
begin
  Result := AName + ':';
  for i := 0 to High(AArgs) do
    Result := Result + TPhosphorRegistry.CodeOf(AArgs[i].Kind);
end;

function TPhosphorVM.Run(AProg: TProgram): Boolean;
var
  i: Integer;
begin
  FProg := AProg;
  FSP := 0;
  FCSP := 0;
  FFrameSP := 0;
  FDataPtr := 0;
  LastError := NoError;
  ErrorLine := 0;
  FErrHandler := -1;
  FErrHandlerMode := 0;
  FErrHandlerFuncIdx := 0;
  FInHandler := False;
  FErrCode := 0; FErrMsg := ''; FErrLine := 0;
  FStmtPC := 0; FStmtSP := 0; FStmtFrameSP := 0;
  FErrStmtPC := 0; FErrStmtSP := 0; FErrStmtFrameSP := 0;
  FSteps := 0;
  FOutputBytes := 0;
  FStartTick := GetTickCount64;
  FTrace := False;
  CloseAllChannels;            // no file channel leaks between programs
  FInBuf := ''; FInPos := 1;
  FCharBuf := ''; FCharPos := 1;
  SetLength(FVars, AProg.VarCount);
  for i := 0 to AProg.VarCount - 1 do
    FVars[i] := DefaultValue(AProg.VarTypes[i]);
  Result := ExecFrom(0, -1);
end;

function TPhosphorVM.ExecFrom(AStartPC, AStopFrameSP: Integer): Boolean;
var
  pc, i, argc, ufi, savedRet, dupBase: Integer;
  ins: TInstr;
  a, b, r, v: TValue;
  e: TPhosphorError;
  args: array of TValue;
  kinds: array of TValueKind;
  res: TResolvedFunc;
  lt: TVarType;
  bpOps: array of TValue;   // a BREAKPOINT's popped operand values
  usingVals: array of TValue;   // a PRINT USING statement's popped values
  sTmp: String;             // scratch for the classic-I/O handlers
  bTmp: Boolean;
  nTmp: Int64;

  { A runtime error. Returns True if an ON ERROR handler took it (pc now points at
    the handler; the caller should Continue), False to abort (LastError set; the
    caller should Exit(False)). The handler runs at the stack/frame level it was
    installed at; the failing statement is remembered for resume. }
  function Fault(const AErr: TPhosphorError): Boolean;
  var
    callErr: TPhosphorError;
    callRet: TValue;
  begin
    FErrCode := Ord(AErr.Code);
    FErrMsg := AErr.Message;
    FErrLine := ins.Line;
    if (FErrHandler >= 0) and (not FInHandler) then
    begin
      FErrStmtPC := FStmtPC; FErrStmtSP := FStmtSP; FErrStmtFrameSP := FStmtFrameSP;
      FSP := FErrHandlerSP; FFrameSP := FErrHandlerFrameSP;
      if FErrHandlerMode = 1 then
      begin
        // `on error call func`: run func(code%, msg$), then continue by its result
        // (return 0 = resume next; return non-zero = abort, re-raising the error).
        FInHandler := True;
        callRet := CallUserFunc(FProg.Consts.Get(FErrHandlerFuncIdx).Str,
                                [ValInt(FErrCode), ValStr(FErrMsg)], callErr);
        FInHandler := False;
        if IsError(callErr) then
        begin
          LastError := callErr; ErrorLine := FErrLine; Exit(False);
        end;
        if (callRet.Kind in [vkInt, vkDouble]) and (AsDouble(callRet) <> 0) then
        begin
          LastError := AErr; ErrorLine := FErrLine; Exit(False);   // handler said: abort
        end;
        FSP := FErrStmtSP; FFrameSP := FErrStmtFrameSP;             // resume next
        pc := FErrStmtPC + 1;
        while (pc < FProg.Count) and (FProg.Instr(pc).Op <> opStmt) do Inc(pc);
        Result := True;
      end
      else
      begin
        // `on error goto label`: jump to the handler
        FInHandler := True;
        pc := FErrHandler;
        Result := True;
      end;
    end
    else
    begin
      LastError := AErr;
      ErrorLine := ins.Line;
      Result := False;
    end;
  end;

  { For arithmetic/comparison ops. 0 = ok (result pushed, fall through to Inc pc),
    1 = a handler took the fault (Continue), 2 = abort (Exit False). }
  function Bin(AErr: TPhosphorError; const AResult: TValue): Integer;
  begin
    if IsError(AErr) then
    begin
      if Fault(AErr) then Result := 1 else Result := 2;
    end
    else
    begin
      Push(AResult);
      Result := 0;
    end;
  end;

  { Emit output, enforcing the output-byte ceiling. False = the ceiling was hit
    (a fatal peLimit is set; the caller must Exit(False)). }
  function EmitOutput(const S: String): Boolean;
  begin
    if (MaxOutputBytes > 0) and (FOutputBytes + Length(S) > MaxOutputBytes) then
    begin
      LastError := MakeError(peLimit, 'output limit exceeded (' + IntToStr(MaxOutputBytes) + ' bytes)');
      ErrorLine := ins.Line;
      Exit(False);
    end;
    Inc(FOutputBytes, Length(S));
    if Assigned(OnOutput) then OnOutput(S);
    Result := True;
  end;

begin
  args := nil;
  kinds := nil;
  bpOps := nil;
  usingVals := nil;
  sTmp := '';
  bTmp := False;
  nTmp := 0;
  pc := AStartPC;
  while pc < FProg.Count do
  begin
    ins := FProg.Instr(pc);
    Inc(FSteps);
    if (MaxSteps > 0) and (FSteps > MaxSteps) then
    begin
      LastError := MakeError(peLimit, 'step budget exceeded (' + IntToStr(MaxSteps) + ' instructions)');
      ErrorLine := ins.Line;
      Exit(False);
    end;
    if (TimeoutMs > 0) and ((FSteps and $FFF) = 0) and
       (GetTickCount64 - FStartTick > QWord(TimeoutMs)) then
    begin
      LastError := MakeError(peLimit, 'time limit exceeded (' + IntToStr(TimeoutMs) + ' ms)');
      ErrorLine := ins.Line;
      Exit(False);
    end;
    case ins.Op of
      opNop: ;
      opPushConst: Push(FProg.Consts.Get(ins.A));
      opPop: Pop;
      opPrint:
        begin
          v := Pop;
          if not EmitOutput(ValToStr(v)) then Exit(False);
        end;
      opPrintLn:
        begin
          v := Pop;
          if not EmitOutput(ValToStr(v) + #10) then Exit(False);
        end;
      opNeg:     begin a := Pop; case Bin(Negate(a, r), r) of 1: Continue; 2: Exit(False); end; end;
      opAdd:     begin b := Pop; a := Pop; case Bin(ValAdd(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opSub:     begin b := Pop; a := Pop; case Bin(ValSub(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opMul:     begin b := Pop; a := Pop; case Bin(ValMul(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opDivReal: begin b := Pop; a := Pop; case Bin(ValDivReal(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opDivInt:  begin b := Pop; a := Pop; case Bin(ValDivInt(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opPow:     begin b := Pop; a := Pop; case Bin(ValPow(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opMod:     begin b := Pop; a := Pop; case Bin(ValMod(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opEQ:      begin b := Pop; a := Pop; case Bin(ValCompare(coEQ, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opNE:      begin b := Pop; a := Pop; case Bin(ValCompare(coNE, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opLT:      begin b := Pop; a := Pop; case Bin(ValCompare(coLT, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opLE:      begin b := Pop; a := Pop; case Bin(ValCompare(coLE, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opGT:      begin b := Pop; a := Pop; case Bin(ValCompare(coGT, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opGE:      begin b := Pop; a := Pop; case Bin(ValCompare(coGE, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opAnd:     begin b := Pop; a := Pop; case Bin(ValAnd(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opOr:      begin b := Pop; a := Pop; case Bin(ValOr(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opNot:     begin a := Pop; case Bin(ValNot(a, r), r) of 1: Continue; 2: Exit(False); end; end;
      opLoadVar: Push(FVars[ins.A]);
      opStoreVar:
        begin
          v := Pop;
          if CanStore(FProg.VarTypes[ins.A], v, r) then
            FVars[ins.A] := r
          else
            if Fault(MakeError(peTypeMismatch, 'cannot store ' + KindName(v.Kind) +
              ' into ' + VarTypeName(FProg.VarTypes[ins.A]) + ' variable')) then Continue else Exit(False);
        end;
      opJumpIfFalse:
        begin
          v := Pop;
          if v.Kind <> vkBool then
            if Fault(MakeError(peTypeMismatch, 'condition is not a boolean')) then Continue else Exit(False);
          if not v.Bl then
          begin
            pc := ins.A;
            Continue;
          end;
        end;
      opJump:
        begin
          pc := ins.A;
          Continue;
        end;
      opReadData:
        begin
          if FDataPtr >= FProg.DataCount then
          begin
            if Fault(MakeError(peRuntime, 'out of DATA')) then Continue else Exit(False);
          end;
          Push(FProg.DataPool[FDataPtr]);
          Inc(FDataPtr);
        end;
      opRestore: FDataPtr := 0;
      opDup2:
        begin
          a := FStack[FSP - 2];
          b := FStack[FSP - 1];
          Push(a);
          Push(b);
        end;
      opDupN:
        begin
          // Duplicate the top ins.A values in order. base is fixed before the
          // pushes so a stack reallocation inside Push cannot disturb the source
          // slots (they sit below the original top and keep their copied values).
          dupBase := FSP - ins.A;
          for i := 0 to ins.A - 1 do
            Push(FStack[dupBase + i]);
        end;
      opTrace:
        begin
          // Turn tracing on (a non-zero value) or off (0). A non-numeric value
          // reads as 0 through AsDouble, so it turns tracing off.
          v := Pop;
          FTrace := (AsDouble(v) <> 0);
        end;
      opBreakpoint:
        begin
          // Pop the ins.A operand values (reverse of the push order) and then the
          // message. Report-and-continue: the host seam is invoked ONLY when
          // tracing is on AND a callback is installed -- a headless host installs
          // none, so BREAKPOINT then does nothing but balance the stack. It never
          // parks the VM, and it never writes back, so every operand VARIABLE the
          // source passed is left untouched (only copies of their values were
          // pushed).
          SetLength(bpOps, ins.A);
          for i := ins.A - 1 downto 0 do
            bpOps[i] := Pop;
          v := Pop;   // the message
          if FTrace and Assigned(OnBreakpoint) then
            OnBreakpoint(ValToStr(v), ins.Line, bpOps);
        end;
      opStmt:
        begin
          // Mark this clean statement boundary; a fault resumes from here.
          FStmtPC := pc; FStmtSP := FSP; FStmtFrameSP := FFrameSP;
        end;
      opSetErrHandler:
        begin
          FErrHandlerMode := ins.B;   // 0 = goto a label (A = pc), 1 = call a func (A = name idx)
          if (ins.B = 0) and (ins.A < 0) then
            FErrHandler := -1         // on error goto 0 -- disable
          else
          begin
            FErrHandler := ins.A;     // installed (a pc for goto, a name index for call)
            if ins.B = 1 then FErrHandlerFuncIdx := ins.A;
            FErrHandlerSP := FSP; FErrHandlerFrameSP := FFrameSP;
          end;
          FInHandler := False;        // (re-)installing re-arms the handler
        end;
      opResume:
        begin
          if not FInHandler then
          begin
            LastError := MakeError(peRuntime, 'resume without an active error handler');
            ErrorLine := ins.Line;
            Exit(False);
          end;
          FInHandler := False;
          FSP := FErrStmtSP; FFrameSP := FErrStmtFrameSP;
          if ins.A = 1 then
          begin
            // resume next: continue at the statement after the one that failed
            pc := FErrStmtPC + 1;
            while (pc < FProg.Count) and (FProg.Instr(pc).Op <> opStmt) do Inc(pc);
          end
          else
            pc := FErrStmtPC;   // resume: retry the failing statement
          Continue;
        end;
      opHalt: Exit(True);
      opGosub:
        begin
          if FCSP = Length(FCallStack) then
            SetLength(FCallStack, (FCSP + 1) * 2);
          FCallStack[FCSP] := pc + 1;   // resume after the GOSUB
          Inc(FCSP);
          pc := ins.A;
          Continue;
        end;
      opReturn:
        begin
          if FCSP = 0 then
            if Fault(MakeError(peRuntime, 'RETURN without GOSUB')) then Continue else Exit(False);
          Dec(FCSP);
          pc := FCallStack[FCSP];
          Continue;
        end;
      opLoadLocal: Push(FFrames[FFrameSP - 1].Locals[ins.A]);
      opStoreLocal:
        begin
          v := Pop;
          lt := FProg.UserFuncs[FFrames[FFrameSP - 1].FuncIndex].LocalTypes[ins.A];
          if CanStore(lt, v, r) then
            FFrames[FFrameSP - 1].Locals[ins.A] := r
          else
            if Fault(MakeError(peTypeMismatch, 'cannot store ' + KindName(v.Kind) +
              ' into ' + VarTypeName(lt) + ' local')) then Continue else Exit(False);
        end;
      opRetFunc:
        begin
          if FFrameSP = 0 then
            if Fault(MakeError(peRuntime, 'return outside a function')) then Continue else Exit(False);
          savedRet := FFrames[FFrameSP - 1].ReturnAddr;  // value stays on the stack
          Dec(FFrameSP);
          // A re-entrant call (CallUserFunc) stops here, handing its return value
          // back to the host through the stack, when the frame it pushed unwinds.
          if FFrameSP = AStopFrameSP then Exit(True);
          pc := savedRet;
          Continue;
        end;
      opCall:
        begin
          argc := ins.B;
          // A user function shadows the library registry for the same name+arity.
          ufi := FProg.FindUserFunc(FProg.Consts.Get(ins.A).Str, argc);
          if ufi >= 0 then
          begin
            if FFrameSP = Length(FFrames) then
              SetLength(FFrames, (FFrameSP + 1) * 2);
            SetLength(FFrames[FFrameSP].Locals, Length(FProg.UserFuncs[ufi].LocalTypes));
            for i := argc - 1 downto 0 do
              FFrames[FFrameSP].Locals[i] := Pop;
            for i := argc to High(FProg.UserFuncs[ufi].LocalTypes) do
              FFrames[FFrameSP].Locals[i] := DefaultValue(FProg.UserFuncs[ufi].LocalTypes[i]);
            FFrames[FFrameSP].FuncIndex := ufi;
            FFrames[FFrameSP].ReturnAddr := pc + 1;
            Inc(FFrameSP);
            pc := FProg.UserFuncs[ufi].Entry;
            Continue;
          end;
          // library call (plain, or host-aware and given the VM to call back with)
          SetLength(args, argc);
          SetLength(kinds, argc);
          for i := argc - 1 downto 0 do
            args[i] := Pop;
          for i := 0 to argc - 1 do
            kinds[i] := args[i].Kind;
          res := Registry.Resolve(FProg.Consts.Get(ins.A).Str, kinds);
          if not res.Found then
          begin
            if Fault(MakeError(peUnknownFunction,
              'no function ' + SignatureOf(FProg.Consts.Get(ins.A).Str, args))) then Continue else Exit(False);
          end;
          e := NoError;
          // The safety net: a library function must never crash the interpreter.
          // Any Pascal exception it raises (e.g. an out-of-range Double->Int64 in a
          // conversion or index argument) is converted to a CATCHABLE engine error,
          // upholding "errors are values, the program keeps running" even for a
          // fault a library forgot to guard.
          try
            if res.IsHost then
              r := res.HostFunc(Self, args, e)
            else
              r := res.Func(args, e);
          except
            on ex: Exception do
            begin
              r := Default(TValue);
              e := MakeError(peRuntime, ex.Message);
            end;
          end;
          if IsError(e) then
          begin
            if Fault(e) then Continue else Exit(False);
          end;
          Push(r);
        end;
      // --- classic console input -----------------------------------------------
      opInputLine: ReadInputLine;   // fill the input buffer; EOF just leaves it empty
      opInputField:
        begin
          e := InputField(ins.A, v);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(v);
        end;
      opInputAll:
        begin
          Push(ValStr(Copy(FInBuf, FInPos, MaxInt)));
          FInPos := Length(FInBuf) + 1;
        end;
      opInputChars:
        begin
          a := Pop;   // count
          Push(ValStr(InputChars(SafeI32(a))));
        end;
      // --- classic file I/O ----------------------------------------------------
      opOpenFile:
        begin
          a := Pop;   // channel number (pushed last)
          b := Pop;   // path (pushed first)
          e := ChanOpen(SafeI32(a), ins.A, ValToStr(b));
          if IsError(e) then if Fault(e) then Continue else Exit(False);
        end;
      opCloseFile:
        begin
          if ins.A = 1 then
            ChanClose(-1)                 // CLOSE with no argument: close every channel
          else
          begin
            a := Pop;
            e := ChanClose(SafeI32(a));
            if IsError(e) then if Fault(e) then Continue else Exit(False);
          end;
        end;
      opPrintFile:
        begin
          v := Pop;   // the value (pushed last)
          a := Pop;   // channel number (pushed first)
          e := ChanWrite(SafeI32(a), ValToStr(v));
          if IsError(e) then if Fault(e) then Continue else Exit(False);
        end;
      opFileField:
        begin
          a := Pop;   // channel number
          e := ChanField(SafeI32(a), ins.A, v);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(v);
        end;
      opFileLine:
        begin
          a := Pop;
          e := ChanLine(SafeI32(a), sTmp);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(ValStr(sTmp));
        end;
      opFileChars:
        begin
          a := Pop;   // channel number (pushed last, on top)
          b := Pop;   // count (pushed first)
          e := ChanChars(SafeI32(a), SafeI32(b), sTmp);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(ValStr(sTmp));
        end;
      opEofFile:
        begin
          a := Pop;
          e := ChanEof(SafeI32(a), bTmp);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(ValBool(bTmp));
        end;
      opLofFile:
        begin
          a := Pop;
          e := ChanLof(SafeI32(a), nTmp);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(ValInt(nTmp));
        end;
      opLocFile:
        begin
          a := Pop;
          e := ChanLoc(SafeI32(a), nTmp);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(ValInt(nTmp));
        end;
      // --- formatted output ----------------------------------------------------
      opPrintUsing:
        begin
          SetLength(usingVals, ins.A);
          for i := ins.A - 1 downto 0 do usingVals[i] := Pop;
          v := Pop;   // the format string (pushed first)
          if not EmitOutput(FormatUsing(ValToStr(v), usingVals)) then Exit(False);
        end;
    else
      if Fault(MakeError(peRuntime, 'bad opcode ' + IntToStr(Ord(ins.Op)))) then Continue else Exit(False);
    end;
    Inc(pc);
  end;
  Result := True;
end;

procedure TPhosphorVM.ClearError;
begin
  FErrCode := 0;
  FErrMsg := '';
  FErrLine := 0;
end;

function TPhosphorVM.CallUserFunc(const AName: String; const Args: array of TValue;
  out Err: TPhosphorError): TValue;
var
  ufi, i, saved: Integer;
begin
  Result := Default(TValue);
  Err := NoError;
  if FProg = nil then
  begin
    Err := MakeError(peRuntime, 'no program is running');
    Exit;
  end;
  ufi := FProg.FindUserFunc(AName, Length(Args));
  if ufi < 0 then
  begin
    Err := MakeError(peUnknownFunction,
      'no BASIC function ' + AName + ' taking ' + IntToStr(Length(Args)) + ' argument(s)');
    Exit;
  end;
  // Push an activation frame, mirroring opCall's user-function path, then run the
  // body re-entrantly until it returns to this frame level. The stack, globals
  // and handle registry are shared with the running program on purpose: a callback
  // sees and mutates the same state, exactly like an in-line GOSUB would.
  saved := FFrameSP;
  if FFrameSP = Length(FFrames) then
    SetLength(FFrames, (FFrameSP + 1) * 2);
  SetLength(FFrames[FFrameSP].Locals, Length(FProg.UserFuncs[ufi].LocalTypes));
  for i := 0 to Length(Args) - 1 do
    FFrames[FFrameSP].Locals[i] := Args[i];
  for i := Length(Args) to High(FProg.UserFuncs[ufi].LocalTypes) do
    FFrames[FFrameSP].Locals[i] := DefaultValue(FProg.UserFuncs[ufi].LocalTypes[i]);
  FFrames[FFrameSP].FuncIndex := ufi;
  FFrames[FFrameSP].ReturnAddr := -1;   // unused: ExecFrom stops by frame level
  Inc(FFrameSP);
  if ExecFrom(FProg.UserFuncs[ufi].Entry, saved) then
    Result := Pop        // the routine's return value
  else
  begin
    Err := LastError;
    FFrameSP := saved;   // unwind on failure
  end;
end;

end.
