{******************************************************************************
  phosphorgui -- the interactive GUI host (the engine's second real consumer)

  MIT License. Copyright (c) 2026 Andre Murta.

  Runs a .bas program that builds a window and enters the message loop
  (app_run). The engine is unchanged and unaware: it sees the same registry and
  the same OnOutput seam as the console host; the GUI libraries, registered here,
  are what turn form@/button@/button_onclick@ into real LCL controls and events.

  Usage:  phosphorgui <file.bas>
******************************************************************************}
program phosphorgui;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  Interfaces,   // the LCL widgetset for this platform
  Forms,
  SysUtils, Classes,
  PhosphorEngine,
  PhosphorGuiCore, PhosphorControlLib, PhosphorFormLib, PhosphorButtonLib,
  PhosphorLabelLib, PhosphorEditLib, PhosphorChoiceLib;

type
  { The host side of the output seam: PRINT/PRINTLN text goes to stdout as raw
    bytes, the same contract the console host honours. }
  TGuiConsole = class
    procedure Output(const AText: String);
  end;

procedure TGuiConsole.Output(const AText: String);
begin
  if Length(AText) > 0 then
    FileWrite(StdOutputHandle, AText[1], Length(AText));
end;

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

var
  eng: TPhosphorEngine;
  con: TGuiConsole;
  path: String;
  rc: Integer;
begin
  if ParamCount < 1 then
  begin
    Writeln(StdErr, 'usage: phosphorgui <file.bas>');
    Halt(2);
  end;
  path := ParamStr(1);
  if not FileExists(path) then
  begin
    Writeln(StdErr, 'phosphorgui: file not found: ', path);
    Halt(2);
  end;

  Application.Initialize;

  con := TGuiConsole.Create;
  eng := TPhosphorEngine.Create;
  try
    eng.OnOutput := @con.Output;
    RegisterGuiCoreFuncs(eng.Registry);
    RegisterControlFuncs(eng.Registry);
    RegisterFormFuncs(eng.Registry);
    RegisterButtonFuncs(eng.Registry);
    RegisterLabelFuncs(eng.Registry);
    RegisterEditFuncs(eng.Registry);
    RegisterChoiceFuncs(eng.Registry);
    rc := eng.Run(ReadSource(path));
    if rc <> 0 then
    begin
      Writeln(StdErr, Format('phosphorgui: %s:%d: %s', [path, eng.ErrorLine, eng.ErrorMessage]));
      Halt(1);
    end;
  finally
    eng.Free;
    con.Free;
  end;
end.
