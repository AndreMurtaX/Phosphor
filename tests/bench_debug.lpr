{******************************************************************************
  bench_debug -- what the debug seam costs, measured, in the tree.

  WHY THIS IS COMMITTED AND NOT A NUMBER IN A DOCUMENT. Three rounds of review
  disagreed about one cell of docs/embedding.md's cost table -- whether deleting
  the two hook lines recovers the detached cost -- and none of them could settle
  it, because each ran a bench that lived in its author's scratch directory and
  went away with it. A measurement nobody else can re-run is an assertion. This
  file is the re-run.

  IT PRINTS AND IT DOES NOT JUDGE TIME. There is no threshold anywhere in here: a
  fixed millisecond bar on an unknown machine produces red at random, which
  teaches everyone to ignore the file. What it DOES judge is the differential --
  that attaching a debugger, arming it, and stepping through every boundary
  change nothing the program computes, prints or answers -- and that assertion is
  why this is a probe and not a script.

  THE VARIANTS, and the first one is not a switch in this file.

    A   the debugger NOT LINKED AT ALL. The hook is inside PhosphorVM.pas, so
        this is not a compile-time option in the host: it is a different engine.
        Compile this same source against a tree from BEFORE the seam existed,
        with -dNOSEAM, and you have A.
    B   this engine, seam never installed, never armed.
    C   attached: seam installed and armed on lines no boundary carries. The
        state a debugging session spends nearly all of its time in.
    D   armed, stopped at entry, answering `step into` for ever. One seam call
        per statement boundary.

  A vs B is the question an embedder who never debugs asks. B vs C is the cost of
  having a debugger attached. C vs D is the cost of a seam call.

  A AND B CANNOT BE INTERLEAVED, which is most of the protocol: they are two
  binaries, so a driver has to alternate the PROCESSES round by round and take
  the best of each, never a mean and never one pass each. B, C and D live in one
  binary and are interleaved inside a single pass, which is why those three cells
  have reproduced across every reviewer and the A cell has not.

  USAGE
    bench_debug              the differential, plus short indicative timings.
                             This is what the suite runs.
    bench_debug --full [N]   the real measurement: four-second shapes, best of N
                             rounds (default 10), B/C/D interleaved.
    bench_debug --fail       corrupt one expectation, to see the differential fail.

  Each timing line is
    PHOSPHOR-BENCH variant=<A|B|C|D> shape=<tight|dense> ms=<best> boundaries=<n>
  which is a regex away from a spreadsheet and is the format a driver reads.
******************************************************************************}
program bench_debug;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils,
{$IFNDEF NOSEAM}
  PhosphorVM,
{$ENDIF}
  PhosphorValue, PhosphorEngine;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure CheckStr(const AGot, AWant, AName: String);
begin
  if AGot = AWant then Inc(Ok)
  else
  begin
    Inc(Failed);
    Writeln(StdErr, 'FAIL: ', AName, ' -- got "', AGot, '", wanted "', AWant, '"');
  end;
end;

type
  TSink = class
    Text: String;
{$IFNDEF NOSEAM}
    Stops: Int64;
    Act: TPhosphorDebugAction;
    function Debug(AReason: TPhosphorStopReason; ALine: Integer;
                   AFrameDepth: Integer): TPhosphorDebugAction;
{$ENDIF}
    procedure Output(const AText: String);
  end;

procedure TSink.Output(const AText: String);
begin
  Text := Text + AText;
end;

{$IFNDEF NOSEAM}
function TSink.Debug(AReason: TPhosphorStopReason; ALine: Integer;
  AFrameDepth: Integer): TPhosphorDebugAction;
begin
  // The parameters are read so that nothing here is folded into a constant.
  if (AReason = srPause) and (ALine < 0) and (AFrameDepth < 0) then Inc(Stops);
  Inc(Stops);
  Result := Act;
end;
{$ENDIF}

