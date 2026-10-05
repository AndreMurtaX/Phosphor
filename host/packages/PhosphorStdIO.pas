{******************************************************************************
  Phosphor BASIC -- the standard files, the same in every thread

  MIT License. Copyright (c) 2026 Andre Murta.

  THE FIVE STANDARD TEXT FILES ARE THREADVARS (rtl/inc/systemh.inc: Input,
  Output, ErrOutput, StdOut and StdErr are declared under `ThreadVar`), and every
  thread the RTL starts re-opens its own five from scratch: InitThread calls
  SysInitStdio (rtl/inc/thread.inc), which calls OpenStdIO over the handles the
  RTL read ONCE at startup -- StdInputHandle and friends -- with the console's
  code page (rtl/inc/text.inc, OpenStdIO).

  So a thread inherits NOTHING this host decided about them on the main thread:

    * not the UTF-8 pin. The host pins every standard file that is not a
      terminal to CP_UTF8, because an editor reading the stream wants UTF-8
      (block S of scripts/test.ps1). A thread's StdErr writes in the console
      code page instead -- the mojibake that pin exists to prevent;
    * not where the files point. crt_hideconsole sends them to NUL and
      crt_showconsole to the NEW console; a thread's copies still name the
      handles from startup -- the released console.

  A per-thread fix at each TThread.Execute would be the instance and not the
  class: it covers the threads written today and misses the next one, and it
  cannot reach a thread a library starts. So the conformance is installed ONCE,
  in the thread manager: every thread anyone starts through BeginThread -- which
  is where TThread starts its own -- runs ConformStdIO before its first line.
  The RTL's ThreadMain calls InitThread before the thread function, so this runs
  AFTER SysInitStdio has opened the copies, and overwrites exactly them.

  WHAT IS COPIED, AND WHY IT IS SAFE. The main thread PUBLISHES its five records'
  handle, mode, code page and I/O functions (PublishStdIO, called at the door
  after the pin and again by crt_hideconsole / crt_showconsole); a new thread
  copies those fields into its own records, which are freshly opened and hold
  nothing buffered. The handle is SHARED, never duplicated, and that is safe
  because a thread never closes its standard files: DoneThread only FLUSHES
  them (rtl/inc/thread.inc, SysFlushStdio). The buffer is the thread's own and
  is never copied -- BufPtr points inside the record that owns it.

  Measured before the repair through `phosphor --diag`, which now writes one
  line from a second thread: with stderr piped, that line arrived in the
  console code page while the main thread's arrived in UTF-8.
******************************************************************************}
unit PhosphorStdIO;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

{ Record where the CALLING thread's standard files point and how they encode,
  as the description every thread started afterwards will copy. Call it from
  the main thread whenever it changes them. }
procedure PublishStdIO;

{ Make the calling thread's five standard files match what was published. Runs
  by itself in every new thread once InstallThreadConformance has run; public so
  a thread the RTL did not start (none today) can ask for it explicitly. }
procedure ConformStdIO;

{ Wrap the thread manager's BeginThread so every thread conforms before its
  first line. Idempotent. Call once, early, from the main thread. }
procedure InstallThreadConformance;

implementation

type
  TStdShape = record
    Handle: THandle;
    Mode: LongInt;
    CodePage: TSystemCodePage;
    InOutFunc, FlushFunc, CloseFunc: CodePointer;
  end;

  PTrampoline = ^TTrampoline;
  TTrampoline = record
    F: TThreadFunc;
    P: Pointer;
  end;

var
  GLock: TRTLCriticalSection;
  GPublished: Boolean = False;
  GShape: array[0..4] of TStdShape;   // Input, Output, ErrOutput, StdOut, StdErr
  GOldBegin: TBeginThreadHandler = nil;

procedure Take(var AText: Text; out AShape: TStdShape);
begin
  AShape.Handle := THandle(TextRec(AText).Handle);
  AShape.Mode := TextRec(AText).Mode;
  AShape.CodePage := TextRec(AText).CodePage;
  AShape.InOutFunc := TextRec(AText).InOutFunc;
  AShape.FlushFunc := TextRec(AText).FlushFunc;
  AShape.CloseFunc := TextRec(AText).CloseFunc;
end;

procedure Give(var AText: Text; const AShape: TStdShape);
begin
  { Only the fields that say where and how. BufPos/BufEnd are zeroed rather than
    copied: a record SysInitStdio has just opened holds nothing, and a count
    copied from another thread's buffer would describe bytes this one never had. }
  TextRec(AText).Handle := AShape.Handle;
  TextRec(AText).Mode := AShape.Mode;
  TextRec(AText).CodePage := AShape.CodePage;
  TextRec(AText).InOutFunc := AShape.InOutFunc;
  TextRec(AText).FlushFunc := AShape.FlushFunc;
  TextRec(AText).CloseFunc := AShape.CloseFunc;
  TextRec(AText).BufPos := 0;
  TextRec(AText).BufEnd := 0;
end;

procedure PublishStdIO;
begin
  EnterCriticalSection(GLock);
  try
    Take(Input, GShape[0]);
    Take(Output, GShape[1]);
    Take(ErrOutput, GShape[2]);
    Take(StdOut, GShape[3]);
    Take(StdErr, GShape[4]);
    GPublished := True;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure ConformStdIO;
begin
  EnterCriticalSection(GLock);
  try
    if not GPublished then Exit;   // nothing decided yet: the RTL's copies stand
    Give(Input, GShape[0]);
    Give(Output, GShape[1]);
    Give(ErrOutput, GShape[2]);
    Give(StdOut, GShape[3]);
    Give(StdErr, GShape[4]);
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function Trampoline(AParam: Pointer): PtrInt;
var
  t: TTrampoline;
begin
  t := PTrampoline(AParam)^;
  Dispose(PTrampoline(AParam));
  ConformStdIO();
  Result := t.F(t.P);
end;

function ConformingBegin(sa: Pointer; stacksize: PtrUInt; ThreadFunction: TThreadFunc;
  p: Pointer; creationFlags: DWord; var ThreadId: TThreadID): TThreadID;
var
  t: PTrampoline;
begin
  New(t);
  t^.F := ThreadFunction;
  t^.P := p;
  Result := GOldBegin(sa, stacksize, @Trampoline, t, creationFlags, ThreadId);
  { No thread means no trampoline to free the record, so it is freed here. Both
    managers answer 0 for a thread they could not start. }
  if Result = TThreadID(0) then Dispose(t);
end;

procedure InstallThreadConformance;
var
  tm: TThreadManager;
begin
  GetThreadManager(tm);
  if tm.BeginThread = @ConformingBegin then Exit;
  GOldBegin := tm.BeginThread;
  tm.BeginThread := @ConformingBegin;
  { SetThreadManager runs the manager's DoneManager then its InitManager. Both
    are nil on Windows (rtl/win/systhrd.inc) and idempotent under cthreads
    (CInitThreads guards its TLS set-up with an interlocked flag), and the
    record put back is the same manager with one field changed. }
  SetThreadManager(tm);
end;

initialization
  InitCriticalSection(GLock);
finalization
  DoneCriticalSection(GLock);
end.
