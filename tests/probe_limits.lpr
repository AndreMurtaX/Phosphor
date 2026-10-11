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
  PhosphorOpcodes, PhosphorValue, PhosphorRegistry, PhosphorVM, PhosphorHandles,
  PhosphorBudget, PhosphorBase64Lib, PhosphorGzipLib, PhosphorHttpLib;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;
  CryptoStart: QWord = 0;

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

{ A limit, and the one named: the run must end with peLimit AND its message
  must contain AFragment -- a limit for a different reason, or at a different
  time, is not the one the check is about (round 6). }
procedure CheckMsg(const AName, ASource: String; ASteps, ATimeoutMs: Int64;
  const AFragment: String);
var
  eng: TPhosphorEngine;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  try
    eng.MaxSteps := ASteps;
    eng.TimeoutMs := ATimeoutMs;
    rc := eng.Run(ASource);
    Report((rc <> 0) and (eng.LastError.Code = peLimit) and
           (Pos(AFragment, eng.LastError.Message) > 0),
           AName + ' (expected a limit naming "' + AFragment + '", got "' +
           eng.LastError.Message + '")');
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
  { See the stride, below: every line of the first and last EdgeCuts of a long
    file, and about MiddleCuts cuts between. }
  EdgeCuts = 100;
  MiddleCuts = 150;
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
  stride, skipped: Integer;
begin
  skipped := 0;
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
      { A CUT AT EVERY LINE IS QUADRATIC IN THE FILE (round-6 review). Each
        cut compiles the whole prefix, twice, so a file of n lines costs about
        n * n / 2 compiled lines: tests/suite/85_datetime_round2.bas, 3964 of
        them, took 667 s of this probe on Windows by itself, which is most of
        why the Windows CI job ran for half an hour. A file up to EdgeCuts * 2
        lines is still cut at every line. A longer one is cut at every line of
        its first and last EdgeCuts -- where a block opens and where the input
        runs out -- and at an even stride between, so the cuts still cover
        the whole file; the cuts left out are counted and printed, never
        dropped in silence. }
      if src.Count > 2 * EdgeCuts then
        stride := (src.Count - 2 * EdgeCuts) div MiddleCuts + 1
      else
        stride := 1;
      for cut := 1 to src.Count do
      begin
        if (stride > 1) and (cut > EdgeCuts) and (cut <= src.Count - EdgeCuts) and
           ((cut - EdgeCuts) mod stride <> 0) then
        begin
          Inc(skipped);
          Continue;
        end;
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
    Writeln('sweep: ', skipped, ' of the corpus''s cuts left out by the stride over long files');
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
{ THE FIFTH CEILING, MaxHandles (ledger m3). Every expectation is derived from
  the rule, not from a run:

  * the check runs AFTER each library call returns, so with a ceiling of 100
    the 101st strings@() is refused before the println that follows it -- the
    output is exactly the lines 1..100;
  * it is a LEVEL: 100 000 lists created and freed one at a time never hold
    more than one, so a ceiling of 100 lets the run finish;
  * 0 is inert: the same 150 lists print all 150 lines;
  * exactly at the ceiling is allowed -- 100 live under 100 is not over it;
  * and like the other four it is fatal: ON ERROR cannot catch it.

  The second and third are the ones a wrong version fails: counting handles
  EVER CREATED fails the second, and testing the ceiling with no `> 0` guard
  fails the third. Both were built and watched failing. }
type
  TTextSink = class
    Text: String;
    procedure Take(const S: String);
  end;

procedure TTextSink.Take(const S: String);
begin
  Text := Text + S;
end;

function Lines(AFrom, ATo: Integer): String;
var i: Integer;
begin
  Result := '';
  for i := AFrom to ATo do Result := Result + IntToStr(i) + LF;
end;

procedure CheckMaxHandles;
const
  Keep150 = 'for i = 1 to 150' + LF + '  l@ = strings@()' + LF +
            '  println str$(i)' + LF + 'next' + LF;
  Keep100 = 'for i = 1 to 100' + LF + '  l@ = strings@()' + LF + 'next' + LF +
            'println "held 100"' + LF;
  Churn = 'for i = 1 to 100000' + LF + '  l@ = strings@()' + LF +
          '  x = strings_free(l@)' + LF + 'next' + LF + 'println "done"' + LF;
  Caught = 'on error goto oops' + LF + 'for i = 1 to 150' + LF +
           '  l@ = strings@()' + LF + 'next' + LF + 'goto fin' + LF +
           'oops:' + LF + 'resume next' + LF + 'fin:' + LF + 'println "escaped"' + LF;

  procedure One(const AName, ASource: String; AMax: Int64; AWantLimit: Boolean;
                const AWantOut: String);
  var
    eng: TPhosphorEngine;
    sink: TTextSink;
    rc: Integer;
  begin
    eng := TPhosphorEngine.Create();
    sink := TTextSink.Create();
    try
      eng.MaxHandles := AMax;
      eng.TimeoutMs := 60000;
      eng.OnOutput := @sink.Take;
      rc := eng.Run(ASource);
      if AWantLimit then
        Report((rc <> 0) and (eng.LastError.Code = peLimit) and
               (Pos('handle limit exceeded (' + IntToStr(AMax), eng.ErrorMessage) > 0),
               AName + ' (expected the handle limit, got code ' +
               IntToStr(Ord(eng.LastError.Code)) + ' ' + eng.ErrorMessage + ')')
      else
        Report(rc = 0, AName + ' (expected success, got ' + eng.ErrorMessage + ')');
      Report(sink.Text = AWantOut, AName + ': the output is exactly what the rule says');
    finally
      sink.Free;
      eng.Free;
    end;
  end;

begin
  One('MaxHandles: 150 kept under 100 is refused after the 101st call', Keep150, 100,
      True, Lines(1, 100));
  One('MaxHandles: a LEVEL -- 100 000 created and freed under 100 finish', Churn, 100,
      False, 'done' + LF);
  One('MaxHandles: 0 is inert -- the same 150 run to the end', Keep150, 0,
      False, Lines(1, 150));
  One('MaxHandles: exactly at the ceiling is not over it', Keep100, 100,
      False, 'held 100' + LF);
  One('MaxHandles: ON ERROR cannot escape it', Caught, 100, True, '');
end;

{ THE LEVEL, AT THE DOORS AN ADVERSARIAL ROUND FOUND (2026-10-07). Three ways the
  level was not what docs/embedding.md says it is:
    * A JSON BORROW COST A HANDLE. json.md says a borrow costs nothing, and a
      loop READING 200 rows was refused at a ceiling of 100. A borrow is now a
      view, which the level leaves out, and the same node is the same view --
      so the sum is 200*201/2 = 20100 and reading one row a thousand times
      leaves exactly two live handles: the document and the one view.
    * A HOST THAT SWALLOWS A CALLBACK'S ERROR kept dispatching: under a ceiling
      of 10, one library call running 1000 handlers that each keep a list ended
      with 1000 live. The documented overshoot is what ONE call creates, so at
      most 11 -- and the run is refused.
    * A CALL THAT MINTS AND THEN RAISES skipped the check: 200 of them under
      100 finished with 200 live. At most 101, and refused. }
function PumpHandlers(AVM: TObject; const Args: array of TValue;
                      out Err: TPhosphorError): TValue;
var
  i: Integer;
  e: TPhosphorError;
begin
  Err := NoError();
  for i := 1 to Trunc(AsDouble(Args[0])) do
    TPhosphorVM(AVM).CallUserFunc('handler', [], e);   // GuiCallBack's shape: record, go on
  Result := ValInt(0);
end;

type
  TMintMarker = class end;