{ THE TWO SHAPES. Every statement in them is a boundary, and the count is
  arithmetic rather than something read off a run: `tight` executes N body
  boundaries plus the statements around the loop, `dense` executes 2N plus its
  own. D's stop counter is compared against that, so a shape that silently
  stopped carrying boundaries could not read as fast. }
function TightSrc(N: Int64): String;
begin
  Result := 's = 0' + #10 +
            'for i = 1 to ' + IntToStr(N) + #10 +
            's = s + 1' + #10 +
            'next' + #10 +
            'println str$(s)' + #10;
end;

function DenseSrc(N: Int64): String;
begin
  Result := 'k = 0' + #10 +
            's = 0' + #10 +
            'while k < ' + IntToStr(N) + #10 +
            'k = k + 1' + #10 +
            's = s + 2' + #10 +
            'endwhile' + #10 +
            'println str$(s)' + #10;
end;

{ One pass. AVariant is 'B', 'C' or 'D' where the seam exists and 'A' where it
  does not. Answers the elapsed milliseconds and fills AText and AStops. }
function OnePass(const AVariant: String; const ASrc: String;
                 out AText: String; out AStops: Int64): QWord;
var
  eng: TPhosphorEngine;
  s: TSink;
  t0: QWord;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  s := TSink.Create();
  try
    eng.OnOutput := @s.Output;
{$IFNDEF NOSEAM}
    s.Act := daRun;
    if AVariant = 'C' then
    begin
      eng.OnDebug := @s.Debug;
      // Armed on lines this program does not have, so every boundary consults
      // the armed set and none of them matches. That is the attached-and-running
      // state, and it is where a session spends its time.
      eng.ArmDebug([900, 901, 902, 903, 904, 905, 906, 907], False);
    end
    else if AVariant = 'D' then
    begin
      eng.OnDebug := @s.Debug;
      s.Act := daStepInto;
      eng.ArmDebug([], True);
    end;
{$ENDIF}
    t0 := GetTickCount64();
    rc := eng.Run(ASrc);
    Result := GetTickCount64() - t0;
    AText := s.Text;
    if rc <> 0 then AText := AText + ' rc=' + IntToStr(rc) + ' ' + eng.ErrorMessage;
{$IFNDEF NOSEAM}
    AStops := s.Stops;
{$ELSE}
    AStops := 0;
{$ENDIF}
  finally
    eng.Free;
    s.Free;
  end;
end;

{ BEST OF N, NEVER A MEAN, AND THE VARIANTS INTERLEAVED RATHER THAN BLOCKED.

  The minimum is the pass least interfered with; an average on a machine with
  anything else running on it measures the other thing. And every variant runs
  once per round before any of them runs twice, so a machine that warms up, or
  that something else starts on halfway through, moves all of them together
  instead of giving the block that ran first a different machine from the block
  that ran last. The first draft of this routine was blocked, and blocking is
  precisely the protocol mistake that made three reviewers disagree about the one
  cell that has to compare two BINARIES and therefore cannot be interleaved at
  all. }
type
  TCell = record
    Variant, Shape, Src: String;
    Best: QWord;
    Stops: Int64;
  end;

var
  Cells: array of TCell;

procedure AddCell(const AVariant, AShape, ASrc: String);
var n: Integer;
begin
  n := Length(Cells);
  SetLength(Cells, n + 1);
  Cells[n].Variant := AVariant;
  Cells[n].Shape := AShape;
  Cells[n].Src := ASrc;
  Cells[n].Best := High(QWord);
  Cells[n].Stops := 0;
end;

procedure RunCells(ARounds: Integer);
var
  r, i: Integer;
  ms: QWord;
  txt: String;
  stops: Int64;
begin
  for r := 1 to ARounds do
    for i := 0 to High(Cells) do
    begin
      ms := OnePass(Cells[i].Variant, Cells[i].Src, txt, stops);
      if ms < Cells[i].Best then Cells[i].Best := ms;
      Cells[i].Stops := stops;
    end;
  for i := 0 to High(Cells) do
    Writeln('PHOSPHOR-BENCH variant=', Cells[i].Variant,
            ' shape=', Cells[i].Shape,
            ' ms=', Cells[i].Best, ' boundaries=', Cells[i].Stops);
