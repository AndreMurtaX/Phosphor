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
    FOnDebug: TPhosphorDebugProc;
    { THE ARMING, HELD HERE AND APPLIED BY ConfigureVM, because Run creates its VM
      as a local and frees it in the same finally -- so there is no VM for a host
      to arm before a one-shot run, and a host that had to reach for one would be
      holding a pointer this class promises not to offer. Held on the engine, the
      one line a host writes works at every door: Run, RunBytecode, Prepare and
      the REPL each get a VM armed the same way. }
    FDbgLines: array of Integer;
    FDbgStopAtEntry: Boolean;
    FDbgArmed: Boolean;
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
    { THE VM THAT IS RUNNING RIGHT NOW, or nil between runs. Every door that
      executes BASIC already wraps exactly that region in BudgetBegin/BudgetEnd,
      so this is set and restored on the same two lines and cannot outlive the VM
      it points at -- which is the whole reason it can be offered at all. Run and
      RunBytecode own their VM as a LOCAL and free it in the same finally, so a
      field that survived the call would be a dangling pointer, and that is the
      trap PreparedVM's own header is about.

      SAVED AND RESTORED, NOT SET AND NILLED, because these doors NEST: a host
      that evaluates a watch expression from inside a stop is running
      CallFunction inside CallFunction, and nilling on the way out of the inner
      one would leave the outer run's seam unable to reach its own VM from the
      next boundary onwards -- a debugger that works until the first watch. See
      the DebugVM property. }
    FLiveVM: TPhosphorVM;
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
    procedure SetOnDebugProp(AValue: TPhosphorDebugProc);
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
    { THE DEBUG SEAM. Nil by default: with none installed nothing ever stops, and
      a VM that is never ARMED does not consult it at all. It is the one seam in
      this engine that MAY BLOCK -- see TPhosphorDebugProc, and TPhosphorVM's
      DebugPoll for what parking in it costs the script and what is given back.

      The pair to it is ArmDebug below. Installing the seam says where to ask;
      arming says when.

      AND IT REACHES A SESSION THAT IS ALREADY PREPARED, which is why this one has
      a setter where OnOutput and OnBreakpoint have a field. ArmDebug forwards to
      a live VM on purpose -- a host changes its breakpoint set mid-session -- and
      a plain field write did not, so the two halves of one attach disagreed:
      Prepare, then install the seam, then arm, then call, gave zero stops and no
      diagnostic at all. That is the shape a GUI uses when a person clicks Debug
      on a script that is already loaded. Measured on both machines before and
      after. }
    property OnDebug: TPhosphorDebugProc read FOnDebug write SetOnDebugProp;
    { ATTACH THE DEBUGGER TO EVERY RUN THIS ENGINE STARTS, with the lines to stop
      on and whether to stop once before the first statement. Applied by
      ConfigureVM, so it reaches Run, RunBytecode, Prepare and the REPL alike; call
      it before the run that should be debugged.

      TO CHANGE THE SET MID-SESSION, or to read state, go to the VM: DebugVM
      answers it from inside the seam at every door, and between calls on a
      prepared session PreparedVM answers the same object. This forwards only the
      BEFORE-a-run half, because that is the half that has no VM to talk to yet.

      PAUSE HAS NO FORWARD HERE, and the reason is a real one rather than an
      omission: InterruptDebug is the one call made from ANOTHER THREAD while a
      run is in progress, and DebugVM is a field this thread writes when the run
      begins and nils when it ends. A forward would read that field from the other
      thread against an object this one may be freeing -- a use-after-free that
      would show up once a month. The pointer is offered to the thread that is
      SAFE to read it from: a host takes DebugVM at its first stop (arm with
      stop-at-entry) and hands that VM to its socket thread, which owns it for the
      rest of the run because Run cannot return while the seam has not. On a
      prepared session PreparedVM is stable between calls and needs none of this. }
    procedure ArmDebug(const ALines: array of Integer; AStopAtEntry: Boolean);
    { Detach. Later runs are undebugged; a prepared VM is detached immediately. }
    procedure DisarmDebug;
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
      before. A seam that wants the VM mid-run asks DebugVM, which is the next
      property and has a different lifetime again. }
    property PreparedVM: TPhosphorVM read FVM;
    property PreparedProgram: TProgram read FProg;
    { THE VM THAT IS EXECUTING RIGHT NOW, and nil at every other moment.

      This exists because the debug seam is `of object` and `Self` inside it is
      the HOST's adapter, not the engine's VM -- three doc blocks used to say
      otherwise, and on the strength of that a host reading the call stack from a
      stop through Run would have found nothing to read it from: PreparedVM is nil
      unless Prepare built it, and Run and RunBytecode keep theirs in a local.
      Adding the VM as a parameter to TPhosphorDebugProc was the other way and was
      refused: that type lives in PhosphorValue, which cannot name TPhosphorVM
      without a circular dependency, so the parameter would have had to be TObject
      and every host would cast it unchecked to reach an object the engine can
      simply hand back with its own type.

      WHAT IT IS GOOD FOR IS THE STOPPED WINDOW AND NOTHING ELSE. Inside the seam
      it answers the running VM, so DbgFrameDepth, DbgFrameFunc, DbgGlobal and
      DbgLocal -- with PreparedProgram's names, or the program the host compiled --
      are all reachable there, and reading them executes nothing. Outside a run it
      is nil, and it must never be stored: for Run and RunBytecode the object it
      points at is freed before the call returns. }
    property DebugVM: TPhosphorVM read FLiveVM;
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
  FOnDebug := nil;
  FDbgLines := nil;
  FDbgStopAtEntry := False;
  FDbgArmed := False;
  FHostServices := Default(THostServices);
  ClearErrorState();
  FMaxSteps := 0;
  FMaxMemoryBytes := 0;
  FMaxOutputBytes := 0;
  FTimeoutMs := 0;
  FVM := nil;
  FLiveVM := nil;
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

