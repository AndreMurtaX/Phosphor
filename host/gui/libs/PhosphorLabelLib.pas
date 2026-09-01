{******************************************************************************
  Phosphor BASIC -- label library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

    label@(parent@)  label@(parent@, caption$)   a static text label
    label_caption@(l@, s$)   label_caption$(l@)

  A label is a TControl (not a TWinControl): no window handle, no focus. Its
  geometry, colour, font, alignment and the rest come from PhosphorControlLib and
  the generic property bridge (autosize, wordwrap, alignment are `control_set@(l,
  "AutoSize"/"WordWrap"/"Alignment", ...)`); this package adds only the caption.
******************************************************************************}
unit PhosphorLabelLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, StdCtrls,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterLabelFuncs(Reg: TPhosphorRegistry);

implementation

function f_label(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  pc: TComponent;
  lbl: TLabel;
begin
  Err := NoError;
  if not GuiResolve(Args[0].Hnd, TWinControl, pc) then
  begin
    Result := ValHandle(0);
    Exit;
  end;
  lbl := TLabel.Create(pc);
  lbl.Parent := TWinControl(pc);
  if Length(Args) >= 2 then lbl.Caption := Args[1].Str;
  Result := ValHandle(GuiRegister(lbl, False));
end;

function f_caption_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TLabel, c) then TLabel(c).Caption := Args[1].Str;
  Result := Args[0];
end;

function f_caption_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TLabel, c) then Result := ValStr(TLabel(c).Caption)
  else Result := ValStr('');
end;

// --- static text (a bordered, non-word-wrapping caption) --------------------
function f_statictext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pc: TComponent; st: TStaticText;
begin
  Err := NoError;
  if not GuiResolve(Args[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  st := TStaticText.Create(pc);
  st.Parent := TWinControl(pc);
  if Length(Args) >= 2 then st.Caption := Args[1].Str;
  Result := ValHandle(GuiRegister(st, False));
end;
function f_st_caption_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TStaticText, c) then TStaticText(c).Caption := Args[1].Str; Result := Args[0]; end;
function f_st_caption_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TStaticText, c) then Result := ValStr(TStaticText(c).Caption) else Result := ValStr(''); end;

procedure RegisterLabelFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('label@:@',   @f_label);
  Reg.Add('label@:@$',  @f_label);
  Reg.Add('label_caption@:@$', @f_caption_set);
  Reg.Add('label_caption$:@',  @f_caption_get);
  Reg.Add('statictext@:@',  @f_statictext);
  Reg.Add('statictext@:@$', @f_statictext);
  Reg.Add('statictext_caption@:@$', @f_st_caption_set);
  Reg.Add('statictext_caption$:@',  @f_st_caption_get);
end;

end.