function MintThenRaise(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  RegisterHandle(TMintMarker.Create());
  raise Exception.Create('validation failed after minting');
  Result := ValInt(0);
end;

{ AND NOW THEY CAN BE FREED (2026-10-08). The same kinds the level could only
  rise for -- a dictionary, a JSON document, a config -- each have a free, so a
  loop that makes one per pass and frees it runs under a ceiling below its pass
  count. The control is the dictionary loop WITHOUT the free, refused at the
  101st: it is the free that keeps the level down. A JSON document goes with the
  views borrowed into it, so the loop that borrows one per pass and frees only
  the document leaves nothing live at all. }
procedure CheckFreesKeepTheLevel;

  function RunOne(const ASource: String): Integer;
  var eng: TPhosphorEngine;
  begin
    eng := TPhosphorEngine.Create();
    try
      eng.MaxHandles := 100;
      Result := eng.Run(ASource);
      if Result <> 0 then
        Report(eng.LastError.Code = peLimit, 'a refusal here is the handle limit (' + eng.ErrorMessage + ')');
    finally
      eng.Free;
    end;
  end;

begin
  Report(RunOne('for i = 1 to 200' + LF + '  d@ = dict@()' + LF + '  x = dict_free(d@)' + LF + 'next' + LF) = 0,
         'MaxHandles: 200 dictionaries made and freed under 100 finish');
  Report(RunOne('for i = 1 to 200' + LF + '  d@ = dict@()' + LF + 'next' + LF) <> 0,
         'the control: the same 200 kept are refused');
  Report(RunOne('for i = 1 to 200' + LF + '  j@ = json_parse@("[1,2,3]")' + LF +
                '  r@ = json_item@(j@, 2)' + LF + '  x = json_free(j@)' + LF + 'next' + LF) = 0,
         'MaxHandles: 200 documents read and freed under 100 finish');
  Report(LiveHandleCount() = 0, 'and leave nothing live, the views gone with their documents (' +
         IntToStr(LiveHandleCount()) + ')');
  Report(RunOne('for i = 1 to 200' + LF + '  c@ = cfg_open@("bin/p9b_probe_free.ini")' + LF +
                '  x = cfg_free(c@)' + LF + 'next' + LF) = 0,
         'MaxHandles: 200 configs opened and freed under 100 finish');
end;

procedure CheckMaxHandlesDoors;
var
  eng: TPhosphorEngine;
  sink: TTextSink;
  rc, i: Integer;
  rows: String;
begin
  rows := '';
  for i := 1 to 200 do
  begin
    if i > 1 then rows := rows + ',';
    rows := rows + '{' + #92 + '"n' + #92 + '":' + IntToStr(i) + '}';
  end;
  eng := TPhosphorEngine.Create();
  sink := TTextSink.Create();
  try
    eng.MaxHandles := 100;
    eng.OnOutput := @sink.Take;
    rc := eng.Run('p@ = json_parse@("[' + rows + ']")' + LF + 'total = 0' + LF +
                  'for i = 1 to json_len(p@)' + LF + '  row@ = json_item@(p@, i)' + LF +
                  '  total = total + json_getn(row@, "n")' + LF + 'next' + LF +
                  'println str$(total)' + LF);
    Report(rc = 0, 'MaxHandles: reading 200 JSON rows under 100 finishes (' + eng.ErrorMessage + ')');
    Report(sink.Text = '20100' + LF, 'and sums them: 200*201/2');
    sink.Text := '';
    rc := eng.Run('p@ = json_parse@("[{' + #92 + '"n' + #92 + '":7}]")' + LF + 'total = 0' + LF +
                  'for i = 1 to 1000' + LF + '  row@ = json_item@(p@, 1)' + LF +
                  '  total = total + json_getn(row@, "n")' + LF + 'next' + LF +
                  'println str$(total)' + LF);
    Report((rc = 0) and (sink.Text = '7000' + LF), 'reading one row a thousand times answers 7000');
    Report(LiveHandleCount() = 2, 'and leaves two live handles, the document and one view (' +
           IntToStr(LiveHandleCount()) + ')');
  finally
    sink.Free;
    eng.Free;
  end;

  eng := TPhosphorEngine.Create();
  try
    eng.MaxHandles := 10;
    eng.Registry.AddHost('pump:n', @PumpHandlers);
    rc := eng.Run('pump(1000)' + LF + 'end' + LF + 'function handler()' + LF +
                  '  h@ = strings@()' + LF + '  return 0' + LF + 'endfunction' + LF);
    Report((rc <> 0) and (eng.LastError.Code = peLimit),
           'MaxHandles: a host that swallows a callback''s refusal still ends the run (' +
           eng.ErrorMessage + ')');
    Report(LiveHandleCount() <= 11, 'with at most one call''s overshoot: ' +
           IntToStr(LiveHandleCount()) + ' live under 10');
  finally
    eng.Free;
  end;

  eng := TPhosphorEngine.Create();
  try
    eng.MaxHandles := 100;
    eng.Registry.Add('mkraise:', @MintThenRaise);
    rc := eng.Run('on error goto h' + LF + 'for i = 1 to 200' + LF + '  x = mkraise()' + LF +
                  'next' + LF + 'end' + LF + 'h:' + LF + 'resume next' + LF);
    Report((rc <> 0) and (eng.LastError.Code = peLimit),
           'MaxHandles: a call that mints and then raises is asked too (' + eng.ErrorMessage + ')');
    Report(LiveHandleCount() <= 101, 'and stops at most one past the ceiling: ' +
           IntToStr(LiveHandleCount()) + ' live under 100');
  finally
    eng.Free;
  end;
end;

{ THERE IS NO CAP ON A PROGRAM'S NAMES, AND THEY COST WHAT THEY WEIGH (ledger m4).

  docs/decisions.md ("No fixed global-variable cap") declined Plan9Basic's 513:
  globals live in a dynamic array addressed by a 32-bit index. Two things make
  that true rather than merely stated, and both are asserted here.

  THE COUNT. 65 537 globals -- one past anything a 16-bit index could address --
  compile, run, and the last one holds its value. tests/suite/13_global_limit.bas
  only ever reached 513, which is exactly the count a reintroduced 513 cap still
  accepts.

  THE COST. Every name table was a front-to-back scan per name, so N globals
  compiled in N^2/2 compares: 16 000 took 0.70 s and 32 000 took 2.67 s on the
  console host, and labels, locals and user functions grew the same way. A cap
  nobody wrote was being enforced by the clock. Each table is indexed now
  (PhosphorNameIndex), and the check is a RATIO, because a ratio survives a slow
  or loaded machine and an absolute time does not: the small program is prepared
  EIGHT times, the program eight times its size once. Linear, the two take the
  same time; quadratic, the second takes eight times as long. The threshold is 3,
  best of three trials each, so a loaded machine has to be wrong in the same
  direction six times to fail it. GetTickCount64 ticks every ~16 ms on Windows,
  which is why both sides are sized to take a few hundred. }
function NamesProgram(AKind: Char; AN: Integer): String;
var
  sl, names: TStringList;
  i: Integer;
  s: String;
begin
  sl := TStringList.Create();
  try
    sl.LineBreak := LF;
    case AKind of
      'g': begin
             for i := 1 to AN do sl.Add('v' + IntToStr(i) + ' = ' + IntToStr(i));
           end;
      'l': begin
             // joined by the list, not by AN concatenations: the generator must
             // not be the quadratic thing in a probe that measures for one
             names := TStringList.Create();
             try
               names.Delimiter := ',';
               names.StrictDelimiter := True;
               for i := 1 to AN do names.Add('a' + IntToStr(i));
               s := 'function big(x) local ' + names.DelimitedText;
             finally
               names.Free;
             end;
             sl.Add(s);
             for i := 1 to AN do sl.Add('  a' + IntToStr(i) + ' = x');
             sl.Add('  return a' + IntToStr(AN));
             sl.Add('endfunction');
             sl.Add('y = big(7)');
           end;
      'j': begin
             sl.Add('goto l1');
             for i := 1 to AN do
             begin
               sl.Add('l' + IntToStr(i) + ':');
               if i < AN then sl.Add('goto l' + IntToStr(i + 1)) else sl.Add('goto done');
             end;
             sl.Add('done:');
           end;
      'f': begin
             sl.Add('t = 0');
             for i := 1 to AN do sl.Add('t = t + f' + IntToStr(i) + '()');
             sl.Add('end');
             for i := 1 to AN do
             begin
               sl.Add('function f' + IntToStr(i) + '()');
               sl.Add('  return 1');
               sl.Add('endfunction');
             end;
           end;
    end;
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

{ Milliseconds to prepare ASource ATimes over, best of three trials; -1 if a
  prepare failed, which is its own failure and must not read as fast. }
function PrepareMs(const ASource: String; ATimes: Integer): Int64;
var
  trial, k: Integer;
  t0, dt: QWord;
  eng: TPhosphorEngine;
begin
  Result := High(Int64);
  for trial := 1 to 3 do
  begin
    t0 := GetTickCount64();
    for k := 1 to ATimes do
    begin
      eng := TPhosphorEngine.Create();
      try
        if eng.Prepare(ASource) <> 0 then Exit(-1);
      finally
        eng.Free;
      end;
    end;
    dt := GetTickCount64() - t0;
    if Int64(dt) < Result then Result := Int64(dt);
  end;
end;

procedure CheckNameTablesScale;
const
  Kinds: array[0..3] of Char = ('g', 'l', 'j', 'f');
  KindName: array[0..3] of String = ('globals', 'locals of one function',
                                     'labels, each reached by a goto',
                                     'user functions, each called once');
  Small = 4000;
var
  eng: TPhosphorEngine;
  prog: TProgram;
  vm: TPhosphorVM;
  k: Integer;
  big, small8, limit: Int64;
  v: TValue;
begin
  eng := TPhosphorEngine.Create();
  try
    if eng.Prepare(NamesProgram('g', 65537)) <> 0 then
      Report(False, '65 537 globals prepare (' + eng.ErrorMessage + ')')
    else
    begin
      prog := eng.PreparedProgram;
      vm := eng.PreparedVM;
      Report(prog.VarCount = 65537, '65 537 globals: one past a 16-bit index, all in the table');
      Report(prog.GlobalName(prog.VarCount - 1) = 'v65537', '  and the last is v65537');
      v := vm.DbgGlobal(prog.VarCount - 1);
      Report(ValToStr(v) = '65537', '  and it holds 65537 after the run');
    end;
  finally
    eng.Free;
  end;

  for k := 0 to High(Kinds) do
  begin
    small8 := PrepareMs(NamesProgram(Kinds[k], Small), 8);
    big := PrepareMs(NamesProgram(Kinds[k], Small * 8), 1);
    if (small8 < 0) or (big < 0) then
    begin
      Report(False, KindName[k] + ': a scaling program failed to prepare');
      Continue;
    end;
    { The small side can measure 0 on a fast machine; a floor of one tick keeps
      the comparison meaningful rather than dividing by it. }
    limit := 3 * small8;
    if limit < 48 then limit := 48;
    // Always printed: the numbers are the evidence, pass or fail.
    Writeln(Format('scale: %s: %d ms for %d once, %d ms for %d eight times (limit %d)',
                   [KindName[k], big, Small * 8, small8, Small, limit]));
    Report(big <= limit, KindName[k] + ' cost what they weigh: eight times the names, ' +
                         'not sixty-four times the time');
  end;
end;

{ A REUSED COMPILER STARTS FROM NO NAMES. The indexes are the compiler's, not the
  program's, so they outlive a Compile -- and TPhosphorEngine makes a fresh
  compiler per call, so nothing in the tree would notice if they were not
  cleared. An embedder holding one would: the second program's globals would
  resolve to the first program's slots, and a label both programs use would be
  refused as a duplicate. Derived from the two listings, not a run: B declares
  `b` before `a`, so its table is b, a; and B's `again:` is its only label. }
procedure CheckReusedCompilerNames;
const
  ProgA = 'a = 1' + LF + 'b = 2' + LF + 'again:' + LF + 'end' + LF;
  ProgB = 'b = 3' + LF + 'a = 4' + LF + 'again:' + LF + 'end' + LF;
var
  comp: TPhosphorCompiler;
  pa, pb: TProgram;
begin
  comp := TPhosphorCompiler.Create();
  pa := nil; pb := nil;
  try
    Report(comp.Compile(ProgA, pa), 'reused compiler: the first program compiles');
    Report(comp.Compile(ProgB, pb),
           'reused compiler: the second compiles -- its label is not the first one''s (' +
           comp.ErrorMessage + ')');
    if pb <> nil then
    begin
      Report(pb.VarCount = 2, 'reused compiler: the second program has its own two globals');
      Report((pb.GlobalName(0) = 'b') and (pb.GlobalName(1) = 'a'),
             'reused compiler: in its own order, b then a');
    end;
  finally
    pa.Free;
    pb.Free;
    comp.Free;
  end;
end;

{ --- ROUND 7: A PASS OVER WHAT THE SCRIPT HOLDS IS PRICED ----------------
  A library call is one instruction however long its argument is, and the VM
  reads its clock every 4096 of them -- so ucase$ of a 50 MB string, 200 times
  in a loop, ran 18344 ms under MaxSteps 1000000 / TimeoutMs 2000 and reported
  success. Every pass over a script-supplied string or container is now priced
  (PhosphorBudget's BudgetMilli* table), and these checks hold it to that.

  CheckTimed is CheckMsg plus the clock: the run must end with peLimit, name the
  function, AND stop within AMaxMs -- a refusal that arrives after the damage
  is the defect, not the fix (round 6's lesson about the salt). CheckQuick is
  the other direction: a legitimate call of ordinary size must SUCCEED, and
  quickly, because a quadratic that finishes is still a quadratic. }
procedure CheckTimed(const AName, ASource: String; ASteps, ATimeoutMs: Int64;
  const AFragment: String; AMaxMs: Int64);
var
  eng: TPhosphorEngine;
  rc: Integer;
  t0, took: QWord;
begin
  eng := TPhosphorEngine.Create();
  try
    eng.MaxSteps := ASteps;
    eng.TimeoutMs := ATimeoutMs;
    t0 := GetTickCount64();
    rc := eng.Run(ASource);
    took := GetTickCount64() - t0;
    Report((rc <> 0) and (eng.LastError.Code = peLimit) and
           (Pos(AFragment, eng.LastError.Message) > 0),
           AName + ' (expected a limit naming "' + AFragment + '", got "' +
           eng.LastError.Message + '")');
    Report(took <= QWord(AMaxMs), AName + ' (stopped after ' + IntToStr(took) +
           ' ms; the bound is ' + IntToStr(AMaxMs) + ')');
  finally
    eng.Free;
  end;
end;

procedure CheckQuick(const AName, ASource: String; ASteps, ATimeoutMs: Int64;
  AMaxMs: Int64);
var
  eng: TPhosphorEngine;
  rc: Integer;
  t0, took: QWord;
begin
  eng := TPhosphorEngine.Create();
  try
    eng.MaxSteps := ASteps;
    eng.TimeoutMs := ATimeoutMs;
    t0 := GetTickCount64();
    rc := eng.Run(ASource);
    took := GetTickCount64() - t0;
    Report(rc = 0, AName + ' (expected success, got "' + eng.ErrorMessage + '")');
    Report(took <= QWord(AMaxMs), AName + ' (took ' + IntToStr(took) +
           ' ms; the bound is ' + IntToStr(AMaxMs) + ')');
  finally
    eng.Free;
  end;
end;

{ A loop of ACount calls of AStmt. }
function Loop(ACount: Integer; const AStmt: String): String;
begin
  Result := 'for i = 1 to ' + IntToStr(ACount) + LF + AStmt + LF + 'next' + LF;
end;

{ Milliseconds, best of two, to build a query of AWords distinct words ending
  in "$" (both dedups see them) and analyse it ATimes, with no ceilings. -1 if
  the run failed, which must not read as fast. }
function RagMs(AWords, ATimes: Integer): Int64;
var
  eng: TPhosphorEngine;
  src: String;
  trial: Integer;
  t0, dt: QWord;
begin
  src := 'l@ = strings@()' + LF +
         'for i = 1 to ' + IntToStr(AWords) + LF +
         'n = strings_add(l@, "w" + str$(i) + "$")' + LF + 'next' + LF +
         'n = strings_linebreak(l@, " ")' + LF + 'q$ = strings_text$(l@)' + LF +
         'r@ = rag@("")' + LF +
         'for k = 1 to ' + IntToStr(ATimes) + LF + 'a$ = rag_analyze$(r@, q$)' + LF + 'next' + LF;
  Result := High(Int64);
  for trial := 1 to 2 do
  begin
    eng := TPhosphorEngine.Create();
    try
      t0 := GetTickCount64();
      if eng.Run(src) <> 0 then Exit(-1);
      dt := GetTickCount64() - t0;
      if Int64(dt) < Result then Result := Int64(dt);
    finally
      eng.Free;
    end;
  end;
end;

procedure CheckRagScale;
var small8, big, limit: Int64;
begin
  small8 := RagMs(5000, 8);
  big := RagMs(40000, 1);
  if (small8 < 0) or (big < 0) then
  begin
    Report(False, 'rag_analyze$ scale: a run failed');
    Exit;
  end;
  limit := 2 * small8;
  if limit < 48 then limit := 48;
  Writeln(Format('scale: rag_analyze$: %d ms for 40000 words once, %d ms for 5000 eight times (limit %d)',
                 [big, small8, limit]));
  Report(big <= limit, 'rag_analyze$ costs what the query weighs: eight times the words, ' +
                       'not sixty-four times the time');
end;

{ ---------------------------------------------------------------------------
  ROUND 8 (2026-10-11): ONE CHECK PER FINDING, IN BOTH DIRECTIONS -- the abuse
  is refused, and the legitimate shape beside it runs. Every exact number is
  derived in the comment above it from PhosphorBudget's prices and the
  arguments, never read off a run: MaxSteps 100000 is an allowance of
  100000 * 256 = 25600000 units, and string$(n) / mulstring$ cost n units (RunOf
  asks one a byte). A programme that checks its own state after a caught
  refusal ends `x = 1 / 0` when the state is wrong -- a division error, which
  Check (expecting success) reports as a failure.
--------------------------------------------------------------------------- }

{ A file of ALines lines of 49 'x' and an LF, written by the host so the script
  under test measures the loads and nothing else. Forward slashes, so the path
  can sit in a BASIC string literal (a backslash there is an escape). }
function MakeLinesFile(const AName: String; ALines: Integer): String;
var fs: TFileStream; line, block: String; i, left: Integer;
begin
  Result := StringReplace(GetTempDir(False), '\', '/', [rfReplaceAll]) + AName;
  line := StringOfChar('x', 49) + #10;
  // Written a 20000-line block at a time: one system call a line is slow on Linux.
  block := '';
  for i := 1 to 20000 do block := block + line;
  fs := TFileStream.Create(Result, fmCreate);
  try
    left := ALines;
    while left >= 20000 do
    begin
      fs.WriteBuffer(block[1], Length(block));
      Dec(left, 20000);
    end;
    for i := 1 to left do fs.WriteBuffer(line[1], Length(line));
  finally
    fs.Free;
  end;
end;

procedure CheckRound8;
var big60, cfgPath: String;
begin
  { (1) path_matchespattern folded both strings WHOLE before its metered loop:
    2000 calls on a 100 MB name with the pattern "x" ran 45859 ms under the
    pair and succeeded step-only. The fold is now per comparison, so that call
    reads ONE byte -- the loop finishes quickly and that is the right answer. }
  CheckQuick('path_matchespattern with a pattern that fails at once reads one byte',
             's$ = string$(20000000, 97)' + LF + Loop(300, 'r = path_matchespattern(s$, "x")') +
             'if r <> 0 then x = 1 / 0' + LF,
             1000000, 2000, 1500);
  { ...and a pattern that makes it read the whole name is charged for that:
    "*b" against a's compares every byte, 4096 comparisons a unit block, so 300
    calls of 20 MB is about 6e9 comparisons and stops at the ceiling. }
  CheckTimed('path_matchespattern that reads the whole name stops at the ceiling',
             's$ = string$(20000000, 97)' + LF + Loop(300, 'r = path_matchespattern(s$, "*b")'),
             1000000, 2000, 'path_matchespattern: ', 3000);

  { (2) json_removeat@ shifted the array's tail unpriced. Each removal from the
    front of n elements now asks (n - 1) pointers at JsonShiftMilliPerItem 128:
    999999 * 0.128 = 127999.872 -> 128000 units the first time (a pointer moved
    measured 0.4 to 1.5 ns from run to run; 1 ns sits inside the bound for both). }
  CheckTimed('json_removeat@ from the front of a million is refused at the ceiling',
             'a@ = json_parse@("[" + mulstring$("1,", 999999) + "1]")' + LF +
             Loop(50000, 'a@ = json_removeat@(a@, 1)'),
             1000000, 0, 'json_removeat@: ', 4000);   // the defect: 22 s
  // ...and the refusal leaves the array whole: after a caught refusal at pass
  // k, exactly k - 1 elements are gone.
  Check('a refused json_removeat@ removes nothing',
        'a@ = json_parse@("[" + mulstring$("1,", 999999) + "1]")' + LF +
        'on error goto h' + LF +
        'for k = 1 to 50000' + LF + 'a@ = json_removeat@(a@, 1)' + LF + 'next' + LF +
        'h:' + LF + 'on error goto 0' + LF +
        'if json_len(a@) <> 1000000 - (k - 1) then x = 1 / 0' + LF +
        'if k >= 50000 then x = 1 / 0' + LF,
        1000000, 0, 0, False);
  // ...while removing from the END, which moves nothing, runs.
  CheckQuick('json_removeat@ of the last element is cheap',
             'a@ = json_parse@("[" + mulstring$("1,", 99999) + "1]")' + LF +
             Loop(50000, 'a@ = json_removeat@(a@, json_len(a@))') +
             'if json_len(a@) <> 50000 then x = 1 / 0' + LF,
             1000000, 2000, 1500);

  { (4) path_combine$ copied its arguments unpriced. The three-part form copies
    the first pair twice: 2 * (1000000 + 1) + 1 = 2000003 bytes at MOVE 48 =
    96000.144 -> 96001 units a call. 24600000 / 96001 = 256.2, so 256 calls
    spend 24576256 and leave 23744 for the 257th. }
  CheckMsg('path_combine$ is priced by what it copies (MOVE)',
           'r$ = string$(1000000, 97)' + LF + Loop(300, 'p$ = path_combine$(r$, "x", "y")'),
           100000, 0, 'path_combine$: that would take 96001 units of work and only 23744 are left');
  CheckQuick('path_combine$ of ordinary paths',
             Loop(20000, 'p$ = path_combine$("C:/data/projects", "phosphor", "notes.txt")'),
             1000000, 2000, 1500);

  { (5) strings_delimitedtext$ charged about 19 ns a field for about 475 ns of
    work: 1000 renders of two million fields ran 36 s step-only. It is now
    sized once and charged per field at PIECE; a step-only host stops at the
    ceiling's worth of work. }
  CheckTimed('strings_delimitedtext$ x1000 over two million fields stops at the ceiling',
             's$ = replacestr$(string$(2000000, 65), "A", "ab,c d" + chr$(10))' + LF +
             'l@ = strings@()' + LF + 'n = strings_text(l@, s$)' + LF +
             Loop(1000, 'r$ = strings_delimitedtext$(l@)'),
             1000000, 0, 'strings_delimitedtext$: ', 4000);   // the defect: 36 s; the exact check below pins the price
  { ...and exactly: 10000 fields of "ab,c d", each charged PIECE 4352 + 6 bytes
    at SCAN 80 = 4832 milli as it is scanned (48320 units a render), then the
    answer -- 10000 * 8 quoted bytes + 9999 delimiters = 89999 -- asked at COPY
    128: ceil(11519.872) = 11520. 59840 a render. The setup is mulstring$'s
    70000 and strings_text's SCAN 5600 + 10001 pieces (43525) + COPY 8960:
    128085, leaving 25471915 of 25600000; 425 renders spend 25432000, and the
    426th is refused part way through its scan. }
  Check('strings_delimitedtext$ is priced per field and per byte',
        's$ = mulstring$("ab,c d" + chr$(10), 10000)' + LF + 'l@ = strings@()' + LF +
        'n = strings_text(l@, s$)' + LF +
        'on error goto h' + LF +
        'for k = 1 to 1000' + LF + 'r$ = strings_delimitedtext$(l@)' + LF + 'next' + LF +
        'h:' + LF + 'on error goto 0' + LF +
        'if k <> 426 then x = 1 / 0' + LF,
        100000, 0, 0, False);
  CheckQuick('strings_delimitedtext$ of a hundred thousand fields',
             's$ = replacestr$(string$(100000, 65), "A", "ab,c d" + chr$(10))' + LF +
             'l@ = strings@()' + LF + 'n = strings_text(l@, s$)' + LF +
             Loop(5, 'r$ = strings_delimitedtext$(l@)') +
             'if bytelen(r$) <> 100000 * 8 + 99999 then x = 1 / 0' + LF,
             1000000, 2000, 1500);

  { (6) A REFUSED MUTATOR LEAVES THE CONTAINER AS IT WAS. strings_values for
    the LAST name of a 20000-line list walks every line, each NAMEITEM 4096
    plus its name and separator (3 to 7 bytes) at COPY 128 -- about 4.9 units
    a line, 98000 a call -- so step-only it is refused near the 2600th call;
    before round 8 that refused call APPENDED a duplicate "k20000=" line, and
    the old value stayed on line 20000. }
  Check('a refused strings_values changes nothing',
        'l@ = strings@()' + LF + Loop(20000, 'n = strings_add(l@, "k" + str$(i) + "=v")') +
        'on error goto h' + LF +
        'for k = 1 to 100000' + LF + 'n = strings_values(l@, "k20000", "new" + str$(k))' + LF + 'next' + LF +
        'h:' + LF + 'on error goto 0' + LF +
        'if k >= 100000 then x = 1 / 0' + LF +
        'if strings_count(l@) <> 20000 then x = 1 / 0' + LF +
        'if strings_strings$(l@, 20000) <> "k20000=new" + str$(k - 1) then x = 1 / 0' + LF,
        1000000, 0, 0, False);
  { Once the budget has latched, an UNSORTED add -- O(1), consulting nothing --
    is not refused and adds exactly once; a SORTED add is metered, so it is
    refused and adds nothing. The latch: a needle as long as each of 20 lines
    makes strings_indexof compare them all, 20 * (1152 + 131072 * 80) milli =
    209738 units a call; the setup spends about 5.9M of the 25.6M, so the loop
    latches within a hundred calls. }
  Check('after the latch an unsorted add adds once, a sorted add not at all',
        'big@ = strings@()' + LF +
        'n = strings_text(big@, mulstring$(string$(131072, 97) + chr$(10), 20))' + LF +
        'nd$ = string$(131072, 98)' + LF +
        's@ = strings@()' + LF + 'n = strings_add(s@, "m")' + LF + 'n = strings_sorted(s@, 1)' + LF +
        'on error goto h1' + LF +
        'for k = 1 to 100000' + LF + 'n = strings_indexof(big@, nd$)' + LF + 'next' + LF +
        'h1:' + LF + 'on error goto 0' + LF +
        'if k >= 100000 then x = 1 / 0' + LF +
        'u@ = strings@()' + LF + 'n = strings_add(u@, "first")' + LF +
        'if n <> 1 then x = 1 / 0' + LF +
        'if strings_count(u@) <> 1 then x = 1 / 0' + LF +
        'on error goto h2' + LF + 'n = strings_add(s@, "a")' + LF + 'x = 1 / 0' + LF +
        'h2:' + LF + 'on error goto 0' + LF +
        'if strings_count(s@) <> 1 then x = 1 / 0' + LF,
        100000, 0, 0, False);
  { A refused SORT leaves the order it found. 200000 lines "b","a","b",... cost
    mulstring$'s 400000 units and strings_text's SCAN 32000 + 200001 pieces at
    4352 (870405) + COPY 51200 = 953605: 1353605 of the 2560000 a MaxSteps of
    10000 allows. The merge sort charges a unit a comparison, about
    200000 * 17.6 = 3.5M, so it is refused part way -- and the old one had
    already written its finished passes back, so line 1 had become "a". }
  Check('a refused strings_sort leaves the list in its order',
        'l@ = strings@()' + LF +
        'n = strings_text(l@, mulstring$("b" + chr$(10) + "a" + chr$(10), 100000))' + LF +
        'on error goto h' + LF + 'n = strings_sort(l@)' + LF + 'x = 1 / 0' + LF +
        'h:' + LF + 'on error goto 0' + LF +
        'if strings_strings$(l@, 1) <> "b" then x = 1 / 0' + LF +
        'if strings_strings$(l@, 2) <> "a" then x = 1 / 0' + LF +
        'if strings_strings$(l@, 199999) <> "b" then x = 1 / 0' + LF,
        10000, 0, 0, False);
  Check('...and strings_sorted refused leaves the flag off',
        'l@ = strings@()' + LF +
        'n = strings_text(l@, mulstring$("b" + chr$(10) + "a" + chr$(10), 100000))' + LF +
        'on error goto h' + LF + 'n = strings_sorted(l@, 1)' + LF + 'x = 1 / 0' + LF +
        'h:' + LF + 'on error goto 0' + LF +
        'if strings_sorted(l@) <> 0 then x = 1 / 0' + LF +
        'if strings_strings$(l@, 1) <> "b" then x = 1 / 0' + LF,
        10000, 0, 0, False);
  { A refused json_merge@ merges NOTHING. s holds three members, each an array
    of 100001 ones: its text is 6 + 3 * 200000 + 8 + 8 + 3 = 600025 bytes with
    1 + 3 + 3 + 300000 + 2 = 300009 openers outside strings, so its parse costs
    SCAN ceil(600025 * 0.08) = 48002, NODE ceil(300010 * 76.8) = 23040768 and
    BYTE ceil(600025 * 1.92) = 1152048: 24240818, after mulstring$'s 200000 and
    one unit for t's one-byte name -- 24440819 of 25600000, leaving 1159181.
    The overlap walk visits 2 + 300007 nodes at ITEM (345611), leaving 813570:
    enough to clone the first member (100002 nodes * 7.68 = 768016) and not the
    second. The old merge priced each member as it grafted it, so it merged "a"
    and then reported the refusal; the new one prices all three first. }
  Check('a refused json_merge@ merges nothing',
        'r$ = mulstring$("1,", 100000)' + LF +
        's@ = json_parse@("{\"a\":[" + r$ + "1],\"b\":[" + r$ + "1],\"c\":[" + r$ + "1]}")' + LF +
        't@ = json_object@()' + LF + 't@ = json_setn@(t@, "x", 1)' + LF +
        'on error goto h' + LF + 't@ = json_merge@(t@, s@)' + LF + 'x = 1 / 0' + LF +
        'h:' + LF + 'on error goto 0' + LF +
        'if json_count(t@) <> 1 then x = 1 / 0' + LF,
        100000, 0, 0, False);
  { A refused autosave puts the config back. The 2 MB value costs string$'s
    2000000 units; MaxSteps 10157 allows 2600192, leaving 600192. The set asks
    its line, 1 + 2000000 bytes at REWRITE 216 = 432001, leaving 168191; the
    autosave then walks the line it would write (NAMEITEM + 2000002 * 216 milli,
    about 432005) and is refused. Before round 8 the value stayed set in memory
    and Modified said so; the file is never written either way. }
  cfgPath := StringReplace(GetTempDir(False), '\', '/', [rfReplaceAll]) + 'phosphor_r8_auto.ini';
  DeleteFile(cfgPath);
  Check('a refused autosave leaves the config as it was',
        'v$ = string$(2000000, 97)' + LF +
        'c@ = cfg_open_auto@("' + cfgPath + '")' + LF +
        'on error goto h' + LF + 'c@ = cfg_sets@(c@, "k", v$)' + LF + 'x = 1 / 0' + LF +
        'h:' + LF + 'on error goto 0' + LF +
        'if cfg_haskey(c@, "k") <> 0 then x = 1 / 0' + LF +
        'if cfg_modified(c@) <> 0 then x = 1 / 0' + LF +
        'if file_exists("' + cfgPath + '") <> 0 then x = 1 / 0' + LF,
        10157, 0, 0, False);
  DeleteFile(cfgPath);

  { (7) line$ charged the whole text before a walk that stops at the line:
    line$(b$, 1) of a 20 MB text was refused after 160 calls for work that
    costs nothing. It is charged for the bytes it walked... }
  CheckQuick('line$ of the first line of a 20 MB text is cheap',
             'b$ = "header,line" + chr$(10) + string$(20000000, 97)' + LF +
             Loop(1000, 'h$ = line$(b$, 1)') + 'if h$ <> "header,line" then x = 1 / 0' + LF,
             1000000, 2000, 1500);
  CheckQuick('s$[1] of a 20 MB text is cheap too',
             'b$ = "header,line" + chr$(10) + string$(20000000, 97)' + LF +
             Loop(1000, 'h$ = b$[1]') + 'if h$ <> "header,line" then x = 1 / 0' + LF,
             1000000, 2000, 1500);
  { ...and a line that is not there walks, and is charged, the whole text: a
    1000000-byte text with no LF read at SCAN 80 is 80000 units a call, and
    24600000 / 80000 = 307.5, so the 308th call latches. }
  CheckMsg('line$ is charged for the whole walk when the line is not there',
           'r$ = string$(1000000, 97)' + LF + Loop(400, 'h$ = line$(r$, 2)'),
           100000, 0, 'line$: the run has spent its step budget of 100000 inside library calls');

  { (8) The TEXT price charged every byte as the densest text there can be.
    Two loads of a 60 MB file of 50-byte lines were refused at 12% of the
    allowance's work; the pieces are now counted. Each load: COPY 60M * 0.128
    = 7680000 after the read, SCAN 4800000, 1200001 pieces at 4352 (5222405)
    and COPY 7680000 for the split: 25382405, twice 50764810 of 256000000. }
  big60 := MakeLinesFile('phosphor_r8_big60.txt', 1200000);
  CheckQuick('two loads of a 60 MB file of 50-byte lines',
             'l@ = strings@()' + LF + 'm@ = strings@()' + LF +
             'n = strings_loadfromfile(l@, "' + big60 + '")' + LF +
             'n = strings_loadfromfile(m@, "' + big60 + '")' + LF +
             'if strings_count(l@) + strings_count(m@) <> 2400000 then x = 1 / 0' + LF,
             1000000, 2000, 3000);
  // Step-only, so the refusal is the budget's arithmetic (the eleventh load:
  // ten spend 253824050 of 256000000) and not whichever clock reads first.
  CheckTimed('twenty loads of it stop at the ceiling',
             'l@ = strings@()' + LF + Loop(20, 'n = strings_loadfromfile(l@, "' + big60 + '")'),
             1000000, 0, 'strings_loadfromfile: ', 4000);
  DeleteFile(big60);
  { ...and a DENSE text still pays what a dense text costs. 100000 lines of
    "a": SCAN 200000 * 0.08 = 16000, 100001 pieces at 4352 = 435205, COPY
    200000 * 0.128 = 25600, 476805 a call. After mulstring$'s 200000, 25400000
    buys 53 calls (25270665) and leaves 129335; the 54th's scan is allowed
    (113335 left) and its pieces are not. }
  CheckMsg('strings_text of a dense text is priced by its pieces',
           't$ = mulstring$("a" + chr$(10), 100000)' + LF + 'l@ = strings@()' + LF +
           Loop(100, 'n = strings_text(l@, t$)'),
           100000, 0, 'strings_text: that would take 435205 units of work and only 113335 are left');

  (* (9) json_parse@ counted the commas INSIDE a string as values. A 1 MB
    document carrying a CSV in one member: '{"csv": "' + 1000000 bytes + '"}'
    is 1000011 bytes with 2 openers outside the string, so a parse is SCAN
    80001 + NODE ceil(3 * 76.8) = 231 + BYTE ceil(1000011 * 1.92) = 1920022:
    2000254. Ten of them fit in a fraction of the pair's allowance; before
    round 8 the seventh was refused. *)
  CheckQuick('ten parses of a 1 MB document carrying a CSV string',
             'r$ = mulstring$("x,", 500000)' + LF +
             'd$ = "{\"csv\": \"" + r$ + "\"}"' + LF +
             Loop(10, 'j@ = json_parse@(d$)' + LF + 'n = json_free(j@)'),
             1000000, 2000, 1500);
  // Step-only, from 24600000: 12 parses spend 24003048 and leave 596952; the
  // 13th's scan (80001) and nodes (231) leave 516720, and its bytes do not fit.
  CheckMsg('json_parse@ is priced by the values outside strings, and the bytes',
           'r$ = mulstring$("x,", 500000)' + LF +
           'd$ = "{\"csv\": \"" + r$ + "\"}"' + LF +
           Loop(20, 'j@ = json_parse@(d$)' + LF + 'n = json_free(j@)'),
           100000, 0, 'json_parse@: that would take 1920022 units of work and only 516720 are left');

  { (10) path_hasvalidfilenamechars was priced at SCAN and cost 2.7 times that.
    At REWRITE 216: 216000 units a megabyte; 24600000 / 216000 = 113.9, so 113
    calls spend 24408000 and the 114th finds 192000. }
  CheckMsg('path_hasvalidfilenamechars is priced at its measured rate (REWRITE)',
           'r$ = string$(1000000, 97)' + LF + Loop(200, 'n = path_hasvalidfilenamechars(r$)'),
           100000, 0, 'path_hasvalidfilenamechars: that would take 216000 units of work and only 192000 are left');
  { changefileext$ makes two copies of stem and extension: 2 * (1000000 + 2)
    at COPY 128 = 256000.512 -> 256001; 96 calls spend 24576096 and leave
    23904. }
  CheckMsg('changefileext$ is priced by its two copies',
           'r$ = string$(1000000, 97)' + LF + Loop(200, 'p$ = changefileext$(r$, ".x")'),
           100000, 0, 'path_changeextension$: that would take 256001 units of work and only 23904 are left');
  CheckQuick('path_hasvalidfilenamechars of an ordinary name',
             Loop(50000, 'n = path_hasvalidfilenamechars("report-2026.txt")'),
             1000000, 2000, 1500);
end;

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

{ ---------------------------------------------------------------------------
  --prices: WHAT EACH PRICED CALL IS CHARGED, BESIDE WHAT IT COSTS (round 8).

  Round 7 wrote a table of BudgetMilli* prices, each "rounded UP from its
  family's slowest member" -- and three of the functions charged from it were
  never in the measurement: strings_delimitedtext$ cost 25-32 times its price,
  path_hasvalidfilenamechars 2.7 times, changefileext$ 2.2 times, while the
  TEXT price refused two loads of a 60 MB file that cost 12% of the allowance.
  A price nobody measured is a guess, and this is the measurement, kept where
  the next price can be held to it.

  Each case runs its statement in a loop under a budget too large to refuse
  anything (MaxSteps 1e12), reads the units the loop was charged (BudgetUsed)
  and the wall time it took, and prints the ratio of the two on the budget's
  own scale (BudgetUnitsPerMsOfWork units = 1 ms). The loop is lengthened until
  it runs at least 300 ms, so GetTickCount64's resolution is a few percent of
  it. The arguments are megabytes, so the VM's own work per iteration is noise.

  THE BOUND, stated once: a charge is right when it is at least HALF of what
  the call costs on this machine (so a host is never over its ceiling by more
  than 2x on this hardware, and a slower one -- Linux under WSL measured 1.1 to
  1.5x -- by less than 3x) and at most FOUR times it (so ordinary work charged
  at a quarter of the allowance is never refused). Outside that the line is
  marked UNDER or OVER and the run exits 1. It prints timings and is not run by
  the suite: a millisecond bar on an unknown machine is red at random -- the
  same reason bench_debug keeps its real measurement behind --full.
--------------------------------------------------------------------------- }
function t_tick(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  Result := ValInt(Int64(GetTickCount64()));
end;

function t_units(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  Result := ValInt(BudgetUsed());
end;

var
  PriceBad: Integer = 0;
  PriceRows: Integer = 0;
  PriceFilter: String = '';   // --prices TEXT: only the cases whose name holds it
  PriceBaseNs: Double = 0;    // the loop's own cost per iteration (the baseline row)

{ One measured loop: K iterations of AStmt after ASetup. ms and units, or
  False when the run failed (a failure must never read as cheap). }
function PriceRun(const ASetup, AStmt: String; K: Int64; out AMs, AUnits: Int64;
                  out AWhy: String): Boolean;
var
  eng: TPhosphorEngine;
  sink: TTextSink;
  src, last: String;
  sl: TStringList;
  sp: Integer;
begin
  Result := False;
  AMs := 0; AUnits := 0; AWhy := '';
  src := ASetup + LF +
         'u0% = budget_units%()' + LF + 't0% = tick_ms%()' + LF +
         'for i = 1 to ' + IntToStr(K) + LF + AStmt + LF + 'next' + LF +
         't1% = tick_ms%()' + LF + 'u1% = budget_units%()' + LF +
         'println str$(t1% - t0%) + " " + str$(u1% - u0%)' + LF;
  eng := TPhosphorEngine.Create();
  sink := TTextSink.Create();
  sl := TStringList.Create();
  try
    RegisterBase64Funcs(eng.Registry);
    RegisterGzipFuncs(eng.Registry);
    RegisterHttpFuncs(eng.Registry);
    eng.Registry.Add('tick_ms%:', @t_tick);
    eng.Registry.Add('budget_units%:', @t_units);
    eng.OnOutput := @sink.Take;
    eng.MaxSteps := 1000000000000;
    if eng.Run(src) <> 0 then
    begin
      AWhy := eng.ErrorMessage;
      Exit;
    end;
    sl.Text := sink.Text;
    if sl.Count = 0 then begin AWhy := 'no output'; Exit; end;
    last := Trim(sl[sl.Count - 1]);
    sp := Pos(' ', last);
    AMs := StrToInt64Def(Copy(last, 1, sp - 1), -1);
    AUnits := StrToInt64Def(Copy(last, sp + 1, MaxInt), -1);
    Result := (AMs >= 0) and (AUnits >= 0);
    if not Result then AWhy := 'unreadable: ' + last;
  finally
    sl.Free;
    sink.Free;
    eng.Free;
  end;
end;

{ AKnown: a price that is outside the bound ON PURPOSE, with the reason -- printed
  beside the row and not counted against the sweep. Each one is a debt with its
  reason written down, the way check-budget.py's ALLOWED is. }
procedure Price(const AName, ASetup, AStmt: String; const AKnown: String = '');
var
  k, ms, units: Int64;
  why, mark: String;
  ratio: Double;
begin
  if (PriceFilter <> '') and (Pos(PriceFilter, AName) = 0) and
     (AName <> 'baseline (x = 1)') then Exit;
  k := 1;
  repeat
    if not PriceRun(ASetup, AStmt, k, ms, units, why) then
    begin
      Writeln(Format('%-34s FAILED: %s', [AName, why]));
      Inc(PriceBad);
      Exit;
    end;
    if ms >= 300 then Break;
    if ms < 20 then k := k * 16 else k := k * (450 div ms + 1);
  until k > 100000000;
  Inc(PriceRows);
  if ms <= 0 then
  begin
    Writeln(Format('%-34s k=%-8d %6d ms   charged %9.1f ms   (too fast to judge)',
                   [AName, k, ms, units / BudgetUnitsPerMsOfWork]));
    Exit;
  end;
  ratio := (units / BudgetUnitsPerMsOfWork) / ms;
  { A call whose work, net of the loop's own instructions, is under 5 us is
    constant work: nothing linear is left to under-charge, so only an
    over-charge is judged. The baseline row measures the loop itself. }
  if AName = 'baseline (x = 1)' then
  begin
    PriceBaseNs := ms * 1000000.0 / k;
    mark := '  (the loop itself)';
  end
  else if ms * 1000000.0 / k - PriceBaseNs < 5000 then
  begin
    if ratio > 4.0 then mark := '  OVER (constant work)' else mark := '  constant work';
  end
  else if ratio < 0.5 then mark := '  UNDER'
  else if ratio > 4.0 then mark := '  OVER'
  else mark := '';
  if (AKnown <> '') and ((Pos('UNDER', mark) > 0) or (Pos('OVER', mark) > 0)) then
    mark := mark + ' -- KNOWN: ' + AKnown
  else if (Pos('UNDER', mark) > 0) or (Pos('OVER', mark) > 0) then Inc(PriceBad);
  Writeln(Format('%-34s k=%-8d %6d ms   charged %9.1f ms   ratio %6.2f%s',
                 [AName, k, ms, units / BudgetUnitsPerMsOfWork, ratio, mark]));
end;

procedure RunPrices;
const
  S4 ='s$ = string$(4000000, 97)';
  T4 = 't$ = mulstring$("Hello World 42 ", 266667)';
  LD = 'ld$ = mulstring$("a" + chr$(10), 2000000)';
  LS = 'ls$ = mulstring$(string$(49, 120) + chr$(10), 80000)';
  { An index of 200 documents in the temp folder, each naming 50 tags and 50
    functions in its header, rebuilt into r@. }
  RagKb = 'kb$ = temppath$() + "/phosphor_price_kb"' + LF +
          'n = dir_create(kb$)' + LF +
          'fl$ = ""' + LF + 'tl$ = ""' + LF +
          'for j = 1 to 50' + LF + 'fl$ = fl$ + "f" + str$(j) + ", "' + LF +
          'tl$ = tl$ + "t" + str$(j) + ", "' + LF + 'next' + LF +
          'for d = 1 to 200' + LF +
          'h$ = "---" + chr$(10) + "id: d" + str$(d) + chr$(10) + "title: doc " + str$(d) + chr$(10) +' +
          ' "tags: " + tl$ + chr$(10) + "functions: " + fl$ + chr$(10) + "---" + chr$(10) + "# body" + chr$(10)' + LF +
          'n = file_writealltext(kb$ + "/d" + str$(d) + ".md", h$)' + LF + 'next' + LF +
          'r@ = rag@(kb$)' + LF + 'r@ = rag_rebuild@(r@)';
begin
  Writeln('price sweep: charged / measured, on the budget''s own scale; bound 0.5 .. 4');
  Price('baseline (x = 1)', '', 'x = 1');
  // --- strings: a pass over a 4 MB argument ------------------------------
  Price('ucase$', S4, 'r$ = ucase$(s$)');
  Price('lcase$', S4, 'r$ = lcase$(s$)');
  Price('len', S4, 'n = len(s$)');
  Price('left$ (all)', S4, 'r$ = left$(s$, 4000000)');
  Price('right$ (all)', S4, 'r$ = right$(s$, 4000000)');
  Price('mid$ (from 2)', S4, 'r$ = mid$(s$, 2)');
  Price('trim$', 's$ = " " + string$(4000000, 97) + " "', 'r$ = trim$(s$)');
  Price('ltrim$', 's$ = " " + string$(4000000, 97)', 'r$ = ltrim$(s$)');
  Price('rtrim$', 's$ = string$(4000000, 97) + " "', 'r$ = rtrim$(s$)');
  Price('reverse$', S4, 'r$ = reverse$(s$)',
        'still the quadratic-append price; scripts/probe_budget.lpr pins a refusal of 40 MB ' +
        '(see CpReverse in PhosphorStrLib)');
  Price('proper$', T4, 'r$ = proper$(t$)');
  Price('swapcase$', T4, 'r$ = swapcase$(t$)');
  Price('alcase$', T4, 'r$ = alcase$(t$)');
  Price('aucase$', T4, 'r$ = aucase$(t$)');
  Price('val', 'z$ = string$(4000000, 48)', 'n = val(z$)');
  Price('isnumeric', 'z$ = string$(4000000, 48)', 'n = isnumeric(z$)');
  Price('isalpha', S4, 'n = isalpha(s$)');
  Price('isdigits', 'z$ = string$(4000000, 48)', 'n = isdigits(z$)');
  Price('isalnum', S4, 'n = isalnum(s$)');
  Price('isspace', 'z$ = string$(4000000, 32)', 'n = isspace(z$)');
  Price('islower', S4, 'n = islower(s$)');
  Price('isupper', 'z$ = string$(4000000, 65)', 'n = isupper(z$)');
  Price('strcmp', S4 + LF + 'u$ = string$(4000000, 97)', 'n = strcmp(s$, u$)');
  Price('strcmpi', S4 + LF + 'u$ = string$(4000000, 65)', 'n = strcmpi(s$, u$)');
  Price('startsstr', S4 + LF + 'u$ = string$(3999999, 97)', 'n = startsstr(s$, u$)');
  Price('endsstr', S4 + LF + 'u$ = string$(3999999, 97)', 'n = endsstr(s$, u$)');
  Price('startstext', S4 + LF + 'u$ = string$(3999999, 65)', 'n = startstext(s$, u$)');
  Price('endstext', S4 + LF + 'u$ = string$(3999999, 65)', 'n = endstext(s$, u$)');
  Price('insert$', S4, 'r$ = insert$(s$, "x", 2)');
  Price('delete$', S4, 'r$ = delete$(s$, 2, 1)');
  Price('stuffstring$', S4, 'r$ = stuffstring$(s$, 2, 1, "xy")');
  Price('ltab$', S4, 'r$ = ltab$(s$, 4000010)');
  Price('lfill$', S4, 'r$ = lfill$(s$, 4000010, 46)');
  Price('center$', S4, 'r$ = center$(s$, 4000010)');
  Price('bytemid$', S4, 'r$ = bytemid$(s$, 2, 3999998)');
  Price('strchar$ (middle)', S4, 'r$ = strchar$(s$, 2000000)');
  Price('strsetchar$', S4, 'r$ = strsetchar$(s$, 2000000, "b")');
  Price('instr (absent byte)', S4, 'n = instr(s$, "b")');
  Price('instrrev (absent byte)', S4, 'n = instrrev(s$, "b")');
  Price('countstr', S4, 'n = countstr(s$, "b")');
  Price('containstext', S4, 'n = containstext(s$, "B")');
  Price('replacestr$ (nothing to do)', S4, 'r$ = replacestr$(s$, "b", "c")');
  Price('replacetext$ (nothing to do)', S4, 'r$ = replacetext$(s$, "b", "c")');
  // ...and the searches where every byte is a first-byte hit, the shape the
  // per-hit price exists for.
  Price('instr (every byte a hit)', S4, 'n = instr(s$, "ab")');
  Price('instr (a 1000-byte needle, 1 MB)', 's$ = string$(1000000, 97)', 'n = instr(s$, string$(1000, 97) + "b")');
  Price('countstr (every byte a match)', S4, 'n = countstr(s$, "a")');
  Price('replacestr$ (every byte, a -> bb)', S4, 'r$ = replacestr$(s$, "a", "bb")');
  Price('replacestr$ (a few, in text)', T4, 'r$ = replacestr$(t$, "World", "Earth")');
  Price('wordcount (every byte a hit)', 'w$ = mulstring$("a,", 2000000)', 'n = wordcount(w$, ",b")');
  Price('count (dense lines)', LD, 'n = count(ld$)');
  Price('count (50-byte lines)', LS, 'n = count(ls$)');
  Price('line$ (last of dense)', LD, 'r$ = line$(ld$, 2000000)');
  Price('line$ (last of 50-byte)', LS, 'r$ = line$(ls$, 80000)');
  Price('line$ (first of 4 MB)', LS, 'r$ = line$(ls$, 1)');
  Price('strline$ (last of 50-byte)', LS, 'r$ = strline$(ls$, 80000)');
  Price('strsetline$ (last)', LS, 'r$ = strsetline$(ls$, 80000, "x")');
  Price('wordcount (dense)', 'w$ = mulstring$("a,", 2000000)', 'n = wordcount(w$, ",")');
  Price('wordcount (50-byte)', 'w$ = mulstring$(string$(49, 120) + ",", 80000)', 'n = wordcount(w$, ",")');
  Price('word$ (last, 50-byte)', 'w$ = mulstring$(string$(49, 120) + ",", 80000)', 'r$ = word$(w$, 80000, ",")');
  Price('funcexists?', S4, 'b? = funcexists?(s$)');
  // --- the OS and paths ------------------------------------------------------
  Price('environ$', S4, 'r$ = environ$(s$)');
  Price('path_getfullpath$', 's$ = string$(400000, 97)', 'r$ = path_getfullpath$(s$)');
  Price('path_getfilename$', S4, 'r$ = path_getfilename$(s$)');
  Price('path_getextension$', S4, 'r$ = path_getextension$(s$)');
  Price('path_getdirectoryname$', 's$ = string$(2000000, 97) + "/" + string$(2000000, 97)', 'r$ = path_getdirectoryname$(s$)');
  Price('changefileext$', S4 + '+ ".txt"', 'r$ = changefileext$(s$, ".bak")');
  Price('path_combine$ (3)', S4, 'r$ = path_combine$(s$, "x", "y")');
  Price('path_hasvalidpathchars', S4, 'n = path_hasvalidpathchars(s$)');
  Price('path_hasvalidfilenamechars', S4, 'n = path_hasvalidfilenamechars(s$)');
  Price('path_matchespattern (2-arg, x)', S4, 'n = path_matchespattern(s$, "x")');
  Price('path_matchespattern (*b)', S4, 'n = path_matchespattern(s$, "*b")');
  Price('file_exists (long path)', S4, 'n = file_exists(s$)');
  Price('dir_exists (long path)', S4, 'n = dir_exists(s$)');
  Price('file_readalltext$ (long path)', S4, 'r$ = file_readalltext$(s$)');
  Price('file_getsize (long path)', S4, 'n = file_getsize(s$)');
  Price('dir_getfiles$ (long path)', S4, 'r$ = dir_getfiles$(s$)');
  // --- lists -----------------------------------------------------------------
  Price('strings_text (dense)', LD + LF + 'l@ = strings@()', 'n = strings_text(l@, ld$)');
  Price('strings_text (50-byte)', LS + LF + 'l@ = strings@()', 'n = strings_text(l@, ls$)');
  Price('strings_commatext (dense)', 'c$ = mulstring$("a,", 2000000)' + LF + 'l@ = strings@()', 'n = strings_commatext(l@, c$)');
  Price('strings_commatext (50-byte)', 'c$ = mulstring$(string$(49, 120) + ",", 80000)' + LF + 'l@ = strings@()', 'n = strings_commatext(l@, c$)');
  Price('strings_delimitedtext (dense)', 'c$ = mulstring$("a,", 2000000)' + LF + 'l@ = strings@()', 'n = strings_delimitedtext(l@, c$)');
  Price('strings_delimitedtext (50-byte)', 'c$ = mulstring$(string$(49, 120) + ",", 80000)' + LF + 'l@ = strings@()', 'n = strings_delimitedtext(l@, c$)');
  Price('strings_delimitedtext (quoted)', 'c$ = mulstring$(chr$(34) + "a b" + chr$(34) + ",", 1000000)' + LF + 'l@ = strings@()', 'n = strings_delimitedtext(l@, c$)');
  Price('strings_text$ (dense)', LD + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, ld$)', 'r$ = strings_text$(l@)');
  Price('strings_text$ (50-byte)', LS + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, ls$)', 'r$ = strings_text$(l@)');
  Price('strings_commatext$ (dense)', LD + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, ld$)', 'r$ = strings_commatext$(l@)');
  Price('strings_delimitedtext$ (quoted)', 's$ = mulstring$("ab,c d" + chr$(10), 500000)' + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, s$)', 'r$ = strings_delimitedtext$(l@)');
  Price('strings_delimitedtext$ (plain)', LD + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, ld$)', 'r$ = strings_delimitedtext$(l@)');
  Price('strings_indexof (absent)', LD + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, ld$)', 'n = strings_indexof(l@, "zz")');
  Price('strings_indexofname (absent)', 'k$ = mulstring$("k=v" + chr$(10), 1000000)' + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, k$)', 'n = strings_indexofname(l@, "zz")');
  Price('strings_values$ (absent)', 'k$ = mulstring$("k=v" + chr$(10), 1000000)' + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, k$)', 'r$ = strings_values$(l@, "zz")');
  Price('strings_insert (front)', LD + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, ld$)', 'n = strings_insert(l@, 1, "x")' + LF + 'n = strings_delete(l@, 1)');
  Price('strings_sort (sorted input)', LD + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, ld$)', 'n = strings_sort(l@)');
  Price('strings_equals', LD + LF + 'l@ = strings@()' + LF + 'n = strings_text(l@, ld$)' + LF + 'm@ = strings@()' + LF + 'n = strings_text(m@, ld$)', 'n = strings_equals(l@, m@)');
  // --- dictionaries -----------------------------------------------------------
  Price('dict_get (4 MB key)', S4 + LF + 'd@ = dict@()', 'n = dict_get(d@, s$)');
  Price('dict_set@ (4 MB key)', S4 + LF + 'd@ = dict@()', 'd@ = dict_set@(d@, s$, 1)');
  Price('dict_remove (front of 200000)', 'd@ = dict@()' + LF + 'for i = 1 to 200000' + LF + 'd@ = dict_set@(d@, "k" + str$(i), 1)' + LF + 'next', 'n = dict_remove(d@, "k1")' + LF + 'd@ = dict_set@(d@, "k1", 1)');
  // --- json --------------------------------------------------------------------
  Price('json_parse@ (numbers)', 'j$ = "[" + mulstring$("1,", 500000) + "1]"', 'j@ = json_parse@(j$)' + LF + 'n = json_free(j@)');
  Price('json_parse@ (short strings)', 'j$ = "[" + mulstring$(chr$(34) + "abcdefgh" + chr$(34) + ",", 200000) + "1]"', 'j@ = json_parse@(j$)' + LF + 'n = json_free(j@)');
  Price('json_parse@ (one long string)', 'j$ = "[" + chr$(34) + string$(4000000, 97) + chr$(34) + "]"', 'j@ = json_parse@(j$)' + LF + 'n = json_free(j@)');
  Price('json_parse@ (csv in a string)', 'j$ = "{" + chr$(34) + "csv" + chr$(34) + ": " + chr$(34) + mulstring$("x,", 500000) + chr$(34) + "}"', 'j@ = json_parse@(j$)' + LF + 'n = json_free(j@)');
  Price('json_clone@', 'j@ = json_parse@("[" + mulstring$("1,", 500000) + "1]")', 'c@ = json_clone@(j@)' + LF + 'n = json_free(c@)');
  Price('json_stringify$', 'j@ = json_parse@("[" + mulstring$("123,", 500000) + "1]")', 'r$ = json_stringify$(j@)');
  Price('json_value$ (a string)', 'j@ = json_parse@("[" + chr$(34) + string$(4000000, 97) + chr$(34) + "]")', 'r$ = json_value$(j@)');
  Price('json_keys@', 'j@ = json_object@()' + LF + 'for i = 1 to 200000' + LF + 'j@ = json_setn@(j@, "k" + str$(i), 1)' + LF + 'next', 'k@ = json_keys@(j@)' + LF + 'n = json_free(k@)');
  Price('json_removeat@ (front)', 'j@ = json_parse@("[" + mulstring$("1,", 1000000) + "1]")', 'j@ = json_removeat@(j@, 1)' + LF + 'j@ = json_pushn@(j@, 1)');
  Price('json_remove@ (first member)', 'j@ = json_object@()' + LF + 'for i = 1 to 200000' + LF + 'j@ = json_setn@(j@, "k" + str$(i), 1)' + LF + 'next', 'j@ = json_remove@(j@, "k1")' + LF + 'j@ = json_setn@(j@, "k1", 1)');
  Price('json_setn@ (replace first)', 'j@ = json_object@()' + LF + 'for i = 1 to 200000' + LF + 'j@ = json_setn@(j@, "k" + str$(i), 1)' + LF + 'next', 'j@ = json_setn@(j@, "k1", 2)');
  Price('json_paths$ (long path)', 'j@ = json_parse@("{}")' + LF + S4, 'r$ = json_paths$(j@, s$)');
  // --- buffers -----------------------------------------------------------------
  Price('buffer_fill', 'b@ = buffer_new@(4000000)', 'n = buffer_fill(b@, 7)');
  Price('buffer_slice$', 'b@ = buffer_new@(4000000)', 'r$ = buffer_slice$(b@, 1, 4000000)');
  Price('buffer_write', 'b@ = buffer_new@(4000000)' + LF + S4, 'n = buffer_write(b@, 1, s$)');
  Price('buffer_copy', 'b@ = buffer_new@(4000000)' + LF + 'c@ = buffer_new@(4000000)', 'n = buffer_copy(c@, 1, b@, 1, 4000000)');
  Price('buffer_equal', 'b@ = buffer_new@(4000000)' + LF + 'c@ = buffer_new@(4000000)', 'n = buffer_equal(b@, c@)');
  Price('buffer_fromstr@', S4, 'b@ = buffer_fromstr@(s$)' + LF + 'n = buffer_free(b@)');
  Price('buffer_tostr$', 'b@ = buffer_new@(4000000)', 'r$ = buffer_tostr$(b@)');
  Price('buffer_indexof (absent)', 'b@ = buffer_new@(4000000)', 'n = buffer_indexof(b@, "x")');
  Price('buffer_indexof (every byte a hit)', 'b@ = buffer_new@(4000000)' + LF + 'n = buffer_fill(b@, 97)', 'n = buffer_indexof(b@, "ab")');
  // --- crypto, encoders --------------------------------------------------------
  Price('crypto_equal?', S4 + LF + 'u$ = string$(4000000, 97)', 'b? = crypto_equal?(s$, u$)');
  Price('sha256$', S4, 'r$ = sha256$(s$)');
  Price('md5$', S4, 'r$ = md5$(s$)');
  Price('base64_encode$', S4, 'r$ = base64_encode$(s$)');
  Price('base64_decode$', 'e$ = base64_encode$(string$(3000000, 97))', 'r$ = base64_decode$(e$)');
  Price('hex_encode$', S4, 'r$ = hex_encode$(s$)');
  Price('hex_decode$', 'e$ = hex_encode$(string$(2000000, 97))', 'r$ = hex_decode$(e$)');
  Price('http_urlencode$', T4, 'r$ = http_urlencode$(t$)');
  Price('http_urldecode$', 'e$ = mulstring$("a%20b", 800000)', 'r$ = http_urldecode$(e$)');
  Price('http_htmlencode$', 'e$ = mulstring$("a<b", 1333333)', 'r$ = http_htmlencode$(e$)');
  Price('http_htmldecode$', 'e$ = mulstring$("a&lt;b", 666666)', 'r$ = http_htmldecode$(e$)');
  Price('gzip_compress$ (one byte repeated)', S4, 'r$ = gzip_compress$(s$)');
  Price('gzip_compress$ (random bytes)', 'b@ = buffer_new@(1000000)' + LF +
        'for j = 1 to 1000000' + LF + 'buffer_set(b@, j, int(rnd() * 256))' + LF + 'next' + LF +
        'g$ = buffer_tostr$(b@)', 'r$ = gzip_compress$(g$)');
  Price('gzip_compress$ (text)', T4, 'r$ = gzip_compress$(t$)');
  // English: this tree's own reference, a few times over (run from the root).
  Price('gzip_compress$ (english, 6)', 'e$ = mulstring$(file_readalltext$("docs/function-reference.md"), 3)', 'r$ = gzip_compress$(e$)');
  Price('gzip_compress$ (english, 1)', 'e$ = mulstring$(file_readalltext$("docs/function-reference.md"), 3)', 'r$ = gzip_compress$(e$, 1)');
  Price('gzip_compress$ (english, 9)', 'e$ = mulstring$(file_readalltext$("docs/function-reference.md"), 3)', 'r$ = gzip_compress$(e$, 9)');
  Price('gzip_compress$ (text, 9)', T4, 'r$ = gzip_compress$(t$, 9)');
  Price('gzip_compress$ (random, 9)', 'b@ = buffer_new@(1000000)' + LF +
        'for j = 1 to 1000000' + LF + 'buffer_set(b@, j, int(rnd() * 256))' + LF + 'next' + LF +
        'g$ = buffer_tostr$(b@)', 'r$ = gzip_compress$(g$, 9)');
  Price('gzip_compress$ (one byte, 1)', S4, 'r$ = gzip_compress$(s$, 1)');
  Price('gzip_decompress$ (text)', T4 + LF + 'z$ = gzip_compress$(t$)', 'r$ = gzip_decompress$(z$)');
  // --- config ------------------------------------------------------------------
  Price('cfg_sets@ (4 MB value)', 'c@ = cfg_open@("")' + LF + S4, 'c@ = cfg_sets@(c@, "k", s$)');
  Price('cfg_gets$ (4 MB value)', 'c@ = cfg_open@("")' + LF + S4 + LF + 'c@ = cfg_sets@(c@, "k", s$)', 'r$ = cfg_gets$(c@, "k", "")');
  Price('formatsettings$', S4, 'r$ = formatsettings$(s$)');
  Price('color', S4, 'n = color(s$)');
  // --- rag -----------------------------------------------------------------------
  Price('rag_analyze$ (a 4 MB query)', 'r@ = rag@("")' + LF + T4, 'a$ = rag_analyze$(r@, t$)');
  Price('rag_retrieve$ (a 4 MB query)', 'r@ = rag@("")' + LF + T4, 'a$ = rag_retrieve$(r@, t$)');
  Price('rag_functions$ (a 4 MB list)', 'r@ = rag@("")' + LF + T4, 'a$ = rag_functions$(r@, t$)');
  Price('rag_tags$ (a 4 MB list)', 'r@ = rag@("")' + LF + 's$ = mulstring$("tag,", 1000000)', 'a$ = rag_tags$(r@, s$)');
  // ...and against an index: 200 documents of 50 tags and 50 functions each,
  // so the products the price names are what the work is.
  Price('rag_functions$ (1000 names, 200 docs)', RagKb + LF +
        'q$ = ""' + LF + 'for j = 1 to 1000' + LF + 'q$ = q$ + "nf" + str$(j) + " "' + LF + 'next',
        'a$ = rag_functions$(r@, q$)');
  Price('rag_tags$ (1000 tags, 200 docs)', RagKb + LF +
        'q$ = ""' + LF + 'for j = 1 to 1000' + LF + 'q$ = q$ + "nt" + str$(j) + ","' + LF + 'next',
        'a$ = rag_tags$(r@, q$)');
  Price('rag_retrieve$ (1000 words, 200 docs)', RagKb + LF +
        'q$ = ""' + LF + 'for j = 1 to 1000' + LF + 'q$ = q$ + "word" + str$(j) + " "' + LF + 'next',
        'a$ = rag_retrieve$(r@, q$)');
  Price('rag_rebuild@ (200 docs)', RagKb, 'r@ = rag_rebuild@(r@)');
  Writeln(Format('price sweep: %d rows, %d outside the bound', [PriceRows, PriceBad]));
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = '--prices') then
  begin
    if ParamCount >= 2 then PriceFilter := ParamStr(2);
    RunPrices();
    if PriceBad > 0 then Halt(1) else Halt(0);
  end;
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

  { --- the crypto library's cost is the script's to name ---------------------
    PBKDF2 runs the iteration count it is given inside ONE opCall, and
    password_verify? runs the count a stored record names -- data, not code.
    Two billion iterations is about twenty minutes here; each ceiling must stop
    it, and the clock one must stop it near its own limit, not at the end. }
  CryptoStart := GetTickCount64();
  Check('a step ceiling stops pbkdf2_sha256$',
        'k$ = pbkdf2_sha256$("pw", "salt", 2000000000, 32)' + LF,
        100000, 0, 0, True);
  Check('a time ceiling stops pbkdf2_sha256$',
        'k$ = pbkdf2_sha256$("pw", "salt", 2000000000, 32)' + LF,
        0, 0, 100, True);
  Check('a time ceiling stops a record that names its own cost',
        'ok? = password_verify?("pw", "pbkdf2_sha256$2000000000$salt$' +
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")' + LF,
        0, 0, 100, True);
  { THE SALT IS WORK TOO (round 5): each of the 32 blocks of a 1024-byte key
    hashes the whole salt again, at ONE round -- so the rounds charge almost
    nothing and an uncharged 4 MB salt ran the derivation ~9x past the clock. }
  { ROUND 6: the time ceiling must stop it BEFORE the work, by the salt's
    charge -- a refusal that came 7x late, after the derivation, passed the
    first version of this check, which asked only whether a limit happened.
    So the MESSAGE is asked: the salt's up-front refusal says "that would
    take", the clock's after-the-fact one says "spent its time limit". }
  CheckMsg('a time ceiling refuses a large salt before hashing it',
        'k$ = pbkdf2_sha256$("pw", string$(4000000, 97), 1, 1024)' + LF,
        0, 100, 'pbkdf2_sha256$: that would take');
  { 200000 steps = 51.2M units. string$ charges one unit per byte
    (PhosphorStrLib's RunOf: BudgetAllows(total)), so building the salt costs
    4M and leaves 47.2M; each of the 32 blocks hashes 4000004 bytes, 62501
    compressions at UnitsPerBlock = 36, 2.25M -- 72M in all. Refused around
    the 21st block; the old code charged nothing for the salt and finished. }
  Check('a step ceiling refuses salt hashing past what is left',
        'k$ = pbkdf2_sha256$("pw", string$(4000000, 97), 1, 1024)' + LF,
        200000, 0, 0, True);
  { ROUND 6: the two ceilings buy one allowance. Under the pair embedding.md
    prescribes, two verifications of a record at Django 5.2's default cost
    (1000000 rounds, about 1.2 s) must both run -- the step ceiling refused the
    second one, after doing its work, while TimeoutMs alone let both finish.
    The record is Python's: hashlib.pbkdf2_hmac('sha256', b'pw',
    b'saltsaltsalt', 1000000, 32), base64. }
  Check('two verifications at Django''s default cost fit MaxSteps = 1000000',
        'r$ = "pbkdf2_sha256$1000000$saltsaltsalt$bFRD7M/RDtmj3WYL25AnrV5IwE7YUQyQ4h1XGcXRuDw="' + LF +
        'if password_verify?("pw", r$) = false then x = 1 / 0' + LF +
        'if password_verify?("pw", r$) = false then x = 1 / 0' + LF,
        1000000, 0, 0, False);
  Report(GetTickCount64() - CryptoStart < 10000,
         'the crypto ceilings stopped within seconds, not minutes');
  { THE DIGESTS ARE WORK TOO (round-6 diff review): they charged nothing, so a
    loop of them over a large string ran past every ceiling and reported
    success -- one call is one instruction. 1000000 steps = 256M units;
    string$ of 10 MB charges 10M; each digest of it is 156251 blocks at
    UnitsPerBlock = 36, 5.6M -- so about the 44th call is refused, before it
    hashes, and the 200 the loop asks for are never reached. The old code
    hashed all 200 (about 2 GB) and finished. }
  CheckMsg('a step ceiling refuses sha256$ past what is left',
        's$ = string$(10000000, 97)' + LF +
        'for i = 1 to 200' + LF + 'k$ = sha256$(s$)' + LF + 'next' + LF,
        1000000, 0, 'sha256$: that would take');
  CheckMsg('a step ceiling refuses sha1$ past what is left',
        's$ = string$(10000000, 97)' + LF +
        'for i = 1 to 200' + LF + 'k$ = sha1$(s$)' + LF + 'next' + LF,
        1000000, 0, 'sha1$: that would take');
  CheckMsg('a step ceiling refuses md5$ past what is left',
        's$ = string$(10000000, 97)' + LF +
        'for i = 1 to 200' + LF + 'k$ = md5$(s$)' + LF + 'next' + LF,
        1000000, 0, 'md5$: that would take');
  CheckMsg('a step ceiling refuses hmac_sha256$ past what is left',
        's$ = string$(10000000, 97)' + LF +
        'for i = 1 to 200' + LF + 'k$ = hmac_sha256$("key", s$)' + LF + 'next' + LF,
        1000000, 0, 'hmac_sha256$: that would take');
  // ...and the documented default fits inside the budget embedding.md prescribes.
  Check('password_hash$ at its default cost fits MaxSteps = 1000000',
        'r$ = password_hash$("pw")' + LF +
        'if password_verify?("pw", r$) = false then x = 1 / 0' + LF,
        1000000, 0, 0, False);

  { --- round 7: every linear pass is priced, by its measured family --------
    THE EXACT REFUSAL POINTS, under MaxSteps = 100000 alone (no clock, so the
    arithmetic is the whole story): the allowance is 100000 * 256 = 25600000
    units, string$(1000000, c) costs 1000000 of them (RunOf asks one a byte),
    and each call is ceil(bytes * price / 1000) for its family's price in
    PhosphorBudget. A pass asked up front (BudgetLinearOk) is refused, without
    latching, at the first call whose price exceeds what is left; a walk charged
    after it ran (BudgetLinearAfterOk) and a metered walk latch at the call that
    crosses the line. The old code charged nothing for any of these and ran all
    of its calls. }
  // ucase$, REWRITE 216: 216000 a call; 24600000 / 216000 = 113.9, so 113 calls
  // spend 24408000 and leave 192000 for the 114th.
  CheckMsg('ucase$ is priced per byte (REWRITE)',
           'r$ = string$(1000000, 97)' + LF + Loop(200, 's$ = ucase$(r$)'),
           100000, 0, 'ucase$: that would take 216000 units of work and only 192000 are left');
  // len, SCAN 80: 80000 a call; 307 calls spend 24560000 and leave 40000.
  CheckMsg('len is priced per byte (SCAN)',
           'r$ = string$(1000000, 97)' + LF + Loop(400, 'n = len(r$)'),
           100000, 0, 'len: that would take 80000 units of work and only 40000 are left');
  // val, NUMBER 432: 432000 a call; 56 calls spend 24192000 and leave 408000.
  CheckMsg('val is priced per byte (NUMBER)',
           'z$ = string$(1000000, 48)' + LF + Loop(200, 'n = val(z$)'),
           100000, 0, 'val: that would take 432000 units of work and only 408000 are left');
  // environ$, OS 1064: 1064000 a call; 23 calls spend 24472000 and leave 128000.
  CheckMsg('environ$ is priced per byte (OS)',
           'r$ = string$(1000000, 97)' + LF + Loop(200, 'e$ = environ$(r$)'),
           100000, 0, 'environ$: that would take 1064000 units of work and only 128000 are left');
  // funcexists?, its own 320 (2.5 ns a byte, PhosphorCallLib): 320000 a call;
  // 24600000 / 320000 = 76.9, so 76 calls spend 24320000 and leave 280000.
  CheckMsg('funcexists? is priced per byte',
           'r$ = string$(1000000, 97)' + LF + Loop(200, 'b? = funcexists?(r$)'),
           100000, 0, 'funcexists?: that would take 320000 units of work and only 280000 are left');
  // strcmp, SCAN over the shorter: two strings cost 2000000; 80000 a call;
  // 23600000 / 80000 = 295 exactly, so the 296th finds 0 left.
  CheckMsg('strcmp is priced by the shorter argument (SCAN)',
           'r$ = string$(1000000, 97)' + LF + 't$ = string$(1000000, 97)' + LF +
           Loop(400, 'n = strcmp(r$, t$)'),
           100000, 0, 'strcmp: that would take 80000 units of work and only 0 are left');
  CheckMsg('crypto_equal? is priced by the shorter argument (SCAN)',
           'r$ = string$(1000000, 97)' + LF + 't$ = string$(1000000, 97)' + LF +
           Loop(400, 'b? = crypto_equal?(r$, t$)'),
           100000, 0, 'crypto_equal?: that would take 80000 units of work and only 0 are left');
  // path_getfilename$, COPY 128: 128000 a call; 192 calls spend 24576000.
  CheckMsg('path_getfilename$ is priced per byte (COPY)',
           'r$ = string$(1000000, 97)' + LF + Loop(300, 'f$ = path_getfilename$(r$)'),
           100000, 0, 'path_getfilename$: that would take 128000 units of work and only 24000 are left');
  // left$ walks to the count, and is charged for what it walked AFTER the walk
  // (COPY 128): 1000000 + 128000 k passes 25600000 at k = 193, which latches.
  CheckMsg('left$ is charged for the walk it made',
           'r$ = string$(1000000, 97)' + LF + Loop(300, 's$ = left$(r$, 1000000)'),
           100000, 0, 'left$: the run has spent its step budget of 100000 inside library calls');
  // ...and a short left$ of the same string costs three characters, not the
  // string: 300 of them are 3 * 128 / 1000 -> 1 unit each.
  Check('left$ of three characters of a long string is cheap',
        'r$ = string$(1000000, 97)' + LF + Loop(300, 's$ = left$(r$, 3)'),
        100000, 0, 0, False);
  // dict_haskey: the key is priced before it is hashed (COPY, 128000), and the
  // hash is metered again inside IndexOf (128000 more, charged at its end). So
  // a call costs 256000 and is ASKED 128000: after 95 calls 280000 is left, the
  // 96th is allowed and leaves 24000, and the 97th is refused.
  CheckMsg('dict_haskey is priced by its key',
           'r$ = string$(1000000, 97)' + LF + 'd@ = dict@()' + LF +
           Loop(200, 'n = dict_haskey(d@, r$)'),
           100000, 0, 'dict_haskey: that would take 128000 units of work and only 24000 are left');
  // strings_values$ is metered per line: NAMEITEM 4096 + 2 bytes of name at
  // COPY 128 = 4352 milli a line, 435200 units a call over 100000 lines. The
  // list costs mulstring$'s 400000 and strings_text's SCAN 32000 + 100001
  // pieces at 4352 (435205) + COPY 51200 = 518405 (round 8; it was TEXT,
  // 832000); 24681595 left buys 56 calls (24371200), and the 57th latches
  // mid-walk.
  CheckMsg('strings_values$ is metered per line',
           'l@ = strings@()' + LF +
           'n = strings_text(l@, mulstring$("k=v" + chr$(10), 100000))' + LF +
           Loop(200, 'v$ = strings_values$(l@, "zzz")'),
           100000, 0, 'strings_values$: the run has spent its step budget of 100000 inside library calls');
  // json_clone@ is priced per node, before it copies (CLONE 7680 milli): a
  // 100001-element array is 768008 units a clone.
  CheckMsg('json_clone@ is priced per node before it copies',
           'j@ = json_parse@("[" + mulstring$("1,", 100000) + "1]")' + LF +
           Loop(200, 'c@ = json_clone@(j@)' + LF + 'n = json_free(c@)'),
           100000, 0, 'json_clone@: the run has spent its step budget of 100000 inside library calls');

  { THE SAME, UNDER THE PAIR docs/embedding.md PRESCRIBES (MaxSteps 1000000,
    TimeoutMs 2000), on the findings' own shapes -- each ran 6 to 45 times past
    the clock and reported success. Each must now stop with the function named
    within 3000 ms: the ceiling plus one call. }
  CheckTimed('ucase$ x200 of 50 MB stops at the ceiling',
             'r$ = string$(50000000, 97)' + LF + Loop(200, 's$ = ucase$(r$)'),
             1000000, 2000, 'ucase$: ', 3000);
  CheckTimed('environ$ x200 of 50 MB stops at the ceiling',
             'r$ = string$(50000000, 97)' + LF + Loop(200, 'e$ = environ$(r$)'),
             1000000, 2000, 'environ$: ', 3000);
  CheckTimed('funcexists? x200 of 10 MB stops at the ceiling',
             'r$ = string$(10000000, 97)' + LF + Loop(200, 'b? = funcexists?(r$)'),
             1000000, 2000, 'funcexists?: ', 3000);
  CheckTimed('strings_values$ x200 over 2000000 lines stops at the ceiling',
             'l@ = strings@()' + LF +
             'n = strings_text(l@, mulstring$("k=v" + chr$(10), 2000000))' + LF +
             Loop(200, 'v$ = strings_values$(l@, "zzz")'),
             1000000, 2000, 'strings_values$: ', 3000);
  CheckTimed('json_clone@ x200 of 1000001 nodes stops at the ceiling',
             'j@ = json_parse@("[" + mulstring$("1,", 1000000) + "1]")' + LF +
             Loop(200, 'c@ = json_clone@(j@)' + LF + 'n = json_free(c@)'),
             1000000, 2000, 'json_clone@: ', 3000);
  CheckTimed('dict_get x200 with a 50 MB key stops at the ceiling',
             'r$ = string$(50000000, 97)' + LF + 'd@ = dict@()' + LF +
             Loop(200, 'n = dict_get(d@, r$)'),
             1000000, 2000, 'dict_get: ', 3000);
  { JsonText's swallowed refusal: json_value$ of a 30 MB array answered "" on its
    eighth call and the run reported success. A render the budget stops is now
    the peLimit of the function that asked for it.

    RE-DERIVED IN ROUND 8, when a rendered byte stopped costing a whole unit
    (7.8 ns; it measures under 2) and costs JsonRenderMilliPerByte, 320: the
    string$ is 30000000 units and the parse SCAN + BYTE 2 * 30000004 = about
    60000008, leaving about 166M; a render is 30000004 * 0.32 = 9600002, so
    the eighth no longer reaches the line and the 18th does. Step-only, so it
    is the budget that stops the render and not whichever clock reads first. }
  CheckTimed('json_value$ reports a render the budget stopped',
             's$ = "[" + chr$(34) + string$(30000000, 97) + chr$(34) + "]"' + LF +
             'j@ = json_parse@(s$)' + LF + Loop(40, 'v$ = json_value$(j@)'),
             1000000, 0, 'json_value$: ', 3000);
  { rag_analyze$, now LINEAR (its dedup was quadratic) and priced by the query:
    40000 words "w1 w2 ..." are 268894 bytes (188894 digits, 40000 w's and a
    separator after each), at RagAnalyzeMilliPerByte 1000000 (round 8; it was
    1216000) = 268894000 units: more than the whole 256000000 allowance, so it
    is refused up front. }
  CheckTimed('rag_analyze$ of a 40000-word query is refused up front',
             'l@ = strings@()' + LF + Loop(40000, 'n = strings_add(l@, "w" + str$(i))') +
             'n = strings_linebreak(l@, " ")' + LF + 'q$ = strings_text$(l@)' + LF +
             'r@ = rag@("")' + LF + 'a$ = rag_analyze$(r@, q$)' + LF,
             1000000, 2000, 'rag_analyze$: that would take 268894000 units', 3000);

  { AND THE LEGITIMATE CALLS OF ORDINARY SIZE STILL RUN, under the pair, and
    quickly. strings_delimitedtext was QUADRATIC: one call on four megabytes
    took 19484 ms and succeeded -- a success check alone would pass it, so each
    of these is bounded in time as well. }
  CheckQuick('strings_delimitedtext of 4 MB is linear',
             'l@ = strings@()' + LF + 'n = strings_delimitedtext(l@, mulstring$("a,", 2000000))' + LF +
             'if n <> 2000001 then x = 1 / 0' + LF,
             1000000, 2000, 1500);
  CheckQuick('count and line$ of a 1 MB text split nothing',
             't$ = mulstring$("ab" + chr$(13) + chr$(10), 350000)' + LF +
             'if count(t$) <> 350001 then x = 1 / 0' + LF +
             'if line$(t$, 350000) <> "ab" then x = 1 / 0' + LF,
             1000000, 2000, 1500);
  CheckQuick('ucase$ of 3 MB once',
             's$ = ucase$(string$(3000000, 97))' + LF +
             'if bytelen(s$) <> 3000000 then x = 1 / 0' + LF,
             1000000, 2000, 1500);
  // 75001 elements rendered compact: 75000 "123" and one "1", ", " between
  // each pair (JsonWrite's array branch), and the brackets:
  // 225000 + 1 + 75000 * 2 + 2 = 375003 bytes.
  CheckQuick('json of a few hundred kilobytes parses and renders',
             'j@ = json_parse@("[" + mulstring$("123,", 75000) + "1]")' + LF +
             's$ = json_stringify$(j@)' + LF +
             'if bytelen(s$) <> 375003 then x = 1 / 0' + LF,
             1000000, 2000, 1500);
  CheckQuick('rag_analyze$ of an ordinary question',
             'r@ = rag@("")' + LF +
             'a$ = rag_analyze$(r@, "how do I read a json file and sort the keys")' + LF +
             'if bytelen(a$) = 0 then x = 1 / 0' + LF,
             1000000, 2000, 1500);
  { The two other quadratics, at a size the budget ALLOWS -- so only their
    speed can fail these. rag_analyze$ deduplicated by scanning everything kept
    (20000 "$" words: 2891 ms, past the clock); a query of them is 148894 bytes,
    149 million units at RagAnalyzeMilliPerByte, inside the allowance, and runs
    in under a second now. wordcount's SplitBy reallocated its slots once per
    piece (4 million pieces: about 2 s; ten million: 12197 ms). }
  CheckQuick('rag_analyze$ of 20000 distinct words is linear',
             'l@ = strings@()' + LF + Loop(20000, 'n = strings_add(l@, "w" + str$(i) + "$")') +
             'n = strings_linebreak(l@, " ")' + LF + 'q$ = strings_text$(l@)' + LF +
             'r@ = rag@("")' + LF + 'a$ = rag_analyze$(r@, q$)' + LF +
             'if bytelen(a$) = 0 then x = 1 / 0' + LF,
             1000000, 2000, 3000);
  { That check can be met by a quadratic dedup: at the largest query the budget
    allows, the dedup's share is a second or so beside the intent scoring that
    dominates. So the SHAPE is measured too, with no ceilings, the way
    CheckNameTablesScale measures the name tables: a query of 5000 words
    analysed eight times against one of 40000 analysed once. Linear, the two
    cost the same; the old dedup made the second about six times the first
    (1593 against 10172 ms at 40000). Best of two, threshold 2: linear measured
    1.1, and the old dedup in ExtractKeywords ALONE measured 2.8. }
  CheckRagScale();
  CheckQuick('wordcount of 4000000 pieces is linear',
             'if wordcount(mulstring$("a,", 4000000), ",") <> 4000001 then x = 1 / 0' + LF,
             1000000, 2000, 1500);
  { Every file operation prices its PATH at the door (IoGate): a 50 MB path is
    10800000 units at the REWRITE rate (round 8; it was the OS rate), and after
    string$'s 50000000 the 20th file_exists of one is refused -- and it is
    REPORTED, as file_exists's peLimit, not answered 0. }
  CheckTimed('file_exists x200 of a 50 MB path stops at the ceiling',
             'r$ = string$(50000000, 97)' + LF + Loop(200, 'n = file_exists(r$)'),
             1000000, 2000, 'file_exists: ', 3000);
  CheckQuick('funcexists? of a 50 MB name is one linear pass',
             'b? = funcexists?(string$(50000000, 97))' + LF +
             'if b? = true then x = 1 / 0' + LF,
             1000000, 2000, 1500);

  CheckRound8();

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
    door, these two rows are what must move with it.
    IT STAYS OPEN BY DECISION (ledger r1, 2026-10-08): which names are
    functions depends on the host, so a refusal here would make whether a file
    compiles depend on where. What closed instead is the silence --
    `phosphor compile --check` reports a name read and never assigned that is
    a function of no arguments (UnassignedFunctionNames, block G2 of
    test.ps1 and test.sh), and scripts/check-examples.py runs that over every
    program in the tree. These rows pin that the COMPILER still accepts it. }
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

  CheckNameTablesScale();
  CheckMaxHandles();
  CheckMaxHandlesDoors();
  CheckFreesKeepTheLevel();
  CheckReusedCompilerNames();

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
