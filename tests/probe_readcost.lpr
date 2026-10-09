{******************************************************************************
  probe_readcost -- a console INPUT$ costs what it reads: O(N), not O(N^2).

  The classic CHANNEL reads have this pinned from BASIC
  (tests/suite/81_chan_read_linear.bas). The CONSOLE twin cannot be: a test
  program's console input is whatever its runner hands the host, and the suite
  runners hand it nothing. So this drives OnInput itself -- the seam every host
  answers -- with a run of short lines, the shape that made it quadratic.

  THE DEFECT (2026-10-09). A console INPUT$ that needed more than one line
  pulled them one at a time and appended each with FCharBuf := FCharBuf + line,
  a copy of everything buffered so far per line: input$(8 MB) of 64-byte lines
  took 0.24 s and input$(32 MB) 2.2 s -- four times the bytes, nine times the
  time. TPhosphorVM.InputChars now collects the lines it needs and joins them
  once.

  THE MEASUREMENT. One `input$(64 MB)` against a control that reads the same
  bytes as 64 calls of input$(1 MB). The control is linear on both sides of the
  fix (each call needs only 16384 lines), so the ratio is the shape, whatever
  the machine's speed. The bound is 4x the control plus a second. The length is
  checked exactly, and so is the last byte, so a fast wrong answer fails too.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail
  to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_readcost;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, PhosphorEngine;

const
  LF = #10;
  { 64-byte records: 63 bytes of text, and the newline the console strips and
    INPUT$ puts back. 2^20 of them is 2^26 bytes, 64 MB. }
  LineText = 63;
  LineCount = 1048576;
  Total = 67108864;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

type
  { LineCount lines of LineText bytes, then end of input. }
  TLines = class
    Left: Integer;
    Line: String;
    function Read(out ALine: String): Boolean;
  end;

  TSink = class
    Text: String;
    procedure Take(const AText: String);
  end;

function TLines.Read(out ALine: String): Boolean;
begin
  ALine := '';
  if Left <= 0 then Exit(False);
  Dec(Left);
  ALine := Line;
  Result := True;
end;

procedure TSink.Take(const AText: String);
begin
  Text := Text + AText;
end;

{ Runs ASource with a fresh 64 MB of lines on the console. Answers the elapsed
  milliseconds and what the program printed. }
function Timed(const ASource: String; out AOut: String; out ARc: Integer): Int64;
var
  eng: TPhosphorEngine;
  src: TLines;
  sink: TSink;
  t0: QWord;
begin
  src := TLines.Create();
  sink := TSink.Create();
  eng := TPhosphorEngine.Create();
  try
    src.Left := LineCount;
    src.Line := StringOfChar('b', LineText);
    eng.OnInput := @src.Read;
    eng.OnOutput := @sink.Take;
    eng.TimeoutMs := 120000;   { a runaway fails the probe instead of hanging it }
    t0 := GetTickCount64();
    ARc := eng.Run(ASource);
    Result := Int64(GetTickCount64() - t0);
    AOut := sink.Text;
    if ARc <> 0 then
      Writeln(StdErr, '  (the program failed: ', eng.LastError.Message, ')');
  finally
    eng.Free;
    sink.Free;
    src.Free;
  end;
end;

var
  outControl, outBig, want: String;
  rcControl, rcBig: Integer;
  msControl, msBig, bound: Int64;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');
  if (ParamCount > 1) or ((ParamCount = 1) and not ProveFail) then
  begin
    Writeln(StdErr, 'probe_readcost: unknown argument ', ParamStr(1));
    Halt(2);
  end;

  { The control: 64 reads of 1 MB, each needing 16384 lines. }
  msControl := Timed(
    't = 0' + LF +
    'for i = 1 to 64' + LF +
    '  t = t + len(input$(1048576))' + LF +
    'next' + LF +
    'println t' + LF, outControl, rcControl);
  { The case: the same bytes in one read. The last byte is the last line's
    newline, which INPUT$ must hand back. }
  msBig := Timed(
    'x$ = input$(67108864)' + LF +
    'println len(x$)' + LF +
    'println asc(right$(x$, 1)); " "; asc(left$(x$, 1))' + LF, outBig, rcBig);

  want := IntToStr(Total) + LF;
  if ProveFail then want := IntToStr(Total + 1) + LF;
  Report((rcControl = 0) and (outControl = want),
         'the control read every byte (printed "' + Trim(outControl) + '")');
  Report((rcBig = 0) and (outBig = IntToStr(Total) + LF + '10 98' + LF),
         'one input$ read every byte, newline last (printed "' +
         StringReplace(Trim(outBig), LF, ' | ', [rfReplaceAll]) + '")');
  bound := 4 * msControl + 1000;
  Report(msBig <= bound,
         'one input$(64 MB) took ' + IntToStr(msBig) + ' ms; the control took ' +
         IntToStr(msControl) + ' ms, bound ' + IntToStr(bound));
  Writeln('control ', msControl, ' ms, one read ', msBig, ' ms');

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
