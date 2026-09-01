{******************************************************************************
  phosphorguitest -- the headless GUI suite runner (a GUI-linked host)

  MIT License. Copyright (c) 2026 Andre Murta.

  The counterpart of phosphortest for the GUI packages. It links the LCL (which
  the engine may not) and registers the GUI libraries alongside the test library,
  then runs one GUI .bas file and reports the assertion tally byte-exact, exactly
  as phosphortest does. It NEVER shows a window or enters the message loop: GUI
  tests construct controls, round-trip properties, and fire events with
  button_click, all headless. Application.Initialize brings up the widgetset (on
  Windows win32, no display; on Linux gtk2, against the session's live display,
  set by the test script) so controls can be built.

  Exit code: 0 all passed, 1 assertions failed, 2 did not compile/run.
******************************************************************************}
program phosphorguitest;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  Interfaces,   // the LCL widgetset (win32 / gtk2), selected at build time
  Forms,
  SysUtils, Classes,
  PhosphorEngine, PhosphorTestLib,
  PhosphorGuiCore, PhosphorFormLib, PhosphorButtonLib;

function ReadSource(const APath: String): String;
var
  fs: TFileStream;
  len: Int64;
begin
  Result := '';
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    len := fs.Size;
    SetLength(Result, len);
    if len > 0 then fs.ReadBuffer(Result[1], len);
  finally
    fs.Free;
  end;
  if (Length(Result) >= 3) and (Result[1] = #$EF) and
     (Result[2] = #$BB) and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
end;

procedure WriteSummary;
var
  s: String;
begin
  s := 'passed: ' + IntToStr(AssertsPassed) + #10 +
       'failed: ' + IntToStr(AssertsFailed) + #10;
  FileWrite(StdOutputHandle, s[1], Length(s));
end;

var
  eng: TPhosphorEngine;
  path: String;
  rc, i: Integer;
begin
  if ParamCount < 1 then
  begin
    Writeln(StdErr, 'usage: phosphorguitest <file.bas>');
    Halt(2);
  end;
  path := ParamStr(1);
  if not FileExists(path) then
  begin
    Writeln(StdErr, 'phosphorguitest: file not found: ', path);
    Halt(2);
  end;

  Application.Initialize;   // bring up the widgetset before any form is built

  eng := TPhosphorEngine.Create;
  try
    RegisterTestFuncs(eng.Registry);
    RegisterGuiCoreFuncs(eng.Registry);
    RegisterFormFuncs(eng.Registry);
    RegisterButtonFuncs(eng.Registry);
    ResetTestState;
    rc := eng.Run(ReadSource(path));
    if rc <> 0 then
    begin
      Writeln(StdErr, Format('phosphorguitest: %s:%d: %s', [path, eng.ErrorLine, eng.ErrorMessage]));
      WriteSummary;
      Halt(2);
    end;
    for i := 0 to Failures.Count - 1 do
      Writeln(StdErr, '  FAIL ', Failures[i]);
    WriteSummary;
    if AssertsFailed = 0 then Halt(0) else Halt(1);
  finally
    eng.Free;
  end;
end.
