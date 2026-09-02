{******************************************************************************
  PhosphorTestLib -- assertion package for the headless test runner

  MIT License. Copyright (c) 2026 Andre Murta.

  Ported from Plan9Basic's tests/TestLib.pas: same idea (assert_* functions that
  always evaluate, count passes and failures, and let execution continue so one
  run reports every problem), adapted to Phosphor -- the ':' registry separator
  and the five-kind TValue. Added for Phosphor's founding-divergence probe:

    assert_true(?) / assert_false(?)   accept a bool VALUE (distinct '?' slot),
                                       proving comparison flows as a bool.
    assert_int(%%)                     both args are int% (dispatch to the '%'
                                       slot IS the proof the value stayed int).
    assert_add_overflows(%%)           the checked add of two int64s overflows,
                                       proving overflow is a catchable result and
                                       not a silent promotion.

  Also the HANDLE-REGISTRY probes (probe_new_a@/probe_new_b@/probe_is_handle/
  probe_is_a/probe_is_b/probe_free/probe_count). They live HERE, on the runner
  side, because they are throwaway stand-ins for the real GUI objects (which need
  a form + a message loop and cannot run headless). Each is backed by a trivial
  TProbeA/TProbeB registered in the engine's handle registry, so a library can
  validate/discriminate/revoke a BASIC handle WITHOUT dereferencing a fabricated
  address -- reusing IsHandle/HandleObj/FreeHandle, the same path that already
  rejects fabricated array/dict/stringlist handles. The live count is tracked
  runner-side (the registry keeps no live total), incremented on register and
  decremented only when a live probe is actually freed.

  This is host/test tooling, not engine code.
******************************************************************************}
unit PhosphorTestLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Math, PhosphorValue, PhosphorErrors, PhosphorRegistry,
  PhosphorHandles;

var
  AssertsPassed: Integer = 0;
  AssertsFailed: Integer = 0;
  Failures: TStringList = nil;
  CurrentCase: String = '';

procedure RegisterTestFuncs(Reg: TPhosphorRegistry);
procedure ResetTestState;

implementation

type
  { Two distinct throwaway classes registered in the handle registry, so a probe
    handle can be discriminated by class (is-this-handle-a-TProbeA) exactly the
    way a real GUI library discriminates a button from a label. They carry no
    state -- their identity is the whole point. }
  TProbeA = class end;
  TProbeB = class end;

var
  InvFS: TFormatSettings;
  ProbeLiveCount: Integer = 0;  // live probe instances the runner has registered

function NumStr(const V: Double): String;
begin
  Result := FloatToStr(V, InvFS);
end;

function NumEquals(const A, B: Double): Boolean;
var
  Eps: Double;
begin
  if A = B then Exit(True);
  Eps := 1E-12 * Max(1.0, Max(Abs(A), Abs(B)));
  Result := Abs(A - B) <= Eps;
end;

procedure RecordPass;
begin
  Inc(AssertsPassed);
end;

procedure RecordFail(const Msg: String);
var
  Where: String;
begin
  Inc(AssertsFailed);
  if CurrentCase <> '' then Where := CurrentCase + ': ' else Where := '';
  if Assigned(Failures) then
    Failures.Add(Where + Msg);
end;

procedure Check(Ok: Boolean; const Msg, Generated: String);
begin
  if Ok then RecordPass
  else if Msg <> '' then RecordFail(Msg + ' -- ' + Generated)
  else RecordFail(Generated);
end;

