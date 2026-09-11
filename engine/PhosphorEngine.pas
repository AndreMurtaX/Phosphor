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
  PhosphorBudget,
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
    FErrorAtEof: Boolean;
    FErrorUnterminated: Boolean;
    FLastError: TPhosphorError;
    FMaxSteps: Int64;
    FMaxMemoryBytes: Int64;
    FMaxOutputBytes: Int64;
    FTimeoutMs: Int64;
    FContainFaults: Boolean;
    FVM: TPhosphorVM;       // the live VM in the prepared (embedding) mode
    FProg: TProgram;        // its compiled program
    FReplVM: TPhosphorVM;   // the live VM of a REPL session
    FReplProg: TProgram;    // the session's compiled program (all lines so far)
    FReplSource: String;    // every line accepted so far
    FReplPC: Integer;       // first instruction of the NEXT line
    function CompileSource(const ASource: String; out AProg: TProgram): Boolean;
    procedure ClearErrorState;
    procedure ConfigureVM(AVM: TPhosphorVM);
    function GetHalted: Boolean;
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
    { A host reading a line at a time asks this before deciding to wait for more:
      a message about a missing terminator means "unfinished" only if the input
      actually ran out -- that is, the PARSER asked for another token and the file
      had ended. A check that runs after the parse is finished answers False even
      though nothing is left to read: `goto nowhere` cannot be repaired by typing
      more. See TPhosphorCompiler.Fail. }
    property ErrorAtEndOfInput: Boolean read FErrorAtEof;
    { True when that failure was SOMETHING OPENED AND NEVER CLOSED -- an `if`, a
      loop, a `select case`, a `function`, or a JSON literal spread over several
      lines -- rather than any other syntax error. With ErrorAtEndOfInput it is the
      whole test a line-at-a-time host needs to decide between "read another line"
      and "reject this". Asking it is how a host avoids matching on the compiler's
      wording, which is not an interface. The name says "block" because that is
      what a person typing at a prompt is nearly always in the middle of; a literal
      continues for the same reason and answers the same way. }
    property ErrorUnterminatedBlock: Boolean read FErrorUnterminated;
    property LastError: TPhosphorError read FLastError;
    { Execution ceilings for running untrusted scripts; 0 (the default) = no limit.
      A ceiling is fatal -- ON ERROR cannot catch it -- so a script cannot escape
      it. LastError.Code is peLimit when one is hit.

      MaxSteps and TimeoutMs reach INSIDE a library call as well. The VM tests
      them between instructions, and a library call is one instruction, so until
      PhosphorBudget existed a single regex_find$ or string$ or pause() ran for
      as long as it liked with every ceiling set. Every entry point below installs
      the budget for the duration of the run (see PhosphorBudget's header for what
      a library does with it) and takes it down again afterwards, so the ceilings
      a host sets are the ceilings it gets. Setting neither leaves the budget
      inert and every library behaving exactly as it did before. }
    property MaxSteps: Int64 read FMaxSteps write FMaxSteps;
    property MaxOutputBytes: Int64 read FMaxOutputBytes write FMaxOutputBytes;
    property TimeoutMs: Int64 read FTimeoutMs write FTimeoutMs;
    { THE FOURTH CEILING, and the one the other three do not imply. They bound how
      LONG a script runs; this bounds how much HEAP it adds while running, measured
      from where the heap stood when the run began -- so it is about the script and
      not about how much your application was already holding.

      Without it, `s$ = string$(200000000, 97)` is refused by the work budget while
      three `s$ = s$ + s$` build 1.6 GB of string and 14.7 GB of peak in three
      instructions, and the run reports success. MaxSteps counts instructions and
      an instruction whose cost is O(n) defeats it; TimeoutMs stops such a run only
      after the allocation is made.

      0 (the default) is unlimited and costs one integer test per concatenation.
      Like the other three it is FATAL: ON ERROR cannot catch it. It is a ceiling,
      not a quota -- it does not prevent every overshoot, because a single
      allocation already under way cannot be interrupted; it stops the NEXT one.
      A host that must bound the process absolutely still wants a job object on
      Windows or an rlimit or cgroup on Linux. }
    property MaxMemoryBytes: Int64 read FMaxMemoryBytes write FMaxMemoryBytes;
    { KEEP THE HOST'S PROCESS ALIVE WHEN THE INTERPRETER TAKES A FAULT.

      The ceilings above bound what a script may SPEND. This bounds what a defect
      may COST. Off by default, because it changes what escapes Run and a host
      that wants to fail fast should keep failing fast.

      Set it and an access violation, a stack overflow or a corrupt heap inside
      execution stops being a Pascal exception on its way out of the engine: Run
      answers False with LastError.Code = peFatal and the exception's class and
      message. Nothing reaches the host's exception handler, so a Lazarus
      application never meets the LCL's modal crash dialog -- which on a machine
      with nobody in front of it is a hang, and gives neither message nor exit
      code. The application chooses what to do: tell the user, save their work,
      close down.

      What it does NOT do, deliberately: give the fault to ON ERROR. A script
      resuming on memory a wild write has already reached answers wrongly instead
      of dying, and a wrong answer nobody is told about is the worse outcome. See
      peFatal in PhosphorErrors.

      The engine instance is spent afterwards either way -- a later Run answers
      peFatal without executing anything. Containment buys the process, not the
      interpreter, so a host that wants to carry on scripting builds a new one. }
    property ContainFaults: Boolean read FContainFaults write FContainFaults;
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
    { True once a CALLBACK has run END -- the script saying its work is finished.
      A prepared session is not halted by the `end` that closes its own top level;
      see TPhosphorVM.EndOfTopLevel. Once this is True every CallFunction is
      refused with peRuntime rather than answered with a default, so a host that
      checks LastError already learns of it; this is here for one that would
      rather ask before calling. Prepare a script again to start over. }
    property Halted: Boolean read GetHalted;
    property SandboxRoot: String read GetSandboxRoot write SetSandboxRootProp;
    { LOOKING AT A PREPARED SCRIPT'S STATE -- the VM and the program Prepare built,
      or nil when nothing is prepared. Read-only; see TPhosphorVM's Dbg* block for
      what the VM will answer and when.

      Through PreparedProgram.GlobalName and LocalName, an embedder can print every
      global and every live local BY NAME after Prepare and between CallFunction
      calls -- state that used to be unreachable because the compiler threw the
      names away. Ask PreparedProgram.HasNames first: it is True for anything
      Prepare compiled and False for a program that came from a .pbc, where there
      is nothing to show and nothing for the temporary filter to judge.
      PreparedProgram.StoppableLines is the set of lines a breakpoint could be
      installed on, answerable before anything runs.

      READ THESE, DO NOT HOLD THEM. Every entry point that starts new work --
      Run, RunBytecode and the next Prepare -- begins by calling Finish, which frees
      THIS VM and THIS program and nils both. A host that caches the program pointer
      and then calls Run is holding a freed object; the properties themselves answer
      nil, so re-read them and never carry one across a call. This is the sentence
      the paragraph below used to be mistaken for: that one is about the locals Run
      makes for itself, which are a different pair with a different lifetime.

      WHY THE PREPARED PAIR AND ONLY THAT ONE. Run creates its VM and its program
      as locals and frees both in one finally, so there is nothing for a caller to
      hold afterwards and a field here would read nil at every moment a host could
      ask. The REPL session keeps its own pair and is not offered here: it is a
      different lifetime with a different owner, and one property that sometimes
      means one and sometimes the other is the shape this engine has been bitten by
      before. A seam that wants the VM mid-run gets it as Self, which is the seam's
      business and not this property's. }
    property PreparedVM: TPhosphorVM read FVM;
    property PreparedProgram: TProgram read FProg;
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
  ClearErrorState();
  FMaxSteps := 0;
  FMaxMemoryBytes := 0;
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

{ THE WHOLE ERROR STATE IS CLEARED IN ONE PLACE, and every entry point calls it.

  The first version of this cleared the two compile flags inside CompileSource, on
  the reasoning that CompileSource is the only routine that ever SETS them. That is
  true and it is not enough: RunBytecode and CallFunction never reach CompileSource
  -- one reads a .pbc through ReadProgram, the other runs on an already-prepared VM
  -- so both of them cleared FErrorLine and FErrorMessage, wrote their own failure
  into them, and left ErrorUnterminatedBlock and ErrorAtEndOfInput describing a
  compile that had failed three calls earlier. An embedder asking the documented
  properties got an answer about the wrong failure, and a REPL-shaped host would
  wedge on it.

  That is the difference between fixing the instance and fixing the class: the rule
  is "every door into the engine starts from a clean error state", so there is one
  routine that says what clean means and six doors that call it. A seventh door
  added later gets it by calling this instead of by remembering four field names. }
procedure TPhosphorEngine.ClearErrorState;
begin
  FErrorLine := 0;
  FErrorMessage := '';
  FErrorAtEof := False;
  FErrorUnterminated := False;
  FLastError := NoError();
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
      FErrorAtEof := comp.ErrorAtEndOfInput;
      FErrorUnterminated := comp.ErrorUnterminatedBlock;
      if FErrorLine = 0 then FErrorLine := 1;
      FLastError := MakeError(peSyntax, FErrorMessage);
    end;
  finally
    comp.Free;
  end;
end;

function TPhosphorEngine.GetHalted: Boolean;
begin
  Result := (FVM <> nil) and FVM.Halted;
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
  AVM.MaxMemoryBytes := FMaxMemoryBytes;
  AVM.ContainFaults := FContainFaults;
end;

function TPhosphorEngine.Run(const ASource: String): Integer;
var
  vm: TPhosphorVM;
  prog: TProgram;
begin
  ClearErrorState();
  Finish();         // a one-shot run discards any prepared state
  ResetHandles();   // no handles leak between programs

  if not CompileSource(ASource, prog) then Exit(FErrorLine);

  vm := TPhosphorVM.Create();
  try
    ConfigureVM(vm);
    // The ceilings, installed where a library call can also see them. Paired with
    // BudgetEnd in a finally, because a run that faults must not leave a stale
    // budget standing over whatever the host does next.
    BudgetBegin(FMaxSteps, FTimeoutMs);
    try
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
      BudgetEnd();
    end;
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
  ClearErrorState();
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
    BudgetBegin(FMaxSteps, FTimeoutMs);
    try
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
      BudgetEnd();
    end;
  finally
    vm.Free;
    prog.Free;
  end;
end;

function TPhosphorEngine.Prepare(const ASource: String): Integer;
begin
  ClearErrorState();
  Finish();         // discard a previous preparation
  ResetHandles();

  if not CompileSource(ASource, FProg) then Exit(FErrorLine);

  FVM := TPhosphorVM.Create();
  ConfigureVM(FVM);
  BudgetBegin(FMaxSteps, FTimeoutMs);
  try
    if not FVM.Run(FProg) then   // run the top level once; the VM stays alive after
    begin
      FLastError := FVM.LastError;
      FErrorMessage := FVM.LastError.Message;
      FErrorLine := FVM.ErrorLine;
      if FErrorLine = 0 then FErrorLine := 1;
      Finish();
      Exit(FErrorLine);
    end;
    { The top level is done, and that is not the program being over.

      docs/language-reference.md teaches `end` before a block of functions, and the
      paragraph above this one keeps the VM alive so the host can call those
      functions. Both are right and they used to meet at a flag nobody cleared: a
      script written the documented way had EVERY CallFunction answer 0 -- not
      after some later halt, but from the first call, with LastError NoError and a
      `$` function handing back a Double. }
    FVM.EndOfTopLevel();
    Result := 0;
  finally
    BudgetEnd();
  end;
end;

function TPhosphorEngine.CallFunction(const AName: String; const Args: array of TValue): TValue;
begin
  ClearErrorState();
  if FVM = nil then
  begin
    FLastError := MakeError(peRuntime, 'no script is prepared (call Prepare first)');
    FErrorMessage := FLastError.Message;
    Exit(Default(TValue));
  end;
  // A call on a prepared VM is a run of its own as far as the ceilings go -- the
  // VM resets its step counter and start tick per Run, and this is the same
  // boundary for the library side.
  BudgetBegin(FMaxSteps, FTimeoutMs);
  try
    Result := FVM.CallUserFunc(AName, Args, FLastError);
  finally
    BudgetEnd();
  end;
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
  ClearErrorState();
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
  // Each REPL line gets its own execution budget, matching RunFrom, which resets
  // the VM's step counter and start tick per line.
  BudgetBegin(FMaxSteps, FTimeoutMs);
  try
    if not FReplVM.RunFrom(prog, startPC) then
    begin
      FLastError := FReplVM.LastError;
      FErrorMessage := FReplVM.LastError.Message;
      FErrorLine := FReplVM.ErrorLine;
      if FErrorLine = 0 then FErrorLine := 1;
      Result := FErrorLine;
    end;
  finally
    BudgetEnd();
  end;
  // Safe only now: the VM no longer refers to the previous program, and every value
  // that came out of its constant pool is reference-counted in the globals.
  if old <> nil then old.Free;
end;

end.
