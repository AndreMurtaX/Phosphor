{******************************************************************************
  probe_limits -- a Pascal test of the execution ceilings (phase-3 step 2)

  Limits are a HOST-facing feature: the embedder sets them on TPhosphorEngine
  before Run, so they are tested here from Pascal, the way a host uses them --
  not from a .bas file (the byte-exact runner sets no limits). Each check runs a
  script under a ceiling and asserts the run aborted with peLimit, that a normal
  script within the ceilings runs clean, and that ON ERROR cannot catch a limit.

  ALSO the FRONT END's ceilings and its refusal to read a token that is not
  there, and those are here for a sharper reason than convenience. Each of them
  used to KILL the process -- an access violation on a source file whose first
  character cannot start a token, a stack overflow on a run of prefix operators
  -- and the negative-test harness asks only whether the exit code was non-zero.
  A crash is non-zero. A .bas file therefore could not tell the fix from the bug:
  it would have gone green either way. From Pascal the question is the one an
  embedding host actually asks: Compile must RETURN False and say why, and it
  must not raise.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail
  to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_limits;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  Classes, SysUtils, PhosphorErrors, PhosphorEngine, PhosphorCompiler,
  PhosphorOpcodes, PhosphorValue, PhosphorRegistry, PhosphorVM;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

{ Run ASource with the given ceilings; assert the outcome. AWantLimit true means
  the run must abort with peLimit; false means it must succeed (Run = 0). }
procedure Check(const AName, ASource: String;
  ASteps, AOutput, ATimeoutMs: Int64; AWantLimit: Boolean);
var
  eng: TPhosphorEngine;
  rc: Integer;
  hitLimit: Boolean;
begin
  eng := TPhosphorEngine.Create();
  try
    eng.MaxSteps := ASteps;
    eng.MaxOutputBytes := AOutput;
    eng.TimeoutMs := ATimeoutMs;
    rc := eng.Run(ASource);
    hitLimit := (rc <> 0) and (eng.LastError.Code = peLimit);
    if AWantLimit then
      Report(hitLimit, AName + ' (expected a limit)')
    else
      Report(rc = 0, AName + ' (expected success)');
  finally
    eng.Free;
  end;
end;

type
  { TWO HOST SEAMS, because two of this ceiling's failure modes can only be
    reached through one. TFreeingSink drops the host's own ballast the first time
    the script prints -- a GUI clearing a log pane is the real shape -- and
    TFatInput hands back 64 KB per line, which is growth arriving through neither
    opAdd nor a registry call. }
  TFreeingSink = class
    Ballast: String;
    Keep: String;
    Fired: Integer;
    Biggest: Int64;    { the largest len= the script reported }
    procedure Take(const S: String);
  end;

  TFatInput = class
    Line: String;
    function Read(out ALine: String): Boolean;
  end;

procedure TFreeingSink.Take(const S: String);
begin
  Inc(Fired);
  if Fired = 1 then Ballast := '';   { the host lets go, mid-run }
  { A NUMBER, not the text of one: 'len=134217728' sorts BEFORE 'len=67108864' as
    a string, so comparing the transcript would have read a bigger tree as a
    smaller one. }
  if Copy(S, 1, 4) = 'len=' then
    Biggest := StrToInt64Def(Trim(Copy(S, 5, Length(S) - 4)), Biggest);
end;

function TFatInput.Read(out ALine: String): Boolean;
begin
  ALine := Line;
  Line := Line + ' ';   { a fresh buffer every time, never a shared reference }
  Result := True;
end;

{ The memory ceiling, which needs its own runner because it is the only one of
  the four whose interesting cases are about SIZE rather than about time. AWant is
  the fragment the message must carry, or '' for a run that must succeed. }
procedure CheckMem(const AName, ASource: String; AMemBytes: Int64;
  const AWant: String; AHostHolds: Integer = 0);
var
  eng: TPhosphorEngine;
  rc: Integer;
  ballast: String;
begin
  { AHostHolds is memory the HOST is already sitting on when the run begins. The
    ceiling is about what the SCRIPT adds, so it must make no difference -- and
    measuring absolute heap instead of growth is a one-line change that no other
    check here can see. An application holding 300 MB of its own data would
    otherwise refuse every script under a 32 MB ceiling before it ran a line. }
  ballast := '';
  if AHostHolds > 0 then ballast := StringOfChar('B', AHostHolds);
  eng := TPhosphorEngine.Create();
  try
    eng.MaxMemoryBytes := AMemBytes;
    eng.TimeoutMs := 60000;   { so a runaway case fails the probe instead of hanging it }
    rc := eng.Run(ASource);
    if AWant = '' then
      Report(rc = 0, AName + ' (expected success, got ' + eng.ErrorMessage + ')')
    else
      Report((rc <> 0) and (eng.LastError.Code = peLimit) and
             (Pos(AWant, eng.ErrorMessage) > 0),
             AName + ' (expected a limit saying "' + AWant + '", got code ' +
             IntToStr(Ord(eng.LastError.Code)) + ' ' + eng.ErrorMessage + ')');
  finally
    eng.Free;
  end;
  if Length(ballast) <> AHostHolds then
    Report(False, AName + ' (the ballast was collected under the check)');
end;

{ The host frees 512 MB of its own the first time the script prints; the script
  keeps allocating and must still be refused. }
procedure CheckMemHostFrees(const AName: String);
var
  eng: TPhosphorEngine;
  sink: TFreeingSink;
  rc: Integer;
begin
  sink := TFreeingSink.Create();
  eng := TPhosphorEngine.Create();
  try
    sink.Ballast := StringOfChar('B', 256 * 1024 * 1024);
    { A SECOND chunk, allocated AFTER the first, so the first is not the last one
      out: GetFPCHeapStatus().CurrHeapUsed does not fall when the LAST large chunk
      is released, and a fixture with one ballast cannot reach this branch at all.
      Measured -- 520 MB before the free and 520 MB after, with one; 520 and 8,
      with two. }
    sink.Keep := StringOfChar('K', 8 * 1024 * 1024);
    eng.OnOutput := @sink.Take;
    eng.MaxMemoryBytes := 32 * 1024 * 1024;
    eng.TimeoutMs := 60000;
    { WHAT IS OBSERVED IS HOW FAR THE SCRIPT GOT, not that it was refused. It is
      refused either way in the end -- once the heap climbs back over the stale
      base -- so `rc` cannot tell the two apart. How much it built before that
      can: the ceiling stops being enforced in between. }
    rc := eng.Run('println "go"' + #10 +
                  's$ = "A"' + #10 +
                  'for i% = 1 to 30' + #10 +
                  '  s$ = s$ + s$' + #10 +
                  '  println "len=" + str$(len(s$))' + #10 +
                  'next' + #10);
    Report((rc <> 0) and (eng.LastError.Code = peLimit),
           AName + ' -- refused (' + IntToStr(Ord(eng.LastError.Code)) + ' ' +
           eng.ErrorMessage + ')');
    Report(sink.Biggest > 0, AName + ' -- the script reported its progress');
    Report(sink.Biggest <= 64 * 1024 * 1024,
           AName + ' -- and stopped near the 32 MB ceiling, not far past it (' +
           IntToStr(sink.Biggest) + ' bytes)');
  finally
    eng.Free;
    sink.Free;
  end;
end;

{ A thousand 64 KB lines through OnInput: 64 MB arriving where neither the opAdd
  pre-check nor the after-a-library-call check is looking. }
procedure CheckMemFatInput(const AName: String);
var
  eng: TPhosphorEngine;
  src: TFatInput;
  rc: Integer;
begin
  src := TFatInput.Create();
  eng := TPhosphorEngine.Create();
  try
    src.Line := StringOfChar('L', 65536);
    eng.OnInput := @src.Read;
    eng.MaxMemoryBytes := 16 * 1024 * 1024;
    eng.TimeoutMs := 60000;
    rc := eng.Run('L@ = strings@()' + #10 +
                  'for i% = 1 to 2000' + #10 +
                  '  line input a$' + #10 +
                  '  n = strings_add(L@, a$)' + #10 +
                  'next' + #10);
    Report((rc <> 0) and (eng.LastError.Code = peLimit),
           AName + ' (got ' + IntToStr(Ord(eng.LastError.Code)) + ' ' +
           eng.ErrorMessage + ')');
  finally
    eng.Free;
    src.Free;
  end;
end;

{ THE SAME TPhosphorVM, RUN TWICE. TPhosphorEngine builds a fresh VM per Run, so
  this shape is only reachable by an embedder holding the VM itself -- which is a
  public class. The base is sampled before the state reset, and the first run's
  memory is still accounted for when the second one samples, so the second run
  starts with a base ABOVE what it will ever hold. Answering "below the base,
  nothing to charge" there turned the ceiling off for the whole second run: 1.3 GB
  through a 128 MB ceiling. The floor has to fall to whatever is actually held. }
procedure CheckMemVmReused(const AName: String);
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  vm: TPhosphorVM;
  first, second: Boolean;
  Src: String;
begin
  { A LITERAL AND opAdd, NO LIBRARY CALL. A bare TPhosphorVM has no Registry --
    TPhosphorEngine is what installs one -- so `string$` here would dereference
    nil and take the probe down with exit 217, which is what the first draft did.
    A kilobyte doubled twenty times is a gigabyte, through the one instruction
    this check is about. }
  Src := 's$ = "' + StringOfChar('A', 1024) + '"' + #10 +
         'for i% = 1 to 20' + #10 + '  s$ = s$ + s$' + #10 + 'next' + #10;
  comp := TPhosphorCompiler.Create();
  prog := nil;
  vm := nil;
  try
    if not comp.Compile(Src, prog) then
    begin
      Report(False, AName + ' (the fixture did not compile)');
      Exit;
    end;
    vm := TPhosphorVM.Create();
    vm.MaxMemoryBytes := 128 * 1024 * 1024;
    vm.TimeoutMs := 60000;
    first := vm.Run(prog);
    second := vm.Run(prog);
    Report((not first) and (not second) and (vm.LastError.Code = peLimit),
           AName + ' (first refused=' + BoolToStr(not first, True) +
           ', second refused=' + BoolToStr(not second, True) + ')');
  finally
    vm.Free;
    prog.Free;
    comp.Free;
  end;
end;

{ Compile ASource and require that it is REJECTED -- Compile returns False, the
  message contains AWantFragment, and NOTHING IS RAISED.

  The except branch is the whole point of doing this from Pascal. An exception
  escaping the compiler is exactly the defect under test (FTokens[-1] on an empty
  token array raised EAccessViolation), so it is caught and reported as a failed
  check rather than being allowed to kill the probe: a dead probe tells the suite
  only that something did not run. This is the same discipline tests/suite/54
  uses for its loops -- a crash test that FAILS instead of crashing the runner. }
procedure CheckRejected(const AName, ASource, AWantFragment: String);
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  rejected: Boolean;
  msg: String;
begin
  comp := TPhosphorCompiler.Create();
  try
    prog := nil;
    msg := '';
    rejected := False;
    try
      rejected := not comp.Compile(ASource, prog);
      if rejected then msg := comp.ErrorMessage;
    except
      on E: Exception do
      begin
        rejected := False;
        msg := 'RAISED ' + E.ClassName + ': ' + E.Message;
      end;
    end;
    if prog <> nil then prog.Free;
    Report(rejected and (Pos(AWantFragment, msg) > 0),
           AName + ' (wanted "' + AWantFragment + '", got "' + msg + '")');
  finally
    comp.Free;
  end;
end;

{ The other half of a ceiling: it must not reject what it was never aimed at.
  A guard that says no to ordinary nesting is a worse bug than the crash. }
procedure CheckAccepted(const AName, ASource: String);
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  accepted: Boolean;
  msg: String;
begin
  comp := TPhosphorCompiler.Create();
  try
    prog := nil;
    msg := '';
    accepted := False;
    try
      accepted := comp.Compile(ASource, prog);
      if not accepted then msg := comp.ErrorMessage;
    except
      on E: Exception do
      begin
        accepted := False;
        msg := 'RAISED ' + E.ClassName + ': ' + E.Message;
      end;
    end;
    if prog <> nil then prog.Free;
    Report(accepted, AName + ' (rejected with "' + msg + '")');
  finally
    comp.Free;
  end;
end;

{ ErrorAtEndOfInput is the flag the REPL reads to decide whether reading another
  line could possibly help. It is a different fact from what the message says and
  cannot be recovered from the text, so it gets its own check. }
procedure CheckErrAtEof(const AName, ASource: String; AWant: Boolean);
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  got: Boolean;
begin
  comp := TPhosphorCompiler.Create();
  try
    prog := nil;
    got := not AWant;   // a raise below leaves the check failing, not passing
    try
      if not comp.Compile(ASource, prog) then got := comp.ErrorAtEndOfInput;
    except
      on E: Exception do got := not AWant;
    end;
    if prog <> nil then prog.Free;
    Report(got = AWant, AName);
  finally
    comp.Free;
  end;
end;

{ NO DIAGNOSTIC ANYWHERE MAY NAME A LINE THE FILE DOES NOT HAVE, AND THE TWO FACTS
  THE PROMPT READS MAY NEVER DISAGREE -- BOTH SWEPT OVER A RANGE NOBODY CHOSE.

  The checks below this one are a list someone wrote, and a list cannot find the
  case its author did not think of. That is not hypothetical here: the first
  attempt at this work generated 270 malformed sources, reported the class closed,
  and had missed the multi-line JSON literal entirely, because every source it
  generated was a malformed BLOCK.

  So this takes the project's OWN corpus -- every .bas the suite, the classic
  runner, the negative corpus, the examples and the package tests contain -- and
  truncates each file at every line, with and without a trailing newline, asking
  one question of each: is the line it reported inside the file it compiled? A
  truncated program is the general shape of "the input ran out", so this reaches
  every construct the project actually uses rather than the ones a test author
  remembered.

  IN-PROCESS ON PURPOSE. The same sweep driven from a shell is one process per
  compile and runs for a quarter of an hour, which is why it would have been a
  script nobody runs. Through TPhosphorCompiler it is thousands of compiles in
  seconds and the suite can afford it on every run.

  It finds the corpus from the BINARY's own path, not the working directory, so it
  answers the same whoever starts it -- and it fails rather than passes when it
  finds nothing, because a sweep that silently sweeps zero files is the exact
  shape of a verification stage that can never reject.

  THE SECOND QUESTION IS THE FLAG HALF, and it is asked here because asking it
  anywhere else did not work. The line above is what a PERSON reads; a host with a
  prompt reads ErrorAtEndOfInput and ErrorUnterminatedBlock instead, and a
  construct that runs out of input, reports the right line and forgets to record
  the fact would pass the line question and still wedge -- or, at this prompt,
  reject -- every user who typed it. A review measured the obvious gate for that
  and it did not hold: "every refusal where the lexer is sitting at the end of the
  input is an unterminated one" had 2046 counter-examples out of 4886 here, every
  one of them `undefined label X`, because that check runs AFTER the parse has
  consumed the file and the lexer is parked at the end by then. The answer was not
  a softer proxy but the one the flag was always supposed to carry: Fail now asks
  whether the PARSER ran out of input, not where the lexer is (TPhosphorCompiler
  gained FParseDone for it), and with that the two flags agree on every one of
  these refusals. So they are asserted to agree -- which fails in both directions.
  A construct that runs out of input without recording it splits them one way; a
  FailUnterminated site added without its tkEOF guard splits them the other, which
  is the belt the console host's `and` is there to be.

  BOTH DIRECTIONS ARE REACHED HERE, and the paragraph that used to sit in this
  place is worth remembering because it was wrong in both directions at once.

  It said the sweep STILL CANNOT REACH the second, because a FailUnterminated
  firing at a REAL token needs a wrong token where a terminator belongs "which a
  truncation never produces". Right about truncation, wrong about the sweep: PUT
  the token there. Every truncation this loop already refuses as unterminated is
  compiled once more with an identifier no block form terminates on appended, and
  nothing may then be recorded as unterminated at a real token. About 1074 extra
  compiles over roughly 26000, inside run-to-run noise; it finds six counter-
  examples the moment ParseSelect's tkEOF guard is removed, named by file and cut.

  And it credited TWO witnesses for that direction -- the misspelled-case-label
  expectation below, and tests/classic/15_repl_bad_case.repl. Measured by removing
  that guard and rebuilding both binaries: ONE goes red. The .repl cannot ever go
  red, because direction B means ErrorUnterminatedBlock while not
  ErrorAtEndOfInput, and the host's `and` at phosphor.lpr:1201 turns that into a
  rejection -- which is the belt doing its job, so the transcript is byte-identical
  by construction. The comment named the belt's VICTIM as the belt's WITNESS. A
  ninth block form is now covered mechanically rather than by anyone remembering
  to add an expectation for it. }
procedure CheckNoPhantomLinesInCorpus;
const
  Dirs: array[0..4] of String = ('tests/suite', 'tests/classic', 'tests/negative',
                                 'examples', 'tests/packages');
var
  root, dir, text, blob: String;
  files: TStringList;
  rec: TSearchRec;
  comp: TPhosphorCompiler;
  prog: TProgram;
  d, f, cut, i, nl, reported, phantoms, runs: Integer;
  split, waiting: Integer;
  src: TStringList;
  worst, worstSplit: String;
  { DIRECTION B: one extra compile per truncation that is already open, with an
    identifier no block form terminates on put where the terminator would go. }
  comp2: TPhosphorCompiler;
  prog2: TProgram;
  intruded, realTok: Integer;
  worstReal: String;
begin
  root := IncludeTrailingPathDelimiter(
            ExpandFileName(ExtractFilePath(ParamStr(0)) + '..'));
  files := TStringList.Create();
  src := TStringList.Create();
  try
    for d := Low(Dirs) to High(Dirs) do
    begin
      dir := IncludeTrailingPathDelimiter(root + StringReplace(Dirs[d], '/',
               PathDelim, [rfReplaceAll]));
      if FindFirst(dir + '*.bas', faAnyFile, rec) = 0 then
      begin
        repeat
          if (rec.Attr and faDirectory) = 0 then files.Add(dir + rec.Name);
        until FindNext(rec) <> 0;
        FindClose(rec);
      end;
    end;
    { A sweep with nothing in it would pass every assertion below. }
    Report(files.Count >= 50,
           'the corpus sweep found the corpus (' + IntToStr(files.Count) +
           ' .bas files under ' + root + ')');
    if files.Count = 0 then Exit;

    phantoms := 0;
    runs := 0;
    split := 0;
    waiting := 0;
    worst := '';
    worstSplit := '';
    intruded := 0;
    realTok := 0;
    worstReal := '';
    for f := 0 to files.Count - 1 do
    begin
      src.LoadFromFile(files[f]);
      { Joined with an explicit #10 rather than with TStringList.Text, which uses
        the platform's LineEnding and would hand this sweep CRLF-separated sources
        on Windows and LF-separated ones on Linux. The whole subject here is which
        line a diagnostic names when the input runs out, so feeding the two
        operating systems different bytes is the one thing that would make the
        answer differ between them for a reason that is not the engine's. }
      for cut := 1 to src.Count do
      begin
        text := '';
        for i := 0 to cut - 1 do
        begin
          if i > 0 then text := text + #10;
          text := text + src[i];
        end;
        for nl := 0 to 1 do
        begin
          if nl = 0 then blob := text + #10 else blob := text;
          if blob = '' then Continue;
          comp := TPhosphorCompiler.Create();
          try
            prog := nil;
            try
              if not comp.Compile(blob, prog) then
              begin
                reported := comp.ErrorLine;
                Inc(runs);
                if reported > cut then
                begin
                  Inc(phantoms);
                  if worst = '' then
                    worst := ExtractFileName(files[f]) + ' cut to ' +
                             IntToStr(cut) + ' lines (trailing newline=' +
                             IntToStr(1 - nl) + ') reported line ' +
                             IntToStr(reported) + ': ' + comp.ErrorMessage;
                end;
                if comp.ErrorAtEndOfInput <> comp.ErrorUnterminatedBlock then
                begin
                  Inc(split);
                  if worstSplit = '' then
                    worstSplit := ExtractFileName(files[f]) + ' cut to ' +
                                  IntToStr(cut) + ' lines (trailing newline=' +
                                  IntToStr(1 - nl) + ') at end of input=' +
                                  BoolToStr(comp.ErrorAtEndOfInput, True) +
                                  ' unterminated=' +
                                  BoolToStr(comp.ErrorUnterminatedBlock, True) +
                                  ': ' + comp.ErrorMessage;
                end
                else if comp.ErrorAtEndOfInput then
                  Inc(waiting);
                { Direction B is reached by PUTTING a wrong token where the
                  terminator belongs, not by cutting tokens away -- which is why
                  the truncation sweep alone could never see it. Only where
                  something really is open, and only on one newline variant, so
                  it costs one extra compile per OPEN truncation rather than one
                  per truncation: measured at about 1074 extra compiles over
                  roughly 26000, inside run-to-run noise. }
                if comp.ErrorUnterminatedBlock and (nl = 0) then
                begin
                  comp2 := TPhosphorCompiler.Create();
                  try
                    prog2 := nil;
                    if not comp2.Compile(text + #10 + 'zzq_not_a_terminator' + #10,
                                         prog2) then
                    begin
                      Inc(intruded);
                      if comp2.ErrorUnterminatedBlock and
                         (not comp2.ErrorAtEndOfInput) then
                      begin
                        Inc(realTok);
                        if worstReal = '' then
                          worstReal := ExtractFileName(files[f]) + ' cut to ' +
                                       IntToStr(cut) + ' lines + one token: ' +
                                       comp2.ErrorMessage;
                      end;
                    end;
                    if prog2 <> nil then prog2.Free;
                  finally
                    comp2.Free;
                  end;
                end;
              end;
            except
              on E: Exception do
              begin
                Inc(phantoms);
                if worst = '' then
                  worst := ExtractFileName(files[f]) + ' cut to ' + IntToStr(cut) +
                           ' RAISED ' + E.ClassName;
              end;
            end;
            if prog <> nil then prog.Free;
          finally
            comp.Free;
          end;
        end;
      end;
    end;
    { The refusals have to be real ones, or "no phantom" means "nothing refused". }
    Report(runs > 1000, 'and the sweep actually reached ' + IntToStr(runs) +
           ' refused compiles to judge');
    Report(phantoms = 0, 'no diagnostic names a line past the end of its file (' +
           IntToStr(phantoms) + ' over ' + IntToStr(runs) + ' refusals; first: ' +
           worst + ')');
    { Both of these, or the one below passes by never meeting the case: if nothing
      in the corpus ever ran out of input, "the two flags agree" would be a
      statement about 4886 Falses. }
    Report(waiting > 500, 'and it reached ' + IntToStr(waiting) +
           ' refusals that a prompt should WAIT on, to judge the pair against');
    Report(split = 0, 'the end-of-input and unterminated flags never disagree (' +
           IntToStr(split) + ' over ' + IntToStr(runs) + ' refusals; first: ' +
           worstSplit + ')');
    Report(intruded > 200, 'and the intruder pass reached ' + IntToStr(intruded) +
           ' open truncations with a wrong token where the terminator belongs');
    Report(realTok = 0, 'nothing is recorded as unterminated at a REAL token (' +
           IntToStr(realTok) + ' over ' + IntToStr(intruded) + '; first: ' +
           worstReal + ')');
  finally
    src.Free;
    files.Free;
  end;
end;

{ THE WHOLE DIAGNOSTIC, NOT JUST THE FACT THAT ONE HAPPENED.

  The negative corpus judges a bad program on its exit code alone, so the LINE a
  compile error names, and the words it uses, were pinned by nothing anywhere in
  this tree. That is how every unterminated block came to report the end of the
  file -- a location with nothing in it to fix, and, for a file that ends with a
  newline, a line one PAST the last, which no editor can even open. It went green
  for months.

  Line, text and the unterminated-block flag are asserted together because the
  console host reads two of the three and a person reads the other. }
procedure CheckDiag(const AName, ASource: String; AWantLine: Integer;
  const AWantMsg: String; AWantUnterminated: Boolean);
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  gotLine: Integer;
  gotMsg: String;
  gotUnterm: Boolean;
begin
  comp := TPhosphorCompiler.Create();
  try
    prog := nil;
    gotLine := -1;
    gotMsg := '(compiled -- no diagnostic at all)';
    gotUnterm := not AWantUnterminated;   // a raise leaves the check failing
    try
      if not comp.Compile(ASource, prog) then
      begin
        gotLine := comp.ErrorLine;
        gotMsg := comp.ErrorMessage;
        gotUnterm := comp.ErrorUnterminatedBlock;
      end;
    except
      on E: Exception do gotMsg := 'RAISED ' + E.ClassName + ': ' + E.Message;
    end;
    if prog <> nil then prog.Free;
    Report((gotLine = AWantLine) and (gotMsg = AWantMsg) and
           (gotUnterm = AWantUnterminated),
           AName + ' (line ' + IntToStr(gotLine) + ', "' + gotMsg +
           '", unterminated=' + BoolToStr(gotUnterm, True) + ')');
  finally
    comp.Free;
  end;
end;

{ NEITHER COMPILE FLAG MAY OUTLIVE THE COMPILE THAT SET IT, THROUGH ANY DOOR.

  Both are set in one place -- TPhosphorEngine.CompileSource, on failure -- and
  every other entry point clears FErrorLine and FErrorMessage while leaving these
  alone. So a host that asked ErrorUnterminatedBlock after a RUNTIME error was
  answered about the last compile that failed, whenever that was. The REPL asks
  exactly there, and the price of a stale True is a prompt that waits for a
  terminator nobody is typing.

  THE FIRST VERSION OF THIS CHECK TESTED ONLY THE HALF THAT HAD BEEN FIXED, which
  is worse than testing nothing because it reads as covered. It drove Run, Run,
  Run -- and all three of those reach CompileSource, which is where the clear had
  been put. TPhosphorEngine has six doors and TWO OF THEM NEVER COMPILE ANYTHING:
  RunBytecode reads a .pbc through ReadProgram, and CallFunction runs on a VM that
  Prepare already built. Both wrote their own failure into ErrorMessage and left
  both flags describing a compile from three calls earlier -- the new public
  property this work adds, and the one docs/embedding.md now tells embedders to
  read, answering about the wrong failure.

  So every door gets a case here, and each is preceded by a Report that the run
  actually reached the state being asked about: without those, a Run that stopped
  failing would make the flag check pass by never getting near the question. }
procedure CheckFlagsDoNotGoStale;
const
  LFc = #10;
var
  eng: TPhosphorEngine;
  comp: TPhosphorCompiler;
  prog: TProgram;
  junk: TMemoryStream;
  notBytecode: String;
  v: TValue;
begin
  { The same question one level down, at the compiler, where a host holding ONE
    TPhosphorCompiler asks it. Compile clears FFailed, FErr and FErrLine on the way
    in; until these two were added to that line, a second compile that SUCCEEDED
    left both standing from the first one that had not. }
  comp := TPhosphorCompiler.Create();
  try
    prog := nil;
    Report(not comp.Compile('if 1 = 1 then' + LFc + '  println "x"' + LFc, prog),
           'the reused-compiler check starts from a compile that failed');
    if prog <> nil then begin prog.Free; prog := nil; end;
    Report(comp.ErrorUnterminatedBlock, 'and the first compile set the flag');
    Report(comp.Compile('println 1' + LFc, prog),
           'and then the SAME compiler compiles a good program');
    if prog <> nil then prog.Free;
    Report(not (comp.ErrorUnterminatedBlock or comp.ErrorAtEndOfInput),
           'a reused compiler does not inherit the previous failure''s flags');
  finally
    comp.Free;
  end;

  eng := TPhosphorEngine.Create();
  try
    Report(eng.Run('a = 1' + LFc + 'if a = 1 then' + LFc + '  println "x"' + LFc) <> 0,
           'the stale-flag check starts from a run that really did fail to compile');
    Report(eng.ErrorUnterminatedBlock and eng.ErrorAtEndOfInput,
           'an unterminated block sets both compile flags');

    { Compiles; fails while RUNNING -- measured, "division by zero" at line 2. d is
      a variable, so nothing folds the division away at compile time. The first
      Report here is not ceremony: without it a Run that stopped failing would make
      the flag check below pass by never getting near the question. }
    Report(eng.Run('d = 0' + LFc + 'x = 1 / d' + LFc) <> 0,
           'and reaches a genuine runtime fault after it');
    Report(not (eng.ErrorUnterminatedBlock or eng.ErrorAtEndOfInput),
           'a runtime fault does not leave the previous compile''s flags standing');

    Report(eng.Run('x = 1 + 1' + LFc) = 0, 'and then a run that succeeds');
    Report(not (eng.ErrorUnterminatedBlock or eng.ErrorAtEndOfInput),
           'a clean run does not leave them standing either');

    { THE TWO DOORS THAT NEVER REACH CompileSource. Set the flags again first, so
      each of these starts from a genuine stale True rather than from a state that
      happened to be clean already. }
    Report(eng.Run('a = 1' + LFc + 'for i = 1 to 3' + LFc + '  println i' + LFc) <> 0,
           'the bytecode door starts from a compile that failed');
    Report(eng.ErrorUnterminatedBlock and eng.ErrorAtEndOfInput,
           'and that compile really did set both flags');
    junk := TMemoryStream.Create();
    try
      (* Not a .pbc: ReadProgram rejects it on the magic, which is a failure that
         never goes near the compiler. The two non-printing bytes are built with
         Chr() rather than written as literals -- every unit here sets the UTF8
         codepage directive, which turns a byte above 127 in a LITERAL into two.
         Both of these are ASCII and would have survived, but the habit is the
         point: the next person who reaches for a high byte here must not learn
         the wrong lesson from this line. *)
      notBytecode := 'not a phosphor bytecode file' + Chr(10) + Chr(0) + Chr(1);
      junk.Write(notBytecode[1], Length(notBytecode));
      junk.Position := 0;
      Report(eng.RunBytecode(junk) <> 0, 'and RunBytecode rejects a stream that is not bytecode');
    finally
      junk.Free;
    end;
    Report(not (eng.ErrorUnterminatedBlock or eng.ErrorAtEndOfInput),
           'a bad bytecode stream does not answer about the previous compile');

    Report(eng.Run('a = 1' + LFc + 'while a < 2' + LFc + '  a = a + 1' + LFc) <> 0,
           'the CallFunction door starts from a compile that failed');
    Report(eng.ErrorUnterminatedBlock and eng.ErrorAtEndOfInput,
           'and that compile really did set both flags too');
    v := eng.CallFunction('nosuch', []);
    Report(eng.LastError.Code <> peNone, 'and CallFunction with nothing prepared fails');
    Report(not (eng.ErrorUnterminatedBlock or eng.ErrorAtEndOfInput),
           'a CallFunction failure does not answer about the previous compile');
    Report(v.Kind = vkDouble, 'and hands back the default value');

    { The same door reached the way an embedder reaches it -- Prepare refuses the
      source, so there is no VM and the very next call is CallFunction.

      The OTHER branch of CallFunction, the one with a VM actually prepared, cannot
      be reached with a stale flag at all, and that was checked rather than assumed:
      a successful Prepare clears the state, and every door that could set the flags
      afterwards (Run, Prepare, ReplRun) calls Finish first and discards the prepared
      VM, so by the time the flags are True there is no VM left to call into. }
    Report(eng.Prepare('a = 1' + LFc + 'repeat' + LFc + '  a = a + 1' + LFc) <> 0,
           'a Prepare that cannot compile fails');
    Report(eng.ErrorUnterminatedBlock, 'and sets the unterminated flag');
    v := eng.CallFunction('nosuch', []);
    Report(eng.LastError.Code <> peNone, 'and the call that follows it fails too');
    Report(not (eng.ErrorUnterminatedBlock or eng.ErrorAtEndOfInput),
           'a call after a refused Prepare does not answer about that Prepare');
  finally
    eng.Free;
  end;
end;

{ Repeat AUnit ACount times -- the generated sources below. }
function Repeated(const AUnit: String; ACount: Integer): String;
var i: Integer;
begin
  Result := '';
  for i := 1 to ACount do Result := Result + AUnit;
end;

const
  LF = #10;
  // Tight infinite loops (no output).
  ForeverLoop = 'top:' + LF + 'x = x + 1' + LF + 'goto top' + LF;
  // Infinite output.
  ForeverPrint = 'top:' + LF + 'print "x"' + LF + 'goto top' + LF;
  // Tries to catch the limit and keep going -- must NOT be able to.
  CatchAndLoop = 'on error goto h' + LF + 'top:' + LF + 'x = x + 1' + LF +
                 'goto top' + LF + 'h:' + LF + 'resume next' + LF;

  { A CEILING CROSSED INSIDE A NESTED ACTIVATION IS STILL FATAL.

    `callfunc` is a library function that re-enters the interpreter, so when the
    body it runs crosses a ceiling, the peLimit travels back to opCall looking
    exactly like a library that returned an error -- and opCall's ON ERROR path
    would have caught it. That was closed by refusing every peLimit at that
    branch, on a grep that found no library producing one.

    One patch later the budget lane gave the libraries their own refusals
    (`string$: that would take 2147483647 units of work`), which are catchable BY
    DESIGN: nothing has been spent and a program that catches one and asks for
    less is behaving correctly. So the code alone can no longer tell the two
    apart, and the VM now discriminates on where the peLimit came from.

    This pins the half that has no other test. Its twin -- a library refusal
    stays catchable -- is pinned by probe_budget's "catching a refusal builds
    nothing" and "a refused write does not poison the next file_copy", which are
    the two that went red when the two patches were first integrated.

    IT IS THE FRAME CEILING AND NOT THE STEP BUDGET ON PURPOSE, and it runs with
    every ceiling at 0 for that reason. FSteps is shared with the outer loop, so
    a step budget crossed inside a callback RE-FIRES one instruction later and
    would be fatal with this rule or without it -- a pin on it passes either way
    and measures nothing. FFrameSP is restored by CallUserFunc, so the frame
    ceiling is the one that genuinely escapes. Measured both ways before this was
    written: with the rule, rc=5 code=7 "call depth limit exceeded (262144
    activation frames)"; with the rule forced False, rc=0 and the program printed
    its continuation line. }
  LimitInsideCallfunc =
    'on error goto h' + LF +
    'function rec(n)' + LF +
    '  return rec(n + 1)' + LF +
    'end function' + LF +
    'y = callfunc("rec", 1)' + LF +
    'println "the handler resumed and the program continued"' + LF +
    'end' + LF +
    'h:' + LF +
    'resume next' + LF;

{ ----------------------------------------------------------------------------
  A FAULT IN THE INTERPRETER IS NOT AN ERROR IN THE PROGRAM.

  Every other check in this file is about a ceiling the SCRIPT crossed. These are
  about something that happened TO the interpreter -- an access violation, a
  stack overflow, a corrupt heap -- and the engine now answers three separate
  questions about one:

    is it offered to ON ERROR?              never, whatever else is true
    does it end the run?                    always
    does it end the PROCESS?                only if ContainFaults is False

  The first is the one worth arguing about, and the argument is in peFatal: a
  wild write has already landed by the time the exception fires, so a script that
  catches it and carries on answers wrongly instead of dying, and a wrong answer
  nobody is told about is worse than a crash. So ON ERROR is not offered it even
  though the engine is perfectly able to offer it.

  The faults here are RAISED ON PURPOSE by a test-only library function and a
  test-only output callback -- one inside opCall's net, one outside it, because
  those are two different code paths and only the second one needs ContainFaults.
  Neither lives in the shipped engine.
---------------------------------------------------------------------------- }

function t_boom(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  E := NoError();
  raise EAccessViolation.Create('a deliberate fault from a library function');
end;

function t_convert(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  E := NoError();
  { THE MIRROR. A value error from a library must stay catchable -- this is the
    direction a guard written in a hurry breaks, and it has broken twice in this
    project already. }
  raise EConvertError.Create('an ordinary bad argument');
end;

var
  BoomOnOutput: Boolean = False;

type
  { A CLASS because OnOutput is a method pointer (`of object`) and a free
    procedure cannot be assigned to one -- the same trap phosphorguitest hit with
    Application.OnException, and it costs a compile error rather than anything
    silent. }
  TFaultingOutput = class
    class procedure Emit(const S: String);
  end;

class procedure TFaultingOutput.Emit(const S: String);
begin
  { Raised from a HOST CALLBACK, which the dispatch loop calls outside opCall's
    try/except -- so this one leaves ExecFrom as a Pascal exception and is the
    case ContainFaults exists for. }
  if BoomOnOutput then
    raise EAccessViolation.Create('a deliberate fault from a host callback');
end;

{ Run ASource with the fault library registered; report what came back. }
{ A REFUSAL THAT LEAKS IS A WORSE BUG THAN WHAT IT REFUSES, and no .bas
  assertion can see one.

  The JSON graft gates (PhosphorJsonLib, SetMember and AddItem) free the node they
  refuse, because the caller has already CLONED it by the time the gate is asked --
  `AddItem(a, level, v.Clone, Err)`. Deleting those two Free calls leaves every
  assertion in tests/suite/27_json.bas green and every runner on both operating
  systems at exit 0, while the process climbs to 4.2 GB against the 13.9 MB it
  holds to now. Measured, by the review that asked for this check.

  So the question is asked the only way it can be: run the SAME work twice with
  different refusal counts and watch the heap high-water. A gate that frees is flat
  in the count; one that leaks is linear in it. The bound is deliberately loose --
  the leak is two orders of magnitude past it, and a tight bound here would be a
  probe that fails on a busy machine. }
procedure CheckRefusedGraftDoesNotLeak;
const
  { Build to the ceiling, then offer a 601-node subtree over and over. Every offer
    is cloned, refused, and must be freed. }
  Sc =
    'root@ = json_array@()' + LF +
    'cur@ = root@' + LF +
    'for i% = 1 to 255' + LF +
    '  n@ = json_array@()' + LF +
    '  x@ = json_push@(cur@, n@)' + LF +
    '  cur@ = json_item@(cur@, 1)' + LF +
    'next' + LF +
    'sub@ = json_array@()' + LF +
    'for i% = 1 to 600' + LF +
    '  x@ = json_pushn@(sub@, i%)' + LF +
    'next' + LF +
    'refused = 0' + LF +
    'seen = 0' + LF +
    'on error goto oops' + LF +
    'for r% = 1 to REPS' + LF +
    '  x@ = json_push@(cur@, sub@)' + LF +
    { NOT THE LAST STATEMENT IN THE BODY, and that is load-bearing. `resume next`
      on the last statement of a block leaves the BLOCK -- gauntlet finding 7,
      still open as this is written -- so with the push last the loop ran ONE pass
      and this check measured 200 refusals against 1 instead of 200 against 10,000.
      It went green with both Free calls deleted, twice, before the count was
      printed and the script was found to be the thing that was wrong. }
    '  seen = seen + 1' + LF +
    'next' + LF +
    'goto done' + LF +
    'oops:' + LF +
    'refused = refused + 1' + LF +
    'resume next' + LF +
    'done:' + LF +
    'on error goto 0' + LF;
var
  eng: TPhosphorEngine;
  small, big: PtrUInt;
  rc: Integer;

  function RunWith(AReps: Integer): PtrUInt;
  var
    src: String;
  begin
    src := StringReplace(Sc, 'REPS', IntToStr(AReps), [rfReplaceAll]);
    eng := TPhosphorEngine.Create();
    try
      rc := eng.Run(src);
      Report(rc = 0, 'the refusal run at ' + IntToStr(AReps) + ' completed');
    finally
      eng.Free();
    end;
    { CurrHeapUsed, sampled AFTER the engine is freed -- so what is still held is
      what nobody owns. MaxHeapUsed was the first spelling and it does not answer
      this: it is a high-water over the whole process, and the tree the script
      builds legitimately dwarfs the difference the leak makes at these counts.
      The check went green with both Free calls deleted, which is how it was
      caught before it shipped. }
    Result := GetFPCHeapStatus().CurrHeapUsed;
  end;

begin
  small := RunWith(200);
  big := RunWith(10000);
  { 9,800 more refusals of a 601-node subtree, and every one of them freed. What
    is still allocated once the engine is gone must not scale with the count. }
  Report(big < small + (16 * 1024 * 1024),
         'a refused graft frees what it refused (still held after the engine went: ' +
         IntToStr(big div 1024) + ' KB against ' + IntToStr(small div 1024) +
         ' KB, over 9,800 more refusals)');
end;

procedure CheckFault(const AName, ASource: String; AContain, AFaultOnOutput: Boolean;
  AWantCode: TPhosphorErrorCode; AWantRc0: Boolean);
var
  eng: TPhosphorEngine;
  rc: Integer;
  raised: Boolean;
begin
  eng := TPhosphorEngine.Create();
  raised := False;
  try
    eng.ContainFaults := AContain;
    eng.Registry.Add('boom:', @t_boom);
    eng.Registry.Add('badarg:', @t_convert);
    BoomOnOutput := AFaultOnOutput;
    if AFaultOnOutput then eng.OnOutput := @TFaultingOutput.Emit;
    try
      rc := eng.Run(ASource);
    except
      on E: Exception do begin raised := True; rc := -1; end;
    end;
    BoomOnOutput := False;
    if AWantRc0 then
      Report((not raised) and (rc = 0), AName)
    else
      Report((not raised) and (rc <> 0) and (eng.LastError.Code = AWantCode),
             AName);
  finally
    eng.Free;
  end;
end;

{ The same, but asserting that the exception DOES escape -- the default. }
procedure CheckFaultEscapes(const AName, ASource: String);
var
  eng: TPhosphorEngine;
  escaped: Boolean;
begin
  eng := TPhosphorEngine.Create();
  escaped := False;
  try
    eng.ContainFaults := False;
    BoomOnOutput := True;
    eng.OnOutput := @TFaultingOutput.Emit;
    try
      eng.Run(ASource);
    except
      on E: EAccessViolation do escaped := True;
    end;
    BoomOnOutput := False;
    Report(escaped, AName);
  finally
    eng.Free;
  end;
end;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  // Step budget bounds an infinite loop.
  Check('step budget', ForeverLoop, 200000, 0, 0, not ProveFail);

  // Output ceiling bounds infinite output.
  Check('output ceiling', ForeverPrint, 0, 50, 0, True);

  // Wall-clock ceiling bounds a loop that produces neither steps-cap nor output.
  Check('time ceiling', ForeverLoop, 0, 0, 50, True);

  // A normal script within generous ceilings runs clean.
  Check('within ceilings runs', 'a = 2 + 3' + LF + 'b = a * a' + LF,
        1000000, 1000, 5000, False);

  // A ceiling is fatal: ON ERROR cannot catch it and loop forever.
  Check('ON ERROR cannot escape a limit', CatchAndLoop, 200000, 0, 0, True);

  // ...including one crossed inside a callback that re-entered the interpreter,
  // which reaches opCall as an ordinary library error. See LimitInsideCallfunc.
  Check('ON ERROR cannot escape a limit crossed inside callfunc',
        LimitInsideCallfunc, 0, 0, 0, True);

  { --- a fault in the interpreter; see the section above --------------------- }

  // Inside opCall's net. The net catches it either way -- what changed is that it
  // is no longer offered to ON ERROR, and no longer wears peRuntime.
  CheckFault('a library fault is peFatal, not a catchable peRuntime',
             'x = boom()' + LF, False, False, peFatal, False);
  CheckFault('...and ON ERROR is not offered it',
             'on error goto h' + LF + 'x = boom()' + LF +
             'println "resumed"' + LF + 'end' + LF + 'h:' + LF +
             'resume next' + LF, False, False, peFatal, False);

  // THE MIRROR, and the direction this project has broken twice: an ordinary
  // value error from the same seam must still be catchable and still peRuntime.
  CheckFault('a library VALUE error is still catchable by ON ERROR',
             'on error goto h' + LF + 'x = badarg()' + LF +
             'end' + LF + 'h:' + LF + 'resume next' + LF,
             False, False, peNone, True);
  CheckFault('...and uncaught it is still an ordinary peRuntime',
             'x = badarg()' + LF, False, False, peRuntime, False);

  // Outside the net: a host callback. Contained, this is a failed Run and
  // nothing reaches the host.
  CheckFault('a host-callback fault is contained when asked',
             'println "hello"' + LF, True, True, peFatal, False);

  // And NOT contained by default -- the exception escapes Run exactly as it
  // always did, so a host that wants to fail fast still does.
  CheckFaultEscapes('a host-callback fault still escapes when not asked',
                    'println "hello"' + LF);

  { --- the front end: a bad FIRST character ---------------------------------
    TLexer.Tokenize gives up the moment it meets a character that cannot start a
    token, so when that character is the first one, not a single token was ever
    pushed. TLexer.Cur's fallback -- FTokens[FCount - 1] -- was then FTokens[-1]
    on a nil array, and copying a TToken out of it also copied its StrVal: String
    field, incrementing a refcount through a wild pointer. TPhosphorCompiler.Fail
    asks Cur().Kind on every failure, so EVERY lexical error at offset 1 came
    through it: `phosphor run` on a file starting with '~' died with an access
    violation instead of printing the error the SAME character prints on line 2,
    `phosphor compile` exited 0 having written nothing, and a UTF-8 BOM -- which
    every Windows editor writes -- killed the REPL on the first line of a piped
    session. }
  CheckRejected('bad first character', '~' + LF, 'unexpected character');
  CheckRejected('lone NUL byte', #0, 'unexpected character');
  CheckRejected('UTF-8 BOM before good source',
                #$EF#$BB#$BF + 'println 1 + 1' + LF, 'unexpected character');
  CheckRejected('the same character on line 2 still reports',
                'print 1' + LF + '~' + LF, 'unexpected character');

  { A lexical failure is never "the input has not finished yet". The flag is what
    tells the REPL to wait for a continuation line, and with no tokens at all the
    synthesised EOF would have read as end-of-input -- so the prompt would have
    sat waiting for a line that can never repair a bad character. }
  CheckErrAtEof('a bad first character is not end-of-input', '~' + LF, False);

  { --- the front end: a block that is never closed -------------------------
    EVERY SOURCE BELOW IS THREE LINES LONG -- four for the two select shapes,
    which need a `case` arm before they can be unfinished -- and in every one of
    them the block opens on LINE 2. The expected line is counted off the literal
    written here, not copied from a run.

    All seven used to answer the LAST line, which for a source ending in a
    newline is one PAST it: three lines of text reporting line 4. The parser
    passed FLex.Cur().Line, and where these fire the current token is the end of
    the input -- the one place in a file where the user can change nothing, and,
    at line 4 of 3, a place no editor can even scroll to. Each parser was already
    holding the opening line in `ln` and threw it away.

    The wording is not invented here either: the engine has said
    "'endif' without a matching 'if'" for the mirror mistake -- a terminator with
    no opener -- since 2026-09-06 (OrphanKeyword). These are the same sentence
    with the two halves swapped, so one mistake reads as one family.

    The third expectation is the fact the console REPL actually reads. It used to
    recover it by comparing the message against nine string literals of its own,
    which is why rewording any of these would have broken multi-line block entry
    at the prompt with nothing anywhere to say so. }
  CheckDiag('an unclosed if names the if, not the end of the file',
            'a = 1' + LF + 'if a = 1 then' + LF + '  println "x"' + LF,
            2, '''if'' on line 2 without a matching ''endif''', True);
  CheckDiag('an unclosed while names both its terminators',
            'a = 1' + LF + 'while a < 3' + LF + '  a = a + 1' + LF,
            2, '''while'' on line 2 without a matching ''endwhile'' or ''wend''', True);
  CheckDiag('an unclosed do while names the do while',
            'a = 1' + LF + 'do while a < 3' + LF + '  a = a + 1' + LF,
            2, '''do while'' on line 2 without a matching ''loop''', True);
  CheckDiag('an unclosed repeat names the repeat',
            'a = 1' + LF + 'repeat' + LF + '  a = a + 1' + LF,
            2, '''repeat'' on line 2 without a matching ''until''', True);
  CheckDiag('an unclosed for names the for',
            'a = 1' + LF + 'for i = 1 to 3' + LF + '  println i' + LF,
            2, '''for'' on line 2 without a matching ''next''', True);
  CheckDiag('an unclosed function names the function',
            'a = 1' + LF + 'function f(n)' + LF + '  return n' + LF,
            2, '''function'' on line 2 without a matching ''endfunction''', True);
  CheckDiag('an unclosed select names the select',
            'a = 1' + LF + 'select case a' + LF + 'case 1' + LF + '  println 1' + LF,
            2, '''select case'' on line 2 without a matching ''endselect''', True);
  CheckDiag('an unclosed select with a case else names the select too',
            'a = 1' + LF + 'select case a' + LF + 'case else' + LF + '  println 1' + LF,
            2, '''select case'' on line 2 without a matching ''endselect''', True);

  { A source with NO trailing newline reports the same line as the one with it.
    Worth its own check because the phantom only LOOKS impossible when the file
    ends in a newline: without one the old code answered the last real line, so a
    builder verifying this with a newline-less file would have seen a plausible
    number and concluded nothing was wrong. }
  CheckDiag('and the same answer when the file does not end in a newline',
            'a = 1' + LF + 'if a = 1 then' + LF + '  println "x"',
            2, '''if'' on line 2 without a matching ''endif''', True);

  { NESTED: the INNER block is the one that is unfinished, and it is the inner
    opener that has to be named. The outer `if` on line 1 is not the mistake. }
  CheckDiag('a nested unclosed block names the inner opener',
            'if 1 = 1 then' + LF + 'for i = 1 to 3' + LF + '  println i' + LF,
            2, '''for'' on line 2 without a matching ''next''', True);

  { A MULTI-LINE JSON LITERAL IS THE SECOND HALF OF THE SAME DEFECT, and it is the
    half that a sweep of malformed BLOCKS could not have found -- it is reached
    through the expression parser, not through ParseBlockUntil, and it carried the
    phantom line out under FOUR different messages (the key test, the two Expects,
    and "unexpected token in expression").

    It was found by truncating the project's own corpus at every line rather than
    by generating more malformed sources: tests/suite/45_json_literals.bas cut to
    97 lines reported line 98. Reduced, it is two lines of source -- an assignment
    and an opening brace -- answering line 3.

    Newlines are ignored inside a literal, which means SkipEols, and SkipEols was
    the only read left in the compiler that could walk past the last real line onto
    the synthesised end-of-input token. Everywhere else the parser stops at a real
    token on a real line, which is why `b = a +` at the end of a file has always
    reported correctly and this did not.

    Each source below is counted off the literal written here. The container that
    is named is the INNERMOST one still open, which is the one the author has to
    close first. }
  CheckDiag('an unclosed json object names the brace, not the end of the file',
            'a = 1' + LF + 'big@ = {' + LF,
            2, '''{'' on line 2 without a matching ''}''', True);
  CheckDiag('an unclosed json array names the bracket',
            'a = 1' + LF + 'big@ = [' + LF,
            2, '''['' on line 2 without a matching '']''', True);
  CheckDiag('an unclosed json literal is named without a trailing newline too',
            'a = 1' + LF + 'big@ = {',
            2, '''{'' on line 2 without a matching ''}''', True);
  CheckDiag('a nested json literal names the inner container',
            'a = 1' + LF + 'big@ = {' + LF + '  "u": [' + LF,
            3, '''['' on line 3 without a matching '']''', True);
  CheckDiag('a json literal that stops after a comma still names its opener',
            'a = 1' + LF + 'big@ = [' + LF + '  1,' + LF,
            2, '''['' on line 2 without a matching '']''', True);
  CheckDiag('a json object that stops after a key and colon names its opener',
            'a = 1' + LF + 'big@ = {' + LF + '  "n":' + LF,
            2, '''{'' on line 2 without a matching ''}''', True);

  { The three checks INSIDE the literal keep their own wording, because none of
    them can see the end of input any more and each is still right about the real
    token it does see. Asserting that is the guard against the obvious overshoot --
    redirecting every failure inside a literal to the opening brace, which would
    blame a correct literal for a mistake several lines below it. }
  CheckDiag('a json key that is not a string still blames the key',
            'a = 1' + LF + 'big@ = {' + LF + '  1: 2' + LF + '}' + LF,
            3, 'a JSON object key must be a string', False);
  CheckDiag('a json literal closed by the wrong bracket still blames the bracket',
            'a = 1' + LF + 'big@ = [' + LF + '  1' + LF + '}' + LF,
            4, 'expected '']''', False);

  { --- and the two that are NOT unterminated blocks, which is the whole point --
    `select case` is the one terminator check in the compiler that also fires on
    a TOKEN. A misspelled label is a mistake on ITS OWN line, inside a select that
    is not unfinished at all, and blaming the select three lines above would be
    the fix overshooting. The flag has to answer False here or the REPL waits for
    a continuation that can never arrive -- which is the defect
    tests/classic/15_repl_bad_case.repl exists to pin, reached from Pascal.

    A select header with no `case` is likewise a malformed LINE: the current
    token is the end of that line, so the line it reports is already the
    actionable one. Left exactly as it was, and pinned so that stays deliberate. }
  CheckDiag('a misspelled case label blames the label, not the select',
            'a = 1' + LF + 'select case a' + LF + 'csae 1' + LF + '  println 1' + LF +
            'endselect' + LF,
            3, 'expected ''case'' or ''endselect''', False);
  CheckErrAtEof('and a misspelled case label is not end-of-input',
                'a = 1' + LF + 'select case a' + LF + 'csae 1' + LF + '  println 1' + LF +
                'endselect' + LF, False);
  CheckDiag('a select header with no case blames its own line',
            'a = 1' + LF + 'select' + LF,
            2, 'expected ''case'' after ''select''', False);

  { The line rewrite must not disturb the OTHER fact each failure records. Fail
    infers ErrorAtEndOfInput from the current token, and the obvious wrong
    simplification -- inferring it from the line it was handed instead -- would
    still pass every check above. }
  CheckErrAtEof('an unclosed block is still end-of-input after the line moved',
                'a = 1' + LF + 'for i = 1 to 3' + LF + '  println i' + LF, True);

  { AND THE OTHER HALF OF THAT FACT: a failure the parser did not raise is not "the
    input ran out", however far the lexer has got. ResolveGotos runs after the
    statement loop has consumed the whole file, so the token in front of it is
    always tkEOF -- and `goto nowhere` therefore answered ErrorAtEndOfInput=True,
    for 2046 of the corpus sweep's 4886 refusals. Nothing wedged at the prompt,
    because the host asks for both facts and the other one is False. What it cost
    was the GATE: while a legitimate refusal can sit at the end of the input
    without being an unfinished construct, "the two flags agree" cannot be
    asserted, and the flag half of this work had nothing sweeping it at all. }
  CheckErrAtEof('a label that does not exist is not end-of-input',
                'println 1' + LF + 'goto nowhere' + LF, False);
  CheckDiag('and it blames the goto, unterminated=False',
            'println 1' + LF + 'goto nowhere' + LF,
            2, 'undefined label nowhere', False);

  { `next i` is the habit of every other BASIC. The answer used to be "expected
    end of line", produced by the statement terminator check far from ParseFor,
    which names a rule instead of the word to delete. }
  CheckDiag('next with a variable says which word to remove',
            'for i = 1 to 3' + LF + '  println i' + LF + 'next i' + LF,
            3, '''next'' takes no variable -- remove the ''i''; the ''for'' on ' +
               'line 1 already names it', False);

  { A DIAGNOSTIC THAT REFUSES A CORRECT PROGRAM IS WORSE THAN THE ONE IT REPLACED.
    Every block form closed properly, including `wend`, `end select` and a `next`
    followed by a statement separator rather than a line end. }
  CheckAccepted('every block form still compiles when it is closed',
                'a = 1' + LF +
                'if a = 1 then' + LF + '  println "y"' + LF + 'endif' + LF +
                'while a < 2' + LF + '  a = a + 1' + LF + 'endwhile' + LF +
                'b = 0' + LF + 'while b < 2' + LF + '  b = b + 1' + LF + 'wend' + LF +
                'c = 0' + LF + 'do while c < 2' + LF + '  c = c + 1' + LF + 'loop' + LF +
                'd = 0' + LF + 'repeat' + LF + '  d = d + 1' + LF + 'until d = 2' + LF +
                'for i = 1 to 2' + LF + '  println i' + LF + 'next' + LF +
                'select case a' + LF + 'case 2' + LF + '  println "two"' + LF +
                'case else' + LF + '  println "no"' + LF + 'endselect' + LF +
                'println f(3)' + LF + 'end' + LF +
                'function f(n)' + LF + '  return n * 2' + LF + 'endfunction' + LF);
  { `next :` and not `next <newline>`: the new check reads the token AFTER next,
    and a statement separator there must stay legal. (A one-line `for` header is
    a different matter -- `for i = 1 to 2 : ...` is rejected by the expression
    parser reading the limit, on this build and before it, and has nothing to do
    with this change.) }
  CheckAccepted('a nested for whose two nexts share a line still compiles',
                'for i = 1 to 2' + LF + '  for j = 1 to 2' + LF +
                '    println j' + LF + '  next : next' + LF);
  CheckAccepted('a comment after next is still a comment, not a variable',
                'for i = 1 to 2' + LF + '  println i' + LF + 'next rem done' + LF);
  CheckAccepted('next is still an ordinary name where it is not a terminator',
                'next = 5' + LF + 'println next' + LF);

  { The multi-line JSON literal the fix touches, in every shape the corpus uses:
    nested containers, a trailing element with no comma, blank lines inside the
    literal, an empty object and an empty array, and a closing bracket on its own
    line. The empty pair matter most -- they are the one path where SkipEols lands
    directly on the closing bracket, which is the case a too-eager end-of-input
    test would have refused. }
  CheckAccepted('a multi-line json literal still compiles',
                'big@ = {' + LF +
                '  "users": [' + LF +
                '    { "id": 1, "name": "a" },' + LF +
                '' + LF +
                '    { "id": 2, "name": "b" }' + LF +
                '  ],' + LF +
                '  "empty@": {},' + LF +
                '  "none@": [],' + LF +
                '  "n": null' + LF +
                '}' + LF +
                'println json_count(json_get@(big@, "users"))' + LF);
  CheckAccepted('an empty json literal spread over lines still compiles',
                'a@ = {' + LF + '}' + LF + 'b@ = [' + LF + ']' + LF);

  CheckFlagsDoNotGoStale;
  CheckNoPhantomLinesInCorpus;

  { --- the front end: a literal the machine cannot hold ---------------------
    '1' followed by 400 zeros was rejected; `1e999` was ACCEPTED, because FPC's
    TryStrToFloat returns True on it and hands back +Inf. That put a non-finite
    Double in the constant pool, falsifying the invariant FiniteD states in
    PhosphorValue, and the first operation that made a NaN of it (x - x) raised
    EInvalidOp and killed the process past an `on error goto`. }
  CheckRejected('overflowing exponent literal', 'x = 1e999' + LF, 'out of range');
  CheckRejected('overflowing exponent literal in DATA',
                'data 1e999' + LF + 'read x' + LF, 'out of range');
  CheckAccepted('the largest double still compiles',
                'x = 1.7976931348623157e308' + LF);
  CheckAccepted('an underflowing exponent is just zero', 'x = 1e-999' + LF);

  { --- the front end: every path that recurses on nesting -------------------
    The parenthesis guard covered ParseExpr and nothing else, and three other
    paths recurse on input depth without passing through it. Each killed the
    process with a stack overflow -- not an exception, so no handler and no crash
    guard ever saw it, and an embedding host went down with the script. }
  CheckRejected('unary minus chain', 'println ' + Repeated('-', 300) + '1' + LF,
                'expression nests');
  CheckRejected('unary plus chain', 'println ' + Repeated('+', 300) + '1' + LF,
                'expression nests');
  CheckRejected('signed exponent chain (ParseSignedPrimary)',
                'println 2 ^ ' + Repeated('-', 300) + '1' + LF, 'expression nests');
  CheckRejected('not chain', 'println ' + Repeated('not ', 300) + '(1 = 1)' + LF,
                'expression nests');
  CheckRejected('nested blocks',
                Repeated('if 1 = 1 then' + LF, 300) + 'print 7' + LF +
                Repeated('endif' + LF, 300), 'blocks nest');
  CheckRejected('nested blocks, one-line form',
                Repeated('if 1 = 1 then ', 300) + 'print 7' + LF, 'blocks nest');
  CheckRejected('parentheses (the ceiling that already existed)',
                'x = ' + Repeated('(', 300) + '1' + Repeated(')', 300) + LF,
                'expression nests');

  { Ordinary nesting must still compile: a ceiling that rejects real programs is
    a worse bug than the crash it was added to prevent. }
  CheckAccepted('64 nested blocks still compile',
                Repeated('if 1 = 1 then' + LF, 64) + 'print 7' + LF +
                Repeated('endif' + LF, 64));
  CheckAccepted('64 parentheses and a few signs still compile',
                'x = ' + Repeated('(', 64) + '---1' + Repeated(')', 64) + LF);

  { --- the front end: a statement that cannot do anything --------------------
    A CALL WITH THE PARENTHESES LEFT OFF WAS A LEGAL STATEMENT. `err_clear` is a
    registered zero-argument function, so the line reads as a correct call and is
    not one: the compiler read the word as a variable, emitted a load and a
    discard, and the program ran to exit 0 having cleared nothing. Every
    registered name behaves that way written bare; the zero-argument ones are the
    subset where the bare word is indistinguishable from the call. It reached
    this project's own suite -- tests/suite/53_bounds said `randomize` and drew
    from a generator that was never seeded, for five days, green.

    These live HERE rather than only in tests/negative for the reason this file's
    header gives: that harness asks only whether the exit code was non-zero, so a
    .bas file cannot tell this refusal from any other refusal, and cannot see the
    message at all. What the message SAYS is most of the value of the change. }
  CheckRejected('a registered name written bare',
                'err_clear' + LF,
                '''err_clear'' on its own does nothing -- a call needs ' +
                'parentheses: err_clear()');
  CheckRejected('the instance that was live in this suite',
                'randomize' + LF,
                '''randomize'' on its own does nothing');
  CheckRejected('a bare name as the body of an inline if',
                'if 1 = 1 then err_clear' + LF, 'on its own does nothing');
  CheckRejected('a bare name in the else arm of an inline if',
                'if 1 = 1 then x = 1 else err_clear' + LF,
                'on its own does nothing');
  CheckRejected('a bare name after a '':'' separator',
                'x = 1 : err_clear' + LF, 'on its own does nothing');
  CheckRejected('a bare name inside a function body',
                'function g()' + LF + '  err_clear' + LF + '  return 0' + LF +
                'endfunction' + LF + 'x = g()' + LF, 'on its own does nothing');
  CheckRejected('a bare name inside a loop body',
                'for i = 1 to 2' + LF + '  err_clear' + LF + 'next' + LF,
                'on its own does nothing');
  { ParseBlockUntil accepts a terminator with no separator in front of it, so
    this shape ends the statement as surely as a newline does and has to be
    judged the same way -- the follower test would otherwise let it through. }
  CheckRejected('a bare name with no separator before its terminator',
                'for i = 1 to 2' + LF + '  err_clear next' + LF,
                'on its own does nothing');
  { The wider half of the same rule: not every effect-free statement is a name. }
  CheckRejected('a bare arithmetic expression',
                'x = 1' + LF + 'x + 1' + LF,
                'computes a value and discards it');
  CheckRejected('a bare literal', 'true' + LF,
                'computes a value and discards it');
  CheckRejected('a bare file query', 'eof(#1)' + LF,
                'computes a value and discards it');
  { ...and it says what was actually LOOKED FOR. An indexed read and a JSON
    literal discard a value too, and are accepted three blocks down, because
    they call something on the way; a sentence that claimed "so it does
    nothing" stated a rule wider than the code enforces. }
  CheckRejected('the wider wording names the test the compiler ran',
                'x = 1' + LF + 'x + 1' + LF, 'has no call in it');

  { THREE MISTAKES, THREE SENTENCES, because one of them cannot be true of all
    three -- and two of these replaced advice that was WRONG rather than merely
    silent. A label written inside a block used to be answered from the far end
    of the program with `undefined label handler`, which was TRUE; answering it
    with "a call needs parentheses: handler()" names a function that does not
    exist. And `if x = 1 then 42` is the classic-BASIC jump, in a language that
    really does label lines with numbers, so the thing to say is how a jump is
    spelled here -- not that a value was discarded. }
  CheckRejected('a label inside a while body is a label, not a call',
                'while 1 = 0' + LF + 'handler:' + LF + 'x = 1' + LF +
                'endwhile' + LF,
                '''handler:'' is a label, and a label belongs to the program');
  CheckRejected('a label inside an if body',
                'if 1 = 1 then' + LF + 'retry:' + LF + 'x = 1' + LF +
                'endif' + LF, 'is a label, and a label belongs to the program');
  CheckRejected('a label inside a function body',
                'function g()' + LF + 'again:' + LF + 'return 0' + LF +
                'endfunction' + LF + 'x = g()' + LF,
                'is a label, and a label belongs to the program');
  CheckRejected('a bare number after then is the jump other dialects had',
                'x = 1' + LF + 'if x = 1 then 42' + LF,
                '''42'' on its own is not a statement -- a number labels a ' +
                'line only at program level, and a jump is written out: goto 42');
  CheckRejected('a bare number inside a block says the same thing',
                'while 1 = 0' + LF + '42' + LF + 'endwhile' + LF,
                'a jump is written out: goto 42');
  { A float is not a line number in any dialect, so it takes the wider sentence
    -- the branch is the INTEGER literal, not "the statement starts with a
    number". }
  CheckRejected('a bare float is not a line number',
                'while 1 = 0' + LF + '4.5' + LF + 'endwhile' + LF,
                'computes a value and discards it');
  { AND TWO SENTENCES THAT ARE DELIBERATELY NOT THE NAME ONE, pinned here so the
    judgement is visible rather than re-opened. A const folds to opPushConst, and
    all three name arms test for a single LOAD, so a bare const takes the general
    sentence -- which is the right one: telling the author to write `K()` would
    name a function no more than `K` is one. Widening those arms to opPushConst
    is the change this row exists to catch. }
  CheckRejected('a bare const name takes the general sentence, not the name one',
                'const K = 5' + LF + 'K' + LF,
                'computes a value and discards it');
  { The other direction of the same limit, and this one the compiler gets WRONG
    on purpose: `x` may genuinely be a variable, and it is still told to add
    parentheses to an `x()` that need not exist. The registry is not visible from
    here and a global carries no "was this assigned", so the likelier reading
    wins; the cost of being wrong was measured and is one step, since following
    the advice answers `no function x:` on that same line. }
  CheckRejected('a variable stranded before a terminator gets the call advice',
                'x = 1' + LF + 'for i = 1 to 2' + LF + 'x next' + LF,
                '''x'' on its own does nothing -- a call needs parentheses: x()');

  { AND THE SECOND SPELLING, ONE TOKEN TO THE RIGHT, which this rule does not
    reach in ANY position and which is the larger half of the surviving defect.
    Everything above is about a STATEMENT. Used as a VALUE the same forgotten
    parentheses are still read as a variable -- and there the compiler has no
    question to ask, because the value IS used and the statement does do
    something. Swept rather than argued: all 109 zero-arity registered names in
    this tree are refused written bare as a statement, and all 109 compile
    silently on the right of an '='; `p$ = date$` leaves p$ empty where
    `date$()` answers the date. The runtime half is asserted in
    tests/suite/19_language_contract.bas. If a later change ever closes this
    door, these two rows are what must move with it. }
  CheckAccepted('the same name on an assignment rhs is still a variable',
                'v = err_clear' + LF);
  CheckAccepted('...and so is a value-returning one, which is the likelier slip',
                'p$ = date$' + LF);

  { THE REFUSAL MUST NOT REACH THE STATEMENT NEXT DOOR, which is the commonest
    statement in the language: a call whose value nobody wants. Nothing in the
    147-file corpus or the documentation's basic blocks was refused by the rule
    above; these are the shapes that would have gone first if it over-reached.
    The runtime half -- that the effect still lands -- is asserted in
    tests/suite/19_language_contract.bas, which can only be written from inside
    the language. }
  CheckAccepted('a zero-argument call as a statement', 'randomize()' + LF);
  CheckAccepted('the measured instance, written correctly', 'err_clear()' + LF);
  CheckAccepted('a call with arguments as a statement', 'len("abc")' + LF);
  CheckAccepted('a user function called as a statement',
                'function g()' + LF + '  return 0' + LF + 'endfunction' + LF +
                'g()' + LF);
  CheckAccepted('a mutator whose returned handle is discarded',
                'a@ = dim@(3)' + LF + 'arr_set@(a@, 1, 5)' + LF);
  CheckAccepted('an indexed assignment', 'a@ = dim@(3)' + LF + 'a@[1] = 5' + LF);
  CheckAccepted('an indexed read as a statement',
                'a@ = dim@(3)' + LF + 'a@[1]' + LF);
  CheckAccepted('a string index as a statement', 's$ = "x"' + LF + 's$[1]' + LF);
  CheckAccepted('a JSON literal as a statement', '[1, 2, 3]' + LF);
  { INPUT$ moves a console or file cursor, so it is an effect even when its
    characters are thrown away -- the two opcodes that stand beside opCall. }
  CheckAccepted('INPUT$ from the console as a statement', 'input$(1)' + LF);
  CheckAccepted('INPUT$ from a channel as a statement', 'input$(1, #1)' + LF);
  CheckAccepted('a call as the body of an inline if', 'if 1 = 1 then len("a")' + LF);
  CheckAccepted('a call after a '':'' separator', 'x = 1 : len("a")' + LF);
  CheckAccepted('a named label at program level',
                'goto done' + LF + 'done:' + LF + 'println "ok"' + LF);
  CheckAccepted('a numeric label at program level',
                'goto 100' + LF + '100' + LF + 'println "ok"' + LF);
  CheckAccepted('a label sharing its line with a statement',
                'goto done' + LF + 'done: println "ok"' + LF);
  { THE LIMIT, PINNED AS A DECISION RATHER THAN LEFT AS A SURPRISE -- AND IT IS
    WIDER THAN A LINE'S START. `name :` is read as a label before any statement
    is parsed, so a call with its parentheses left off is a label there and is
    still silent; Compile's loop re-runs that reader wherever a statement may
    begin at PROGRAM LEVEL, which is a line's start, after a ':' separator, after
    a numeric label, and after another label. All four are spelled out below. A
    generated sweep -- a numeric label or not, times a named label or not, times
    nought, one or two statements already closed by a ':' -- found all twelve
    prefixes silent when RUN and read through err(), while all eight block forms
    refused; these rows are the ones that go red if that ever changes, and
    CheckAccepted is the weaker half of the pin, since it only says the line
    compiles. The runtime half -- that the function was never CALLED -- is in
    tests/suite/19_language_contract.bas, which asserts it for the same four
    positions.

    Separating a label from a missing call needs a label that no `goto` names,
    and of the 284 label definitions in this tree's 147 .bas files the only
    unreferenced ones are the six lines written to demonstrate this limit -- so
    such a rule would break nothing already written here, and would still be the
    wrong rule: a jump not yet written is a legitimate program, and "nothing
    jumps here" describes the label rather than the missing parentheses.
    docs/language-reference.md says the same in prose. If a later change closes
    this door, THESE are the lines that must change with it. }
  CheckAccepted('a bare call name before a '':'' at a line''s start is a label',
                'randomize : x = rnd(10)' + LF);
  CheckAccepted('...and after a '':'' separator mid-line, which is a statement '
                + 'start too',
                'y = 1 : randomize : z = 2' + LF);
  CheckAccepted('...and after a numeric label, which is one as well',
                '10 randomize : x = 1' + LF);
  CheckAccepted('...and after another label, the fourth of the four',
                'goto head' + LF + 'head: randomize : x = 1' + LF);
  CheckAccepted('a label after a '':'' separator at program level',
                'goto two' + LF + 'x = 1 : two:' + LF + 'println "ok"' + LF);
  CheckAccepted('a label after a numeric label on the same line',
                'goto three' + LF + '20 three:' + LF + 'println "ok"' + LF);

  { AND IT MUST NOT TAKE OVER A DIAGNOSTIC THAT WAS ALREADY BETTER. The refusal
    fires only when the statement ENDS at the expression -- OrphanKeyword's
    restriction, for OrphanKeyword's reason. `local v` on a line of its own is
    still `expected end of line`; answering it with "a call needs parentheses:
    local()" would send the author somewhere worse than the silence did. And the
    typo'd case label is the shape tests/classic/15_repl_bad_case.repl exists
    for: it must keep the message the REPL discriminates on. }
  CheckRejected('local on a line of its own keeps its own message',
                'function g()' + LF + '  local v' + LF + '  return 0' + LF +
                'endfunction' + LF + 'x = g()' + LF, 'expected end of line');
  { `local v` cannot break: `v` is not one of the fifteen, so the follower test
    never looked at it. `local step` is the one that CAN, and did -- a first
    version of this check took all fifteen of OrphanKeyword's words as
    statement-enders, and `step`, `then`, `to` and `local` end nothing. The
    eleven that do are the block terminators, and OrphanKeyword now answers
    which is which so the two lists cannot drift apart. }
  CheckRejected('local before a name that is a contextual keyword',
                'function g()' + LF + '  local step' + LF + '  return 0' + LF +
                'endfunction' + LF + 'x = g()' + LF, 'expected end of line');
  CheckRejected('local before to keeps its own message',
                'function g()' + LF + '  local to' + LF + '  return 0' + LF +
                'endfunction' + LF + 'x = g()' + LF, 'expected end of line');
  CheckRejected('a name followed by step keeps its own message',
                'x = 1' + LF + 'x step' + LF, 'expected end of line');
  { And when a contextual keyword DOES reach the expression statement -- the one
    route is a block terminator behind it with no separator -- the true sentence
    is the word's own. `local` is not a function that parentheses would rescue. }
  CheckRejected('a stranded local before a terminator keeps ITS sentence',
                'for i = 1 to 2' + LF + 'local next' + LF,
                '''local'' belongs on the ''function'' line');
  CheckRejected('a stranded step before a terminator keeps ITS sentence',
                'for i = 1 to 2' + LF + 'step next' + LF,
                '''step'' belongs on a ''for'' line');
  CheckRejected('a stranded next before a terminator keeps ITS sentence',
                'if 1 = 1 then' + LF + 'next endif' + LF,
                '''next'' without a matching ''for''');
  CheckRejected('two juxtaposed names keep their own message',
                'foo bar' + LF, 'expected end of line');
  CheckRejected('a typo''d case label keeps the message the REPL reads',
                'select case 1' + LF + 'csae 1' + LF + 'endselect' + LF,
                'expected ''case'' or ''endselect''');

  { A ceiling that refuses must not pay for refusing; see the note on the check. }
  CheckRefusedGraftDoesNotLeak;

  { THE FOURTH CEILING. The other three bound how LONG a script runs, and the
    budget unit's own header says in terms that none of them bounds memory: RULE 1
    is asked at the opCall seam by a LIBRARY about its own arguments, and `+` is
    not a library call. Three instructions out of a million reached 1.6 GB of
    string and 14.7 GB of peak with rc 0. }

  { The shape the finding names: double a string, one O(n) instruction at a time. }
  CheckMem('memory ceiling: doubling is refused before it allocates',
           's$ = string$(2000000, 97)' + LF +
           'for i% = 1 to 6' + LF + '  s$ = s$ + s$' + LF + 'next' + LF,
           32 * 1024 * 1024, 'memory limit exceeded');

  { UNLIMITED IS STILL UNLIMITED. 0 is the default and must change nothing: a
    ceiling that a host did not ask for would be the failure mode this project
    names first. }
  CheckMem('and the same run is untouched with no ceiling set',
           's$ = string$(2000000, 97)' + LF +
           'for i% = 1 to 6' + LF + '  s$ = s$ + s$' + LF + 'next' + LF,
           0, '');

  { THE FLOOR ONLY EVER FALLS. If the host releases its own memory while the
    script runs, the heap drops below the base the run started from -- and the
    first version answered "nothing to charge" and turned the ceiling OFF for the
    rest of the run: 1516 MB through a 32 MB ceiling, where the same script with
    the host holding on was refused at 591 MB. }
  CheckMemHostFrees('the ceiling survives the host freeing its own memory');
  CheckMemVmReused('and a VM run a second time is bounded like the first');

  { GROWTH THROUGH A HOST SEAM. It arrives at neither an opAdd nor a registry
    call -- but to MATTER it has to be retained, and retaining it means a
    container or a string, so one of the two checks meets it on the way. This
    asserts that, rather than the seam itself. }
  CheckMemFatInput('growth arriving through the input seam is caught');

  { THE GROWTH IN THE RIGHT OPERAND. Every other check here puts the size in the
    LEFT one, so `growth := Length(a.Str) + TextLenOf(b)` was never exercised
    through b -- and three mutations walked through: TextLenOf answering 0,
    RoomFor ignoring its AGrowth argument entirely, and the pre-check disabled.
    That last one is the whole stated reason for putting a check at opAdd rather
    than only in the step loop, so nothing pinned the design's own justification.
    Deliberately under 4096 instructions, so ONLY the pre-check can catch it. }
  CheckMem('memory ceiling: a growth carried by the RIGHT operand is refused',
           'b$ = string$(20000000, 65)' + LF +
           'p$ = "x"' + LF +
           'q$ = p$ + b$' + LF,
           32 * 1024 * 1024, 'memory limit exceeded');

  { A LIBRARY CALL IS ASKED ABOUT DIRECTLY, not only every 4096 steps. Twelve big
    allocations in about forty instructions never reached the step-loop check. }
  CheckMem('memory ceiling: a library allocation is refused in a short script',
           'a$ = string$(60000000, 65)' + LF +
           'b$ = string$(60000000, 66)' + LF +
           'c$ = string$(60000000, 67)' + LF +
           'd$ = string$(60000000, 68)' + LF,
           32 * 1024 * 1024, 'memory limit exceeded');

  { AND len() DOES NOT COST EIGHT BYTES PER BYTE. It used to build a table of one
    Int64 per input byte just to count the entries, so this reached 1716 MB under
    this very ceiling and answered rc 0. }
  CheckMem('len() of a large string does not allocate past the ceiling',
           's$ = string$(20000000, 65)' + LF +
           'n% = len(s$)' + LF +
           'if n% <> 20000000 then' + LF + '  x = 1 / 0' + LF + 'end if' + LF,
           64 * 1024 * 1024, '');

  { THE BACKSTOP. Memory that grows through a library, one call at a time, with no
    single allocation large enough for the pre-check to look at. A FRESH string per
    turn: adding one `chunk$` a thousand times stores a thousand references to one
    buffer -- AnsiStrings are refcounted -- and the heap barely moves, which is how
    the first version of this check passed while measuring nothing. }
  CheckMem('memory ceiling: growth with no large concatenation is caught too',
           'L@ = strings@()' + LF +
           'for i% = 1 to 4000' + LF +
           '  n = strings_add(L@, string$(65536, 65))' + LF +
           'next' + LF,
           32 * 1024 * 1024, 'memory limit exceeded');

  { THE CEILING IS ABOUT THE SCRIPT, NOT ABOUT THE PROCESS. Same script, same
    ceiling, with the host already holding 64 MB of its own. }
    { The loop is not decoration: the periodic check fires every 4096 steps, so a
      four-line script finishes before one ever looks at the heap. A first draft
      had no loop and could not tell the two spellings apart. }
  CheckMem('a ceiling bounds what the SCRIPT adds, not what the host holds',
           's$ = string$(4000000, 97)' + LF +
           'for i% = 1 to 5000' + LF + '  n = n + 1' + LF + 'next' + LF +
           'if len(s$) <> 4000000 then' + LF + '  x = 1 / 0' + LF + 'end if' + LF,
           32 * 1024 * 1024, '', 64 * 1024 * 1024);

  { AND ORDINARY WORK UNDER THE CEILING IS UNTOUCHED. }
  CheckMem('ordinary string building under the ceiling is not refused',
           's$ = ""' + LF +
           'for i% = 1 to 20000' + LF + '  s$ = s$ + "x"' + LF + 'next' + LF +
           'if len(s$) <> 20000 then' + LF + '  x = 1 / 0' + LF + 'end if' + LF,
           32 * 1024 * 1024, '');

  { FATAL, like the other three: a script cannot catch its way out of its own
    ceiling. The handler below would swallow an ordinary error. }
  CheckMem('ON ERROR cannot escape the memory ceiling',
           'on error goto oops' + LF +
           's$ = string$(2000000, 97)' + LF +
           'for i% = 1 to 6' + LF + '  s$ = s$ + s$' + LF + '  n = n + 1' + LF +
           'next' + LF +
           'goto fin' + LF + 'oops:' + LF + 'resume next' + LF + 'fin:' + LF,
           32 * 1024 * 1024, 'memory limit exceeded');

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
