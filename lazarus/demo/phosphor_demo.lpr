{******************************************************************************
  Phosphor BASIC -- a Lazarus application with a BASIC engine embedded in it.

  MIT License. Copyright (c) 2026 Andre Murta.

  Open lazarus/demo/phosphor_demo.lpi in the Lazarus IDE and press Run, or build
  it from a shell:

      lazbuild lazarus/demo/phosphor_demo.lpi

  What it shows, in five examples: a script printing; a script calling functions
  the APPLICATION registered; a script handling its own error with ON ERROR; a
  script whose error nobody handled, reaching the host; a runaway loop stopped by
  a ceiling ON ERROR cannot catch; and a bug in the host's own code, contained,
  with the application still standing afterwards.

  The engine is a library and it links without the LCL. This program links the
  LCL because it draws a window, not because Phosphor needs one.
******************************************************************************}
program phosphor_demo;

{$mode objfpc}{$H+}{$J-}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Interfaces, Forms, Dialogs,
  MainForm, PhosphorDemoRunner;

type
  { THE SECOND HALF OF THE STORY, and a Lazarus application embedding ANY
    interpreter wants both halves.

    TPhosphorEngine.ContainFaults keeps a fault inside the INTERPRETER from ever
    reaching this program. It cannot do anything about a fault in the program's
    own code -- a nil control, a bad cast in an event handler -- and the LCL's
    default answer to one of those is a modal dialog. On a machine with nobody in
    front of it, a modal dialog is a HANG: no message, no exit code, nothing in a
    log, and worse than the crash it replaced.

    So the application answers for itself, first, before anything can raise. This
    is exactly what phosphor.exe does; see host/console/phosphor.lpr. }
  TAppCrashGuard = class
    class procedure Report(Sender: TObject; E: Exception);
  end;

class procedure TAppCrashGuard.Report(Sender: TObject; E: Exception);
begin
  { A real application logs here, and saves whatever the user has open, before it
    says anything. The message box is this demo being a demo: it is the one place
    a dialog is the right answer, because there IS somebody in front of it. }
  try
    MessageDlg('Phosphor demo',
               'The application itself faulted -- this is NOT the script engine.'
               + LineEnding + LineEnding + E.ClassName + ': ' + E.Message
               + LineEnding + LineEnding +
               'A real application would save the user''s work here, then close.',
               mtError, [mbOK], 0);
  except
    // nowhere left to say it; the exit code still carries the news
  end;
  Halt(3);
end;

var
  Demo: TDemoForm;

begin
  Application.Title := 'Phosphor demo';
  Application.OnException := @TAppCrashGuard.Report;   // never the LCL's dialog
  RequireDerivedFormResource := False;   // the form is built in code; see mainform.pas
  Application.Initialize;
  Demo := TDemoForm.CreateNew(Application);
  Demo.Show;
  Application.Run;
end.