// --- bound functions --------------------------------------------------------
function t_test_case(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  CurrentCase := Args[0].Str;
  Result := ValInt(1);
end;

function t_assert_true(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := AsDouble(Args[0]) <> 0;
  Check(ok, '', 'expected true, got false');
  Result := ValInt(Ord(ok));
end;

function t_assert_true_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := AsDouble(Args[0]) <> 0;
  Check(ok, Args[1].Str, 'expected true, got false');
  Result := ValInt(Ord(ok));
end;

function t_assert_true_bool(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Check(Args[0].Bl, '', 'expected true, got false');
  Result := ValInt(Ord(Args[0].Bl));
end;

function t_assert_false(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := AsDouble(Args[0]) = 0;
  Check(ok, '', 'expected false, got true');
  Result := ValInt(Ord(ok));
end;

function t_assert_false_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := AsDouble(Args[0]) = 0;
  Check(ok, Args[1].Str, 'expected false, got true');
  Result := ValInt(Ord(ok));
end;

function t_assert_false_bool(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Check(not Args[0].Bl, '', 'expected false, got true');
  Result := ValInt(Ord(not Args[0].Bl));
end;

function t_assert_eq_num(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := NumEquals(AsDouble(Args[0]), AsDouble(Args[1]));
  Check(ok, '', 'expected ' + NumStr(AsDouble(Args[1])) + ', got ' + NumStr(AsDouble(Args[0])));
  Result := ValInt(Ord(ok));
end;

function t_assert_eq_num_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := NumEquals(AsDouble(Args[0]), AsDouble(Args[1]));
  Check(ok, Args[2].Str, 'expected ' + NumStr(AsDouble(Args[1])) + ', got ' + NumStr(AsDouble(Args[0])));
  Result := ValInt(Ord(ok));
end;

function t_assert_eq_str(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := Args[0].Str = Args[1].Str;
  Check(ok, '', 'expected "' + Args[1].Str + '", got "' + Args[0].Str + '"');
  Result := ValInt(Ord(ok));
end;

function t_assert_eq_str_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := Args[0].Str = Args[1].Str;
  Check(ok, Args[2].Str, 'expected "' + Args[1].Str + '", got "' + Args[0].Str + '"');
  Result := ValInt(Ord(ok));
end;

function t_assert_near(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := Abs(AsDouble(Args[0]) - AsDouble(Args[1])) <= Abs(AsDouble(Args[2]));
  Check(ok, '', 'expected ' + NumStr(AsDouble(Args[1])) + ' +/- ' + NumStr(AsDouble(Args[2])) +
               ', got ' + NumStr(AsDouble(Args[0])));
  Result := ValInt(Ord(ok));
end;

function t_assert_near_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := Abs(AsDouble(Args[0]) - AsDouble(Args[1])) <= Abs(AsDouble(Args[2]));
  Check(ok, Args[3].Str, 'expected ' + NumStr(AsDouble(Args[1])) + ' +/- ' + NumStr(AsDouble(Args[2])) +
                         ', got ' + NumStr(AsDouble(Args[0])));
  Result := ValInt(Ord(ok));
end;

// The value stayed an int% -- dispatch to the '%%' slot only happens for int args.
function t_assert_int(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError;
  ok := Args[0].Int = Args[1].Int;
  Check(ok, '', 'expected int ' + IntToStr(Args[1].Int) + ', got ' + IntToStr(Args[0].Int));
  Result := ValInt(Ord(ok));
end;

// The checked add of two int64s overflows -- a catchable result, not a raise
// and not a silent double.
function t_assert_add_overflows(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: Int64; ok: Boolean;
begin
  Err := NoError;
  ok := not TryAddI64(Args[0].Int, Args[1].Int, r);
  Check(ok, '', 'expected overflow for ' + IntToStr(Args[0].Int) + ' + ' + IntToStr(Args[1].Int));
  Result := ValInt(Ord(ok));
end;

// --- handle-registry probes -------------------------------------------------
// A live probe handle is a real registry id; a fabricated one (pointer@(n)) is
// not, and IsHandle tells them apart WITHOUT dereferencing the address.

function t_probe_new_a(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValHandle(RegisterHandle(TProbeA.Create));
  Inc(ProbeLiveCount);
end;

function t_probe_new_b(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValHandle(RegisterHandle(TProbeB.Create));
  Inc(ProbeLiveCount);
end;

// Live registry id of ANY kind -> a handle; a fabricated/stale/nil id is not.
function t_probe_is_handle(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValInt(Ord((Args[0].Kind = vkHandle) and IsHandle(Args[0].Hnd)));
end;

// Class discrimination: a live handle reports ONLY its own class. This is the
// check that stops a wrong-class handle from writing through the wrong vtable.
function t_probe_is_a(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValInt(Ord((Args[0].Kind = vkHandle) and IsHandle(Args[0].Hnd)
                       and (HandleObj(Args[0].Hnd) is TProbeA)));
end;

function t_probe_is_b(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValInt(Ord((Args[0].Kind = vkHandle) and IsHandle(Args[0].Hnd)
                       and (HandleObj(Args[0].Hnd) is TProbeB)));
end;

// Revoke: free a live probe handle (1) and invalidate its id; a fabricated or
// already-stale handle is refused (0), never followed.
function t_probe_free(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean; obj: TObject;
begin
  Err := NoError;
  ok := False;
  if (Args[0].Kind = vkHandle) and IsHandle(Args[0].Hnd) then
  begin
    obj := HandleObj(Args[0].Hnd);
    ok := (obj is TProbeA) or (obj is TProbeB);
  end;
  if ok then
  begin
    FreeHandle(Args[0].Hnd);
    Dec(ProbeLiveCount);
  end;
  Result := ValInt(Ord(ok));
end;

function t_probe_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValInt(ProbeLiveCount);
end;

procedure RegisterTestFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('test_case:$', @t_test_case);

  Reg.Add('assert_true:n',   @t_assert_true);
  Reg.Add('assert_true:n$',  @t_assert_true_msg);
  Reg.Add('assert_true:?',   @t_assert_true_bool);
  Reg.Add('assert_false:n',  @t_assert_false);
  Reg.Add('assert_false:n$', @t_assert_false_msg);
  Reg.Add('assert_false:?',  @t_assert_false_bool);

  Reg.Add('assert_eq:nn',    @t_assert_eq_num);
  Reg.Add('assert_eq:nn$',   @t_assert_eq_num_msg);
  Reg.Add('assert_eq:$$',    @t_assert_eq_str);
  Reg.Add('assert_eq:$$$',   @t_assert_eq_str_msg);

  Reg.Add('assert_near:nnn',  @t_assert_near);
  Reg.Add('assert_near:nnn$', @t_assert_near_msg);

  Reg.Add('assert_int:%%',            @t_assert_int);
  Reg.Add('assert_add_overflows:%%',  @t_assert_add_overflows);

  Reg.Add('probe_new_a@:',   @t_probe_new_a);
  Reg.Add('probe_new_b@:',   @t_probe_new_b);
  Reg.Add('probe_is_handle:@', @t_probe_is_handle);
  Reg.Add('probe_is_a:@',    @t_probe_is_a);
  Reg.Add('probe_is_b:@',    @t_probe_is_b);
  Reg.Add('probe_free:@',    @t_probe_free);
  Reg.Add('probe_count:',    @t_probe_count);
end;

procedure ResetTestState;
begin
  AssertsPassed := 0;
  AssertsFailed := 0;
  CurrentCase := '';
  ProbeLiveCount := 0;
  if Assigned(Failures) then Failures.Clear;
end;

initialization
  Failures := TStringList.Create;
  InvFS := DefaultFormatSettings;
  InvFS.DecimalSeparator := '.';
  InvFS.ThousandSeparator := #0;

finalization
  FreeAndNil(Failures);

end.
