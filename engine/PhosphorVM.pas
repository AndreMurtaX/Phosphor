{******************************************************************************
  Phosphor BASIC -- the stack VM

  MIT License. Copyright (c) 2026 Andre Murta.

  Executes a TProgram over a stack of TValue. Calls are resolved from the actual
  runtime kinds of their arguments through the registry (int% widens to an 'n'
  slot, an exact '%' slot is preferred). Arithmetic and call errors are RETURNED
  as engine error state, never raised. All output leaves through OnOutput.
******************************************************************************}
unit PhosphorVM;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Math, PhosphorValue, PhosphorErrors, PhosphorOpcodes, PhosphorRegistry,
  PhosphorSandbox;

{ IS THIS EXCEPTION EVIDENCE THAT MEMORY IS ALREADY DAMAGED?

  Read from the RTL rather than assumed, because the hierarchy is a trap. FPC
  3.2.2 makes EExternal the root of the OS/hardware family in
  rtl/objpas/sysutils/sysutilh.inc:130 -- and EIntError and EMathError
  DESCEND FROM IT (:142, :149). So "is EExternal" alone calls a division by zero
  a state fault. The two math families are subtracted for that reason.

  What remains under EExternal is the real list: EAccessViolation (and EBusError
  under it), EStackOverflow, EPrivilege, EControlC, EExternalException. Added by
  name from the other side of the tree: EInvalidPointer, a corrupt heap, which is
  EHeapMemoryError and not EExternal at all.

  EOutOfMemory is DELIBERATELY NOT HERE, though it is its sibling under
  EHeapMemoryError: an allocation that fails has failed cleanly and nothing was
  written. A script that catches it and asks for less is behaving correctly, so
  it stays an ordinary catchable error. }
function IsStateFault(E: Exception): Boolean;

