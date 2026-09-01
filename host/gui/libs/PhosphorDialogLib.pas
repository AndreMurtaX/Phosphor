{******************************************************************************
  Phosphor BASIC -- dialog library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  The common dialogs. A dialog's Execute is MODAL -- it blocks until the user
  answers -- so it belongs to the interactive host, not the headless byte-exact
  suite (which would hang on it, the way setfocus did). What the suite checks is
  a dialog's CONFIGURATION; the one-shot convenience calls (msgbox, openfile$,
  ...) are provided for real programs and are documented interactive-only.

  Configured, then Execute'd in the interactive host:
    opendialog@()  savedialog@()  selectdirdialog@()  colordialog@()
    dialog_title@/$  dialog_filter@/$  dialog_filename@/$  dialog_initialdir@/$
    colordialog_color@/()
    dialog_execute(d@)                 -> 1 if accepted, 0 if cancelled  (modal)

  One-shot, modal (interactive host only):
    msgbox(msg$)  msgbox(msg$, title$)          show a message
    msgbox_confirm(msg$)                         -> 1 yes, 0 no
    openfile$([filter$])   savefile$([filter$])  -> the chosen path, or ""
    selectdir$()                                 -> the chosen folder, or ""
******************************************************************************}
unit PhosphorDialogLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, Dialogs, Graphics,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterDialogFuncs(Reg: TPhosphorRegistry);

implementation

// --- constructors -----------------------------------------------------------
function f_opendialog(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValHandle(GuiRegister(TOpenDialog.Create(nil), True)); end;
function f_savedialog(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValHandle(GuiRegister(TSaveDialog.Create(nil), True)); end;
function f_selectdirdialog(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValHandle(GuiRegister(TSelectDirectoryDialog.Create(nil), True)); end;
function f_colordialog(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValHandle(GuiRegister(TColorDialog.Create(nil), True)); end;

// --- shared configuration (TCommonDialog / TFileDialog) ---------------------
function f_title_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCommonDialog, c) then TCommonDialog(c).Title := A[1].Str; Result := A[0]; end;
function f_title_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCommonDialog, c) then Result := ValStr(TCommonDialog(c).Title) else Result := ValStr(''); end;
function f_filter_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TFileDialog, c) then TFileDialog(c).Filter := A[1].Str; Result := A[0]; end;
function f_filter_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TFileDialog, c) then Result := ValStr(TFileDialog(c).Filter) else Result := ValStr(''); end;
function f_filename_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TFileDialog, c) then TFileDialog(c).FileName := A[1].Str; Result := A[0]; end;
function f_filename_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TFileDialog, c) then Result := ValStr(TFileDialog(c).FileName) else Result := ValStr(''); end;
function f_initialdir_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TFileDialog, c) then TFileDialog(c).InitialDir := A[1].Str; Result := A[0]; end;
function f_initialdir_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TFileDialog, c) then Result := ValStr(TFileDialog(c).InitialDir) else Result := ValStr(''); end;
function f_colordialog_color_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TColorDialog, c) then TColorDialog(c).Color := TColor(Round(AsDouble(A[1]))); Result := A[0]; end;
function f_colordialog_color_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TColorDialog, c) then Result := ValInt(TColorDialog(c).Color) else Result := ValInt(0); end;

// --- modal actions (interactive host only) ----------------------------------
function f_dialog_execute(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TCommonDialog, c) then Result := ValInt(Ord(TCommonDialog(c).Execute)) else Result := ValInt(0); end;

function f_msgbox(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; ShowMessage(A[0].Str); Result := ValInt(0); end;
function f_msgbox_titled(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; MessageDlg(A[1].Str, A[0].Str, mtInformation, [mbOK], 0); Result := ValInt(0); end;
function f_msgbox_confirm(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValInt(Ord(MessageDlg(A[0].Str, mtConfirmation, [mbYes, mbNo], 0) = mrYes)); end;

function OneShotFile(ADlg: TOpenDialog; const AFilter: String): String;
begin
  Result := '';
  try
    if AFilter <> '' then ADlg.Filter := AFilter;
    if ADlg.Execute then Result := ADlg.FileName;
  finally
    ADlg.Free;
  end;
end;
function f_openfile(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(OneShotFile(TOpenDialog.Create(nil), '')); end;
function f_openfile_filter(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(OneShotFile(TOpenDialog.Create(nil), A[0].Str)); end;
function f_savefile(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(OneShotFile(TSaveDialog.Create(nil), '')); end;
function f_savefile_filter(const A: array of TValue; out E: TPhosphorError): TValue;
begin E := NoError; Result := ValStr(OneShotFile(TSaveDialog.Create(nil), A[0].Str)); end;
function f_selectdir(const A: array of TValue; out E: TPhosphorError): TValue;
var d: TSelectDirectoryDialog;
begin
  E := NoError; Result := ValStr('');
  d := TSelectDirectoryDialog.Create(nil);
  try if d.Execute then Result := ValStr(d.FileName); finally d.Free; end;
end;

procedure RegisterDialogFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('opendialog@:', @f_opendialog);
  Reg.Add('savedialog@:', @f_savedialog);
  Reg.Add('selectdirdialog@:', @f_selectdirdialog);
  Reg.Add('colordialog@:', @f_colordialog);
  Reg.Add('dialog_title@:@$', @f_title_set);  Reg.Add('dialog_title$:@', @f_title_get);
  Reg.Add('dialog_filter@:@$', @f_filter_set); Reg.Add('dialog_filter$:@', @f_filter_get);
  Reg.Add('dialog_filename@:@$', @f_filename_set); Reg.Add('dialog_filename$:@', @f_filename_get);
  Reg.Add('dialog_initialdir@:@$', @f_initialdir_set); Reg.Add('dialog_initialdir$:@', @f_initialdir_get);
  Reg.Add('colordialog_color@:@n', @f_colordialog_color_set); Reg.Add('colordialog_color:@', @f_colordialog_color_get);
  // modal (interactive host only)
  Reg.Add('dialog_execute:@', @f_dialog_execute);
  Reg.Add('msgbox:$', @f_msgbox);
  Reg.Add('msgbox:$$', @f_msgbox_titled);
  Reg.Add('msgbox_confirm:$', @f_msgbox_confirm);
  Reg.Add('openfile$:', @f_openfile);
  Reg.Add('openfile$:$', @f_openfile_filter);
  Reg.Add('savefile$:', @f_savefile);
  Reg.Add('savefile$:$', @f_savefile_filter);
  Reg.Add('selectdir$:', @f_selectdir);
end;

end.
