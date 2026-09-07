{******************************************************************************
  Phosphor BASIC -- the Lazarus demo's window.

  MIT License. Copyright (c) 2026 Andre Murta.

  There are no decisions in this file. Every one of them is in
  PhosphorDemoRunner, which has no LCL attached and which demo_smoke.lpr
  exercises in the suite on both operating systems. What is left here is the
  arrangement of six controls and the wiring of two clicks.

  THE CONTROLS ARE BUILT IN CODE AND THERE IS NO .lfm, deliberately. A .lfm
  resolves its property names when the form is STREAMED, not when the unit is
  compiled, so a typo in one is a run-time EReadError that no compile and no
  headless check would catch -- and this demo has to survive a machine with no
  display, which is where the suite runs it. Built in code, every control is
  checked by the compiler, and the whole window is one screen of readable Pascal
  for somebody who came here to copy the integration rather than the layout.

  The integration itself is nine lines and it is in PhosphorDemoRunner, not here:
  create a TPhosphorEngine, point OnOutput at something, add your own functions
  to its Registry, set the ceilings, set ContainFaults, call Run, read
  LastError.Code. That is the whole API this demo is demonstrating.
******************************************************************************}
unit MainForm;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Graphics, Controls, Forms, StdCtrls, ExtCtrls, ComCtrls,
  PhosphorDemoRunner;

type
  TDemoForm = class(TForm)
  private
    FExamples: TListBox;
    FSource: TMemo;
    FOutput: TMemo;
    FRun: TButton;
    FStatus: TStatusBar;
    procedure ExampleChosen(Sender: TObject);
    procedure RunClicked(Sender: TObject);
    function SourceFor(AIndex: Integer): String;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
  end;

implementation

const
  { The five the smoke test asserts, in the same order, from the same unit --
    so the window and the check cannot drift apart. }
  ExampleNames: array[0..4] of String = (
    '1. hello, and calling back into the application',
    '2. the script handles its own error',
    '3. nobody handles it, so the host is told',
    '4. a runaway loop meets a ceiling',
    '5. a bug in the HOST''s own function'
  );

constructor TDemoForm.CreateNew(AOwner: TComponent; Num: Integer);
var
  leftPane: TPanel;
begin
  inherited CreateNew(AOwner, Num);
  Caption := 'Phosphor BASIC — embedded in a Lazarus application';
  Width := 980;
  Height := 660;
  Position := poScreenCenter;

  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := True;
  FStatus.SimpleText := 'Pick an example, then Run.';

  leftPane := TPanel.Create(Self);
  leftPane.Parent := Self;
  leftPane.Align := alLeft;
  leftPane.Width := 320;
  leftPane.BevelOuter := bvNone;

  FExamples := TListBox.Create(Self);
  FExamples.Parent := leftPane;
  FExamples.Align := alClient;
  FExamples.OnClick := @ExampleChosen;

  FRun := TButton.Create(Self);
  FRun.Parent := leftPane;
  FRun.Align := alBottom;
  FRun.Height := 40;
  FRun.Caption := 'Run';
  FRun.OnClick := @RunClicked;

  FSource := TMemo.Create(Self);
  FSource.Parent := Self;
  FSource.Align := alTop;
  FSource.Height := 300;
  FSource.ScrollBars := ssAutoBoth;
  FSource.WordWrap := False;
  FSource.Font.Name := 'Courier New';

  FOutput := TMemo.Create(Self);
  FOutput.Parent := Self;
  FOutput.Align := alClient;
  FOutput.ScrollBars := ssAutoBoth;
  FOutput.WordWrap := False;
  FOutput.ReadOnly := True;
  FOutput.Font.Name := 'Courier New';

  FExamples.Items.AddStrings(ExampleNames);
  FExamples.ItemIndex := 0;
  ExampleChosen(nil);
end;

function TDemoForm.SourceFor(AIndex: Integer): String;
begin
  case AIndex of
    0: Result := DemoScriptHello;
    1: Result := DemoScriptCaught;
    2: Result := DemoScriptUncaught;
    3: Result := DemoScriptRunaway;
    4: Result := DemoScriptHostFault;
  else
    Result := '';
  end;
end;

procedure TDemoForm.ExampleChosen(Sender: TObject);
begin
  FSource.Text := SourceFor(FExamples.ItemIndex);
  FOutput.Clear;
  FStatus.SimpleText := 'Ready. The source is editable — change it and Run.';
end;

procedure TDemoForm.RunClicked(Sender: TObject);
var
  r: TDemoResult;
begin
  { The whole of the demo, and the reason there is nothing else in this file:
    one call, and a record describing what happened. It cannot raise. }
  r := RunDemoScript(FSource.Text);

  FOutput.Lines.Text := r.Output;
  if r.HostLog <> '' then
  begin
    FOutput.Lines.Add('');
    FOutput.Lines.Add('--- what the script sent to app_log ---');
    FOutput.Lines.Add(TrimRight(r.HostLog));
  end;
  if r.Message <> '' then
  begin
    FOutput.Lines.Add('');
    FOutput.Lines.Add('--- what the host was told ---');
    FOutput.Lines.Add(r.Message);
  end;

  FStatus.SimpleText := OutcomeName(r.Outcome) +
                        '   (LastError.Code = ' + IntToStr(r.Code) + ')';

  { THE POINT OF EXAMPLE 5. The application is still here to say so. Without
    ContainFaults this line would never run: the access violation would have left
    Run as a Pascal exception and ended at the LCL's modal crash dialog, which on
    an unattended machine is a hang -- no message, no exit code, nothing to log. }
  if r.Outcome = doFault then
    FOutput.Lines.Add(
      LineEnding +
      'The interpreter faulted and this application is still running. It could ' +
      'now save the user''s work and shut down on its own terms. The engine ' +
      'instance is spent: a further Run would answer peFatal without executing ' +
      'anything, so a host that wants to carry on scripting builds a new one.');
end;

end.