end;

{ THE DIFFERENTIAL, which is the part that can fail. Attaching, arming and
  stepping must change nothing: same bytes out, same answer. Small on purpose --
  this is an equality, not a measurement, and it does not need four seconds. }
procedure Differential;
const
  N = 1000;
var
  tB, tC, tD: String;
  sB, sC, sD: Int64;
begin
  OnePass('B', TightSrc(N), tB, sB);
  OnePass('C', TightSrc(N), tC, sC);
  OnePass('D', TightSrc(N), tD, sD);
  if ProveFail then tD := tD + '!';
  CheckStr(tB, '1000' + #10, 'bench: the detached run prints the sum');
  CheckStr(tC, tB, 'bench: attaching a debugger changes nothing the program prints');
  CheckStr(tD, tB, 'bench: stepping every boundary changes nothing either');
{$IFNDEF NOSEAM}
  { AND THE STEPPER REALLY VISITED THEM, so "changed nothing" cannot be true
    because nothing happened. Derived: `s = 0`, then N executions of the body,
    then the `println`, so strictly more than N boundaries -- a bound rather than
    an equality, because the `for` header and `next` carry boundaries of their
    own and how many is the compiler's business and not this file's. }
  CheckStr(BoolToStr(sD > N, True), 'True',
           'bench: and the stepping variant really was offered every boundary (' +
           IntToStr(sD) + ')');
  CheckStr(BoolToStr(sC = 0, True), 'True',
           'bench: while the armed-but-never-matching variant stopped at none');
{$ENDIF}
end;

var
  full: Boolean;
  rounds: Integer;
  want: String;
  tightN, denseN: Int64;
begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');
  full := (ParamCount >= 1) and (ParamStr(1) = '--full');
  { WHICH VARIANTS TO TIME, default all of them. A driver comparing A, H and P --
    three BINARIES, one detached cell each -- asks for 'B' alone, because timing
    C and D in a build whose hook has been deleted measures B three more times
    and costs a minute a round. }
  want := 'ABCD';
  if full and (ParamCount >= 3) then want := UpperCase(ParamStr(3));

  Differential();

  if full then
  begin
    { Four million and eight million boundaries: on this project's machines each
      pass is over four seconds, so a 15.6 ms scheduling quantum is under 0.4% of
      it. An earlier round sized these at one second, where a quantum is 1.5%,
      and read a single tick as a 1.58% effect. }
    rounds := 10;
    if ParamCount >= 2 then rounds := StrToIntDef(ParamStr(2), 10);
    tightN := 4000000;
    denseN := 4000000;
  end
  else
  begin
    { Indicative only, and sized so the suite pays well under a second for them.
      Nothing is concluded from these; --full is where the numbers come from. }
    rounds := 2;
    tightN := 150000;
    denseN := 150000;
  end;

{$IFNDEF NOSEAM}
  if Pos('B', want) > 0 then AddCell('B', 'tight', TightSrc(tightN));
  if Pos('C', want) > 0 then AddCell('C', 'tight', TightSrc(tightN));
  if Pos('D', want) > 0 then AddCell('D', 'tight', TightSrc(tightN));
  if Pos('B', want) > 0 then AddCell('B', 'dense', DenseSrc(denseN));
  if Pos('C', want) > 0 then AddCell('C', 'dense', DenseSrc(denseN));
  if Pos('D', want) > 0 then AddCell('D', 'dense', DenseSrc(denseN));
{$ELSE}
  { A is the only variant a build without the seam HAS, so the filter is not
    consulted here: asking for 'B' from the pristine binary means "the detached
    cell", and the detached cell of a build with no debugger in it is A. }
  AddCell('A', 'tight', TightSrc(tightN));
  AddCell('A', 'dense', DenseSrc(denseN));
{$ENDIF}
  RunCells(rounds);

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