{ THE SEAM REACHES THE VMs THAT ALREADY EXIST, exactly as ArmDebug does and to
  the same two objects. ConfigureVM is the only other copier and it has been and
  gone by the time a host attaches to a prepared session; a host that installs the
  seam BEFORE Prepare is unaffected, because this writes the field ConfigureVM
  then reads. Nil is forwarded too -- detaching mid-session is the same question
  asked the other way round, and a host that clears the seam must not be left with
  a VM still holding it. }
procedure TPhosphorEngine.SetOnDebugProp(AValue: TPhosphorDebugProc);
begin
  FOnDebug := AValue;
  if FVM <> nil then FVM.OnDebug := AValue;
  if FReplVM <> nil then FReplVM.OnDebug := AValue;
end;

procedure TPhosphorEngine.ArmDebug(const ALines: array of Integer; AStopAtEntry: Boolean);
var
  i: Integer;
begin
  SetLength(FDbgLines, Length(ALines));
  for i := 0 to High(ALines) do FDbgLines[i] := ALines[i];
  FDbgStopAtEntry := AStopAtEntry;
  FDbgArmed := True;
  // A session that is already prepared is armed NOW rather than at its next run:
  // its VM is the one the host is about to call into, and ConfigureVM has been
  // and gone. The sorting and de-duplication happen there, once, not here.
  if FVM <> nil then FVM.ArmDebug(FDbgLines, AStopAtEntry);
  if FReplVM <> nil then FReplVM.ArmDebug(FDbgLines, AStopAtEntry);
end;

procedure TPhosphorEngine.DisarmDebug;
begin
  FDbgArmed := False;
  FDbgLines := nil;
  FDbgStopAtEntry := False;
  if FVM <> nil then FVM.DisarmDebug();
  if FReplVM <> nil then FReplVM.DisarmDebug();
end;

procedure TPhosphorEngine.ConfigureVM(AVM: TPhosphorVM);
begin
  AVM.Registry := FRegistry;
  AVM.OnOutput := FOnOutput;
  AVM.OnInput := FOnInput;
  AVM.OnBreakpoint := FOnBreakpoint;
  AVM.OnDebug := FOnDebug;
  // The arming, if the host asked for one. A VM that is not armed never consults
  // the seam, so the cost of installing OnDebug and never arming is one Boolean
  // test per statement boundary.
  if FDbgArmed then AVM.ArmDebug(FDbgLines, FDbgStopAtEntry);
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
  savedLive: TPhosphorVM;
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
    // budget standing over whatever the host does next. FLiveVM is set and cleared
    // on the same two lines: see DebugVM -- this local is freed below, so the only
    // safe lifetime for that pointer is exactly the region that is executing.
    savedLive := FLiveVM; FLiveVM := vm;
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
      // A door that succeeded reports no error. See CallFunction for the whole
      // of why this is not already true from the ClearErrorState at the top: a
      // seam may re-enter the engine from inside a stop, and a watch expression
      // that faults leaves its verdict standing in these two fields.
      ClearErrorState();
      Result := 0;
    finally
      BudgetEnd();
      FLiveVM := savedLive;               // never outlives the VM it points at
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
  savedLive: TPhosphorVM;
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
    savedLive := FLiveVM; FLiveVM := vm;  // see DebugVM
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
      ClearErrorState();     // a door that succeeded reports no error; see CallFunction
      Result := 0;
    finally
      BudgetEnd();
      FLiveVM := savedLive;               // never outlives the VM it points at
    end;
  finally
    vm.Free;
    prog.Free;
  end;
