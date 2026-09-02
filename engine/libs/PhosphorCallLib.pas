{******************************************************************************
  Phosphor BASIC -- indirect call library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  callfunc calls a BASIC user function chosen at run time by name, and returns
  its result. It is the language-visible face of the engine's host-callback seam
  (TPhosphorVM.CallUserFunc): the SAME re-entrant path a GUI event dispatcher
  uses to run a handler. Proving it here, headless and with no GUI at all, freezes
  the seam before phase 2's LCL host is built on top of it.

    callfunc(name$)          call name$ with no arguments
    callfunc(name$, x)       call name$ with one argument (any kind)

  The suffix on the call (none / % / $ / @ / ?) is chosen to read as the callee's
  return type -- one spelling for each of the five value kinds, so a caller writes
  `n% = callfunc%(...)` or `ok? = callfunc?(...)` and it reads right. Every spelling
  runs the same primitive, and the value that comes back is whatever the routine
  returned (its kind is checked where it is finally stored, like any other value).
  The routine runs over the caller's globals and handles,
  so it can read and change shared state -- an event handler bumping a counter is
  the canonical use.

  This package registers host-aware functions (AddHost): the VM hands each call
  the executing engine so it can re-enter BASIC. It is still host-agnostic -- the
  boundary check passes -- because "run a BASIC routine" needs no console, file or
  window, only the VM already on the stack.
******************************************************************************}
unit PhosphorCallLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorVM;

procedure RegisterCallFuncs(Reg: TPhosphorRegistry);

implementation

{ callfunc(name$) -- no argument beyond the name. }
function f_call0(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Result := TPhosphorVM(AVM).CallUserFunc(Args[0].Str, [], Err);
end;

{ callfunc(name$, x) -- one argument of any kind, passed straight through. }
function f_call1(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Result := TPhosphorVM(AVM).CallUserFunc(Args[0].Str, [Args[1]], Err);
end;

procedure RegisterCallFuncs(Reg: TPhosphorRegistry);
const
  { One return-suffix spelling per value kind (none / % / $ / @ / ?); all share one
    impl -- the suffix only tells the caller's reader (and the compiler) the kind. }
  Names: array[0..4] of String = ('callfunc', 'callfunc%', 'callfunc$', 'callfunc@', 'callfunc?');
  { The one argument may be any of the five kinds. }
  ArgCodes: array[0..4] of Char = ('n', '%', '$', '@', '?');
var
  s, a: Integer;
begin
  for s := 0 to High(Names) do
  begin
    Reg.AddHost(Names[s] + ':$', @f_call0);
    for a := 0 to High(ArgCodes) do
      Reg.AddHost(Names[s] + ':$' + ArgCodes[a], @f_call1);
  end;
end;

end.
