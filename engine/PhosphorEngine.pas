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
  PhosphorCompiler, PhosphorVM, PhosphorHandles, PhosphorBytecode, PhosphorSandbox,
  // library packages (engine/libs)
  PhosphorArrayLib, PhosphorDictLib, PhosphorStrListLib, PhosphorStrLib, PhosphorNumLib,
  PhosphorJsonLib, PhosphorDateTimeLib, PhosphorRegexLib, PhosphorIoLib, PhosphorBufferLib,
  PhosphorConfigLib,
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
    FOnInput: TPhosphorInputProc;
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
    FReplVM: TPhosphorVM;   // the live VM of a REPL session
    FReplProg: TProgram;    // the session's compiled program (all lines so far)
    FReplSource: String;    // every line accepted so far
    FReplPC: Integer;       // first instruction of the NEXT line
    function CompileSource(const ASource: String; out AProg: TProgram): Boolean;
    procedure ConfigureVM(AVM: TPhosphorVM);
    function GetSandboxRoot: String;
    procedure SetSandboxRootProp(const AValue: String);
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
    { REPL SESSION. ReplRun compiles the whole session so far plus ALine and executes
      only the instructions the new line added, over the state the previous lines
      built -- so `a = 10` on one line and `println a` on the next work, and a
      function defined earlier stays callable.

      Why recompiling is safe: the compiler allocates a global's index on the name's
      FIRST appearance, so appending source only appends names and every earlier
      index is unchanged; likewise instructions are emitted in order, so the earlier
      ones keep their positions and are simply not re-executed.

      Returns 0, or the 1-based line of the error (ErrorMessage explains it). A line
      that fails to COMPILE is rejected and the session is left untouched, so the
      next line sees the same state; a line that compiles but faults at run time is
      kept (its instructions are part of the program) and is not re-run.
      ReplReset starts over. }
    function ReplRun(const ALine: String): Integer;
    procedure ReplReset;
    property Registry: TPhosphorRegistry read FRegistry;
    property OnOutput: TPhosphorOutputProc read FOnOutput write FOnOutput;
    { The INPUT seam. Nil by default: a headless host installs none, and INPUT /
      LINE INPUT / INPUT$ then read as empty. A console host wires it to a line
      reader; the engine only ever offers the seam. }
    property OnInput: TPhosphorInputProc read FOnInput write FOnInput;
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
    { The FOURTH ceiling, and the only one that bounds WHERE rather than how long.
      '' (the default) = no sandbox: every path a script names reaches the real
      filesystem, which is what a trusted script wants and what every host did
      before this existed. Set it and every file, directory, channel and package
      call must resolve inside that directory -- '..' and symlinks included -- or
      it is refused, and the platform's scratch directories (temppath$, homepath$,
      cfg_path$) answer inside the root instead of outside it. Reading it back
      answers the root actually installed, which is the resolved absolute path,
      or '' if the directory could not be made.

      PROCESS-WIDE, unlike the other three: a library function is a plain callback
      with no VM to ask, so two engines in one process share one root. Setting it
      from a host with several engines sets it for all of them. }
    property SandboxRoot: String read GetSandboxRoot write SetSandboxRootProp;
  end;

implementation

constructor TPhosphorEngine.Create;
begin
  inherited Create();
  // Fire loudly if an opcode was renumbered -- a silent bytecode-format break.
  if not VerifyOpcodeNumbering() then
    raise EPhosphorInternal.Create('opcode numbering is corrupt (see PhosphorOpcodes)');
  FRegistry := TPhosphorRegistry.Create();
  RegisterArrayFuncs(FRegistry);   // built-in library packages (engine/libs)
  RegisterDictFuncs(FRegistry);
  RegisterStrListFuncs(FRegistry);
  RegisterStrFuncs(FRegistry);
  RegisterNumFuncs(FRegistry);
  RegisterJsonFuncs(FRegistry);
  RegisterDateTimeFuncs(FRegistry);
  RegisterRegexFuncs(FRegistry);
  RegisterIoFuncs(FRegistry);
  RegisterBufferFuncs(FRegistry);   // the mutable half of byte work; shares Io's TPhosphorBytes
  RegisterConfigFuncs(FRegistry);
  RegisterSysFuncs(FRegistry);
  RegisterPlatformFuncs(FRegistry);
  RegisterCallFuncs(FRegistry);
  RegisterErrFuncs(FRegistry);
  RegisterHostFuncs(FRegistry);
  RegisterRagFuncs(FRegistry);
  FOnOutput := nil;
  FOnInput := nil;
  FOnBreakpoint := nil;
  FHostServices := Default(THostServices);
  FErrorLine := 0;
  FErrorMessage := '';
  FLastError := NoError();
  FMaxSteps := 0;
  FMaxOutputBytes := 0;
  FTimeoutMs := 0;
  FVM := nil;
  FProg := nil;
  FReplVM := nil;
  FReplProg := nil;
  FReplSource := '';
  FReplPC := 0;