end;

function TPhosphorEngine.Prepare(const ASource: String): Integer;
var
  savedLive: TPhosphorVM;
begin
  ClearErrorState();
  Finish();         // discard a previous preparation
  ResetHandles();

  if not CompileSource(ASource, FProg) then Exit(FErrorLine);

  FVM := TPhosphorVM.Create();
  ConfigureVM(FVM);
  savedLive := FLiveVM; FLiveVM := FVM;                      // see DebugVM
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
    ClearErrorState();     // a door that succeeded reports no error; see CallFunction
    Result := 0;
  finally
    BudgetEnd();
    FLiveVM := savedLive;
  end;
end;

function TPhosphorEngine.CallFunction(const AName: String; const Args: array of TValue): TValue;
var
  savedLive: TPhosphorVM;
  { THIS CALL'S OWN ERROR, AND NOT THE FIELD. CallUserFunc takes it as an `out`
    parameter, so passing FLastError hands the VM a reference to the ONE field
    every door shares -- and this door nests inside itself. A watch expression
    evaluated from a stop is a CallFunction inside a CallFunction: the inner one
    opens by writing `NoError` through that reference, faults, and writes its
    error through it, and when the outer call finishes cleanly it has nothing left
    to say so with. It never writes the field again, and the failure branch below
    then reports the INNER call's error as the OUTER call's verdict.

    A local is the fix, because the question "did THIS call fail" has to be asked
    of a value only this activation can write. See the success branch below for
    the other half. }
  err: TPhosphorError;
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
  savedLive := FLiveVM; FLiveVM := FVM;                      // see DebugVM
  BudgetBegin(FMaxSteps, FTimeoutMs);
  try
    Result := FVM.CallUserFunc(AName, Args, err);
  finally
    BudgetEnd();
    FLiveVM := savedLive;
  end;
  if IsError(err) then
  begin
    FLastError := err;
    FErrorMessage := err.Message;
    FErrorLine := FVM.ErrorLine;
  end
  else
    { A CALL THAT SUCCEEDED REPORTS NO ERROR, and saying so takes a line because
      of what can run in between. ClearErrorState at the top of this routine was
      the whole of it, which is correct for a call nothing nests inside -- and
      this is the door a debug seam re-enters through, on purpose and by document.
      A watch expression that faults sets these two fields from ITS OWN
      CallFunction, the outer call then finishes cleanly, and `IsError` is False
      so the failure branch above does not run: the host reads its successful
      call's verdict and is told `division by zero` at a line in somebody else's
      evaluation.

      MEASURED: a prepared session, a breakpoint in `f1`, the seam evaluating a
      faulting `f1` and continuing -- the outer call answered 7 and `ErrorMessage`
      said `division by zero` at line 8. Found by the three-leg differential in
      tests/probe_sweep.lpr on the `innerfault` shapes, the first round the
      compared verdict carried the error line and the error message; pinned by
      name in tests/probe_step.lpr.

      The evaluation's own verdict is NOT taken away from the host: it is read
      from the nested call, which is where it belongs and is what
      docs/embedding.md tells a host to do. Only the outer call's answer about
      ITSELF is corrected. }
    ClearErrorState();
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
  savedLive: TPhosphorVM;
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
  savedLive := FLiveVM; FLiveVM := FReplVM;                   // see DebugVM
  BudgetBegin(FMaxSteps, FTimeoutMs);
  try
    if not FReplVM.RunFrom(prog, startPC) then
    begin
      FLastError := FReplVM.LastError;
      FErrorMessage := FReplVM.LastError.Message;
      FErrorLine := FReplVM.ErrorLine;
      if FErrorLine = 0 then FErrorLine := 1;
      Result := FErrorLine;
    end
    else
      ClearErrorState();   // a door that succeeded reports no error; see CallFunction
  finally
    BudgetEnd();
    FLiveVM := savedLive;
  end;
  // Safe only now: the VM no longer refers to the previous program, and every value
  // that came out of its constant pool is reference-counted in the globals.
  if old <> nil then old.Free;
end;

end.
