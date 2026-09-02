{******************************************************************************
  Phosphor BASIC -- engine facade (the public seam of the library)

  MIT License. Copyright (c) 2026 Andre Murta.

  The engine is a library: it knows nothing about consoles, files, windows or the
  LCL. Everything it shows the outside world leaves through OnOutput; a host
  registers function packages into Registry. This replaces the phase-0 walking
  skeleton (which understood only PRINT/PRINTLN of a literal) with the real
  pipeline: lexer -> compiler -> stack VM over the five-kind value model.

  Run returns 0 on success, or the 1-based source line of the first error;
  ErrorMessage then explains it. Errors are reported, not raised.
******************************************************************************}
unit PhosphorEngine;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes,
  PhosphorValue, PhosphorErrors, PhosphorOpcodes, PhosphorRegistry,
  PhosphorCompiler, PhosphorVM, PhosphorHandles, PhosphorBytecode,
  // library packages (engine/libs)
  PhosphorArrayLib, PhosphorDictLib, PhosphorStrListLib, PhosphorStrLib, PhosphorNumLib,
  PhosphorJsonLib, PhosphorDateTimeLib, PhosphorRegexLib, PhosphorIoLib, PhosphorConfigLib,
  PhosphorSysLib, PhosphorPlatformLib, PhosphorCallLib, PhosphorErrLib, PhosphorHostLib,
  PhosphorRagLib;

const
  PhosphorVersion = '0.0.1';

type
  EPhosphorInternal = class(Exception);

  TPhosphorEngine = class
  private
    FRegistry: TPhosphorRegistry;
    FOnOutput: TPhosphorOutputProc;
    FOnBreakpoint: TPhosphorBreakpointProc;
    FHostServices: THostServices;
    FErrorLine: Integer;
    FErrorMessage: String;
    FLastError: TPhosphorError;
    FMaxSteps: Int64;
    FMaxOutputBytes: Int64;
    FTimeoutMs: Int64;
    FVM: TPhosphorVM;       // the live VM in the prepared (embedding) mode
    FProg: TProgram;        // its compiled program
    function CompileSource(const ASource: String; out AProg: TProgram): Boolean;
    procedure ConfigureVM(AVM: TPhosphorVM);
  public
    constructor Create;
    destructor Destroy; override;
    { Compile and run ASource (UTF-8) to completion, one-shot. 0 on success;
      otherwise the 1-based line of the first error (ErrorMessage explains it). }
    function Run(const ASource: String): Integer;
    { Run a compiled .pbc read from AStream (a TFileStream, a TBytesStream, ...) --
      no lexer or compiler involved. 0 on success; 1 if the stream is not a valid
      .pbc (ErrorMessage says why: bad magic, wrong version, opcode-set mismatch, or
      corruption); otherwise the 1-based line of the first run-time error. }
    function RunBytecode(AStream: TStream): Integer;
    { Embedding mode: compile ASource and run its top level ONCE, keeping the VM
      alive so a host can then call the routines it defined, over the same globals
      and handles, as many times as it likes. 0 on success, else the error line.
      A second Prepare (or Finish) discards the previous one. }
    function Prepare(const ASource: String): Integer;
    { Call a BASIC function on the prepared VM and return its value. Sets LastError
      / ErrorMessage (and returns a default value) if nothing is prepared, the
      function is unknown, or it fails. }
    function CallFunction(const AName: String; const Args: array of TValue): TValue;
    { Discard the prepared VM and its handles. Called by Destroy. }
    procedure Finish;
    property Registry: TPhosphorRegistry read FRegistry;
    property OnOutput: TPhosphorOutputProc read FOnOutput write FOnOutput;
    { The BREAKPOINT seam. Nil by default: with none installed (a headless host),
      BREAKPOINT reports nothing and continues. A host that wants a debug pause
      assigns a report-only callback here -- the engine never blocks on it. }
    property OnBreakpoint: TPhosphorBreakpointProc read FOnBreakpoint write FOnBreakpoint;
    { The host-services seam. Empty by default (a headless host installs none), so
      processmessages/handlemessage answer 0 and copytext$/pastetext$ answer "".
      A GUI host assigns the pump and clipboard methods it can provide; the engine
      never blocks and never faults on a field left nil. }
    property HostServices: THostServices read FHostServices write FHostServices;
    property ErrorLine: Integer read FErrorLine;
    property ErrorMessage: String read FErrorMessage;
    property LastError: TPhosphorError read FLastError;
    { Execution ceilings for running untrusted scripts; 0 (the default) = no limit.
      A ceiling is fatal -- ON ERROR cannot catch it -- so a script cannot escape
      it. LastError.Code is peLimit when one is hit. }
    property MaxSteps: Int64 read FMaxSteps write FMaxSteps;
    property MaxOutputBytes: Int64 read FMaxOutputBytes write FMaxOutputBytes;
    property TimeoutMs: Int64 read FTimeoutMs write FTimeoutMs;
  end;

implementation