end;

destructor TPhosphorEngine.Destroy;
begin
  Finish();
  ReplReset();
  FRegistry.Free;
  inherited Destroy();
end;

{ Compile ASource; on failure fill the engine error state and return False. }
function TPhosphorEngine.CompileSource(const ASource: String; out AProg: TProgram): Boolean;
var
  comp: TPhosphorCompiler;
begin
  comp := TPhosphorCompiler.Create();
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

function TPhosphorEngine.GetSandboxRoot: String;
begin
  Result := PhosphorSandbox.SandboxRoot;
end;

procedure TPhosphorEngine.SetSandboxRootProp(const AValue: String);
begin
  PhosphorSandbox.SetSandboxRoot(AValue);
end;

procedure TPhosphorEngine.ConfigureVM(AVM: TPhosphorVM);
begin
  AVM.Registry := FRegistry;
  AVM.OnOutput := FOnOutput;
  AVM.OnInput := FOnInput;
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
  FLastError := NoError();
  Finish();         // a one-shot run discards any prepared state
  ResetHandles();   // no handles leak between programs

  if not CompileSource(ASource, prog) then Exit(FErrorLine);

  vm := TPhosphorVM.Create();
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
  FLastError := NoError();
  Finish();
  ResetHandles();

  if not ReadProgram(AStream, prog, err) then
  begin
    FErrorMessage := err;
    FErrorLine := 1;
    FLastError := MakeError(peSyntax, err);
    Exit(1);
  end;

  vm := TPhosphorVM.Create();
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
  FLastError := NoError();
  Finish();         // discard a previous preparation
  ResetHandles();

  if not CompileSource(ASource, FProg) then Exit(FErrorLine);

  FVM := TPhosphorVM.Create();
  ConfigureVM(FVM);
  if not FVM.Run(FProg) then   // run the top level once; the VM stays alive after
  begin
    FLastError := FVM.LastError;
    FErrorMessage := FVM.LastError.Message;
    FErrorLine := FVM.ErrorLine;
    if FErrorLine = 0 then FErrorLine := 1;
    Finish();
    Exit(FErrorLine);
  end;
  Result := 0;
end;

function TPhosphorEngine.CallFunction(const AName: String; const Args: array of TValue): TValue;
begin
  FErrorMessage := '';
  FLastError := NoError();
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
    ResetHandles();   // the prepared program's handles go with it
  end;
  if FProg <> nil then
  begin
    FProg.Free;
    FProg := nil;
  end;
end;

procedure TPhosphorEngine.ReplReset;
begin
  if FReplVM <> nil then
  begin
    FReplVM.Free;
    FReplVM := nil;
    ResetHandles();
  end;
  if FReplProg <> nil then
  begin
    FReplProg.Free;
    FReplProg := nil;
  end;
  FReplSource := '';
  FReplPC := 0;
end;

function TPhosphorEngine.ReplRun(const ALine: String): Integer;
var
  cand: String;
  prog, old: TProgram;
  startPC: Integer;
begin
  FErrorLine := 0;
  FErrorMessage := '';
  FLastError := NoError();
  cand := FReplSource + ALine + #10;
  // A line that does not compile never joins the session.
  if not CompileSource(cand, prog) then Exit(FErrorLine);

  if FReplVM = nil then
  begin
    Finish();         // a session and a prepared script do not share a VM
    ResetHandles();
    FReplVM := TPhosphorVM.Create();
    ConfigureVM(FReplVM);
  end;

  startPC := FReplPC;
  old := FReplProg;
  FReplProg := prog;                 // the VM runs the NEW program from here on
  FReplSource := cand;
  FReplPC := prog.Count;
  Result := 0;
  if not FReplVM.RunFrom(prog, startPC) then
  begin
    FLastError := FReplVM.LastError;
    FErrorMessage := FReplVM.LastError.Message;
    FErrorLine := FReplVM.ErrorLine;
    if FErrorLine = 0 then FErrorLine := 1;
    Result := FErrorLine;
  end;
  // Safe only now: the VM no longer refers to the previous program, and every value
  // that came out of its constant pool is reference-counted in the globals.
  if old <> nil then old.Free;
end;

end.