const
  { Classic file-I/O channel numbers run 1..MaxChannel (#0 is not used). The cap
    keeps the channel table a fixed, cheap array; classic BASICs cap far lower. }
  MaxChannel = 255;
  { Bytes pulled from disk per window refill on a streamed read. }
  ChanChunk = 65536;
  { How deeply a callback may re-enter the interpreter. CallUserFunc (callfunc, a
    GUI event, an `on error call` handler) re-enters ExecFrom with a NATIVE call, so
    each level costs process stack rather than heap. Ordinary BASIC recursion is a
    jump inside one interpreter loop and is NOT bounded by this. }
  MaxCallDepth = 256;
  { How many TValue slots the expression stack may ever hold. The stack doubles on
    demand and nothing shrank it, so how big it got was a value the PROGRAM chose:
    a .pbc that runs `DUPN n` in a loop adds n slots a pass, for ever.

    AND THE END OF THAT IS NOT AN EXCEPTION. The obvious assumption is that
    SetLength eventually raises EOutOfMemory and the only complaint is that it
    raises it in the dispatch loop, outside every try/except the VM has, so it
    reaches the host as "unhandled". Measured on 2026-09-06, it does not: asked for
    96 GB, SetLength COMMITTED it -- the process was watched holding 101,573,304 KB
    -- and the machine paged itself to a standstill until it was killed by hand. A
    script cannot be allowed to do that to the box its host runs on.

    The ceiling is deliberately far above anything a program can mean. A TValue is
    48 bytes, so this is 48 MB of pure operand stack; the deepest expression the
    parser will accept costs a few dozen slots, and the widest thing the compiler
    emits -- `a@[i,i,...] += 1`, which pushes the handle and every subscript and
    then DUPNs the lot -- needs two slots per subscript, so it takes a source line
    with more than half a million commas to reach it. THAT IS WRITEABLE, and it
    was written: a generated line of 1 200 000 subscripts crosses the ceiling and
    is refused cleanly at a 199 MB peak (measured 2026-09-06). The claim this
    comment used to make -- that such a line was beyond reach -- was wrong, and
    the ceiling is load-bearing rather than theoretical. Crossing it is a FATAL
    peLimit, like the step and output budgets and for the same reason: a ceiling a
    script could catch is a ceiling a script can sit on top of. }
  MaxStackDepth = 1048576;
  { How deeply GOSUB may nest. THE SAME UNBOUNDED DOUBLING AS THE VALUE STACK, and
    a far shorter program reaches it -- `1000 gosub 1000` is three lines of plain
    BASIC with no crafted bytecode, no operand and no arithmetic. Measured against
    the build that bounded only the value stack: 260 MB at 0,5 s, 516 MB at 1,0 s,
    1543 MB at 1,3 s and still doubling when the harness killed it, while the same
    loop written with `goto` sits at 2,7 MB for ever. FCallStack holds one Integer
    per level, so this ceiling is 4 MB; the deepest GOSUB nest the suite pins is
    20 000, and this is fifty times that. }
  MaxGosubDepth = 1048576;
  { How deeply BASIC RECURSION may nest, and how many local slots those activation
    frames may hold between them.

    opCall is a jump inside one interpreter loop -- that is exactly why MaxCallDepth
    does NOT bound it (see the note there) -- so an ordinary recursive function that
    never returns grows FFrames with the same unbounded doubling GOSUB had:

        function f(n)
          return f(n + 1)
        endfunction
        println f(1)

    measured at 1020 MB in 3,3 s and still climbing.

    TWO CEILINGS, BECAUSE ONE NUMBER CANNOT PRICE A FRAME. A frame costs a fixed
    ~157 bytes plus 48 bytes per local slot (measured: 100 000 frames of a
    one-parameter function peak at 15,7 MB, of a 200-local function at 937,7 MB).
    Bounding the DEPTH alone would let a wide function buy gigabytes at a depth the
    ceiling calls acceptable; bounding the SLOTS alone would let a one-slot function
    run to millions of frames. So BOTH are bounded, independently, at the push:
    MaxFrameDepth frames, and MaxFrameSlots local slots held by them together
    (TPhosphorVM.FFrameSlots). Neither ceiling is derived from the program.

    A DERIVED CEILING WAS TRIED FIRST AND REFUSED ORDINARY CODE. Round two enforced
    `min(MaxFrameDepth, MaxFrameSlots div <widest local table in the PROGRAM>)`, a
    product that is only tight when the widest function is the one on the stack.
    When it is not, it is too strict by widest/actual -- 10 000x on the programs
    below -- and the memory it declines to spend is zero. Three things compounded:
    the widest table is a property of the whole program, it counts a function that
    NEED NEVER BE CALLED, and the width can arise silently, because every `for`
    loop inside a function allocates a hidden local slot (__forN, see
    PhosphorCompiler's ParseFor). Measured (2026-09-07): 5 242 slots anywhere in
    the file put the ceiling at exactly 200, the depth this suite pins as
    legitimate, so an UNCALLED function with 6 000 `for` loops refused an unrelated
    depth-200 recursion at 174 frames, and 20 000 `for` loops refused a plain
    NON-RECURSIVE chain f1->f2->...->f60 of sixty distinct one-parameter functions.
    Counting the slots costs one subtraction and one add per call and answers the
    question the ceiling is actually asking.

    THE COUNT IS OVER THE FRAMES THE ARRAY HOLDS, NOT THE LIVE PREFIX, and that
    difference is the whole reason it is a memory bound. A returned frame keeps its
    Locals array until some later call lands on the same index, so a wide call made
    one level SHALLOWER each time strands a wide array at every index it used and
    is never charged for one of them:

        for i = 300 to 1 step -1 : x = down(i) : next   ' down(i) recurses i deep,
                                                       ' calls wide(), returns

    with 100 000 locals in wide() never has more than ~100 300 slots LIVE -- a
    tenth of the budget -- and holds 1 378,7 MB when it finishes (measured on the
    build with no ceiling at all). Charging what is held refuses it after ten
    iterations; charging only the live prefix would let it run.

    Crossing either ceiling is a FATAL peLimit, for the reason given at
    MaxStackDepth. }
  { HOW MANY BYTES MAY BE ADDED BEFORE THE HEAP IS ASKED ABOUT AGAIN.
    GetFPCHeapStatus is about 39 ns and a short concatenation about 3, so an
    unconditional query would be a tax on every string-building script to catch a
    ceiling only large allocations can cross. But a THRESHOLD alone was not
    enough: 700 concatenations of 64000 bytes each -- every one under the
    threshold -- reached 43 MB under a 4 MB ceiling and finished before the
    step-loop check ever looked, because that fires only every 4096 steps.

    So the growth ACCUMULATES: one add and one compare per concatenation, and the
    heap is asked once per 64 KB added rather than once per concatenation. The
    overshoot is then bounded by 64 KB plus whatever single allocation is in
    flight, instead of by 4095 times the threshold. }
  MemCheckFrom = 65536;
  MaxFrameDepth = 262144;
  MaxFrameSlots = 1048576;

type
  { One activation of a user function: its local frame (parameters first, then
    declared locals), the function it belongs to, and where to resume.

    CallerStmt* is the CALLER's statement boundary, put here by the call and taken
    back by the return. Without it the "current statement" kept pointing into a
    function that had already returned: `x = f(1) / 0` faults in the CALLER, but
    the last boundary passed was the one inside f, so ON ERROR remembered a resume
    point in a frame that no longer existed and `resume next` continued inside the
    dead body -- silently running nothing at all in the caller. (2026-09-06.) }
  TCallFrame = record
    Locals: array of TValue;
    FuncIndex: Integer;
    ReturnAddr: Integer;
    CallerStmtPC, CallerStmtSP, CallerStmtFrameSP: Integer;
  end;

  { An open file channel for classic I/O (OPEN ... AS #n).

    Every mode keeps its TFileStream open, so a channel is a live view of the file,
    not a snapshot, and a file far larger than RAM can be read. INPUT and BINARY
    read through a sliding WINDOW: Buf holds only the bytes read ahead and not yet
    consumed (Pos is the 1-based cursor into it, BufStart the file offset of Buf[1]),
    so the logical file cursor is BufStart + Pos - 1 and memory is bounded by the
    read chunk and the longest line -- never by the file size.

    BINARY is read/write and positionable: SEEK moves the cursor, INPUT$ reads at it
    and PRINT # overwrites at it. OUTPUT/APPEND stay write-only and append-only. }
  TChannelMode = (cmInput, cmOutput, cmAppend, cmBinary);
  TFileChannel = record
    Open: Boolean;
    Mode: TChannelMode;
    Stream: TFileStream;
    Buf: RawByteString;    // INPUT/BINARY: the read-ahead window, byte-exact
    Pos: Integer;          // 1-based cursor into Buf
    BufStart: Int64;       // file offset of Buf[1]
  end;

  TPhosphorVM = class
  private
    FStack: array of TValue;
    FSP: Integer;    // points one past the top
    // Set by Push when the value stack would have to grow past MaxStackDepth. Push
    // has no way to report -- it is a procedure called from twenty places, several
    // of them inside the error machinery itself -- so it refuses the growth, drops
    // the value, and raises the flag; the dispatch loop turns it into a fatal
    // peLimit at the very next instruction boundary, before anything else runs.
    FStackLimit: Boolean;
    FVars: array of TValue;
    FCallStack: array of Integer;   // GOSUB return addresses
    FCSP: Integer;
    FFrames: array of TCallFrame;   // user-function activation frames
    FFrameSP: Integer;
    // Sum of Length(FFrames[i].Locals) over the WHOLE array, live frames and
    // returned ones alike -- the local slots this VM is actually holding, which is
    // what MaxFrameSlots bounds. It is maintained at the three places that change
    // one of those lengths (the two frame pushes and RestoreOverlap) and nowhere
    // else: it does not depend on FFrameSP, so the paths that move the frame
    // POINTER wholesale -- a fault dropping to the handler's level, a resume
    // climbing back, CallUserFunc restoring the level it borrowed -- cannot put it
    // out of step with the array. See MaxFrameDepth.
    FFrameSlots: Integer;
    FDataPtr: Integer;              // READ position in the DATA pool
    FProg: TProgram;                // the running program (reachable during a call)
    // ON ERROR state. FErrHandler is the handler pc, or -1 when none is installed.
    // opStmt keeps FStmt* pointing at the current clean statement boundary; on a
    // caught error those are copied to FErrStmt* (the resume point) before the
    // handler runs and moves FStmt* on. FInHandler blocks re-entry until a resume.
    FErrHandler: Integer;
    FErrHandlerSP, FErrHandlerFrameSP: Integer;
    FErrHandlerMode: Integer;    // 0 = goto a label, 1 = call a function
    FErrHandlerFuncIdx: Integer; // const-pool index of the function name (call mode)
    FInHandler: Boolean;
    FErrCode: Integer;              // last caught error: code / message / line
    FErrMsg: String;
    FErrLine: Integer;
    FErrStmtPC, FErrStmtSP, FErrStmtFrameSP: Integer; // the failing statement, for resume
    // THE OVERLAP. A handler runs at the level it was INSTALLED at, but `resume`
    // returns to the level the failing STATEMENT ran at, and the second is deeper
    // whenever the fault happened inside a call made mid-expression. Everything
    // between the two -- the caller's half-evaluated operands, and every activation
    // frame down to the faulting one -- is still needed by the pending resume and
    // was sitting in exactly the slots the handler then wrote into. It is copied
    // aside on the fault and put back on the resume.
    FErrSaveStack: array of TValue;
    FErrSaveFrames: array of TCallFrame;
    FErrSaveValid: Boolean;
    // END must end the PROGRAM. Inside a re-entrant call (callfunc, a GUI event, an
    // `on error call` handler) opHalt only left that activation, and its caller read
    // the exit as an ordinary return.
    FHalted: Boolean;
    // Re-entrant depth. Ordinary recursion is a jump within one interpreter loop and
    // costs heap; CallUserFunc re-enters ExecFrom with a NATIVE call, so recursion
    // through callfunc costs process stack and used to end in a segfault.
    FCallDepth: Integer;
    { WHERE A peLimit CAME FROM, WHICH DECIDES WHETHER IT IS FATAL.

      A ceiling crossed by the VM is fatal: a script must not be able to catch
      the limit it is sitting on. A LIBRARY that refuses a job up front because
      its size is too big is a different event with the same code -- nothing has
      been spent, nothing has been crossed, and a program that catches it and
      does something smaller is behaving correctly.

      Both arrive at opCall's library branch as `e.Code = peLimit`, so the code
      alone cannot tell them apart. This flag can: it is cleared immediately
      before every library dispatch and set only where a NESTED ACTIVATION of
      this VM hit a ceiling (CallUserFunc's own two, and a peLimit carried out of
      the inner ExecFrom). Set means the ceiling was crossed inside; clear means
      a library said no before starting.

      The rule this replaces read `if e.Code = peLimit then fatal`, justified by
      a grep -- "peLimit has nine producers and none is in any library" -- that
      was TRUE WHEN IT WAS RUN and false one patch later, when the budget lane
      gave the libraries their own refusals. Both patches were verified in
      isolation and only their integration could show it: probe_budget went to
      205/2, on the two cases that catch a refusal and continue. }
    FLimitFromInner: Boolean;
    { CONTAINMENT: does a fault end the RUN, or the PROCESS? See ContainFaults. }
    FContainFaults: Boolean;
    { Set once a state fault has been contained. This VM is not reusable after
      one: the fault unwound Pascal frames the interpreter still believed in, so
      FSP, FFrameSP and every handle the run owned are in whatever state the
      unwinding left them. Running again would be building on that, which is the
      very thing containment exists to avoid -- so a later Run refuses in one
      line instead. The host keeps its process; it does not keep this engine. }
    FFaulted: Boolean;
    // Execution limits (set from the engine before Run; 0 = unlimited). Counters
    // are reset per Run. A limit is FATAL -- it aborts with peLimit and cannot be
    // caught by ON ERROR, so a script cannot escape its own ceiling.
    FSteps: Int64;
    FOutputBytes: Int64;
    FHeapBase: PtrUInt;     // heap in use when this run began; see MaxMemoryBytes
    FUncharged: Int64;      // bytes added since the heap was last consulted
    FHeapBased: Boolean;    // FHeapBase has been sampled for this session
    FStartTick: QWord;
    // Debug tracing, set by the TRACE statement (opTrace). BREAKPOINT reports the
    // frame through OnBreakpoint only while this is on; off, it is a pure no-op.
    FTrace: Boolean;
    // Classic-I/O state, all per-Run. FChannels[n] is the file on #n. The console
    // INPUT buffer holds the last line read for INPUT/LINE INPUT; the console char
    // buffer feeds INPUT$(n) from a line-based host, keeping any unread remainder.
    FChannels: array[1..MaxChannel] of TFileChannel;
    FInBuf: String;         // console INPUT: the current line
    FInPos: Integer;        // console INPUT: 1-based cursor into FInBuf
    FCharBuf: String;       // console INPUT$: buffered characters not yet consumed
    FCharPos: Integer;      // console INPUT$: 1-based cursor into FCharBuf
    procedure Push(const V: TValue);
    function Pop: TValue;
    { POINT THE VM AT A PROGRAM. The only place FProg is assigned, so that
      anything derived from the program is derived exactly when the program
      changes and can never describe a previous one. Nothing is derived here any
      more -- the frame ceilings used to be, and MaxFrameDepth records what that
      cost -- but the seam stays, because the next thing that wants a per-program
      value has one honest place to go and no reason to reach for a cache keyed on
      the program POINTER, which is wrong for a reason that is easy to miss: a
      TProgram can be freed and the next one allocated at the same address. }
    procedure UseProgram(AProg: TProgram);
    { ENTERING THE VM INSTALLS THE FPU MASK, LEAVING IT PUTS THE HOST'S BACK.
      Every arithmetic guarantee this engine makes rests on overflow producing
      +Inf for FiniteD to report rather than raising EOverflow at the instruction
      -- and it was installed by Run and RunFrom only, so the OTHER two ways into
      execution ran the same instructions under the host's mask. Through the
      embedding pattern docs/embedding.md documents (Prepare, then CallFunction)
      an ordinary `x * 10` on 1e308 died with an unhandled EOverflow at exit 217,
      while the identical expression inside Run reported "floating point overflow
      in *" catchably (measured 2026-09-07). Making it a property of ENTERING --
      four call sites, one rule -- is the point: a fifth entry point added later
      is wrong in a way a reader can see. Nesting is safe: the mask is a set, the
      inner install is a no-op, and the inner leave restores the outer's set. }
    { Turn a caught state fault into a failed Run. Sets FFaulted, so this VM is
      done, and answers False for the caller to return. }
    function ContainFault(E: Exception): Boolean;
    function EnterFPU: TFPUExceptionMask;
    procedure LeaveFPU(const ASaved: TFPUExceptionMask);
    procedure CloseAllChannels;
    function ValidChannel(ANum: Integer): Boolean;
    // Classic-I/O primitives. Each returns an engine error (NoError on success) so
    // the opcode handlers can route a failure through Fault (ON ERROR-catchable).
    function ChanOpen(ANum, AMode: Integer; const APath: String): TPhosphorError;
    function ChanClose(ANum: Integer): TPhosphorError;
    // Window management for the streaming readers. ChanMore pulls one more chunk
    // from disk (False at end of file); ChanEnsure guarantees ANeed unconsumed
    // bytes if the file has them; ChanCursor is the logical file offset.
    function ChanMore(ANum: Integer): Boolean;
    function ChanEnsure(ANum, ANeed: Integer): Boolean;
    function ChanCursor(ANum: Integer): Int64;
    function ChanSeek(ANum: Integer; APos: Int64): TPhosphorError;
    function ChanWrite(ANum: Integer; const S: String): TPhosphorError;
    function ChanField(ANum, ATypeCode: Integer; out V: TValue): TPhosphorError;
    function ChanLine(ANum: Integer; out S: String): TPhosphorError;
    function ChanChars(ANum, ACount: Integer; out S: String): TPhosphorError;
    function ChanEof(ANum: Integer; out B: Boolean): TPhosphorError;
    function ChanLof(ANum: Integer; out N: Int64): TPhosphorError;
    function ChanLoc(ANum: Integer; out N: Int64): TPhosphorError;
    // Console INPUT primitives (over the OnInput seam). INPUT / LINE INPUT and
    // INPUT$ share one console buffer (FCharBuf/FCharPos), so char reads and line
    // reads consume the same stream in order, as a classic BASIC console does.
    function PullLine: Boolean;                       // append one host line; False at EOF
    function ReadInputLine: Boolean;                  // fill FInBuf; False at EOF
    function InputField(ATypeCode: Integer; out V: TValue): TPhosphorError;
    function InputChars(ACount: Integer): String;
    { The fetch-decode-execute loop. Runs from AStartPC until the program halts
      (or its instructions run out) OR a user-function return brings the frame
      stack back down to AStopFrameSP -- the bound that lets CallUserFunc invoke
      one BASIC routine re-entrantly and hand control back. The top-level Run uses
      AStopFrameSP = -1, a level the frame stack never reaches, so it runs to end. }
    function ExecFrom(AStartPC, AStopFrameSP: Integer): Boolean;
  public
    OnOutput: TPhosphorOutputProc;
    { The INPUT seam, nil by default (a headless host installs none). The VM asks
      the host for the next console line through it; with none installed, INPUT
      reads as empty. Wired like OnOutput -- the engine only offers the seam. }
    OnInput: TPhosphorInputProc;
    { The BREAKPOINT seam, nil by default (a headless host installs none). The VM
      calls it -- and only while tracing is on -- to REPORT a breakpoint's frame,
      then continues unconditionally. It must never block; see the opBreakpoint
      handler. }
    OnBreakpoint: TPhosphorBreakpointProc;
    { The host-services seam, all-nil by default (a headless host installs none).
      Library functions ask the host for an event pump or the clipboard through
      it; with a field unset they get the empty answer, never a fault. Wired like
      OnOutput/OnBreakpoint -- the engine only ever offers the seam, the platform
      work belongs to a host. }
    HostServices: THostServices;
    Registry: TPhosphorRegistry;
    LastError: TPhosphorError;
    ErrorLine: Integer;
    // Host-set execution ceilings; 0 = unlimited (the default, zero cost).
    MaxSteps: Int64;        // instruction budget (the answer to an infinite loop)
    MaxOutputBytes: Int64;  // total bytes emitted through OnOutput
    TimeoutMs: Int64;       // wall-clock ceiling in milliseconds
    { HOW MUCH HEAP THIS RUN MAY ADD, and the fourth ceiling because the other
      three do not bound memory at all -- which the budget unit says in its own
      header and no ceiling acted on.

      MaxSteps counts INSTRUCTIONS, and one instruction whose cost is O(n) makes
      it a poor proxy: measured under the ceilings docs/embedding.md prescribes,
      `s$ = string$(200000000, 97)` is allowed and then three `s$ = s$ + s$` reach
      1.6 GB of string and 14.7 GB of peak, in three instructions out of a
      million, rc 0. TimeoutMs does stop such a run -- after the allocation. And
      the budget's RULE 1 is asked at the opCall seam by a LIBRARY about its own
      arguments, so `+` was never in front of it: it is opAdd, a VM instruction.

      Measured from the heap as this run STARTS, so it bounds what the SCRIPT
      adds and does not depend on how much the host was already holding. }
    MaxMemoryBytes: Int64;
    constructor Create;
    destructor Destroy; override;   // closes any file channels left open
    function Run(AProg: TProgram): Boolean;  // False on error (LastError/ErrorLine set)
    { Run AProg from AStartPC over the CURRENT globals, handles and open channels,
      instead of a clean slate -- the REPL session path. FVars grows to AProg.VarCount
      keeping every existing value, so a variable set by an earlier line survives, and
      user functions defined earlier stay callable because AProg still carries them. }
    function RunFrom(AProg: TProgram; AStartPC: Integer): Boolean;
    { Call a BASIC user function by name, re-entrantly, over the SAME globals and
      handles as the running program. This is the host callback seam: an event
      dispatcher (or the callfunc primitive) runs a BASIC routine and gets its
      return value back. Err is set (and the result is a default value) if the
      function is unknown or the routine fails. }
    function CallUserFunc(const AName: String; const Args: array of TValue;
                          out Err: TPhosphorError): TValue;
    { Same, but falling through to the LIBRARY when the program defines no such
      routine -- the order opCall uses, so an indirect call means what a direct
      one means. This is what callfunc calls. }
    function CallByName(const AName: String; const Args: array of TValue;
                        out Err: TPhosphorError): TValue;
    { Is anything callable under this name -- a routine of the running program or
      a library function -- without calling it? The same two places CallByName
      looks. About the NAME only: the arity and kinds of a call that has not
      happened yet are not knowable, and guessing is not a predicate. }
    function KnowsName(const AName: String): Boolean;
    { The last error caught by an ON ERROR handler -- what err()/errmsg$()/erl()
      read. Set on each fault; persists until the next fault. }
    { True once the program has run END. A host that re-enters the VM (a GUI event
      bridge, a callback) must check this after the call and stop: END means the
      PROGRAM is over, not just the routine that said it. }
    { WHAT HAPPENS WHEN THE INTERPRETER ITSELF TAKES A FAULT.

      False (the default, and what every version before this did): the Pascal
      exception travels out of Run into the host, which is where a Lazarus
      application meets the LCL's default handler and its modal dialog -- on a
      machine with nobody in front of it, a dialog is a HANG, which is worse than
      a crash because it gives no message and no exit code.

      True: the fault is caught at the edge of execution and turned into an
      ordinary failed Run -- Result False, LastError carrying peFatal and the
      exception's class and message. Nothing is raised at the host. ON ERROR is
      NOT offered it and never will be; see peFatal for why resuming a script on
      damaged memory is the worse of the two outcomes. The host gets what it
      actually needs: a chance to tell the user, save their work, and shut down
      on its own terms.

      This engine instance is finished either way -- FFaulted makes the next Run
      refuse. Containment buys the PROCESS, not the interpreter. }
    property ContainFaults: Boolean read FContainFaults write FContainFaults;
    { True once the program has run END. Read it after a callback: END means the
      PROGRAM is over, not just the routine that said it, and CallUserFunc refuses
      every later call rather than running one and discarding its answer. }
    property Halted: Boolean read FHalted;
    { The top level finishing is NOT the program being over.

      `end` before a block of subroutines is the idiom the language reference
      teaches, and Prepare runs the top level once and keeps the VM alive for the
      host to call into -- so the two documented halves met at a flag that made
      every later call answer 0. Prepare says so here, once, after a top level that
      completed. Nothing else may call this: a callback that halts really has ended
      the program, and clearing that would be the defect wearing the other face. }
    procedure EndOfTopLevel;
    property ErrCode: Integer read FErrCode;
    property ErrMessage: String read FErrMsg;
    property ErrLine: Integer read FErrLine;
    procedure ClearError;   // reset err()/errmsg$()/erl() to "no error"
    { READ-ONLY STATE, FOR A HOST THAT WANTS TO LOOK. Nothing here writes, and the
      dispatch loop does not know they exist -- no field was added, no branch was
      put on any execution path, and a program that never calls one costs exactly
      what it cost before.

      WHAT THEY ARE VALID FOR, which is the half that a caller gets wrong. They
      describe the VM AS IT STANDS. That is a useful thing to ask three times:

        * after Prepare, and between CallFunction calls -- the globals the top
          level built, which is what an embedder dumping state wants and is the
          whole reason this is worth having before any debugger exists;
        * from inside a seam the VM called into (OnOutput, OnBreakpoint, a library
          function) -- the frames are live and DbgFrameDepth is above zero;
        * never after the VM has been freed. TPhosphorEngine.Run frees its VM and
          its program in the same finally, so there is nothing left to ask; the
          prepared VM (Prepare) is the one that outlives its call.

      DbgProgram may be nil -- a VM that has not run yet has no program -- and a
      program read back from a .pbc carries no names. Every index is bounded here
      rather than at the caller: a host dumping state loops over counts, and an
      accessor that faulted on a stale count would take down a process that was
      only asking a question. }
    function DbgProgram: TProgram;
    function DbgGlobalCount: Integer;
    function DbgGlobal(AIndex: Integer): TValue;
    { How many activation frames are live. 0 at the top level. }
    function DbgFrameDepth: Integer;
    { The index into DbgProgram.UserFuncs of the function frame AFrame is running,
      counting from 0 = the OUTERMOST call, or -1 if there is no such frame. }
    function DbgFrameFunc(AFrame: Integer): Integer;
    function DbgFrameLocalCount(AFrame: Integer): Integer;
    function DbgLocal(AFrame, ASlot: Integer): TValue;
  end;

implementation

function IsStateFault(E: Exception): Boolean;
begin
  if E = nil then Exit(False);
  if (E is EIntError) or (E is EMathError) then Exit(False);   // value errors
  Result := (E is EExternal) or (E is EInvalidPointer);
end;

constructor TPhosphorVM.Create;
begin
  inherited Create();
  SetLength(FStack, 64);
  FSP := 0;
  LastError := NoError();
  ErrorLine := 0;
  // No frames yet, so no local slots held; see MaxFrameDepth.
  FFrameSlots := 0;
end;

{ THE VALUE MAY LIVE IN THE ARRAY THIS IS ABOUT TO MOVE.

  V arrives BY REFERENCE (const TValue is passed as a pointer), and a caller is
  entitled to pass a stack slot: opDupN does, deliberately, because copying each
  element into a temporary first would be a managed-string refcount per element in
  the one loop where the count is large. SetLength REALLOCATES -- the old block is
  released and every pointer into it, V included, dangles -- so `FStack[FSP] := V`
  read a freed TValue and then refcounted whatever its Str field happened to
  contain. The comment that used to sit over opDupN's loop defended the INDEX
  across the reallocation, which never needed defending; the REFERENCE did.

  It is reachable from plain source, with no bytecode to craft:

      a@ = dim@(5)
      a@[1,1, ... ,1] += 1        (16384 subscripts or more)

  compiles to `DUPN 16385`, whose 16385th push is the one that doubles the stack.
  Access violation, exit 3, uncatchable, in a process an embedder owns. (2026-09-06.)

  THE FIX IS HERE, NOT AT THE CALL SITE, because "no caller may hold a reference
  into a structure the callee reallocates" is not a rule twenty call sites can be
  trusted to keep -- and the next one to break it would be written by someone who
  had read the reassuring comment. Push is the only routine that grows FStack, so
  Push is where the reference is made safe: the value is copied out BEFORE the
  array moves, and only on the doubling. The ordinary push is the else branch and
  is byte for byte what it was.

  It also refuses to grow past MaxStackDepth; see FStackLimit. }
procedure TPhosphorVM.Push(const V: TValue);
var
  moved: TValue;
  want: Integer;
begin
  if FSP = Length(FStack) then
  begin
    want := Length(FStack) * 2;
    if want < 64 then want := 64;           // (a zero-length stack would never grow)
    if want > MaxStackDepth then want := MaxStackDepth;
    if FSP >= want then
    begin
      // At the ceiling. Nothing is allocated and nothing is written: the value is
      // dropped and the dispatch loop stops the program at the next instruction.
      FStackLimit := True;
      Exit;
    end;
    moved := V;                             // out of the block that is about to go
    SetLength(FStack, want);
    FStack[FSP] := moved;
  end
  else
    FStack[FSP] := V;
  Inc(FSP);
end;

function TPhosphorVM.Pop: TValue;
begin
  if FSP = 0 then
  begin
    Result := Default(TValue);
    Exit;
  end;
  Dec(FSP);
  Result := FStack[FSP];
end;

procedure TPhosphorVM.UseProgram(AProg: TProgram);
begin
  FProg := AProg;
end;

function TPhosphorVM.ContainFault(E: Exception): Boolean;
begin
  FFaulted := True;
  { The CLASS is in the message on purpose. "Invalid floating point operation"
    and "Access violation" are different news for whoever reads the log, and by
    the time a host sees this the stack that produced it is gone. }
  LastError := MakeError(peFatal, E.ClassName + ': ' + E.Message);
  if ErrorLine = 0 then ErrorLine := FErrLine;
  Result := False;
end;

function TPhosphorVM.EnterFPU: TFPUExceptionMask;
begin
  Result := GetExceptionMask();
  SetExceptionMask(Result + [exOverflow, exUnderflow, exPrecision, exDenormalized]);
end;

procedure TPhosphorVM.LeaveFPU(const ASaved: TFPUExceptionMask);
begin
  SetExceptionMask(ASaved);
end;

destructor TPhosphorVM.Destroy;
begin
  CloseAllChannels();
  inherited Destroy();
end;

procedure TPhosphorVM.CloseAllChannels;
var i: Integer;
begin
  for i := 1 to MaxChannel do
    if FChannels[i].Open then
    begin
      FChannels[i].Stream.Free;   // nil-safe (INPUT channels keep Stream nil)
      FChannels[i].Stream := nil;
      FChannels[i].Buf := '';
      FChannels[i].Open := False;
    end;
end;

function TPhosphorVM.ValidChannel(ANum: Integer): Boolean;
begin
  Result := (ANum >= 1) and (ANum <= MaxChannel);
end;

{ --- classic-I/O field parsing (shared by console INPUT and INPUT#) ------------
  Take the next delimited field from Buf starting at Pos (1-based), advancing Pos
  past it and one trailing comma. In file mode leading blanks and newlines are
  skipped and an unquoted field ends at a comma OR any whitespace/newline; on the
  console a field ends only at a comma (interior spaces are kept). A leading double
  quote reads a quoted string, with "" meaning a literal quote. }
function NextFieldStr(const Buf: String; var Pos: Integer; AFileMode: Boolean): String;
var
  n, k: Integer;
  r: RawByteString;
begin
  Result := '';
  n := Length(Buf);
  if AFileMode then
    while (Pos <= n) and ((Buf[Pos] = ' ') or (Buf[Pos] = #9) or
                          (Buf[Pos] = #13) or (Buf[Pos] = #10)) do Inc(Pos);
  // The field is built by INDEXED writes into a RawByteString (its length can
  // never exceed the rest of the buffer). Appending byte by byte to a String
  // re-encodes any byte >= 128 through the UTF-8 codepage and lands it as '?',
  // which silently destroyed binary and Latin-1 fields.
  if n - Pos + 1 > 0 then SetLength(r, n - Pos + 1) else SetLength(r, 0);
  k := 0;
  if (Pos <= n) and (Buf[Pos] = '"') then
  begin
    Inc(Pos);   // opening quote
    while Pos <= n do
    begin
      if Buf[Pos] = '"' then
      begin
        if (Pos < n) and (Buf[Pos + 1] = '"') then
          begin Inc(k); r[k] := '"'; Inc(Pos, 2); end      // "" -> a literal quote
        else
          begin Inc(Pos); Break; end;                       // closing quote
      end
      else
        begin Inc(k); r[k] := Buf[Pos]; Inc(Pos); end;
    end;
  end
  else
  begin
    while Pos <= n do
    begin
      if Buf[Pos] = ',' then Break;
      if AFileMode and ((Buf[Pos] = ' ') or (Buf[Pos] = #9) or
                        (Buf[Pos] = #13) or (Buf[Pos] = #10)) then Break;
      Inc(k); r[k] := Buf[Pos];
      Inc(Pos);
    end;
    if not AFileMode then
      while (k > 0) and (r[k] = ' ') do Dec(k);   // trim trailing blanks
  end;
  SetLength(r, k);
  Result := r;
  // consume a single trailing separator comma (skip blanks before it in file mode)
  if AFileMode then
    while (Pos <= n) and ((Buf[Pos] = ' ') or (Buf[Pos] = #9) or
                          (Buf[Pos] = #13) or (Buf[Pos] = #10)) do Inc(Pos);
  if (Pos <= n) and (Buf[Pos] = ',') then Inc(Pos);
end;

{ Coerce a raw input field to a variable's type. Type code: 0 number, 1 string,
  2 int, 3 bool. An empty field takes the type's default; a non-empty field that
  will not parse is a catchable runtime error. }
function CoerceField(const AField: String; ATypeCode: Integer; out V: TValue): TPhosphorError;
var
  iv: Int64;
  dv: Double;
  fs: TFormatSettings;
  low: String;
begin
  Result := NoError();
  V := Default(TValue);
  case ATypeCode of
    1: V := ValStr(AField);
    0, 2:
      begin
        if AField = '' then
        begin
          if ATypeCode = 2 then V := ValInt(0) else V := ValInt(0);
          Exit;
        end;
        if TryStrToInt64(AField, iv) then
        begin
          if ATypeCode = 2 then V := ValInt(iv)
          else V := ValInt(iv);   // vtNumber holds an int% happily
          Exit;
        end;
        fs := DefaultFormatSettings;
        fs.DecimalSeparator := '.';
        fs.ThousandSeparator := #0;
        if TryStrToFloat(AField, dv, fs) then
        begin
          { NON-FINITE IS DECIDED FIRST, BEFORE ANY COMPARISON TOUCHES dv.

            The int% branch below reached InI64Range, whose own comment says "NaN
            and Inf fail both comparisons, so they answer False" -- true of IEEE
            predicates, false of the instruction FPC emits for them with
            exInvalidOp unmasked. See NonFinite. The two messages are kept exactly
            as they were, so nothing downstream can tell this reordering happened
            except by not crashing. }
          if IsNan(dv) or IsInfinite(dv) then
          begin
            if ATypeCode = 2 then
              Result := MakeError(peRuntime, '"' + AField + '" is out of integer range')
            else
              Result := MakeError(peRuntime, '"' + AField + '" is out of range');
          end
          else if ATypeCode = 2 then
          begin
            if InI64Range(dv) then V := ValInt(Round(dv))
            else Result := MakeError(peRuntime, '"' + AField + '" is out of integer range');
          end
          { THE FINITENESS GATE APPLIES TO INPUT TOO.

            "no TValue ever holds a non-finite Double" (see FiniteD in
            PhosphorValue) is what makes it safe to run a program with the
            invalid-operation trap unmasked -- and TryStrToFloat is perfectly happy
            to answer a field like 1e999 with +Inf. `input x` over that field used
            to store the Inf and carry on; the next operation on it (x - x, an Inf
            to NaN) then raised EInvalidOp OUTSIDE the engine's error path, so the
            process died with "unhandled EInvalidOp" at exit 3 and the running
            program could not catch a thing. In an embedded host that is the host's
            process, which decisions.md forbids.

            A field is DATA, not source, so this arrives from a file as readily as
            from a keyboard: `input #1, x` over a data line reaches this same
            function through opFileField. Refused here, next to the int% overflow
            just above, with the offending text in the message. (2026-09-06.) }
          else if IsInfinite(dv) or IsNan(dv) then
            Result := MakeError(peRuntime, '"' + AField + '" is out of range')
          else V := ValDouble(dv);
        end
        else
          Result := MakeError(peRuntime, '"' + AField + '" is not a number');
      end;
    3:
      begin
        low := LowerCase(AField);
        if (low = 'true') or (low = '1') or (low = 'yes') then V := ValBool(True)
        else if (low = 'false') or (low = '0') or (low = 'no') or (low = '') then V := ValBool(False)
        else Result := MakeError(peRuntime, '"' + AField + '" is not true/false');
      end;
  else
    Result := MakeError(peTypeMismatch, 'cannot read input into this variable');
  end;
end;

{ IS THIS VALUE A DOUBLE NO COMPARISON MAY TOUCH?

  `d <> d` is the classic NaN self-test and it is WRONG HERE. On x86-64 FPC emits
  COMISD for a Double comparison, and COMISD signals the invalid-operation
  exception on a QUIET NaN, not merely a signalling one -- and the engine runs
  with exInvalidOp UNMASKED (see EnterFPU: only overflow/underflow/precision/
  denormal are masked, deliberately). So the test written to AVOID a trap IS the
  trap. Measured 2026-09-07 in a process carrying the VM's own mask: `nan <> nan`
  raises EInvalidOp before it can answer.

  Every one of these comparisons sits in the dispatch loop or in a helper the
  dispatch loop calls, outside any try/except, so the raise leaves as "unhandled
  EInvalidOp", exit 217, and the host's process is gone. A host that hands a NaN
  to a prepared script -- CallFunction is the documented seam -- reached this from
  `len(input$(x))`, `eof(x)` and `close #x` alike, all three at exit 217.

  IsNan and IsInfinite read the exponent and mantissa bits (FPC 3.2.2
  rtl/objpas/math.pp:2265, 2304 -- no FP comparison in either) and cannot raise.
  Use them. Never let a Double that came from outside the arithmetic kernel meet a
  comparison, ordered or not, before this has answered False. }
function NonFinite(const V: TValue): Boolean;
begin
  Result := (V.Kind = vkDouble) and (IsNan(V.Num) or IsInfinite(V.Num));
end;

{ A crash-proof Double -> Int32 for the classic-I/O opcodes (file numbers, byte
  counts). Out-of-range or NaN values never reach Round (which would raise): a huge
  magnitude clamps to the Int32 extreme -- for a file number that lands outside
  1..MaxChannel so the channel op reports "out of range", and for a byte count it
  simply means "as many as there are".

  The NaN test comes FIRST and is a bit test, not a comparison; see NonFinite. The
  three ordered comparisons below are safe only because a NaN has already left. }
function SafeI32(const V: TValue): Integer;
var d: Double;
begin
  d := AsDouble(V);
  if IsNan(d) then Result := 0
  else if d >= 2147483647.0 then Result := High(Integer)
  else if d <= -2147483648.0 then Result := Low(Integer)
  else Result := Round(d);
end;

{ The same for a 64-bit quantity -- SEEK's file position, which must not be
  narrowed to 32 bits (a position past 2 GB would clamp and two offsets would
  collapse onto one).

  This exists rather than calling PhosphorValue's ArgI64 because that routine
  still opens with `d <> d`, and opSeekFile is in the dispatch loop with no
  try/except over it, so the trap described at NonFinite would kill the process
  through `seek #1, x`. Fixing ArgI64 belongs to the unit that owns it; NOT
  DEPENDING on that fix belongs here. }
function SafeI64(const V: TValue): Int64;
var d: Double;
begin
  if V.Kind = vkInt then Exit(V.Int);       // exact: no trip through Double
  d := AsDouble(V);
  if IsNan(d) then Result := 0
  else if d >= 9223372036854775808.0 then Result := High(Int64)
  else if d <= -9223372036854775808.0 then Result := Low(Int64)
  else Result := Round(d);
end;

// --- console INPUT -----------------------------------------------------------
function TPhosphorVM.PullLine: Boolean;
var line: String;
begin
  Result := Assigned(OnInput) and OnInput(line);
  if Result then FCharBuf := FCharBuf + line + #10;   // the stripped newline is significant
end;

function TPhosphorVM.ReadInputLine: Boolean;
var nl, i: Integer;
begin
  // Take the next line out of the shared console buffer, pulling host lines until
  // a newline (or the input) runs out. INPUT$ reads from the same cursor, so a
  // mid-line INPUT$ leaves the rest of the line for the next LINE INPUT.
  nl := 0;
  while nl = 0 do
  begin
    for i := FCharPos to Length(FCharBuf) do
      if FCharBuf[i] = #10 then begin nl := i; Break; end;
    if nl > 0 then Break;
    if not PullLine() then Break;
  end;
  if (nl = 0) and (FCharPos > Length(FCharBuf)) then
  begin
    FInBuf := ''; FInPos := 1;
    Exit(False);   // no input remains
  end;
  if nl = 0 then nl := Length(FCharBuf) + 1;   // a final line with no trailing newline
  FInBuf := Copy(FCharBuf, FCharPos, nl - FCharPos);
  if (Length(FInBuf) > 0) and (FInBuf[Length(FInBuf)] = #13) then
    SetLength(FInBuf, Length(FInBuf) - 1);      // drop a CR from a CRLF line
  FInPos := 1;
  FCharPos := nl + 1;
  if FCharPos > Length(FCharBuf) then begin FCharBuf := ''; FCharPos := 1; end;
  Result := True;
end;

function TPhosphorVM.InputField(ATypeCode: Integer; out V: TValue): TPhosphorError;
var field: String;
begin
  field := NextFieldStr(FInBuf, FInPos, False);
  Result := CoerceField(field, ATypeCode, V);
end;

function TPhosphorVM.InputChars(ACount: Integer): String;
begin
  Result := '';
  if ACount <= 0 then Exit;
  while (Length(FCharBuf) - FCharPos + 1) < ACount do
    if not PullLine() then Break;   // EOF: hand back whatever is buffered
  if FCharPos > Length(FCharBuf) then Exit;
  Result := Copy(FCharBuf, FCharPos, ACount);
  Inc(FCharPos, Length(Result));
  if FCharPos > Length(FCharBuf) then begin FCharBuf := ''; FCharPos := 1; end;
end;

// --- file channels -----------------------------------------------------------
function TPhosphorVM.ChanOpen(ANum, AMode: Integer; const APath: String): TPhosphorError;
var
  fmode: TChannelMode;
begin
  Result := NoError();
  if not ValidChannel(ANum) then
    Exit(MakeError(peRuntime, 'file number #' + IntToStr(ANum) + ' is out of range (1..' + IntToStr(MaxChannel) + ')'));
  if FChannels[ANum].Open then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is already open'));
  case AMode of
    0: fmode := cmInput;
    1: fmode := cmOutput;
    2: fmode := cmAppend;
    3: fmode := cmBinary;
  else
    Exit(MakeError(peRuntime, 'bad OPEN mode'));
  end;
  // One gate for all five OPEN modes: a channel is the other way a script reaches
  // the filesystem, and it must be bounded by the same root as file_* is.
  if not SandboxAllows(APath, puRead) then
    Exit(MakeError(peRuntime, 'cannot open "' + APath + '": outside the sandbox root'));
  if (fmode <> cmInput) and not SandboxAllows(APath, puWrite) then
    Exit(MakeError(peRuntime, 'cannot open "' + APath + '" for writing: outside the sandbox root'));
  // Reset the slot field by field -- FillChar over a record holding a managed
  // string would zero the reference without releasing it.
  FChannels[ANum].Stream := nil;
  FChannels[ANum].Buf := '';
  FChannels[ANum].Pos := 1;
  FChannels[ANum].BufStart := 0;
  FChannels[ANum].Mode := fmode;
  try
    case fmode of
      cmInput:
        begin
          if not FileExists(APath) then
            Exit(MakeError(peRuntime, 'cannot open "' + APath + '" for input: no such file'));
          // Streamed, not slurped: the file stays open and is read a window at a
          // time, so a file larger than memory is still readable.
          FChannels[ANum].Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
        end;
      cmOutput:
        // fmCreate ALONE takes an exclusive share on Windows and nothing at all on
        // Linux, so `open f$ for input as #1 : open f$ for output as #4` errored on
        // one platform and worked on the other. Denying other WRITERS while still
        // letting readers in matches what an output channel means, and makes the
        // two platforms answer the same.
        FChannels[ANum].Stream := TFileStream.Create(APath, fmCreate or fmShareDenyWrite);
      cmAppend:
        begin
          if FileExists(APath) then
          begin
            FChannels[ANum].Stream := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyWrite);
            FChannels[ANum].Stream.Seek(0, soEnd);
          end
          else
            FChannels[ANum].Stream := TFileStream.Create(APath, fmCreate or fmShareDenyWrite);
        end;
      cmBinary:
        begin
          // Read/write and positionable; created empty if it does not exist yet.
          if FileExists(APath) then
            FChannels[ANum].Stream := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyWrite)
          else
            FChannels[ANum].Stream := TFileStream.Create(APath, fmCreate or fmShareDenyWrite);
        end;
    end;
    FChannels[ANum].Open := True;
  except
    on E: Exception do
      Result := MakeError(peRuntime, 'cannot open "' + APath + '": ' + E.Message);
  end;
end;

{ Pull one more chunk from disk into the window. False at end of file. }
function TPhosphorVM.ChanMore(ANum: Integer): Boolean;
var chunk: RawByteString; got: Integer;
begin
  Result := False;
  if FChannels[ANum].Stream = nil then Exit;
  // Drop what has already been consumed before growing, so the window stays small.
  if FChannels[ANum].Pos > 1 then
  begin
    Inc(FChannels[ANum].BufStart, FChannels[ANum].Pos - 1);
    Delete(FChannels[ANum].Buf, 1, FChannels[ANum].Pos - 1);
    FChannels[ANum].Pos := 1;
  end;
  SetLength(chunk, ChanChunk);
  got := FChannels[ANum].Stream.Read(chunk[1], ChanChunk);
  if got <= 0 then Exit;
  SetLength(chunk, got);
  FChannels[ANum].Buf := FChannels[ANum].Buf + chunk;
  Result := True;
end;

{ True once ANeed unconsumed bytes are in the window (or the file ran out). }
function TPhosphorVM.ChanEnsure(ANum, ANeed: Integer): Boolean;
begin
  while (Length(FChannels[ANum].Buf) - FChannels[ANum].Pos + 1) < ANeed do
    if not ChanMore(ANum) then Break;
  Result := (Length(FChannels[ANum].Buf) - FChannels[ANum].Pos + 1) >= ANeed;
end;

{ The logical file offset of the next byte to be read (0-based). }
function TPhosphorVM.ChanCursor(ANum: Integer): Int64;
begin
  Result := FChannels[ANum].BufStart + FChannels[ANum].Pos - 1;
end;

{ Move the read/write cursor. APos is 1-BASED, like every other index in the
  language: seek #n, 1 is the first byte, and `seek #n, loc(n)` is a no-op. }
function TPhosphorVM.ChanSeek(ANum: Integer; APos: Int64): TPhosphorError;
begin
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  // Every other channel primitive checks the mode; this one did not, so SEEK
  // repositioned an APPEND channel and the next PRINT # overwrote in place. An
  // append-only log lost its first bytes, silently, with exit code 0. OUTPUT and
  // APPEND are write-only and append-only by contract (see the mode table above);
  // BINARY is read/write and positionable, and positioning a read is harmless.
  if not (FChannels[ANum].Mode in [cmInput, cmBinary]) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) +
      ' is not open for random access (only INPUT and BINARY can seek)'));
  if APos < 1 then
    Exit(MakeError(peRuntime, 'seek: position must be 1 or more'));
  Result := NoError();
  try
    FChannels[ANum].Stream.Position := APos - 1;
    FChannels[ANum].Buf := '';
    FChannels[ANum].Pos := 1;
    FChannels[ANum].BufStart := APos - 1;
  except
    on E: Exception do
      Result := MakeError(peRuntime, 'seek failed: ' + E.Message);
  end;
end;

function TPhosphorVM.ChanClose(ANum: Integer): TPhosphorError;
begin
  Result := NoError();
  // No sentinel here any more. `ANum < 0 means close everything` was an internal
  // convention that a USER-supplied number could reach: `close #n%` with n% gone
  // negative closed every open channel and reported success, so a program that
  // computes its channel numbers lost every file it was midway through writing.
  // The bare CLOSE calls CloseAllChannels directly instead.
  if not ValidChannel(ANum) then
    Exit(MakeError(peRuntime, 'file number #' + IntToStr(ANum) + ' is out of range'));
  if not FChannels[ANum].Open then Exit;   // closing an unopened channel is a no-op
  FChannels[ANum].Stream.Free;
  FChannels[ANum].Stream := nil;
  FChannels[ANum].Buf := '';
  FChannels[ANum].Open := False;
end;

function TPhosphorVM.ChanWrite(ANum: Integer; const S: String): TPhosphorError;
begin
  Result := NoError();
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  if FChannels[ANum].Mode = cmInput then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is open for input, not output'));
  if Length(S) = 0 then Exit;
  if FChannels[ANum].Mode = cmBinary then
  begin
    // Overwrite AT THE CURSOR. Reads buffer ahead, so the stream position may sit
    // past it; put the stream back on the logical cursor, write, then drop the
    // stale window and let the cursor follow the write.
    FChannels[ANum].Stream.Position := ChanCursor(ANum);
    FChannels[ANum].Stream.WriteBuffer(S[1], Length(S));
    FChannels[ANum].Buf := '';
    FChannels[ANum].Pos := 1;
    FChannels[ANum].BufStart := FChannels[ANum].Stream.Position;
    Exit;
  end;
  FChannels[ANum].Stream.WriteBuffer(S[1], Length(S));
end;

function TPhosphorVM.ChanField(ANum, ATypeCode: Integer; out V: TValue): TPhosphorError;
var field: String; i, j, n: Integer; found: Boolean;
begin
  V := Default(TValue);
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  if not (FChannels[ANum].Mode in [cmInput, cmBinary]) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open for input'));
  // Read ahead until the window holds THE WHOLE FIELD (or the file ends).
  repeat
    found := False;
    n := Length(FChannels[ANum].Buf);
    // Where the field really begins: after the blanks NextFieldStr will skip.
    // Looking for a terminator from the cursor found those blanks and stopped.
    i := FChannels[ANum].Pos;
    while (i <= n) and ((FChannels[ANum].Buf[i] = ' ') or (FChannels[ANum].Buf[i] = #9) or
                        (FChannels[ANum].Buf[i] = #13) or (FChannels[ANum].Buf[i] = #10)) do
      Inc(i);
    if i <= n then
      if FChannels[ANum].Buf[i] = '"' then
      begin
        // a quoted field ends at its closing quote; "" is an escaped one
        j := i + 1;
        while j <= n do
          if FChannels[ANum].Buf[j] <> '"' then Inc(j)
          else if (j < n) and (FChannels[ANum].Buf[j + 1] = '"') then Inc(j, 2)
          else begin found := True; Break; end;
      end
      else
        for j := i to n do
          if (FChannels[ANum].Buf[j] = ',') or (FChannels[ANum].Buf[j] = ' ') or
             (FChannels[ANum].Buf[j] = #9) or (FChannels[ANum].Buf[j] = #13) or
             (FChannels[ANum].Buf[j] = #10) then begin found := True; Break; end;
    if found then Break;
  until not ChanMore(ANum);
  field := NextFieldStr(FChannels[ANum].Buf, FChannels[ANum].Pos, True);
  Result := CoerceField(field, ATypeCode, V);
end;

function TPhosphorVM.ChanLine(ANum: Integer; out S: String): TPhosphorError;
var p, n, start: Integer; found: Boolean;
begin
  S := '';
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  if not (FChannels[ANum].Mode in [cmInput, cmBinary]) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open for input'));
  Result := NoError();
  // Read ahead until the window holds a line terminator (or the file ends), so a
  // line spanning a chunk boundary still comes back whole.
  repeat
    found := False;
    for p := FChannels[ANum].Pos to Length(FChannels[ANum].Buf) do
      if (FChannels[ANum].Buf[p] = #10) or (FChannels[ANum].Buf[p] = #13) then
        begin found := True; Break; end;
    if found then Break;
  until not ChanMore(ANum);
  n := Length(FChannels[ANum].Buf);
  p := FChannels[ANum].Pos;
  start := p;
  // Scan to the terminator, then take the run with ONE Copy. Appending byte by
  // byte re-encodes any byte >= 128 through the UTF-8 codepage and lands it as
  // '?', silently destroying binary and Latin-1 data.
  while (p <= n) and (FChannels[ANum].Buf[p] <> #10) and (FChannels[ANum].Buf[p] <> #13) do Inc(p);
  S := Copy(FChannels[ANum].Buf, start, p - start);
  // Step over the line terminator (CR, LF, or CRLF). If the CR was the last byte
  // the window held, the LF has not been read yet: commit the position, pull the
  // next chunk, and look again. Without this the pair was split, the LF began the
  // next read, and a two-line file came back as three.
  if (p <= n) and (FChannels[ANum].Buf[p] = #13) then
  begin
    Inc(p);
    if p > n then
    begin
      FChannels[ANum].Pos := p;
      if ChanMore(ANum) then
      begin
        p := FChannels[ANum].Pos;
        n := Length(FChannels[ANum].Buf);
      end;
    end;
  end;
  if (p <= n) and (FChannels[ANum].Buf[p] = #10) then Inc(p);
  FChannels[ANum].Pos := p;
end;

function TPhosphorVM.ChanChars(ANum, ACount: Integer; out S: String): TPhosphorError;
var avail: Integer;
begin
  S := '';
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  if not (FChannels[ANum].Mode in [cmInput, cmBinary]) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open for input'));
  Result := NoError();
  if ACount <= 0 then Exit;
  ChanEnsure(ANum, ACount);                  // pull what the request needs
  avail := Length(FChannels[ANum].Buf) - FChannels[ANum].Pos + 1;
  if avail <= 0 then Exit;
  if ACount > avail then ACount := avail;     // a short read at end of file
  S := Copy(FChannels[ANum].Buf, FChannels[ANum].Pos, ACount);
  Inc(FChannels[ANum].Pos, ACount);
end;

function TPhosphorVM.ChanEof(ANum: Integer; out B: Boolean): TPhosphorError;
begin
  B := True;
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  if not (FChannels[ANum].Mode in [cmInput, cmBinary]) then
    Exit(MakeError(peRuntime, 'eof() needs a file open for input or binary'));
  Result := NoError();
  B := not ChanEnsure(ANum, 1);   // nothing buffered AND nothing left on disk
end;

function TPhosphorVM.ChanLof(ANum: Integer; out N: Int64): TPhosphorError;
begin
  N := 0;
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  Result := NoError();
  N := FChannels[ANum].Stream.Size;   // live size, every mode
end;

function TPhosphorVM.ChanLoc(ANum: Integer; out N: Int64): TPhosphorError;
begin
  N := 0;
  if not (ValidChannel(ANum) and FChannels[ANum].Open) then
    Exit(MakeError(peRuntime, 'file #' + IntToStr(ANum) + ' is not open'));
  Result := NoError();
  // 1-BASED, like every other position in the language: the number of the next
  // byte to be read or written, so `seek #n, loc(n)` changes nothing.
  if FChannels[ANum].Mode in [cmInput, cmBinary] then
    N := ChanCursor(ANum) + 1           // the logical cursor, not the read-ahead
  else
    N := FChannels[ANum].Stream.Position + 1;
end;

// --- PRINT USING formatter ---------------------------------------------------
// A classic-BASIC subset: numeric fields of '#' digit positions with optional
// '.' decimals, ',' grouping, a leading '+' or '$$'/'**', and a trailing '+'/'-';
// string fields '&' (whole), '!' (first char) and '\ \' (fixed width); '_' escapes
// the next literal character. Values fill fields left to right; if values remain
// after the format ends and it held at least one field, the format repeats.
function GroupThousands(const Digits: String): String;
var i, c, w: Integer;
begin
  // Sized up front and filled from the right. The old shape prepended one CHAR at a
  // time, which is both the codepage hazard and quadratic; digits are ASCII so
  // nothing was corrupted, but the rule against concatenating a Char is absolute
  // here so that the check enforcing it needs no exceptions.
  if Digits = '' then Exit('');
  w := Length(Digits) + (Length(Digits) - 1) div 3;
  SetLength(Result, w);
  c := 0;
  for i := Length(Digits) downto 1 do
  begin
    Result[w] := Digits[i];
    Dec(w);
    Inc(c);
    if (c mod 3 = 0) and (i > 1) then
    begin
      Result[w] := ',';
      Dec(w);
    end;
  end;
end;

function FormatNumericField(const Spec: String; const V: TValue): String;
var
  s, core, intPartStr, fracPartStr, numText, leftSign, trailSignStr, dollarStr, intField: String;
  fracDigits, width, pad, dotPos2, i: Integer;
  grouping, signLead, trailPlus, trailMinus, dollar, starFill, neg: Boolean;
  dotPos: Integer;
  av: Double;
  fs: TFormatSettings;
  padChar: Char;
begin
  s := Spec;
  dollar := False; starFill := False; signLead := False;
  trailPlus := False; trailMinus := False;
  if (Length(s) >= 2) and (s[1] = '$') and (s[2] = '$') then begin dollar := True; Delete(s, 1, 2); end
  else if (Length(s) >= 2) and (s[1] = '*') and (s[2] = '*') then begin starFill := True; Delete(s, 1, 2); end;
  if (Length(s) >= 1) and (s[1] = '+') then begin signLead := True; Delete(s, 1, 1); end;
  if (Length(s) >= 1) and (s[Length(s)] = '+') then begin trailPlus := True; SetLength(s, Length(s) - 1); end
  else if (Length(s) >= 1) and (s[Length(s)] = '-') then begin trailMinus := True; SetLength(s, Length(s) - 1); end;
  grouping := Pos(',', s) > 0;
  dotPos := Pos('.', s);
  fracDigits := 0;
  if dotPos > 0 then
    for i := dotPos + 1 to Length(s) do if s[i] = '#' then Inc(fracDigits);
  // The integer field width is the count of positions the spec devotes to the
  // integer part -- including any leading '$$'/'**'/'+' and grouping commas, but
  // not a trailing sign -- so the sign or floating '$' occupies a real column.
  begin
    core := Spec;
    if (Length(core) >= 1) and (core[Length(core)] in ['+', '-']) then
      SetLength(core, Length(core) - 1);
    dotPos2 := Pos('.', core);
    if dotPos2 > 0 then width := dotPos2 - 1 else width := Length(core);
  end;

  av := AsDouble(V);
  { `av < 0` IS AN ORDERED COMPARISON and PRINT USING is reached with whatever the
    program -- or a host, through CallFunction -- put in the value. A NaN operand
    raises EInvalidOp here, inside opPrintUsing, outside any try/except; see
    NonFinite. A non-finite value has no digits to lay out anyway, so it takes the
    text PRINT would give it and the field's own padding, and never meets a
    comparison at all. }
  if IsNan(av) or IsInfinite(av) then
  begin
    core := ValToStr(V);
    if starFill then padChar := '*' else padChar := ' ';
    pad := width - Length(core);
    if pad >= 0 then Result := StringOfChar(padChar, pad) + core
    else Result := '%' + core;      // overflow: the classic leading '%'
    Exit;
  end;
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;
  { AN int% IS LAID OUT FROM ITS OWN DIGITS, for the same reason str$ grew a ':%'
    slot: AsDouble above is a widening, and above 2^53 the Double has already
    lost the low digits before any formatter sees it.

      row% = 1234567890123456789
      println using "####################"; row%   ->  1234567890123456800

    while `println row%` printed all nineteen digits correctly. The field is
    twenty columns wide and the value fits; nothing overflowed and nothing was
    reported -- three digits were simply replaced. IntToStr of the Int64 is the
    exact primitive the rest of the engine already uses for vkInt.

    The sign is taken from the INTEGER, and the magnitude by dropping the minus
    from its text rather than by Abs(): Abs(Low(Int64)) has no Int64 result. }
  if V.Kind = vkInt then
  begin
    neg := V.Int < 0;
    numText := IntToStr(V.Int);
    if neg then Delete(numText, 1, 1);
    if fracDigits > 0 then numText := numText + '.' + StringOfChar('0', fracDigits);
  end
  else
  begin
    neg := av < 0;
    numText := FloatToStrF(Abs(av), ffFixed, 18, fracDigits, fs);
  end;
  dotPos2 := Pos('.', numText);
  if dotPos2 = 0 then begin intPartStr := numText; fracPartStr := ''; end
  else begin intPartStr := Copy(numText, 1, dotPos2 - 1); fracPartStr := Copy(numText, dotPos2 + 1, MaxInt); end;
  if grouping then intPartStr := GroupThousands(intPartStr);

  leftSign := ''; trailSignStr := '';
  if trailPlus then begin if neg then trailSignStr := '-' else trailSignStr := '+'; end
  else if trailMinus then begin if neg then trailSignStr := '-' else trailSignStr := ' '; end
  else if signLead then begin if neg then leftSign := '-' else leftSign := '+'; end
  else if neg then leftSign := '-';
  if dollar then dollarStr := '$' else dollarStr := '';

  core := dollarStr + leftSign + intPartStr;
  if starFill then padChar := '*' else padChar := ' ';
  pad := width - Length(core);
  if pad >= 0 then intField := StringOfChar(padChar, pad) + core
  else intField := '%' + core;   // overflow: the classic leading '%'

  Result := intField;
  if dotPos > 0 then Result := Result + '.' + fracPartStr;
  Result := Result + trailSignStr;
end;

function ValFieldStr(const V: TValue): String;
begin
  if V.Kind = vkString then Result := V.Str else Result := ValToStr(V);
end;

function FormatUsing(const Fmt: String; const Vals: array of TValue): String;
var
  i, j, n, vi: Integer;
  spec, sv: String;
  width, svLen: Integer;
  fieldSeen: Boolean;

  function NextVal: TValue;
  begin
    if vi <= High(Vals) then begin Result := Vals[vi]; Inc(vi); end
    else begin Result := ValInt(0); Inc(vi); end;
  end;

begin
  Result := '';
  n := Length(Fmt);
  vi := 0;
  fieldSeen := False;
  i := 1;
  while i <= n do
  begin
    // numeric field?
    if (Fmt[i] = '#') or
       ((Fmt[i] = '+') and (i < n) and (Fmt[i + 1] in ['#', '.', '$', '*'])) or
       ((Fmt[i] = '$') and (i < n) and (Fmt[i + 1] = '$')) or
       ((Fmt[i] = '*') and (i < n) and (Fmt[i + 1] = '*')) then
    begin
      j := i;
      if (Fmt[j] = '$') and (j < n) and (Fmt[j + 1] = '$') then Inc(j, 2)
      else if (Fmt[j] = '*') and (j < n) and (Fmt[j + 1] = '*') then Inc(j, 2);
      if (j <= n) and (Fmt[j] = '+') then Inc(j);
      while (j <= n) and (Fmt[j] in ['#', ',', '.']) do Inc(j);
      if (j <= n) and (Fmt[j] in ['+', '-']) then Inc(j);
      spec := Copy(Fmt, i, j - i);
      Result := Result + FormatNumericField(spec, NextVal());
      fieldSeen := True;
      i := j;
    end
    else if Fmt[i] = '&' then
    begin
      Result := Result + ValFieldStr(NextVal());
      fieldSeen := True;
      Inc(i);
    end
    else if Fmt[i] = '!' then
    begin
      sv := ValFieldStr(NextVal());
      // Copy(), not sv[1]: a Char carries this unit's codepage into the
      // concatenation and destroys any byte >= 128. A one-character SLICE does not.
      { AND THE SLICE IS ONE CHARACTER, NOT ONE BYTE. Copy(sv,1,1) took the LEAD
        BYTE of a two-byte character -- `print using "[!]"; "ecole"` with an
        accented e wrote 5B C3 5D, a lone 0xC3 between the brackets. The comment
        above was right that a Char must not be concatenated and wrong that a
        one-byte Copy is therefore safe: docs/language-reference.md:435 defines
        '!' as "its first character", and stdout gets raw bytes, so the pipe or
        the file was left holding half a codepoint. }
      if sv <> '' then Result := Result + Utf8Left(sv, 1) else Result := Result + ' ';
      fieldSeen := True;
      Inc(i);
    end
    else if Fmt[i] = '\' then
    begin
      // '\' ... '\' -- a fixed-width string field of (2 + inner spaces) columns.
      j := i + 1;
      while (j <= n) and (Fmt[j] <> '\') do Inc(j);
      if j <= n then
      begin
        width := j - i + 1;
        sv := ValFieldStr(NextVal());
        { COLUMNS ARE CHARACTERS. Measuring and cutting this field with Length()
          and Copy() did both halves wrong at once: a value longer than the field
          was truncated MID-CODEPOINT (`\  \` with an accented "cafe" emitted
          "caf" + a lone 0xC3), and a value shorter than it was padded by BYTES,
          so a four-character accented cell got one pad space where its
          four-character ASCII neighbour got two and every table with an accent
          in it came out ragged. rtab$ -- the same job, one function away in
          StrLib -- has always padded to CpLen; this now agrees with it. }
        svLen := Utf8Len(sv);
        if svLen >= width then sv := Utf8Left(sv, width)
        else sv := sv + StringOfChar(' ', width - svLen);
        Result := Result + sv;
        fieldSeen := True;
        i := j + 1;
      end
      else
        begin Result := Result + Copy(Fmt, i, 1); Inc(i); end;   // an unpaired '\' is literal
    end
    else if (Fmt[i] = '_') and (i < n) then
    begin
      Result := Result + Copy(Fmt, i + 1, 1);   // '_' escapes the next character literally
      Inc(i, 2);
    end
    else
    begin
      Result := Result + Copy(Fmt, i, 1);
      Inc(i);
    end;
    // reached the end with values to spare and fields to reuse: repeat the format
    if (i > n) and fieldSeen and (vi <= High(Vals)) then
      i := 1;
  end;
end;

function SignatureOf(const AName: String; const AArgs: array of TValue): String;
var
  i: Integer;
begin
  Result := AName + ':';
  for i := 0 to High(AArgs) do
    Result := Result + TPhosphorRegistry.CodeOf(AArgs[i].Kind);
end;

{ Arithmetic must not be able to kill the interpreter.

  FPC leaves the IEEE overflow trap UNMASKED, so an ordinary `x = x * 1.5` in a
  loop eventually raises a hardware EOverflow -- which is not an exception the
  engine can turn into an error value, because it unwinds straight past ExecFrom
  and out of the host. `10.0 ^ 200 * 10.0 ^ 200` aborted the process with exit
  217, and `on error goto` could not see it.

  Masking exOverflow makes that multiplication produce +Inf instead, which
  FiniteD then reports as a catchable Phosphor error at the operator that
  produced it. INVALID-OPERATION AND DIVIDE-BY-ZERO STAY UNMASKED on purpose: the
  finiteness invariant means Inf and NaN never enter the value space, so those
  traps should be unreachable -- and if one ever does fire, it should fire loudly
  rather than silently returning a wrong number.

  The mask is restored on the way out: the engine is embeddable, and a host's FPU
  configuration is the host's business, not ours. }
function TPhosphorVM.Run(AProg: TProgram): Boolean;
var
  i: Integer;
  savedMask: TFPUExceptionMask;
begin
  if FFaulted then
  begin
    LastError := MakeError(peFatal,
      'this interpreter took a fault and cannot run again; create a new one');
    ErrorLine := 0;
    Exit(False);
  end;
  UseProgram(AProg);
  FSP := 0;
  FCSP := 0;
  FFrameSP := 0;
  FDataPtr := 0;
  LastError := NoError();
  ErrorLine := 0;
  FErrHandler := -1;
  FErrHandlerMode := 0;
  FErrHandlerFuncIdx := 0;
  FInHandler := False;
  FErrSaveValid := False;
  FHalted := False;
  FCallDepth := 0;
  FLimitFromInner := False;
  FErrCode := 0; FErrMsg := ''; FErrLine := 0;
  FErrStmtPC := 0; FErrStmtSP := 0; FErrStmtFrameSP := 0;
  FSteps := 0;
  FOutputBytes := 0;
  FStackLimit := False;
  FStartTick := GetTickCount64;
  FHeapBase := GetFPCHeapStatus().CurrHeapUsed;
  FHeapBased := True;
  FTrace := False;
  CloseAllChannels();            // no file channel leaks between programs
  FInBuf := ''; FInPos := 1;
  FCharBuf := ''; FCharPos := 1;
  SetLength(FVars, AProg.VarCount);
  for i := 0 to AProg.VarCount - 1 do
    FVars[i] := DefaultValue(AProg.VarTypes[i]);
  savedMask := EnterFPU();
  try
    try
      Result := ExecFrom(0, -1);
    except
      // See ContainFaults. Only a STATE fault is contained, and only when the
      // host asked for it; anything else travels on exactly as it always did.
      on E: Exception do
        if FContainFaults and IsStateFault(E) then
          Result := ContainFault(E)
        else
          raise;
    end;
  finally
    LeaveFPU(savedMask);
  end;
end;

function TPhosphorVM.RunFrom(AProg: TProgram; AStartPC: Integer): Boolean;
var
  i, had: Integer;
  savedMask: TFPUExceptionMask;
begin
  if FFaulted then
  begin
    LastError := MakeError(peFatal,
      'this interpreter took a fault and cannot run again; create a new one');
    ErrorLine := 0;
    Exit(False);
  end;
  UseProgram(AProg);
  LastError := NoError();
  ErrorLine := 0;
  // A fresh expression/call stack per line; everything else -- globals, handles,
  // open file channels, the DATA cursor, an installed ON ERROR handler -- persists,
  // which is the whole point of a session.
  FSP := 0;
  FCSP := 0;
  FFrameSP := 0;
  { AND A FRESH HALT. `end` ends the LINE that ran it, not the session: the prompt
    is still there and the person is still typing. Run cleared this and RunFrom did
    not, so `end` at the REPL poisoned every later line -- and did it almost
    invisibly, because opCall's post-call check (`if FHalted then Exit(True)`) makes
    the line abort at its FIRST LIBRARY CALL and report success. `println "x"` still
    worked; `println len("x")` printed nothing and answered rc 0. }
  FHalted := False;
  had := Length(FVars);
  if AProg.VarCount > had then
  begin
    SetLength(FVars, AProg.VarCount);
    for i := had to AProg.VarCount - 1 do
      FVars[i] := DefaultValue(AProg.VarTypes[i]);
  end;
  // Each line gets its own execution budget.
  FSteps := 0;
  FOutputBytes := 0;
  FStackLimit := False;
  FStartTick := GetTickCount64;
  { STEPS AND TIME DO NOT SURVIVE A LINE; MEMORY DOES. Each REPL line is its own
    run for the step counter and the clock, and re-sampling the base here made the
    memory ceiling mean nothing across a session: five lines each just under a
    256 MB ceiling reached 2575 MB and answered rc 0. The base is taken once, when
    the session starts, and ResetHandles-level teardown is what starts a new one. }
  if not FHeapBased then
  begin
    FHeapBase := GetFPCHeapStatus().CurrHeapUsed;
    FHeapBased := True;
  end;
  savedMask := EnterFPU();
  try
    try
      Result := ExecFrom(AStartPC, -1);
    except
      on E: Exception do
        if FContainFaults and IsStateFault(E) then
          Result := ContainFault(E)
        else
          raise;
    end;
  finally
    LeaveFPU(savedMask);
  end;
end;

{ How many bytes this value adds to a concatenation, WITHOUT building its text.
  A string contributes its own bytes; anything else contributes its str$ form,
  which is at most a handful -- 32 is a generous bound and the exactness does not
  matter, because the caller is deciding whether a growth is worth measuring and
  then measuring the heap itself. }
function TextLenOf(const V: TValue): Int64;
begin
  if V.Kind = vkString then Result := Length(V.Str) else Result := 32;
end;

function TPhosphorVM.ExecFrom(AStartPC, AStopFrameSP: Integer): Boolean;
var
  pc, i, argc, ufi, savedRet, dupBase: Integer;
  slots: Integer;           // the local slots one frame push adds to FFrameSlots
  ins: TInstr;
  a, b, r, v: TValue;
  e: TPhosphorError;
  args: array of TValue;
  kinds: array of TValueKind;
  res: TResolvedFunc;
  lt: TVarType;
  // This activation's clean statement boundary -- a LOCAL, not a field: a
  // re-entrant call runs its own statements and must not move the resume point of
  // the activation that is waiting for it.
  stmtPC, stmtSP, stmtFrameSP: Integer;
  bpOps: array of TValue;   // a BREAKPOINT's popped operand values
  usingVals: array of TValue;   // a PRINT USING statement's popped values
  sTmp: String;             // scratch for the classic-I/O handlers
  bTmp: Boolean;
  nTmp: Int64;
  growth: Int64;            // bytes a concatenation is about to add; MaxMemoryBytes

  { Put back what the handler ran on top of, and stand at the failing statement's
    level again. Without this the resume re-exposed slots the handler had since
    written into: an enclosing `1000 + risky(0)` came back as 7 + 5 because the
    handler's own `zz = 7` had landed in the slot holding the 1000, and a handler
    that called a function overwrote the faulting frame, so returning from the
    resumed body jumped back into the handler. }
  procedure RestoreOverlap;
  var i, j: Integer;
  begin
    if FErrSaveValid then
    begin
      for i := 0 to High(FErrSaveStack) do
        FStack[FErrHandlerSP + i] := FErrSaveStack[i];
      for i := 0 to High(FErrSaveFrames) do
      begin
        FFrames[FErrHandlerFrameSP + i].FuncIndex := FErrSaveFrames[i].FuncIndex;
        FFrames[FErrHandlerFrameSP + i].ReturnAddr := FErrSaveFrames[i].ReturnAddr;
        FFrames[FErrHandlerFrameSP + i].CallerStmtPC := FErrSaveFrames[i].CallerStmtPC;
        FFrames[FErrHandlerFrameSP + i].CallerStmtSP := FErrSaveFrames[i].CallerStmtSP;
        FFrames[FErrHandlerFrameSP + i].CallerStmtFrameSP := FErrSaveFrames[i].CallerStmtFrameSP;
        // This is the third and last place a frame's local table changes size, so
        // the held-slot count is kept here too; see MaxFrameDepth and FFrameSlots.
        // No ceiling is applied: these arrays are a copy of frames that were
        // already inside the budget when the fault took them aside, and refusing
        // to put them back would break the resume the copy exists for. The total
        // it restores to can stand ABOVE MaxFrameSlots -- the handler's own frames
        // above the resume level are still held -- and the next push refuses.
        Dec(FFrameSlots, Length(FFrames[FErrHandlerFrameSP + i].Locals));
        SetLength(FFrames[FErrHandlerFrameSP + i].Locals, Length(FErrSaveFrames[i].Locals));
        Inc(FFrameSlots, Length(FErrSaveFrames[i].Locals));
        for j := 0 to High(FErrSaveFrames[i].Locals) do
          FFrames[FErrHandlerFrameSP + i].Locals[j] := FErrSaveFrames[i].Locals[j];
      end;
      FErrSaveValid := False;
    end;
    FSP := FErrStmtSP; FFrameSP := FErrStmtFrameSP;
  end;

  { Put pc on the statement AFTER the one that faulted -- what `resume next` and a
    zero-returning `on error call` handler both continue at. Call it only once
    RestoreOverlap has stood the VM back at the faulting statement's level.

    "THE NEXT STATEMENT" ONLY EXISTS INSIDE THE BODY THAT FAULTED. A fault in a
    called function resumes in that function (its frame is back), so the next
    statement has to be one of ITS statements; walking on into whatever the
    compiler laid out after the body ran the CALLER's code with the callee's frame
    still stacked. For

        function f(x)
          return no_such_name(x)
        endfunction
        on error goto oops
        println "before: " ; str$(f(-5))

    the scan left the body, found the next boundary in the main program -- the very
    statement that called f -- and called f again: the program printed its first
    line for ever. (2026-09-06.)

    WHEN THE FAULTING STATEMENT WAS THE LAST OF THE BODY, "next" is the end of the
    function: it returns the default value for its type and the caller's pending
    expression carries on with that, exactly as falling off the end of a body
    always does. Unwinding further -- resuming in the caller, as VB does -- was the
    other candidate and is NOT what Phosphor does: a fault deeper in already
    resumes at the next statement of the frame that faulted (54_onerror_reentrancy
    pins `1000 + risky(0)` = 1005), and the last statement of a body is not a
    special case of that rule, it is the end of it.

    A caller of this only ever has to `Continue`. If the end-of-body return unwinds
    the very frame a re-entrant activation was launched for, pc lands past the last
    instruction, so the loop ends and ExecFrom returns True with the value on the
    stack -- what opRetFunc does with Exit(True) at that same moment. It must NOT
    be reached with that frame's ReturnAddr (-1, "no return address"): resuming to
    pc -1 read out of bounds for ever, which is the shape 54_onerror_reentrancy's
    third case was written for. }
  procedure ResumeAtNextStmt;
  var scan, bodyEnd, entry, ufi: Integer;
  begin
    // The body's extent. ParseFunction emits `opJump <past the body>` immediately
    // before the entry point so that normal flow steps over the body, which makes
    // that jump's target the first instruction beyond it. A program not built that
    // way (only a hand-written .pbc can be) gets the bounded answer -- the function
    // ends here -- rather than a jump into open code.
    bodyEnd := FProg.Count;
    if FFrameSP > 0 then
    begin
      entry := FProg.UserFuncs[FFrames[FFrameSP - 1].FuncIndex].Entry;
      if (entry > 0) and (FProg.Instr(entry - 1).Op = opJump) and
         (FProg.Instr(entry - 1).A > entry) and (FProg.Instr(entry - 1).A <= FProg.Count) then
        bodyEnd := FProg.Instr(entry - 1).A
      else
        bodyEnd := entry;   // extent unknown: end the function instead of guessing
    end;
    { WHERE THE FAILING STATEMENT ENDS, WHICH THE COMPILER WROTE DOWN.

      Resuming has to continue in CONTROL-FLOW order, and scanning forward for the
      next opStmt gave the textual one: past the last statement of a `then` block
      it found the `else` block, past a case arm it found the next arm, and past a
      loop body it found the statement after the loop. ParseStatement patches A
      with the pc the statement ends at, so that pc IS the continuation -- the jump
      over the else, the jump to endselect, the loop's own tail -- and executing it
      does the right thing by construction.

      The scan stays as the answer for A = 0, which is a statement whose parse
      failed and any .pbc written before this. Bounded by bodyEnd either way: a
      hand-written .pbc is the only thing that can carry an A pointing elsewhere,
      and it gets the same bounded answer everything else in this procedure gets. }
    scan := FProg.Instr(FErrStmtPC).A;
    if (scan <= FErrStmtPC) or (scan > bodyEnd) then
    begin
      scan := FErrStmtPC + 1;
      while (scan < bodyEnd) and (FProg.Instr(scan).Op <> opStmt) do Inc(scan);
    end;
    if scan < bodyEnd then
    begin
      pc := scan;
      Exit;
    end;
    if FFrameSP = 0 then
    begin
      // Top level, nothing after the failing statement: the program is over. (A
      // function DEFINED after it is not "next" -- the definition's own statement
      // boundary sits in the main program and jumps over the body.)
      pc := FProg.Count;
      Exit;
    end;
    ufi := FFrames[FFrameSP - 1].FuncIndex;
    Push(DefaultValue(FProg.UserFuncs[ufi].RetType));
    pc := FFrames[FFrameSP - 1].ReturnAddr;
    Dec(FFrameSP);
    if FFrameSP = AStopFrameSP then
      pc := FProg.Count   // this activation is done; see the note above
    else
    begin
      stmtPC := FFrames[FFrameSP].CallerStmtPC;
      stmtSP := FFrames[FFrameSP].CallerStmtSP;
      stmtFrameSP := FFrames[FFrameSP].CallerStmtFrameSP;
    end;
  end;

  { A runtime error. Returns True if an ON ERROR handler took it (pc now points at
    the handler; the caller should Continue), False to abort (LastError set; the
    caller should Exit(False)). The handler runs at the stack/frame level it was
    installed at; the failing statement is remembered for resume.

    TWO RULES THIS ACTIVATION MUST RESPECT.

    (1) It may only run a handler that BELONGS to it. AStopFrameSP is this
        activation's floor, so a handler installed at or below that floor was
        installed by an OUTER ExecFrom that is still live on the Pascal stack.
        Running it here used to execute the rest of the program inside the nested
        loop -- which then fell off the end, returned "success" to CallUserFunc, and
        let the caller run everything a second time. The fault is returned instead,
        and the outer activation handles it where its own state is intact.

    (2) It must not destroy what the resume needs. See FErrSaveStack. }
  function Fault(const AErr: TPhosphorError): Boolean;
  var
    callErr: TPhosphorError;
    callRet: TValue;
    i, j, n: Integer;
  begin
    FErrCode := Ord(AErr.Code);
    FErrMsg := AErr.Message;
    FErrLine := ins.Line;
    if (FErrHandler >= 0) and (not FInHandler) and
       (FErrHandlerFrameSP > AStopFrameSP) then
    begin
      { THE HANDLER IS BOUNDED AGAIN HERE, AT THE USE.

        opSetErrHandler checks its operand against the program that CONTAINS the
        instruction. That is the right check for a corrupt .pbc and the wrong one
        for the question asked here, because the handler OUTLIVES its program:
        FErrHandler and FErrHandlerFuncIdx persist across REPL lines on purpose
        (RunFrom keeps the ON ERROR state so a session-installed handler survives)
        while FProg is replaced line by line, and nothing clears them. That is
        safe today only because PhosphorEngine.ReplRun recompiles FReplSource +
        the new line, so every program is a strict superset of the last and a
        prefix index still means the same thing -- a property of the FRONT END,
        two units away, that this file cannot see and did not choose. A check on
        the value about to be USED cannot be fooled by that changing, or by a
        second meaning added to A later. It costs one comparison on the error
        path. }
      { The bound is opSetErrHandler's own, to the letter -- `> FProg.Count` for a
        pc, not `>=`. A handler pc of exactly Count is what the install accepts
        and what ends the program harmlessly when it is jumped to, so tightening
        it here would REFUSE something the other check calls legal. A use-site
        guard that disagrees with its install-site guard is a new bug, not a fix. }
      if ((FErrHandlerMode = 1) and
          ((FErrHandlerFuncIdx < 0) or (FErrHandlerFuncIdx >= FProg.Consts.Count))) or
         ((FErrHandlerMode <> 1) and (FErrHandler > FProg.Count)) then
      begin
        LastError := MakeError(peRuntime,
          'the installed ON ERROR handler does not belong to the running program');
        ErrorLine := ins.Line;
        Exit(False);
      end;
      FErrStmtPC := stmtPC; FErrStmtSP := stmtSP; FErrStmtFrameSP := stmtFrameSP;
      // Copy the overlap aside BEFORE unwinding onto it.
      n := FErrStmtSP - FErrHandlerSP;
      if n < 0 then n := 0;
      SetLength(FErrSaveStack, n);
      for i := 0 to n - 1 do
        FErrSaveStack[i] := FStack[FErrHandlerSP + i];
      n := FErrStmtFrameSP - FErrHandlerFrameSP;
      if n < 0 then n := 0;
      SetLength(FErrSaveFrames, n);
      for i := 0 to n - 1 do
      begin
        FErrSaveFrames[i].FuncIndex := FFrames[FErrHandlerFrameSP + i].FuncIndex;
        FErrSaveFrames[i].ReturnAddr := FFrames[FErrHandlerFrameSP + i].ReturnAddr;
        FErrSaveFrames[i].CallerStmtPC := FFrames[FErrHandlerFrameSP + i].CallerStmtPC;
        FErrSaveFrames[i].CallerStmtSP := FFrames[FErrHandlerFrameSP + i].CallerStmtSP;
        FErrSaveFrames[i].CallerStmtFrameSP := FFrames[FErrHandlerFrameSP + i].CallerStmtFrameSP;
        // The locals are copied ELEMENT BY ELEMENT: assigning the dynamic array
        // would only share a reference, and an element write through the other
        // name would then reach right into the copy.
        SetLength(FErrSaveFrames[i].Locals, Length(FFrames[FErrHandlerFrameSP + i].Locals));
        for j := 0 to High(FFrames[FErrHandlerFrameSP + i].Locals) do
          FErrSaveFrames[i].Locals[j] := FFrames[FErrHandlerFrameSP + i].Locals[j];
      end;
      FErrSaveValid := True;
      FSP := FErrHandlerSP; FFrameSP := FErrHandlerFrameSP;
      if FErrHandlerMode = 1 then
      begin
        // `on error call func`: run func(code%, msg$), then continue by its result
        // (return 0 = resume next; return non-zero = abort, re-raising the error).
        FInHandler := True;
        callRet := CallUserFunc(FProg.Consts.Get(FErrHandlerFuncIdx).Str,
                                [ValInt(FErrCode), ValStr(FErrMsg)], callErr);
        FInHandler := False;
        if IsError(callErr) then
        begin
          LastError := callErr; ErrorLine := FErrLine; Exit(False);
        end;
        if FHalted then Exit(True);          // the handler said END: end the program
        // NonFinite first: `<> 0` on a NaN is a trap, not a test (see NonFinite),
        // and a handler is free to return one. The answer it stands in for is the
        // IEEE one -- NaN and +-Inf are both "not zero" -- so a handler returning
        // one still means abort.
        if (callRet.Kind in [vkInt, vkDouble]) and
           (NonFinite(callRet) or (AsDouble(callRet) <> 0)) then
        begin
          LastError := AErr; ErrorLine := FErrLine; Exit(False);   // handler said: abort
        end;
        RestoreOverlap();                                           // resume next
        ResumeAtNextStmt();
        Result := True;
      end
      else
      begin
        // `on error goto label`: jump to the handler
        FInHandler := True;
        pc := FErrHandler;
        Result := True;
      end;
    end
    else
    begin
      LastError := AErr;
      ErrorLine := ins.Line;
      Result := False;
    end;
  end;

  { For arithmetic/comparison ops. 0 = ok (result pushed, fall through to Inc pc),
    1 = a handler took the fault (Continue), 2 = abort (Exit False). }
  function Bin(AErr: TPhosphorError; const AResult: TValue): Integer;
  begin
    if IsError(AErr) then
    begin
      if Fault(AErr) then Result := 1 else Result := 2;
    end
    else
    begin
      Push(AResult);
      Result := 0;
    end;
  end;

  { Why a local slot could not be used, for opLoadLocal/opStoreLocal. Built ONLY
    on the failing path -- the guards at those two opcodes stay integer compares,
    which is the whole reason this is not a "check it and return NoError" helper:
    a managed TPhosphorError returned by value on every local access is a real
    cost, and locals are as hot as the VM gets. }
  function BadLocal(ASlot: Integer; const AVerb: String): TPhosphorError;
  begin
    if FFrameSP = 0 then
      Result := MakeError(peRuntime, 'corrupt bytecode: local slot ' +
                          IntToStr(ASlot) + ' ' + AVerb + ' outside any function')
    else
      Result := MakeError(peRuntime, 'corrupt bytecode: local slot ' +
                          IntToStr(ASlot) + ' is outside the ' +
                          IntToStr(Length(FFrames[FFrameSP - 1].Locals)) +
                          ' locals of this function');
  end;

  { WOULD ADDING AGrowth BYTES CROSS THE MEMORY CEILING? False = it would, and a
    fatal peLimit is set, so the caller must Exit(False).

    THE CHEAP QUESTION IS ASKED FIRST AND THE EXPENSIVE ONE ALMOST NEVER.
    GetFPCHeapStatus costs about 39 ns on this machine -- twelve times a short
    string concatenation, measured -- so consulting it in front of every `+` would
    be a tax on every string-building script for the sake of a ceiling that only
    large allocations can cross. Callers therefore ask only when the growth is
    worth asking about (MemCheckFrom), and the periodic check in the step loop
    catches an accumulation of small ones. }
  function RoomFor(AGrowth: Int64): Boolean;
  var
    used: PtrUInt;
  begin
    Result := True;
    if MaxMemoryBytes <= 0 then Exit;
    FUncharged := 0;
    used := GetFPCHeapStatus().CurrHeapUsed;
    { THE FLOOR ONLY EVER FALLS, and the first version's `Exit` here turned the
      ceiling OFF for the rest of the run instead.

      Two reachable spellings, both measured. A TPhosphorVM run a SECOND time
      samples its base while the first run's memory is still accounted for, so
      every later question answered "below the base, nothing to charge" and 1.3 GB
      went through a 128 MB ceiling. And a host that frees its own memory during a
      run -- a GUI clearing a log pane from OnOutput -- did the same: 1516 MB
      through a 32 MB ceiling, where the same script with the host holding on was
      refused at 591 MB.

      Sampling the base LATER does not fix it, and that was tried and measured:
      GetFPCHeapStatus().CurrHeapUsed does not fall when the last large chunk is
      released, so the base stays high whatever the ordering. Lowering the floor to
      whatever is actually held is the answer -- the ceiling then means "this much
      more than the least you have held since you started", which is the honest
      reading of a growth bound. }
    if used < FHeapBase then FHeapBase := used;
    if Int64(used - FHeapBase) + AGrowth <= MaxMemoryBytes then Exit;
    LastError := MakeError(peLimit, 'memory limit exceeded (' +
      IntToStr(MaxMemoryBytes) + ' bytes)');
    ErrorLine := ins.Line;
    Result := False;
  end;

  { Emit output, enforcing the output-byte ceiling. False = the ceiling was hit
    (a fatal peLimit is set; the caller must Exit(False)). }
  function EmitOutput(const S: String): Boolean;
  begin
    if (MaxOutputBytes > 0) and (FOutputBytes + Length(S) > MaxOutputBytes) then
    begin
      LastError := MakeError(peLimit, 'output limit exceeded (' + IntToStr(MaxOutputBytes) + ' bytes)');
      ErrorLine := ins.Line;
      Exit(False);
    end;
    Inc(FOutputBytes, Length(S));
    if Assigned(OnOutput) then OnOutput(S);
    Result := True;
  end;

begin
  args := nil;
  kinds := nil;
  bpOps := nil;
  usingVals := nil;
  sTmp := '';
  bTmp := False;
  nTmp := 0;
  ins := Default(TInstr);   // so the guards below can report a line before the first fetch
  pc := AStartPC;
  stmtPC := AStartPC; stmtSP := FSP; stmtFrameSP := FFrameSP;
  while pc < FProg.Count do
  begin
    { A NEGATIVE pc IS AN INDEX BEFORE THE PROGRAM, and the loop condition only
      bounds it from above. Eight places assign pc -- opJump, opJumpIfFalse,
      opGosub, opReturn (from the GOSUB stack), opCall (a function entry), the ON
      ERROR install, opResume, and ResumeAtNextStmt (from a frame's ReturnAddr,
      which is deliberately -1 on a frame the host pushed) -- and each is bounded
      by a DIFFERENT argument about where its value came from. This is the one
      place all eight pass through, so the bound is taken once, here, for a cost
      of one integer compare per instruction. AStartPC is covered too: it is
      chosen by the host and by UserFuncs[].Entry.

      Fault, not fatal: a program with `on error goto` gets its handler, and the
      handler pc was checked when it was installed, so the next pc is sound. }
    if pc < 0 then
      if Fault(MakeError(peRuntime, 'corrupt bytecode: jumped to instruction ' +
               IntToStr(pc) + ', before the start of the program')) then Continue else Exit(False);
    ins := FProg.Instr(pc);
    { The value stack hit MaxStackDepth on some push since the last instruction.
      Push cannot report (see FStackLimit); it dropped the value rather than
      allocate, so the stack is short of what the program believes and nothing
      further may run. }
    if FStackLimit then
    begin
      LastError := MakeError(peLimit, 'value stack limit exceeded (' +
                             IntToStr(MaxStackDepth) + ' values)');
      ErrorLine := ins.Line;
      Exit(False);
    end;
    Inc(FSteps);
    if (MaxSteps > 0) and (FSteps > MaxSteps) then
    begin
      LastError := MakeError(peLimit, 'step budget exceeded (' + IntToStr(MaxSteps) + ' instructions)');
      ErrorLine := ins.Line;
      Exit(False);
    end;
    { THERE IS NO PERIODIC MEMORY CHECK HERE, AND THERE WAS.

      It fired every 4096 instructions, which is both too coarse and, once the
      other two checks existed, unnecessary. Too coarse: a script that allocates
      gigabytes in forty instructions never reaches it -- twelve string$ calls
      reached 3814 MB under a 256 MB ceiling. Unnecessary: memory reaches a script
      through exactly two doors, and both are now asked directly. `opAdd`
      accumulates and asks per 64 KB added; every library call asks on the way
      out. Growth through any other seam has to be RETAINED to matter, and
      retaining it means a container (a library call) or a string (an opAdd).

      Removing it also removed its cost, which was not free: one test per
      instruction, measured at 3 to 4 percent on a tight arithmetic loop even with
      no ceiling set. A branch no test can reach, that everything pays for, is
      decoration. }
    if (TimeoutMs > 0) and ((FSteps and $FFF) = 0) and
       (GetTickCount64 - FStartTick > QWord(TimeoutMs)) then
    begin
      LastError := MakeError(peLimit, 'time limit exceeded (' + IntToStr(TimeoutMs) + ' ms)');
      ErrorLine := ins.Line;
      Exit(False);
    end;
    case ins.Op of
      opNop: ;
      { THE THREE FREQUENT OPERANDS THAT INDEX, BOUNDED WHERE THEY ARE USED.

        TConstPool.Get and the FVars/VarTypes arrays are UNCHECKED reads
        (PhosphorOpcodes.pas:167 is a bare `Result := FItems[Index]`), so a wrong
        operand here is a read of whatever lies past the array -- and for
        STOREVAR a WRITE. ValidateProgram bounds all three, which covers every
        .pbc; it does NOT cover TPhosphorVM.Run(AProg), a public entry point an
        embedder can hand a TProgram assembled by hand, and that is the same
        argument that put the argc/LocalTypes bound at opCall. Round one left
        these out on the ground that the compiler is not untrusted input and the
        compare would cost real speed. The speed was then MEASURED, on a loop of
        200 000 000 instructions built from exactly these opcodes: three runs at
        28,85 / 29,00 / 29,05 s without the bounds, three at 27,57 / 27,42 /
        27,40 s with them. Not a cost at all -- the bounded build is if anything
        marginally faster, which is code layout, not cleverness. The reason for
        leaving them out was not true, so they are in.

        Written as one UNSIGNED comparison rather than two signed ones: a
        negative A becomes a huge Cardinal and fails the same test, so the pair
        of branches the obvious form emits collapses to one. }
      opPushConst:
        begin
          if Cardinal(ins.A) >= Cardinal(FProg.Consts.Count) then
            if Fault(MakeError(peRuntime, 'corrupt bytecode: constant ' +
                     IntToStr(ins.A) + ' is outside the ' +
                     IntToStr(FProg.Consts.Count) + '-entry pool')) then Continue else Exit(False);
          Push(FProg.Consts.Get(ins.A));
        end;
      opPop: Pop();
      opPrint:
        begin
          v := Pop();
          if not EmitOutput(ValToStr(v)) then Exit(False);
        end;
      opPrintLn:
        begin
          v := Pop();
          if not EmitOutput(ValToStr(v) + #10) then Exit(False);
        end;
      opNeg:     begin a := Pop(); case Bin(Negate(a, r), r) of 1: Continue; 2: Exit(False); end; end;
      opAdd:
        begin
          b := Pop(); a := Pop();
          { The one instruction whose result size is known before it is built, and
            the one the budget unit's header names as the hole. A '+' whose LEFT
            operand is a string concatenates; anything else is arithmetic and
            allocates nothing worth counting. }
          if (MaxMemoryBytes > 0) and (a.Kind = vkString) then
          begin
            growth := Int64(Length(a.Str)) + TextLenOf(b);
            Inc(FUncharged, growth);
            if (FUncharged >= MemCheckFrom) and (not RoomFor(growth)) then Exit(False);
          end;
          case Bin(ValAdd(a, b, r), r) of 1: Continue; 2: Exit(False); end;
        end;
      opSub:     begin b := Pop(); a := Pop(); case Bin(ValSub(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opMul:     begin b := Pop(); a := Pop(); case Bin(ValMul(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opDivReal: begin b := Pop(); a := Pop(); case Bin(ValDivReal(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opDivInt:  begin b := Pop(); a := Pop(); case Bin(ValDivInt(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opPow:     begin b := Pop(); a := Pop(); case Bin(ValPow(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opMod:     begin b := Pop(); a := Pop(); case Bin(ValMod(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opEQ:      begin b := Pop(); a := Pop(); case Bin(ValCompare(coEQ, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opNE:      begin b := Pop(); a := Pop(); case Bin(ValCompare(coNE, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opLT:      begin b := Pop(); a := Pop(); case Bin(ValCompare(coLT, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opLE:      begin b := Pop(); a := Pop(); case Bin(ValCompare(coLE, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opGT:      begin b := Pop(); a := Pop(); case Bin(ValCompare(coGT, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opGE:      begin b := Pop(); a := Pop(); case Bin(ValCompare(coGE, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opAnd:     begin b := Pop(); a := Pop(); case Bin(ValAnd(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opOr:      begin b := Pop(); a := Pop(); case Bin(ValOr(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opNot:     begin a := Pop(); case Bin(ValNot(a, r), r) of 1: Continue; 2: Exit(False); end; end;
      opLoadVar:
        begin
          // See the note at opPushConst. FVars is sized to FProg.VarCount by Run
          // and only ever grows in RunFrom, so VarCount bounds both arrays.
          if Cardinal(ins.A) >= Cardinal(FProg.VarCount) then
            if Fault(MakeError(peRuntime, 'corrupt bytecode: variable ' +
                     IntToStr(ins.A) + ' is outside the ' +
                     IntToStr(FProg.VarCount) + ' this program declares')) then Continue else Exit(False);
          Push(FVars[ins.A]);
        end;
      opStoreVar:
        begin
          // Refused BEFORE the pop, so a `resume` retries a statement whose
          // operand stack is untouched -- the rule opStoreLocal follows.
          if Cardinal(ins.A) >= Cardinal(FProg.VarCount) then
            if Fault(MakeError(peRuntime, 'corrupt bytecode: variable ' +
                     IntToStr(ins.A) + ' is outside the ' +
                     IntToStr(FProg.VarCount) + ' this program declares')) then Continue else Exit(False);
          v := Pop();
          e := StoreCheck(FProg.VarTypes[ins.A], v, r);
          if not IsError(e) then
            FVars[ins.A] := r
          else
          begin
            if e.Code = peTypeMismatch then
              e := MakeError(peTypeMismatch, 'cannot store ' + KindName(v.Kind) +
                ' into ' + VarTypeName(FProg.VarTypes[ins.A]) + ' variable');
            if Fault(e) then Continue else Exit(False);
          end;
        end;
      opJumpIfFalse:
        begin
          v := Pop();
          if v.Kind <> vkBool then
            if Fault(MakeError(peTypeMismatch, 'condition is not a boolean')) then Continue else Exit(False);
          if not v.Bl then
          begin
            pc := ins.A;
            Continue;
          end;
        end;
      opJump:
        begin
          pc := ins.A;
          Continue;
        end;
      opReadData:
        begin
          if FDataPtr >= FProg.DataCount then
          begin
            if Fault(MakeError(peRuntime, 'out of DATA')) then Continue else Exit(False);
          end;
          Push(FProg.DataPool[FDataPtr]);
          Inc(FDataPtr);
        end;
      opRestore: FDataPtr := 0;
      { THE TWO DUPS INDEX FStack DIRECTLY, so they -- alone among the stack
        opcodes -- can read below FStack[0].

        Everything else takes its operands through Pop(), which bottoms out
        harmlessly at FSP = 0. These two compute a slot and read it, so a .pbc
        holding `DUPN 1000000` with an empty stack read a megabyte below the array
        and then REFCOUNTED each slot's Str field as if it were a string: an
        out-of-bounds read followed by a write through a garbage pointer, which
        arrived as "unhandled EAccessViolation" and exit 3. (2026-09-06.)

        WHY THE CHECK IS HERE AND NOT IN ValidateProgram. The loader verifies what
        an instruction says about itself -- a constant index, a variable index, a
        jump target. How DEEP the value stack is at an instruction is not a
        property of the instruction; it is a property of the path taken to reach
        it, and the loader has neither a control-flow graph nor a way to build a
        sound one: opGosub/opReturn pick a return address at run time, an ON ERROR
        handler is entered from any faulting instruction with FSP reset to the
        install point, `resume` re-enters mid-statement, and CallUserFunc re-enters
        ExecFrom at a function entry chosen by the host. A static answer would be
        unsound or would reject programs the compiler legitimately emits. FSP here
        is the real depth, so the refusal lives here, and it is one compare.

        ins.A is also re-checked for a negative: ValidateProgram runs on a LOADED
        program, and a program that came straight from the compiler never passed
        through it.

        THE SAME ARGUMENT NAMES THREE MORE OPCODES, and they are checked the same
        way, at opCall, opBreakpoint and opPrintUsing below. Each takes a COUNT
        from its own operand and then pops that many values, and the count is what
        an allocation is sized from. `CALL x, 2000000000` asked SetLength for two
        billion TValues; it did not fail and did not raise -- it COMMITTED the
        96 GB and left the machine paging until it was killed by hand (measured
        2026-09-06; see MaxStackDepth). The bound is FSP in all four cases: there
        is no honest reading of "pop N values" when the stack does not hold N, and
        FSP is a run-time fact for the reason spelled out above. }
      opDup2:
        begin
          if FSP < 2 then
            if Fault(MakeError(peRuntime, 'corrupt bytecode: DUP2 needs 2 values ' +
                     'but the stack holds ' + IntToStr(FSP))) then Continue else Exit(False);
          a := FStack[FSP - 2];
          b := FStack[FSP - 1];
          Push(a);
          Push(b);
        end;
      opDupN:
        begin
          if (ins.A < 0) or (ins.A > FSP) then
            if Fault(MakeError(peRuntime, 'corrupt bytecode: DUPN wants ' +
                     IntToStr(ins.A) + ' values but the stack holds ' +
                     IntToStr(FSP))) then Continue else Exit(False);
          // Duplicate the top ins.A values in order. dupBase is fixed before the
          // pushes because the INDEX has to survive a reallocation inside Push --
          // and so does the REFERENCE `FStack[dupBase + i]` names, which is the
          // part this comment used to leave out and Push now guarantees. Read the
          // note over Push before changing either.
          dupBase := FSP - ins.A;
          for i := 0 to ins.A - 1 do
            Push(FStack[dupBase + i]);
        end;
      opTrace:
        begin
          // Turn tracing on (a non-zero value) or off (0). A non-numeric value
          // reads as 0 through AsDouble, so it turns tracing off. NonFinite first:
          // `<> 0` on a NaN raises rather than answering (see NonFinite), and a
          // non-finite value is "not zero", so it turns tracing ON.
          v := Pop();
          FTrace := NonFinite(v) or (AsDouble(v) <> 0);
        end;
      opBreakpoint:
        begin
          // Pop the ins.A operand values (reverse of the push order) and then the
          // message. Report-and-continue: the host seam is invoked ONLY when
          // tracing is on AND a callback is installed -- a headless host installs
          // none, so BREAKPOINT then does nothing but balance the stack. It never
          // parks the VM, and it never writes back, so every operand VARIABLE the
          // source passed is left untouched (only copies of their values were
          // pushed).
          //
          // ins.A operands AND the message, so the stack must hold A + 1 -- which
          // is also what bounds the SetLength one line down. See the note at the
          // dups.
          if (ins.A < 0) or (ins.A >= FSP) then
            if Fault(MakeError(peRuntime, 'corrupt bytecode: BREAKPOINT wants ' +
                     IntToStr(ins.A) + ' operands and a message but the stack holds ' +
                     IntToStr(FSP) + ' values')) then Continue else Exit(False);
          SetLength(bpOps, ins.A);
          for i := ins.A - 1 downto 0 do
            bpOps[i] := Pop();
          v := Pop();   // the message
          if FTrace and Assigned(OnBreakpoint) then
            OnBreakpoint(ValToStr(v), ins.Line, bpOps);
        end;
      opStmt:
        begin
          // Mark this clean statement boundary; a fault resumes from here.
          stmtPC := pc; stmtSP := FSP; stmtFrameSP := FFrameSP;
        end;
      { A MEANS TWO DIFFERENT THINGS AND B SAYS WHICH, so one check cannot cover
        both -- and the loader's does not try. ValidateProgram bounds A as a pc
        (-1..Count) for every SETERRHANDLER it sees, which is the RIGHT check when
        B = 0 and the WRONG one when B = 1, where A is an index into the constant
        pool. The two ranges overlap without agreeing: in a program of 200
        instructions and 3 constants, `SETERRHANDLER A=150, B=1` passes the loader
        untouched, and the first fault then reads Consts.Get(150) -- past the pool,
        past the array, and refcounts whatever Str field it lands on.

        So the operand is checked HERE, where B is in hand and says what A is. It
        cannot be moved into the loader without teaching the loader the same case
        split, and this file cannot reach into that one; a check the VM makes on
        the value it is about to USE is in any case the one that cannot be fooled
        by a second meaning added later. SETERRHANDLER runs once per `on error`
        statement, so the cost is not on any path that matters.

        B itself is bounded too. It was assigned straight into FErrHandlerMode and
        only ever compared against 1, so B = 7 quietly meant "goto", with A still
        carrying whatever the file said. }
      opSetErrHandler:
        begin
          if (ins.B <> 0) and (ins.B <> 1) then
            if Fault(MakeError(peRuntime, 'corrupt bytecode: ON ERROR mode ' +
                     IntToStr(ins.B) + ' is neither goto (0) nor call (1)')) then Continue else Exit(False);
          if ins.B = 1 then
          begin
            // call mode: A is the const-pool index of the handler's NAME.
            if (ins.A < 0) or (ins.A >= FProg.Consts.Count) then
              if Fault(MakeError(peRuntime, 'corrupt bytecode: ON ERROR CALL names ' +
                       'constant ' + IntToStr(ins.A) + ', outside the ' +
                       IntToStr(FProg.Consts.Count) + '-entry constant pool')) then Continue else Exit(False);
          end
          else
            // goto mode: A is a pc, or any negative for `on error goto 0`.
            if ins.A > FProg.Count then
              if Fault(MakeError(peRuntime, 'corrupt bytecode: ON ERROR GOTO ' +
                       IntToStr(ins.A) + ', outside a program of ' +
                       IntToStr(FProg.Count) + ' instructions')) then Continue else Exit(False);
          FErrHandlerMode := ins.B;   // 0 = goto a label (A = pc), 1 = call a func (A = name idx)
          if (ins.B = 0) and (ins.A < 0) then
            FErrHandler := -1         // on error goto 0 -- disable
          else
          begin
            FErrHandler := ins.A;     // installed (a pc for goto, a name index for call)
            if ins.B = 1 then FErrHandlerFuncIdx := ins.A;
            FErrHandlerSP := FSP; FErrHandlerFrameSP := FFrameSP;
          end;
          FInHandler := False;        // (re-)installing re-arms the handler
        end;
      opResume:
        begin
          if not FInHandler then
          begin
            LastError := MakeError(peRuntime, 'resume without an active error handler');
            ErrorLine := ins.Line;
            Exit(False);
          end;
          FInHandler := False;
          RestoreOverlap();
          if ins.A = 1 then
            // resume next: continue at the statement after the one that failed
            ResumeAtNextStmt()
          else
            pc := FErrStmtPC;   // resume: retry the failing statement
          Continue;
        end;
      opHalt:
        begin
          // Flagged, not just returned. A re-entrant activation's Exit(True) reads
          // to CallUserFunc as "the routine returned a value", so a BASIC click
          // handler that says `end` used to pop the CALLER's pending operand as its
          // return value and leak the frame it had pushed.
          FHalted := True;
          Exit(True);
        end;
      opGosub:
        begin
          { THE GOSUB RETURN STACK IS BOUNDED FOR THE REASON THE VALUE STACK IS.
            This doubled without a ceiling, and no operand and no crafted bytecode
            is needed to sit on it -- `1000 gosub 1000` is three lines of source.
            Measured against the build that bounded only the value stack: 1543 MB
            in 1,3 s, still doubling, while the same loop with `goto` holds at
            2,7 MB. See MaxGosubDepth.

            FATAL, not a Fault: it is a resource ceiling like the step and output
            budgets, and a handler that caught it would be running with the return
            stack still pinned at the ceiling. The refusal is taken BEFORE the
            growth, so nothing is allocated on the way out. }
          if FCSP >= MaxGosubDepth then
          begin
            LastError := MakeError(peLimit, 'GOSUB nesting limit exceeded (' +
                                   IntToStr(MaxGosubDepth) + ' levels)');
            ErrorLine := ins.Line;
            Exit(False);
          end;
          if FCSP = Length(FCallStack) then
          begin
            // Clamped so the last doubling lands ON the ceiling instead of one
            // power of two past it; FCSP < MaxGosubDepth above, so the new length
            // is always greater than FCSP.
            i := (FCSP + 1) * 2;
            if i > MaxGosubDepth then i := MaxGosubDepth;
            SetLength(FCallStack, i);
          end;
          FCallStack[FCSP] := pc + 1;   // resume after the GOSUB
          Inc(FCSP);
          pc := ins.A;
          Continue;
        end;
      opReturn:
        begin
          if FCSP = 0 then
            if Fault(MakeError(peRuntime, 'RETURN without GOSUB')) then Continue else Exit(False);
          Dec(FCSP);
          pc := FCallStack[FCSP];
          Continue;
        end;
      { A LOCAL NEEDS AN ACTIVATION FRAME, and the frame it lands in decides how
        many slots there are.

        opReturn and opRetFunc, three lines up, already refuse to run on an empty
        stack of their own kind. These two did not, and a .pbc whose MAIN BODY
        contains `LOADLOCAL 0` reached FFrames[-1]: a read of a TCallFrame's
        dynamic-array header from before the array, and -- worse -- for the store a
        write through whatever that header happened to contain. Both arrived as
        "unhandled EAccessViolation" and exit 3, uncatchable, in a process the host
        owns. (2026-09-06.)

        The slot is bounded against THIS frame, not against the program. The loader
        can only bound it against the widest local table in the file, because
        nothing on disk says which function an instruction belongs to (see the note
        at opLoadLocal in ValidateProgram); a slot legal for the widest function and
        wild for the one actually running still indexed past the frame's Locals.
        That one has not been seen to fault -- a short array's slack is usually
        still mapped -- which is precisely the kind of luck that stops holding. The
        frame knows its own size, so ask the frame.

        STATIC OR RUN TIME: "is a frame live at this instruction" is a property of
        the PATH, not of the instruction, exactly like the stack depth the two dups
        need, so ValidateProgram cannot decide it and the dispatch loop must. The
        two tests are written as separate statements rather than one `or` so that
        the frame index is never formed before the frame is known to exist,
        whatever the boolean-evaluation switch is set to. }
      opLoadLocal:
        begin
          if FFrameSP = 0 then
            if Fault(BadLocal(ins.A, 'read')) then Continue else Exit(False);
          if (ins.A < 0) or (ins.A >= Length(FFrames[FFrameSP - 1].Locals)) then
            if Fault(BadLocal(ins.A, 'read')) then Continue else Exit(False);
          Push(FFrames[FFrameSP - 1].Locals[ins.A]);
        end;
      opStoreLocal:
        begin
          // Refused BEFORE the pop: the store never begins, so a `resume` retries a
          // statement whose operand is still where the saved overlap expects it.
          if FFrameSP = 0 then
            if Fault(BadLocal(ins.A, 'written')) then Continue else Exit(False);
          if (ins.A < 0) or (ins.A >= Length(FFrames[FFrameSP - 1].Locals)) then
            if Fault(BadLocal(ins.A, 'written')) then Continue else Exit(False);
          v := Pop();
          lt := FProg.UserFuncs[FFrames[FFrameSP - 1].FuncIndex].LocalTypes[ins.A];
          e := StoreCheck(lt, v, r);
          if not IsError(e) then
            FFrames[FFrameSP - 1].Locals[ins.A] := r
          else
          begin
            if e.Code = peTypeMismatch then
              e := MakeError(peTypeMismatch, 'cannot store ' + KindName(v.Kind) +
                ' into ' + VarTypeName(lt) + ' local');
            if Fault(e) then Continue else Exit(False);
          end;
        end;
      opRetFunc:
        begin
          if FFrameSP = 0 then
            if Fault(MakeError(peRuntime, 'return outside a function')) then Continue else Exit(False);
          savedRet := FFrames[FFrameSP - 1].ReturnAddr;  // value stays on the stack
          Dec(FFrameSP);
          // A re-entrant call (CallUserFunc) stops here, handing its return value
          // back to the host through the stack, when the frame it pushed unwinds.
          // Its frame carries no caller statement -- the caller is Pascal code, not
          // this activation -- so the restore below is deliberately not reached.
          if FFrameSP = AStopFrameSP then Exit(True);
          // Back in the caller: its statement boundary is the current one again.
          stmtPC := FFrames[FFrameSP].CallerStmtPC;
          stmtSP := FFrames[FFrameSP].CallerStmtSP;
          stmtFrameSP := FFrames[FFrameSP].CallerStmtFrameSP;
          pc := savedRet;
          Continue;
        end;
      opCall:
        begin
          argc := ins.B;
          { THE ARGUMENT COUNT IS AN OPERAND, and it sizes two allocations and
            three loops. ValidateProgram refuses a negative B and stops there; the
            useful bound is the other end, and it is FSP, which the loader cannot
            know (the note at the dups says why). `CALL f, 2000000000` used to
            reach `SetLength(args, 2000000000)` -- 96 GB of TValue -- and the
            EOutOfMemory raised inside the dispatch loop left the process as
            "unhandled", uncatchable, with the host's data still in it. }
          if (argc < 0) or (argc > FSP) then
            if Fault(MakeError(peRuntime, 'corrupt bytecode: CALL wants ' +
                     IntToStr(argc) + ' arguments but the stack holds ' +
                     IntToStr(FSP) + ' values')) then Continue else Exit(False);
          // A is the const-pool index of the callee's NAME, and it is read at
          // four places below. One bound, here, covers all four; see opPushConst.
          if Cardinal(ins.A) >= Cardinal(FProg.Consts.Count) then
            if Fault(MakeError(peRuntime, 'corrupt bytecode: CALL names constant ' +
                     IntToStr(ins.A) + ', outside the ' +
                     IntToStr(FProg.Consts.Count) + '-entry pool')) then Continue else Exit(False);
          // A user function shadows the library registry for the same name+arity.
          ufi := FProg.FindUserFunc(FProg.Consts.Get(ins.A).Str, argc);
          if ufi >= 0 then
          begin
            { AND THE FRAME MUST HOLD THE PARAMETERS. FindUserFunc matches on name
              AND arity, so argc = ParamCount here -- but the frame is sized from
              LocalTypes, and nothing in this file says the two agree. A .pbc whose
              function table claims one parameter and zero locals is refused by
              ValidateProgram, which is the right place for a fact the file
              carries; a program built in memory -- by the compiler, or by an
              embedder assembling a TProgram -- never passes through the loader at
              all, and this write goes out of bounds without it. }
            if argc > Length(FProg.UserFuncs[ufi].LocalTypes) then
              if Fault(MakeError(peRuntime, 'corrupt bytecode: ' +
                       FProg.UserFuncs[ufi].Name + ' is called with ' + IntToStr(argc) +
                       ' arguments but its frame holds ' +
                       IntToStr(Length(FProg.UserFuncs[ufi].LocalTypes)) +
                       ' locals')) then Continue else Exit(False);
            { AND THE FRAME STACK IS BOUNDED, for the third time and the same
              reason. MaxCallDepth bounds RE-ENTRANT calls because those cost
              process stack; this bounds ORDINARY BASIC RECURSION, which is a jump
              inside this loop and costs only heap -- and so grew without any
              ceiling at all. `function f(n) return f(n+1)` reached 1020 MB in
              3,3 s. Two ceilings, because a frame's price is a fixed part and a
              per-slot part; see MaxFrameDepth. Fatal, before the growth, as at
              GOSUB. }
            if FFrameSP >= MaxFrameDepth then
            begin
              LastError := MakeError(peLimit, 'call depth limit exceeded (' +
                                     IntToStr(MaxFrameDepth) + ' activation frames)');
              ErrorLine := ins.Line;
              Exit(False);
            end;
            { The slot budget, charged on what the frame array will hold once this
              call has taken its index -- the slots already at that index are about
              to be replaced, so they are given back first.

              COMPARED AS `want > budget - held`, NOT `held + want > budget`. The
              left form never adds two numbers this routine does not control:
              LocalTypes comes from the program, and a .pbc claiming a local table
              near High(Integer) would make the sum wrap negative and pass a test
              it should fail. The right-hand side going negative -- which it does
              whenever RestoreOverlap has put back more than it took away -- is not
              a special case here: every non-negative want is then refused, which
              is exactly what a total already over the budget should do. }
            slots := Length(FProg.UserFuncs[ufi].LocalTypes);
            if FFrameSP < Length(FFrames) then
              Dec(slots, Length(FFrames[FFrameSP].Locals));
            if slots > MaxFrameSlots - FFrameSlots then
            begin
              LastError := MakeError(peLimit, 'local slot limit exceeded (' +
                                     IntToStr(MaxFrameSlots) + ' slots in ' +
                                     IntToStr(FFrameSP) + ' activation frames)');
              ErrorLine := ins.Line;
              Exit(False);
            end;
            Inc(FFrameSlots, slots);
            if FFrameSP = Length(FFrames) then
            begin
              i := (FFrameSP + 1) * 2;
              if i > MaxFrameDepth then i := MaxFrameDepth;
              SetLength(FFrames, i);
            end;
            SetLength(FFrames[FFrameSP].Locals, Length(FProg.UserFuncs[ufi].LocalTypes));
            for i := argc - 1 downto 0 do
              FFrames[FFrameSP].Locals[i] := Pop();
            for i := argc to High(FProg.UserFuncs[ufi].LocalTypes) do
              FFrames[FFrameSP].Locals[i] := DefaultValue(FProg.UserFuncs[ufi].LocalTypes[i]);
            FFrames[FFrameSP].FuncIndex := ufi;
            FFrames[FFrameSP].ReturnAddr := pc + 1;
            // The caller's statement boundary rides on the frame and comes back at
            // the return, so a fault AFTER the call returns still resumes in the
            // caller. See TCallFrame.
            FFrames[FFrameSP].CallerStmtPC := stmtPC;
            FFrames[FFrameSP].CallerStmtSP := stmtSP;
            FFrames[FFrameSP].CallerStmtFrameSP := stmtFrameSP;
            Inc(FFrameSP);
            pc := FProg.UserFuncs[ufi].Entry;
            Continue;
          end;
          // library call (plain, or host-aware and given the VM to call back with)
          SetLength(args, argc);
          SetLength(kinds, argc);
          for i := argc - 1 downto 0 do
            args[i] := Pop();
          for i := 0 to argc - 1 do
            kinds[i] := args[i].Kind;
          res := Registry.Resolve(FProg.Consts.Get(ins.A).Str, kinds);
          if not res.Found then
          begin
            if Fault(MakeError(peUnknownFunction,
              'no function ' + SignatureOf(FProg.Consts.Get(ins.A).Str, args))) then Continue else Exit(False);
          end;
          e := NoError();
          // Cleared HERE, at the dispatch, not at the check: a library that calls
          // back in through CallUserFunc sets it, and only a call that got that far
          // may claim a ceiling was crossed. See FLimitFromInner.
          FLimitFromInner := False;
          // The safety net: a library function must never crash the interpreter.
          // Any Pascal exception it raises (e.g. an out-of-range Double->Int64 in a
          // conversion or index argument) is converted to a CATCHABLE engine error,
          // upholding "errors are values, the program keeps running" even for a
          // fault a library forgot to guard.
          try
            if res.IsHost then
              r := res.HostFunc(Self, args, e)
            else
              r := res.Func(args, e);
            { A LIBRARY CALL IS WHERE THE BIG ALLOCATIONS ARE, and the step-loop
              check could not see them: it fires every 4096 instructions, and a
              script that allocates gigabytes in forty does not reach it. Measured:
              twelve `string$(200000000)` into distinct globals is 3814 MB under a
              256 MB ceiling, rc 0.

              Asked HERE, after every library call, because that is exactly where
              a script's memory comes from that `opAdd` does not supply -- an
              array resized, a document parsed, an archive inflated, a list grown.
              One query per call against a call that costs 21 to 115 microseconds
              on this build is under a thousandth of it, so unlike the `+` path
              this one needs no threshold. }
            if (MaxMemoryBytes > 0) and (not RoomFor(0)) then Exit(False);
          except
            on ex: Exception do
            begin
              r := Default(TValue);
              { NOT EVERY EXCEPTION IS AN ERROR THE PROGRAM CAN BE TOLD ABOUT.

                This net used to convert ALL of them to a catchable peRuntime,
                and for a bad argument -- a conversion, a range, a division --
                that is exactly right and stays. But it also handed an ACCESS
                VIOLATION to ON ERROR, and resuming a script after one means
                resuming on memory a wild write has already reached. The script
                then keeps going and answers wrongly, which is worse than the
                crash it replaced: a crash is loud.

                A state fault therefore ends execution here, before Fault is
                consulted, and carries peFatal so the host can tell it apart from
                a script error nobody handled. Whether the PROCESS survives is a
                separate question, answered by ContainFaults at the entry. }
              if IsStateFault(ex) then
              begin
                LastError := MakeError(peFatal,
                  ex.ClassName + ' in ' + FProg.Consts.Get(ins.A).Str +
                  ': ' + ex.Message);
                ErrorLine := ins.Line;
                FFaulted := True;
                Exit(False);
              end;
              e := MakeError(peRuntime, ex.Message);
            end;
          end;
          if IsError(e) then
          begin
            { A BUDGET THAT CAME BACK FROM A NESTED ACTIVATION IS STILL A BUDGET.
              `callfunc` re-enters the VM through CallByName/CallUserFunc; when
              the inner ExecFrom aborts on a ceiling, that peLimit arrives here as
              an ordinary library error and would be handed to Fault -- catchable,
              which is exactly what a fatal limit must never be. It happens not to
              have been an escape for the step budget (FSteps is shared, so the
              outer loop re-fires it one instruction later), but that is an
              accident of which counter is per-VM and which is per-activation, and
              the value-stack ceiling stops being self-re-arming the moment
              CallUserFunc restores the stack it borrowed. Decided on the CODE, so
              it holds for every ceiling. peLimit has NINE producers in this unit
              -- output, value stack, steps, time, GOSUB, call depth and local
              slots in this loop, and the two frame ceilings again in
              CallUserFunc, which is NOT in this loop -- and `grep -rn peLimit
              engine/ host/` finds none in any library or host, only the two
              places that NAME the code. So treating one as fatal here cannot
              swallow a legitimate library error. (Round two's report said
              "exactly four producers, all of them the ceilings in this loop",
              which was assumed rather than counted.) }
            if (e.Code = peLimit) and FLimitFromInner then
            begin
              LastError := e;
              ErrorLine := ins.Line;
              Exit(False);
            end;
            if Fault(e) then Continue else Exit(False);
          end;
          // The finiteness invariant (PhosphorValue, FiniteD) covers library
          // results too: exp(1000) overflows to +Inf inside the RTL, and pushing
          // that would put a value into the program that no later operator could
          // handle. It reports here instead, at the call that produced it.
          if FHalted then Exit(True);   // a callback ran END
          if (r.Kind = vkDouble) and (IsNan(r.Num) or IsInfinite(r.Num)) then
          begin
            if Fault(MakeError(peIntOverflow, FProg.Consts.Get(ins.A).Str +
              ' has no finite result for those arguments')) then Continue else Exit(False);
          end;
          Push(r);
        end;
      // --- classic console input -----------------------------------------------
      opInputLine: ReadInputLine();   // fill the input buffer; EOF just leaves it empty
      opInputField:
        begin
          e := InputField(ins.A, v);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(v);
        end;
      opInputAll:
        begin
          Push(ValStr(Copy(FInBuf, FInPos, MaxInt)));
          FInPos := Length(FInBuf) + 1;
        end;
      opInputChars:
        begin
          a := Pop();   // count
          Push(ValStr(InputChars(SafeI32(a))));
        end;
      // --- classic file I/O ----------------------------------------------------
      opOpenFile:
        begin
          a := Pop();   // channel number (pushed last)
          b := Pop();   // path (pushed first)
          e := ChanOpen(SafeI32(a), ins.A, ValToStr(b));
          if IsError(e) then if Fault(e) then Continue else Exit(False);
        end;
      opCloseFile:
        begin
          if ins.A = 1 then
            CloseAllChannels()            // CLOSE with no argument: close every channel
          else
          begin
            a := Pop();
            e := ChanClose(SafeI32(a));
            if IsError(e) then if Fault(e) then Continue else Exit(False);
          end;
        end;
      opPrintFile:
        begin
          v := Pop();   // the value (pushed last)
          a := Pop();   // channel number (pushed first)
          e := ChanWrite(SafeI32(a), ValToStr(v));
          if IsError(e) then if Fault(e) then Continue else Exit(False);
        end;
      opFileField:
        begin
          a := Pop();   // channel number
          e := ChanField(SafeI32(a), ins.A, v);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(v);
        end;
      opFileLine:
        begin
          a := Pop();
          e := ChanLine(SafeI32(a), sTmp);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(ValStr(sTmp));
        end;
      opFileChars:
        begin
          a := Pop();   // channel number (pushed last, on top)
          b := Pop();   // count (pushed first)
          e := ChanChars(SafeI32(a), SafeI32(b), sTmp);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(ValStr(sTmp));
        end;
      opEofFile:
        begin
          a := Pop();
          e := ChanEof(SafeI32(a), bTmp);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(ValBool(bTmp));
        end;
      opLofFile:
        begin
          a := Pop();
          e := ChanLof(SafeI32(a), nTmp);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(ValInt(nTmp));
        end;
      opLocFile:
        begin
          a := Pop();
          e := ChanLoc(SafeI32(a), nTmp);
          if IsError(e) then if Fault(e) then Continue else Exit(False);
          Push(ValInt(nTmp));
        end;
      opSeekFile:
        begin
          a := Pop();   // the 1-based position (pushed last)
          b := Pop();   // the channel number (pushed first)
          // A 64-BIT NARROWING for the POSITION. Narrowing it to 32 bits clamped
          // every offset past 2 GB to 2147483647, so two different positions in a
          // large file collapsed onto one and `seek #1, lof(1) + 1` landed a
          // gigabyte inside the file instead of at its end. The channel NUMBER
          // stays 32-bit -- it is an index into a 255-entry table.
          //
          // SafeI64, not PhosphorValue's ArgI64: same clamping, but its NaN test
          // is a bit test rather than the `d <> d` that traps here. See SafeI64.
          e := ChanSeek(SafeI32(b), SafeI64(a));
          if IsError(e) then if Fault(e) then Continue else Exit(False);
        end;
      // --- formatted output ----------------------------------------------------
      opPrintUsing:
        begin
          // ins.A values AND the format string, so the stack must hold A + 1 --
          // the same bound, for the same allocation, as at BREAKPOINT and CALL.
          if (ins.A < 0) or (ins.A >= FSP) then
            if Fault(MakeError(peRuntime, 'corrupt bytecode: PRINT USING wants ' +
                     IntToStr(ins.A) + ' values and a format but the stack holds ' +
                     IntToStr(FSP) + ' values')) then Continue else Exit(False);
          SetLength(usingVals, ins.A);
          for i := ins.A - 1 downto 0 do usingVals[i] := Pop();
          v := Pop();   // the format string (pushed first)
          if not EmitOutput(FormatUsing(ValToStr(v), usingVals)) then Exit(False);
        end;
    else
      if Fault(MakeError(peRuntime, 'bad opcode ' + IntToStr(Ord(ins.Op)))) then Continue else Exit(False);
    end;
    Inc(pc);
  end;
  Result := True;
end;

procedure TPhosphorVM.EndOfTopLevel;
begin
  FHalted := False;
end;

procedure TPhosphorVM.ClearError;
begin
  FErrCode := 0;
  FErrMsg := '';
  FErrLine := 0;
end;

{ THE READ-ONLY WINDOW. See the block over the declarations for the lifetime.

  Each of these answers for an index it was not given, rather than indexing and
  hoping. DbgGlobalCount is the program's DECLARED count, not Length(FVars): Run
  sizes the slots to it and RunFrom only grows them, so the two normally agree --
  but FProg is assigned before the slots are sized, and a contained fault leaves
  them in whatever state the unwinding left them. The count a host loops over must
  be the one the program declares, and an index with no slot behind it reads as
  the default for its declared type, which is what the VM itself would read. }
function TPhosphorVM.DbgProgram: TProgram;
begin
  Result := FProg;
end;

function TPhosphorVM.DbgGlobalCount: Integer;
begin
  if FProg = nil then Exit(0);
  Result := FProg.VarCount;
end;

function TPhosphorVM.DbgGlobal(AIndex: Integer): TValue;
begin
  Result := Default(TValue);
  if (FProg = nil) or (AIndex < 0) or (AIndex >= FProg.VarCount) then Exit;
  if AIndex > High(FVars) then
  begin
    if AIndex <= High(FProg.VarTypes) then
      Result := DefaultValue(FProg.VarTypes[AIndex]);
    Exit;
  end;
  Result := FVars[AIndex];
end;

function TPhosphorVM.DbgFrameDepth: Integer;
begin
  Result := FFrameSP;
end;

function TPhosphorVM.DbgFrameFunc(AFrame: Integer): Integer;
begin
  if (AFrame < 0) or (AFrame >= FFrameSP) then Exit(-1);
  Result := FFrames[AFrame].FuncIndex;
end;

function TPhosphorVM.DbgFrameLocalCount(AFrame: Integer): Integer;
begin
  if (AFrame < 0) or (AFrame >= FFrameSP) then Exit(0);
  Result := Length(FFrames[AFrame].Locals);
end;

function TPhosphorVM.DbgLocal(AFrame, ASlot: Integer): TValue;
begin
  Result := Default(TValue);
  if (AFrame < 0) or (AFrame >= FFrameSP) then Exit;
  if (ASlot < 0) or (ASlot > High(FFrames[AFrame].Locals)) then Exit;
  Result := FFrames[AFrame].Locals[ASlot];
end;

{ Call ANYTHING by name, in the order a direct call uses: the program's own
  routines first, the registry second. That order is opCall's, and matching it is
  the whole point -- callfunc("sqr", 9) has to mean what sqr(9) means, including
  which of two same-named things wins. }
function TPhosphorVM.KnowsName(const AName: String): Boolean;
var
  i: Integer;
begin
  Result := False;
  if FProg <> nil then
    for i := 0 to FProg.UserFuncCount - 1 do
      if SameText(FProg.UserFuncs[i].Name, AName) then Exit(True);
  Result := (Registry <> nil) and Registry.HasName(AName);
end;

function TPhosphorVM.CallByName(const AName: String; const Args: array of TValue;
  out Err: TPhosphorError): TValue;
var
  kinds: array of TValueKind;
  res: TResolvedFunc;
  i: Integer;
  savedMask: TFPUExceptionMask;
begin
  { EXISTENCE DECIDES, not the error code. This used to call the routine and fall
    through to the library whenever the answer came back peUnknownFunction -- on
    the reading that the code meant "there is no such routine". It also means "the
    routine ran and hit a name IT could not resolve", and then the fallback ran a
    DIFFERENT function under the same name and returned its answer as if nothing
    had happened:

      function abs(x)
        return nao_existe(x)
      endfunction
      println abs(-5)             -> no function nao_existe:%      (correct)
      println callfunc("abs", -5) -> 5                             (the library's)

    which is exactly the property callfunc is documented to have: an indirect call
    means what a direct one means. FindUserFunc by name AND arity is how opCall
    decides, so it is how this decides. }
  if FProg.FindUserFunc(AName, Length(Args)) >= 0 then
    Exit(CallUserFunc(AName, Args, Err));

  SetLength(kinds, Length(Args));
  for i := 0 to High(Args) do kinds[i] := Args[i].Kind;
  res := Registry.Resolve(AName, kinds);
  if not res.Found then
  begin
    // Neither a routine of this program nor a library function. One message for
    // both, because from the caller's side there is one question.
    Err := MakeError(peUnknownFunction, 'no function ' + SignatureOf(AName, Args));
    Exit;
  end;
  Err := NoError();
  // The same safety net opCall puts around a library call: a Pascal exception
  // from inside a library becomes a catchable engine error, never a crash. Under
  // the same FPU mask, too: a library that overflows must report the way it
  // reports inside Run, not raise a different exception because the host happened
  // to call in by a different door. See EnterFPU.
  savedMask := EnterFPU();
  try
    try
      if res.IsHost then
        Result := res.HostFunc(Self, Args, Err)
      else
        Result := res.Func(Args, Err);
    except
      on E: Exception do
        Err := MakeError(peRuntime, AName + ': ' + E.Message);
    end;
  finally
    LeaveFPU(savedMask);
  end;
  { AND THE FINITENESS GATE THE MASK MAKES NECESSARY.

    Masking overflow is what turns a raise into a +Inf, so a seam that installs
    the mask and does NOT gate the result is a seam that hands the host an
    infinity where it used to get an error -- a silent wrong answer, which is
    worse than the crash it replaced. opCall applies exactly this test to a
    library result (see the note there); this is the same test on the same values
    reached by the other door, which is also what "an indirect call means what a
    direct one means" requires. It names the function that actually overflowed,
    so `callfunc("exp", 1000)` reports `exp`, as docs/libraries/num.md describes
    the rule, rather than `callfunc`. }
  if (not IsError(Err)) and (Result.Kind = vkDouble) and
     (IsNan(Result.Num) or IsInfinite(Result.Num)) then
  begin
    Err := MakeError(peIntOverflow, AName + ' has no finite result for those arguments');
    Result := Default(TValue);
  end;
end;

function TPhosphorVM.CallUserFunc(const AName: String; const Args: array of TValue;
  out Err: TPhosphorError): TValue;
var
  ufi, i, saved, savedSP, slots: Integer;
  savedLimit: Boolean;
  savedMask: TFPUExceptionMask;
begin
  Result := Default(TValue);
  Err := NoError();
  if FProg = nil then
  begin
    Err := MakeError(peRuntime, 'no program is running');
    Exit;
  end;
  { A HALTED SESSION ANSWERS, IT DOES NOT PRETEND.

    This used to run the body and then throw the answer away: the flag was read
    AFTER execution, so a halt raised by a PREVIOUS call was taken to mean "this
    call halted". The body ran -- with all its side effects -- the real return
    value left by opRetFunc was dropped by the finally's FSP := savedSP, and Err
    stayed NoError. A host following docs/embedding.md saw a successful call
    returning 0, for ever, with no way to tell: TPhosphorEngine did not expose
    Halted either.

    Refused here, BEFORE the frame is pushed, so nothing runs at all. `end` means
    the program is over; the honest answer to "call this function" is no. }
  if FHalted then
  begin
    Err := MakeError(peRuntime, 'the script has run END; this session is over -- ' +
      'Prepare it again before calling into it');
    Exit;
  end;
  ufi := FProg.FindUserFunc(AName, Length(Args));
  if ufi < 0 then
  begin
    Err := MakeError(peUnknownFunction,
      'no BASIC function ' + AName + ' taking ' + IntToStr(Length(Args)) + ' argument(s)');
    Exit;
  end;
  // Push an activation frame, mirroring opCall's user-function path, then run the
  // body re-entrantly until it returns to this frame level. The stack, globals
  // and handle registry are shared with the running program on purpose: a callback
  // sees and mutates the same state, exactly like an in-line GOSUB would.
  // Bounded. Each re-entry is a NATIVE Pascal call, so recursion through callfunc
  // spends process stack: 20000 levels used to raise EStackOverflow deep inside the
  // interpreter, leave FFrameSP thousands deep because no unwinding ran, and then
  // segfault while the ON ERROR handler tried to resume into abandoned frames. An
  // ordinary recursive BASIC function is unaffected -- opCall is a jump inside one
  // interpreter loop and costs only heap.
  if FCallDepth >= MaxCallDepth then
  begin
    Err := MakeError(peRuntime, 'call nesting too deep: ' + AName +
      ' is more than ' + IntToStr(MaxCallDepth) + ' re-entrant calls in');
    Exit;
  end;
  // The frame must hold the parameters. This is opCall's check, on opCall's write,
  // reached the other way -- through the host callback seam rather than through an
  // instruction -- so it is made here too rather than left to whoever calls in.
  if Length(Args) > Length(FProg.UserFuncs[ufi].LocalTypes) then
  begin
    Err := MakeError(peRuntime, 'corrupt bytecode: ' + AName + ' is called with ' +
      IntToStr(Length(Args)) + ' arguments but its frame holds ' +
      IntToStr(Length(FProg.UserFuncs[ufi].LocalTypes)) + ' locals');
    Exit;
  end;
  // opCall's two frame ceilings, on opCall's growth, reached the other way. A host
  // event dispatcher calls in at whatever depth the VM already stands at, so the
  // bounds have to be here too; see MaxFrameDepth.
  if FFrameSP >= MaxFrameDepth then
  begin
    Err := MakeError(peLimit, 'call depth limit exceeded (' +
      IntToStr(MaxFrameDepth) + ' activation frames)');
    FLimitFromInner := True;   // a ceiling, crossed in here; see FLimitFromInner
    Exit;
  end;
  slots := Length(FProg.UserFuncs[ufi].LocalTypes);
  if FFrameSP < Length(FFrames) then
    Dec(slots, Length(FFrames[FFrameSP].Locals));
  if slots > MaxFrameSlots - FFrameSlots then
  begin
    Err := MakeError(peLimit, 'local slot limit exceeded (' +
      IntToStr(MaxFrameSlots) + ' slots in ' + IntToStr(FFrameSP) +
      ' activation frames)');
    FLimitFromInner := True;   // a ceiling, crossed in here; see FLimitFromInner
    Exit;
  end;
  Inc(FFrameSlots, slots);
  saved := FFrameSP;
  savedSP := FSP;
  savedLimit := FStackLimit;
  if FFrameSP = Length(FFrames) then
  begin
    i := (FFrameSP + 1) * 2;
    if i > MaxFrameDepth then i := MaxFrameDepth;
    SetLength(FFrames, i);
  end;
  SetLength(FFrames[FFrameSP].Locals, Length(FProg.UserFuncs[ufi].LocalTypes));
  for i := 0 to Length(Args) - 1 do
    FFrames[FFrameSP].Locals[i] := Args[i];
  for i := Length(Args) to High(FProg.UserFuncs[ufi].LocalTypes) do
    FFrames[FFrameSP].Locals[i] := DefaultValue(FProg.UserFuncs[ufi].LocalTypes[i]);
  FFrames[FFrameSP].FuncIndex := ufi;
  FFrames[FFrameSP].ReturnAddr := -1;   // unused: ExecFrom stops by frame level
  // No caller STATEMENT either -- this frame was pushed by Pascal, not by an opCall
  // in some activation's statement. The slot is reused from an earlier call, so it
  // is cleared rather than left holding a boundary from a program long since past.
  FFrames[FFrameSP].CallerStmtPC := -1;
  FFrames[FFrameSP].CallerStmtSP := 0;
  FFrames[FFrameSP].CallerStmtFrameSP := 0;
  Inc(FFrameSP);
  Inc(FCallDepth);
  savedMask := EnterFPU();   // this is an entry into execution; see EnterFPU
  try
   try
    if ExecFrom(FProg.UserFuncs[ufi].Entry, saved) then
    begin
      // A HALT is not a return. opRetFunc never ran, so there is no return value on
      // the stack, and popping one takes whatever the caller had pushed and still
      // needs.
      if FHalted then
        Result := Default(TValue)
      else
        Result := Pop();   // the routine's return value
    end
    else
    begin
      Err := LastError;
      // A ceiling the INNER activation crossed. It travels back to opCall as an
      // ordinary library error, and this is the only place that still knows it was
      // not a library saying no. See FLimitFromInner.
      if Err.Code = peLimit then FLimitFromInner := True;
    end;
   except
     { THE HOST-CALLBACK DOOR IS AN ENTRY INTO EXECUTION TOO, and it is the one a
       GUI application actually uses: a button click calls a BASIC function
       through here. Containing at Run alone would leave exactly the case the
       option was built for -- an event handler faulting inside the host's own
       message loop -- travelling on to the LCL. See ContainFaults. }
     on E: Exception do
       if FContainFaults and IsStateFault(E) then
       begin
         ContainFault(E);
         Err := LastError;
         Result := Default(TValue);
       end
       else
         raise;
   end;
  finally
    // On EVERY exit -- returned, faulted, or unwound by an exception raised deeper
    // in -- the frame level goes back to where it was. Only the failure branch used
    // to do this, so anything that escaped as a Pascal exception left the frame
    // stack permanently deeper than the program believed.
    Dec(FCallDepth);
    LeaveFPU(savedMask);
    FFrameSP := saved;
    { AND THE VALUE STACK, WHICH THIS RESTORED FOR THE FRAMES ONLY.

      A call that ends in an error leaves FSP wherever the failed body left it. On
      the success path the return value has just been popped and FSP is already
      savedSP, so this is a no-op; on the failure path it is the whole fix. A host
      dispatching GUI events through this seam LEAKED ONE SLOT PER FAILING EVENT:
      measured, 400 000 failing callbacks walked the value stack from 3 MB to
      24 MB, and at 1 048 576 of them it reached the ceiling -- at which point
      every LATER callback, including one that could not fail, answered "value
      stack limit exceeded" for ever. Nothing in any script was responsible for
      either half.

      FStackLimit is RESTORED, not cleared. Clearing it would hide a real ceiling
      from an outer ExecFrom that is still live on the Pascal stack; restoring the
      value it had on entry says precisely what is true -- the drop happened above
      savedSP, in slots that are now gone. The ceiling still ends the program,
      because a peLimit coming back out of here is refused as fatal at opCall's
      library branch and by Fault's `on error call` path. }
    FSP := savedSP;
    FStackLimit := savedLimit;
  end;
end;

end.