constructor TPhosphorEngine.Create;
begin
  inherited Create;
  // Fire loudly if an opcode was renumbered -- a silent bytecode-format break.
  if not VerifyOpcodeNumbering then
    raise EPhosphorInternal.Create('opcode numbering is corrupt (see PhosphorOpcodes)');
  FRegistry := TPhosphorRegistry.Create;
  RegisterArrayFuncs(FRegistry);   // built-in library packages (engine/libs)
  RegisterDictFuncs(FRegistry);
  RegisterStrListFuncs(FRegistry);
  RegisterStrFuncs(FRegistry);
  RegisterNumFuncs(FRegistry);
  RegisterJsonFuncs(FRegistry);
  RegisterDateTimeFuncs(FRegistry);
  RegisterRegexFuncs(FRegistry);
  RegisterIoFuncs(FRegistry);
  RegisterConfigFuncs(FRegistry);
  RegisterSysFuncs(FRegistry);
  RegisterPlatformFuncs(FRegistry);
  RegisterCallFuncs(FRegistry);
  RegisterErrFuncs(FRegistry);
  RegisterHostFuncs(FRegistry);
  RegisterRagFuncs(FRegistry);
  FOnOutput := nil;
  FOnBreakpoint := nil;
  FHostServices := Default(THostServices);
  FErrorLine := 0;
  FErrorMessage := '';
  FLastError := NoError;
  FMaxSteps := 0;
  FMaxOutputBytes := 0;
  FTimeoutMs := 0;
  FVM := nil;
  FProg := nil;
end;

destructor TPhosphorEngine.Destroy;
begin
  Finish;
  FRegistry.Free;
  inherited Destroy;
end;

{ Compile ASource; on failure fill the engine error state and return False. }
function TPhosphorEngine.CompileSource(const ASource: String; out AProg: TProgram): Boolean;
var
  comp: TPhosphorCompiler;
begin
  comp := TPhosphorCompiler.Create;
  try
    Result := comp.Compile(ASource, AProg);
    if not Result then
    begin
      FErrorMessage := comp.ErrorMessage;
      FErrorLine := comp.ErrorLine;
      if FErrorLine = 0 then FErrorLine := 1;
      FLastError := MakeError(peSyntax, FErrorMessage);
    end;
  finally
    comp.Free;
  end;
end;

procedure TPhosphorEngine.ConfigureVM(AVM: TPhosphorVM);
begin
  AVM.Registry := FRegistry;
  AVM.OnOutput := FOnOutput;
  AVM.OnBreakpoint := FOnBreakpoint;
  AVM.HostServices := FHostServices;
  AVM.MaxSteps := FMaxSteps;
  AVM.MaxOutputBytes := FMaxOutputBytes;
  AVM.TimeoutMs := FTimeoutMs;
end;

function TPhosphorEngine.Run(const ASource: String): Integer;
var
  vm: TPhosphorVM;
  prog: TProgram;
begin
  FErrorLine := 0;
  FErrorMessage := '';
  FLastError := NoError;
  Finish;         // a one-shot run discards any prepared state
  ResetHandles;   // no handles leak between programs

  if not CompileSource(ASource, prog) then Exit(FErrorLine);

  vm := TPhosphorVM.Create;
  try
    ConfigureVM(vm);
    if not vm.Run(prog) then
    begin
      FLastError := vm.LastError;
      FErrorMessage := vm.LastError.Message;
      FErrorLine := vm.ErrorLine;
      if FErrorLine = 0 then FErrorLine := 1;
      Exit(FErrorLine);
    end;
    Result := 0;
  finally
    vm.Free;
    prog.Free;
  end;
end;

function TPhosphorEngine.RunBytecode(AStream: TStream): Integer;
var
  vm: TPhosphorVM;
  prog: TProgram;
  err: String;
begin
  FErrorLine := 0;
  FErrorMessage := '';
  FLastError := NoError;
  Finish;
  ResetHandles;

  if not ReadProgram(AStream, prog, err) then
  begin
    FErrorMessage := err;
    FErrorLine := 1;
    FLastError := MakeError(peSyntax, err);
    Exit(1);
  end;

  vm := TPhosphorVM.Create;
  try
    ConfigureVM(vm);
    if not vm.Run(prog) then
    begin
      FLastError := vm.LastError;
      FErrorMessage := vm.LastError.Message;
      FErrorLine := vm.ErrorLine;
      if FErrorLine = 0 then FErrorLine := 1;
      Exit(FErrorLine);
    end;
    Result := 0;
  finally
    vm.Free;
    prog.Free;
  end;
end;

function TPhosphorEngine.Prepare(const ASource: String): Integer;
begin
  FErrorLine := 0;
  FErrorMessage := '';
  FLastError := NoError;
  Finish;         // discard a previous preparation
  ResetHandles;

  if not CompileSource(ASource, FProg) then Exit(FErrorLine);

  FVM := TPhosphorVM.Create;
  ConfigureVM(FVM);
  if not FVM.Run(FProg) then   // run the top level once; the VM stays alive after
  begin
    FLastError := FVM.LastError;
    FErrorMessage := FVM.LastError.Message;
    FErrorLine := FVM.ErrorLine;
    if FErrorLine = 0 then FErrorLine := 1;
    Finish;
    Exit(FErrorLine);
  end;
  Result := 0;
end;

function TPhosphorEngine.CallFunction(const AName: String; const Args: array of TValue): TValue;
begin
  FErrorMessage := '';
  FLastError := NoError;
  FErrorLine := 0;
  if FVM = nil then
  begin
    FLastError := MakeError(peRuntime, 'no script is prepared (call Prepare first)');
    FErrorMessage := FLastError.Message;
    Exit(Default(TValue));
  end;
  Result := FVM.CallUserFunc(AName, Args, FLastError);
  if IsError(FLastError) then
  begin
    FErrorMessage := FLastError.Message;
    FErrorLine := FVM.ErrorLine;
  end;
end;

procedure TPhosphorEngine.Finish;
begin
  if FVM <> nil then
  begin
    FVM.Free;
    FVM := nil;
    ResetHandles;   // the prepared program's handles go with it
  end;
  if FProg <> nil then
  begin
    FProg.Free;
    FProg := nil;
  end;
end;

end.
