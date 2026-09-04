{******************************************************************************
  Phosphor BASIC -- host-services library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  The language-visible face of the engine's host-services seam (THostServices on
  the VM). These are the functions that, in a lesser design, would have to reach
  into a windowing framework for an event loop or the system clipboard -- and so
  would drag a GUI dependency into anything that used them. Here they stay
  host-agnostic: each asks the VM's HostServices seam, which a host fills in and a
  headless runner leaves empty.

    processmessages()   pump the host event loop; 1 if a host pumped, else 0
    handlemessage()     wait for/dispatch one host message; 1 if it could, else 0
    copytext$(s$)       put s$ on the host clipboard; returns the text it stored,
                        or "" when there is no clipboard service (and sets strerror)
    pastetext$()        read the host clipboard; returns its text, or "" with none
    strerror()          the last host-services error code -- 0 when clear, non-zero
                        when the previous copytext$/pastetext$ found no service

  Empty is a real answer, not a failure. With no seam installed the calls return
  their empty answer instead of pretending or crashing; the guarding invariant is
  that asking an absent service NEVER dereferences a nil method. A missing
  clipboard is, additionally, an error the SCRIPT can see (strerror), so a program
  can offer a fallback rather than being surprised.

  These register as host-aware functions (AddHost) because they consult the VM's
  seam; they are still host-agnostic -- the boundary check passes -- because the
  seam is a plain method pointer the VM already carries, and this unit reaches no
  console, file or window. The platform work lives in a host that installs the
  methods; the engine only ever offers the seam.
******************************************************************************}
unit PhosphorHostLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorVM;

procedure RegisterHostFuncs(Reg: TPhosphorRegistry);

implementation

const
  SERR_NONE                 = 0;   // clear: the last clipboard call succeeded
  SERR_NO_CLIPBOARD_SERVICE = 1;   // there was no host clipboard to talk to

var
  { The last host-services error code, read back by strerror(). Set by the
    clipboard functions: 0 on success, non-zero when no service answered. A
    module-level last-error, exactly like PhosphorIoLib's GIoError and StrLib's
    valcode -- the failure is a value the script inspects, not an exception. }
  GStrError: Integer;

{ processmessages() -- 1 where a host installed an event pump, 0 where none. }
function h_processmessages(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var vm: TPhosphorVM;
begin
  Err := NoError();
  vm := TPhosphorVM(AVM);
  if Assigned(vm.HostServices.ProcessMessages) then
    Result := ValInt(vm.HostServices.ProcessMessages())
  else
    Result := ValInt(0);
end;

{ handlemessage() -- the same, for a single wait-for/dispatch-one-message. }
function h_handlemessage(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var vm: TPhosphorVM;
begin
  Err := NoError();
  vm := TPhosphorVM(AVM);
  if Assigned(vm.HostServices.HandleMessage) then
    Result := ValInt(vm.HostServices.HandleMessage())
  else
    Result := ValInt(0);
end;

{ copytext$(s$) -- store s$ on the host clipboard and hand back what was stored.
  With no clipboard service it stores nothing, returns "", and records the error
  so strerror() can report it. It NEVER raises: an unassigned seam is the empty
  answer, not an access violation. }
function h_copytext(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var vm: TPhosphorVM;
begin
  Err := NoError();
  vm := TPhosphorVM(AVM);
  if Assigned(vm.HostServices.ClipboardCopy) and vm.HostServices.ClipboardCopy(Args[0].Str) then
  begin
    GStrError := SERR_NONE;
    Result := ValStr(Args[0].Str);
  end
  else
  begin
    GStrError := SERR_NO_CLIPBOARD_SERVICE;
    Result := ValStr('');
  end;
end;

{ pastetext$() -- read the host clipboard back, or "" when there is no service
  (again recording the error). Never raises. }
function h_pastetext(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var vm: TPhosphorVM; s: String;
begin
  Err := NoError();
  vm := TPhosphorVM(AVM);
  s := '';
  if Assigned(vm.HostServices.ClipboardPaste) and vm.HostServices.ClipboardPaste(s) then
  begin
    GStrError := SERR_NONE;
    Result := ValStr(s);
  end
  else
  begin
    GStrError := SERR_NO_CLIPBOARD_SERVICE;
    Result := ValStr('');
  end;
end;

{ strerror() -- the last host-services error code. Plain (no VM needed): it only
  reads the module-level last-error the clipboard functions leave behind. }
function h_strerror(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(GStrError);
end;

procedure RegisterHostFuncs(Reg: TPhosphorRegistry);
begin
  Reg.AddHost('processmessages:', @h_processmessages);
  Reg.AddHost('handlemessage:',   @h_handlemessage);
  Reg.AddHost('copytext$:$',      @h_copytext);
  Reg.AddHost('pastetext$:',      @h_pastetext);
  Reg.Add('strerror:',            @h_strerror);
end;

initialization
  GStrError := SERR_NONE;

end.
