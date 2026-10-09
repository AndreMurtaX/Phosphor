{******************************************************************************
  Phosphor BASIC -- regular-expression library (a function package)

  MIT License. Copyright (c) 2026 Andre Murta.

  Thin wrappers over the RTL's TRegExpr. Throughout, the PATTERN comes first and
  the text second (the opposite of instr and most of StrLib). Positions are
  1-based and absence is 0 -- the same base as instr in this engine. Group 0 is
  the whole match; the find-list functions answer a string-list handle, which
  StrListLib reads back. A malformed pattern is RETURNED as an error, not raised.

  THE ONE LIBRARY CALL THAT COULD NOT BE STOPPED. Everything below runs inside a
  single opCall, and the VM tests MaxSteps and TimeoutMs only BETWEEN
  instructions -- so a host that set every ceiling docs/embedding.md prescribes
  still waited for ever on

      regex_find$("(a+)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!")

  forty characters and a nine-character pattern, 2^40 attempts. Worse than the
  string builders, this one cannot be charged as it goes: TRegExpr's matcher is a
  recursive backtracker with no step hook, no timeout property and no interrupt,
  so between Exec and its return there is no line of our code that runs at all.

  So this library obeys RULE 3 of PhosphorBudget: when -- and only when -- a host
  installed a budget, the PATTERN is judged before Exec is called, and one whose
  worst case is unbounded work is refused with a catchable error naming the
  construct. Every entry point below goes through RegexGuard, so there is no
  spelling of "run a regex" that skips the judgement; the find-all loop, which IS
  ours, charges the budget per match on top of that.

  A host that sets no ceilings gets exactly what it got before: RegexGuard's
  first line is BudgetActive, and every pattern that ran yesterday runs today.
******************************************************************************}
unit PhosphorRegexLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, RegExpr,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorStrListLib,
  PhosphorBudget;

procedure RegisterRegexFuncs(Reg: TPhosphorRegistry);

{ Exported so that a probe can measure them against the matcher they predict,
  which is how the 2026-10-09 sweep used them. RegexStackBound answers False,
  with AWhy, for a pattern whose SHAPE TRegExpr 0.987 cannot run without
  recursing for ever or reading past the text; otherwise True, with ABytes an
  upper bound on the stack that compiling the pattern and matching it against
  ASubjectLen bytes can take (0 when TRegExpr will reject the pattern as
  malformed before it recurses at all). RegexStackLeft is what the calling
  thread has left to give. }
function RegexStackBound(const APattern: String; ASubjectLen: Int64;
                         out ABytes: Int64; out AWhy: String): Boolean;
function RegexStackLeft: Int64;

implementation

(* --------------------------------------------------------------------------
  THE CALLS THAT KILLED THE HOST. TRegExpr 0.987 is a recursive compiler and a
  recursive backtracker, and both recurse on the machine stack with no limit of
  their own. Measured with a generated sweep of 16390 patterns, each in a fresh
  process, and by painting the stack around single calls (2026-10-09):

    D1  COMPILE, unbounded. FillFirstCharSet walks the program from its start
        through everything that can match nothing, and walks INTO every loop.
        A loop whose body it can walk through comes back to the loop, and it
        walks the body again, for ever: (a{0,2}){2}, (a{0,2})+,
        (b|a{0,1}){2}, (a?)?? -- a group with a path that consumes nothing,
        under any count or a lazy or greedy repeat, reached from the
        pattern's start through optional parts. ParsePiece refuses a repeat
        of a body it KNOWS can be empty, but it believes x{0,n} with n > 0 and
        a backreference have width, and it lets ?? through unasked.
    D2  EXEC, unbounded. A repeat with no upper count over a body that can
        match nothing iterates on the empty match for ever: b(a{0,2})+,
        b(a{0,2})*, b(a{0,2})*?c. The greedy forms jump back with no progress
        check; the lazy and {n,} forms count to 2^31 (a lazy one only when
        what follows it fails, so a trailing b(a{0,2})*? is refused without
        needing to be -- a repeat that never repeats, kept refused for one
        rule instead of two).
    D3  EXEC, out of bounds. A counted backreference (\1* \1+ \1{n} \1??) is
        repeated by regrepeat, which, when the group captured nothing, counts
        empty copies up to the maximum, and the matcher then backs off by
        "that many bytes": ()\1*x read 2^31 bytes past the text (an access
        violation), and ()\1*?x answered a 5994-byte match of a one-byte
        subject -- heap memory handed back as text. A bounded count reads
        past by up to the count, so every count is refused, and so is a
        counted reference inside its own group, whose end is stale when the
        group is entered again. A reference to a group the pattern does not
        have is safe (0.987 maps it to -1) and is allowed.
    D4  EXEC and COMPILE, bounded but deep. Every group, every alternation and
        every repeat of a group costs one 240-byte MatchPrim frame (208 on
        Linux) per pass, and the frames of a successful path all stay on the
        stack until the match ends. (a|b)* takes four per byte: a 20000-byte
        subject overflowed Windows' 16 MB stack and a 10000-byte one Linux's
        8 MB. A long pattern costs the same way: four thousand a? take 4000
        frames to match and 4000 to compile.

  What an overflow does next is the reason this is not left to the exception
  handler. On Windows the first overflow in a thread arrives as EStackOverflow
  and is caught as a regex error, and the SECOND is an access violation that
  ends the process, because the stack's guard page is not re-armed. On Linux
  the FIRST one ends the process: the RTL installs no alternate signal stack, so
  the SIGSEGV handler has nowhere to run. There is no second chance to give.

  So every pattern is READ before TRegExpr sees it, by a parser that mirrors
  0.987's own (ParseReg, ParseBranch, ParsePiece, ParseAtom -- the same tokens,
  the same flags, the same program shape), and D1-D3 are refused as shapes.
  D4 is refused by arithmetic: the parse gives an upper bound A + B*L on the
  MatchPrim frames of any path that consumes L bytes, and the bytes that bound
  costs are compared with the stack the calling thread has left.

  WHAT THE PARSER DOES NOT UNDERSTAND, IT LEAVES TO TRegExpr. A pattern this
  parser cannot read is one TRegExpr rejects during its parse, which is before
  any of the recursion above; it raises its own compile error and nothing
  changes. The probe asserts that direction: no pattern this parser gives up on
  compiles. Every verdict here holds with or without a budget, for every host.
  -------------------------------------------------------------------------- *)

const
  { MatchPrim's frame is 240 bytes on x86_64-win64 and 208 on x86_64-linux
    (FPC 3.2.2, measured by painting the stack); FillFirstCharSet's is 112. One
    figure above both serves every recursion counted below. }
  RxFrameBytes = 256;
  { Left untouched for what runs around the recursion: Exec's own frames,
    regrepeat, the exception machinery, a signal handler, Windows' guard pages. }
  RxStackMargin = 64 * 1024;
  { A thread the RTL did not start has no StackBottom of its own; it is
    assumed to have this much, which a thread of any usual size has. }
  RxUnknownStack = 256 * 1024;
  RxNSubExp = 90;                     // regexpr.pas NSUBEXP: groups, (?:) included
  RxMaxBracesArg = $7FFFFFFF - 1;     // regexpr.pas MaxBracesArg
  RxInfinite = 1.0e300;

type
  { What a match of a piece of pattern can cost. }
  TRxCost = record
    Empty: Boolean;    // can match while consuming nothing: anchors, \b and
                       // backreferences included -- what is TRUE, not believed
    MinLen: Int64;     // the fewest bytes one match of it consumes
    A, B: Double;      // MatchPrim frames on any path consuming c bytes <= A + B*c
    Danger: String;    // an endless repeat inside, under this reading ('' = none)
  end;

  { What a piece of pattern is, to TRegExpr and to its matcher.

    NESTED OP_LOOPs DO NOT COUNT, as engine/PhosphorBudget.pas's MarkLoops
    records: 0.987 keeps a counted or lazy group repeat's iteration count in one
    LoopStack slot per nesting depth, and OP_LOOPENTRY zeroes the slot while an
    earlier instance at that depth may still be on the backtracking stack. The
    sweep met it as a stack 30 frames deeper than the counts allow. So every
    piece carries two readings: T, with every count trusted, and U, with every
    OP_LOOP inside it read as the loop it may become -- no upper bound, and a
    lower bound of at most one, because the first visit after OP_LOOPENTRY
    always sees a count of zero and must run the body once before any stale
    count can let it out. A piece takes U when it is an OP_LOOP that holds one,
    and so, by the same rule one level up, does everything inside one. }
  TRxShape = record
    Width: Boolean;    // ParsePiece's flag_HasWidth: what TRegExpr BELIEVES
    Simple: Boolean;   // flag_Simple: a one-node operand for STAR/PLUS/BRACES
    Pass: Boolean;     // FillFirstCharSet walks through it to what follows
    Nodes: Double;     // program nodes FillFirstCharSet can recurse through
    BackRef: Integer;  // > 0: the atom is the backreference \BackRef
    HasLoop: Boolean;  // an OP_LOOP somewhere inside
    T, U: TRxCost;
  end;

function RxEmptyCost: TRxCost;
begin
  Result.Empty := True;
  Result.MinLen := 0;
  Result.A := 0;
  Result.B := 0;
  Result.Danger := '';
end;

function RxEmptyShape: TRxShape;
begin
  Result.Width := False;
  Result.Simple := False;
  Result.Pass := True;
  Result.Nodes := 0;
  Result.BackRef := 0;
  Result.HasLoop := False;
  Result.T := RxEmptyCost();
  Result.U := RxEmptyCost();
end;

function RxConsumer(ASimple: Boolean; AMinLen: Int64): TRxShape;
begin
  Result := RxEmptyShape();
  Result.Width := True;
  Result.Simple := ASimple;
  Result.Pass := False;
  Result.T.Empty := AMinLen = 0;
  Result.T.MinLen := AMinLen;
  Result.U := Result.T;
end;

function RxMax(const X, Y: Double): Double;
begin
  if X > Y then Result := X else Result := Y;
end;

function RegexStackLeft: Int64;
var sp, bottom: PtrUInt; here: Byte;
begin
  here := 0;
  sp := PtrUInt(@here) + here;      // a local's address: this frame's place on the stack
  bottom := PtrUInt(StackBottom);
  if (bottom = 0) or (sp <= bottom) or (sp - bottom > StackLength + 65536) then
    Exit(RxUnknownStack);
  Result := Int64(sp - bottom);
end;

function RegexStackBound(const APattern: String; ASubjectLen: Int64;
                         out ABytes: Int64; out AWhy: String): Boolean;
type
  TRxMods = record
    S, G, X: Boolean;    // the modifiers that change the program's SHAPE
  end;
var
  n, i: Integer;
  mods: TRxMods;
  npar: Integer;          // regnpar: every '(' that is a group, (?:) included
  ncap: Integer;          // GrpCount: capturing groups numbered so far
  capEmpty: array[1..RxNSubExp] of Boolean;
  capOpen: array[1..RxNSubExp] of Boolean;
  refs: array of record Num, Pos: Integer; end;   // counted backreferences
  nrefs: Integer;
  danger: String;
  bail: Boolean;          // TRegExpr rejects this pattern: leave it to TRegExpr
  L: Double;
  top: TRxShape;
  k: Integer;
  need: Double;

  procedure Refuse(const AWhat: String; APos: Integer);
  begin
    if danger = '' then danger := AWhat + ' (pos ' + IntToStr(APos) + ')';
  end;

  function Ch(AIdx: Integer): Char;    // regparse^, with the terminating #0
  begin
    if (AIdx >= 1) and (AIdx <= n) then Result := APattern[AIdx] else Result := #0;
  end;

  function IsDigit(C: Char): Boolean;
  begin
    Result := (C >= '0') and (C <= '9');
  end;

  function IsHex(C: Char): Boolean;
  begin
    Result := IsDigit(C) or ((C >= 'a') and (C <= 'f')) or ((C >= 'A') and (C <= 'F'));
  end;

  function IsIgnored(C: Char): Boolean;     // regexpr.pas IsIgnoredChar
  begin
    Result := C in [' ', #9, #13, #10];
  end;

  function IsMetaClass(C: Char): Boolean;   // regexpr.pas _IsMetaChar
  begin
    Result := C in ['d', 'D', 's', 'S', 'w', 'W', 'v', 'V', 'h', 'H'];
  end;

  function IsMeta1(C: Char): Boolean;       // regexpr.pas _IsMetaSymbol1
  begin
    Result := C in ['^', '$', '.', '[', '(', ')', '|', '?', '+', '*', '\', '{'];
  end;

  { UnQuoteChar: i is on the escape letter; leave i on the escape's LAST byte,
    as 0.987 does. False when 0.987 raises. }
  function UnQuote: Boolean;
  begin
    Result := True;
    case Ch(i) of
      'c':
        begin
          Inc(i);
          Result := (i <= n) and (Ch(i) in ['a'..'z', 'A'..'Z']);
        end;
      'x':
        begin
          Inc(i);
          if i > n then Exit(False);
          if Ch(i) = '{' then
          begin
            Inc(i);
            while (i <= n) and (Ch(i) <> '}') do
            begin
              if not IsHex(Ch(i)) then Exit(False);
              Inc(i);
            end;
            if i > n then Exit(False);
          end
          else
          begin
            if not IsHex(Ch(i)) then Exit(False);
            Inc(i);
            if (i > n) or not IsHex(Ch(i)) then Exit(False);
          end;
        end;
    end;
  end;

  { A [...] class, i just past the '['. }
  function SkipClass: Boolean;
  var canRange: Boolean;
  begin
    Result := False;
    if Ch(i) = '^' then Inc(i);
    canRange := False;
    if Ch(i) = ']' then
    begin
      canRange := Ch(i + 1) = '-';
      Inc(i);
    end;
    while (i <= n) and (Ch(i) <> ']') do
    begin
      if (Ch(i) = '-') and (i + 1 <= n) and (Ch(i + 1) = ']') then
      begin
        Inc(i);
        Break;
      end;
      if (Ch(i) = '-') and (i + 1 <= n) and canRange then
      begin
        Inc(i);
        if Ch(i) = '\' then
        begin
          if IsMetaClass(Ch(i + 1)) then Exit;
          Inc(i);
          if not UnQuote() then Exit;
        end;
        canRange := False;
        Inc(i);
      end
      else
      begin
        if Ch(i) = '\' then
        begin
          Inc(i);
          if i > n then Exit;
          if IsMetaClass(Ch(i)) then
            canRange := False
          else
          begin
            if not UnQuote() then Exit;
            canRange := (i + 2 <= n) and (Ch(i + 1) = '-') and (Ch(i + 2) <> ']');
          end;
        end
        else
          canRange := (i + 2 <= n) and (Ch(i + 1) = '-') and (Ch(i + 2) <> ']');
        Inc(i);
      end;
    end;
    if Ch(i) <> ']' then Exit;
    Inc(i);
    Result := True;
  end;

  { ParseModifiers: i is just past "(?". The letters up to the ')' change the
    modifiers for the rest of the enclosing group; i ends past the ')'. }
  function ReadMods: Boolean;
  var isOn: Boolean;
  begin
    Result := False;
    isOn := True;
    while (i <= n) and (Ch(i) <> ')') do
    begin
      case Ch(i) of
        '-': isOn := False;
        'S', 's': mods.S := isOn;
        'G', 'g': mods.G := isOn;
        'X', 'x': mods.X := isOn;
        'I', 'i', 'R', 'r', 'M', 'm': ;
      else
        Exit;                                       // reeUnrecognizedModifier
      end;
      Inc(i);
    end;
    if i > n then Exit;
    Inc(i);
    Result := True;
  end;

  function ParseReg(AParen, AReach: Boolean; out S: TRxShape): Boolean; forward;

  function ParseAtom(AReach: Boolean; out S: TRxShape): Boolean;
  var c: Char; len, emitted, cap: Integer; ender: Char;
  begin
    Result := False;
    S := RxEmptyShape();
    c := Ch(i);
    Inc(i);
    case c of
      '^': ;                                        // OP_BOL
      '$': S.Pass := False;                         // OP_EOL: FillFirstCharSet stops
      '.': S := RxConsumer(mods.S, 1);              // OP_ANY is simple, OP_ANYML not
      '[':
        begin
          if not SkipClass() then Exit;
          S := RxConsumer(True, 1);
        end;
      '(':
        if Ch(i) = '?' then
        begin
          if Ch(i + 1) = ':' then
          begin
            Inc(i, 2);
            if not ParseReg(True, AReach, S) then Exit;
            S.Simple := False;
          end
          else if Ch(i + 1) = '#' then
          begin
            Inc(i, 2);
            while (i <= n) and (Ch(i) <> ')') do Inc(i);
            if Ch(i) <> ')' then Exit;
            Inc(i);                                 // OP_COMMENT
          end
          else
          begin
            Inc(i);
            if not ReadMods() then Exit;            // OP_COMMENT; the rest of the group changes
          end;
        end
        else
        begin
          cap := 0;
          if ncap < RxNSubExp - 1 then
          begin
            Inc(ncap);
            cap := ncap;
            capOpen[cap] := True;
          end;
          if not ParseReg(True, AReach, S) then Exit;
          S.Simple := False;
          if cap > 0 then
          begin
            capOpen[cap] := False;
            capEmpty[cap] := S.T.Empty or S.U.Empty;
          end;
        end;
      '|', ')', '?', '+', '*': Exit;                // "follows nothing", or worse
      '\':
        begin
          if i > n then Exit;
          case Ch(i) of
            'b', 'B', 'A': ;                        // OP_BOUND, OP_NOTBOUND, OP_BOL
            'Z': S.Pass := False;                   // OP_EOL
            'd', 'D', 's', 'S', 'w', 'W', 'v', 'V', 'h', 'H':
              S := RxConsumer(True, 1);
            '1'..'9':
              begin
                { OP_BSUBEXP: TRegExpr gives it width and calls it simple, and
                  FillFirstCharSet stops at it -- but it matches nothing when
                  its group captured nothing. }
                S := RxConsumer(True, 0);           // width believed, emptiness true
                S.BackRef := Ord(Ch(i)) - Ord('0');
              end;
          else
            if not UnQuote() then Exit;
            S := RxConsumer(True, 1);
          end;
          Inc(i);
        end;
    else
      begin
        Dec(i);
        if mods.X and ((c = '#') or IsIgnored(c)) then
        begin
          if c = '#' then
          begin
            while (i <= n) and (Ch(i) <> #13) and (Ch(i) <> #10) do Inc(i);
            while (i <= n) and ((Ch(i) = #13) or (Ch(i) = #10)) do Inc(i);
          end
          else
            while (i <= n) and IsIgnored(Ch(i)) do Inc(i);
          // OP_COMMENT
        end
        else
        begin
          len := 0;
          while (i + len <= n) and not IsMeta1(Ch(i + len)) do Inc(len);
          if len <= 0 then
          begin
            if c <> '{' then Exit;
            len := 1;                               // a stray '{' and what follows it
            while (i + len <= n) and not IsMeta1(Ch(i + len)) do Inc(len);
          end;
          ender := Ch(i + len);
          if (len > 1) and (ender in ['*', '+', '?', '{']) then Dec(len);
          { One OP_EXACTLY. flag_Simple when the run is one byte long, counted
            before (?x) drops its blanks -- as 0.987 counts it. }
          S := RxConsumer(len = 1, 1);
          emitted := 0;
          while (i <= n) and (len > 0) and ((not mods.X) or (Ch(i) <> '#')) do
          begin
            if (not mods.X) or not IsIgnored(Ch(i)) then Inc(emitted);
            Inc(i);
            Dec(len);
          end;
          S.T.MinLen := emitted;
          S.T.Empty := emitted = 0;   // never: a run starts on a byte it keeps
          S.U := S.T;
        end;
      end;
    end;
    Result := True;
  end;

  { One atom and the quantifier after it. }
  function ParsePiece(AReach: Boolean; out S: TRxShape): Boolean;
  var
    a: TRxShape;
    op: Char;
    lo, hi: Int64;
    lazy, nonGreedy, isLoop: Boolean;
    digits, opPos: Integer;
    numOk: Boolean;

    { A group repeated ALo..AHi times (AHi = RxMaxBracesArg: no bound) over a
      body costing C -- a branch that jumps back, or an OP_LOOP: either way one
      frame per pass on top of the body's own. A pass that consumes nothing is
      bounded only by the count, and one that consumes MinLen bytes or more
      only by the subject. }
    function Repeated(const C: TRxCost; ALo, AHi: Int64): TRxCost;
    var iterFrames, opt1, opt2: Double;
    begin
      Result := RxEmptyCost();
      Result.Empty := (ALo = 0) or C.Empty;
      Result.MinLen := ALo * C.MinLen;
      Result.Danger := C.Danger;
      if (AHi >= RxMaxBracesArg) and C.Empty and (Result.Danger = '') then
        Result.Danger := 'a repeat with no upper count over a group that can ' +
          'match nothing -- TRegExpr''s matcher would recurse without end (pos ' +
          IntToStr(opPos) + ')';
      iterFrames := 1 + C.A;
      if AHi >= RxMaxBracesArg then opt1 := RxInfinite
      else opt1 := 2 + AHi * iterFrames + C.B * L;
      if C.MinLen > 0 then opt2 := 2 + (iterFrames / C.MinLen + C.B) * L
      else opt2 := RxInfinite;
      if opt1 <= opt2 then
      begin
        Result.A := 2 + AHi * iterFrames;
        Result.B := C.B;
      end
      else
      begin
        Result.A := 2;
        Result.B := iterFrames / C.MinLen + C.B;
      end;
    end;

    { The digits at i, as ParseNumber reads them; i ends past them. False past
      eight digits or MaxBracesArg (reeBRACESArgTooBig). }
    function ReadNum(out V: Int64; out ADigits: Integer): Boolean;
    begin
      V := 0;
      ADigits := 0;
      while (i <= n) and IsDigit(Ch(i)) do
      begin
        if ADigits < 9 then V := V * 10 + (Ord(Ch(i)) - Ord('0'));
        Inc(ADigits);
        Inc(i);
      end;
      Result := (ADigits <= 8) and (V <= RxMaxBracesArg);
    end;

    procedure CountRef;
    begin
      if a.BackRef <= 0 then Exit;
      if capOpen[a.BackRef] then
        Refuse('a counted backreference inside its own group', opPos);
      if nrefs >= Length(refs) then SetLength(refs, Length(refs) * 2 + 4);
      refs[nrefs].Num := a.BackRef;
      refs[nrefs].Pos := opPos;
      Inc(nrefs);
    end;

  begin
    Result := False;
    if not ParseAtom(AReach, a) then Exit;
    op := Ch(i);
    if not (op in ['*', '+', '?', '{']) then
    begin
      S := a;
      Exit(True);
    end;
    if (not a.Width) and (op <> '?') then Exit;     // reePlusStarOperandCouldBeEmpty
    opPos := i;
    lo := 0;
    hi := RxMaxBracesArg;
    case op of
      '*': ;
      '+': lo := 1;
      '?': hi := 1;
      '{':
        begin
          Inc(i);
          numOk := ReadNum(lo, digits);
          if ((Ch(i) <> '}') and (Ch(i) <> ',')) or (digits = 0) or not numOk then Exit;
          if Ch(i) = ',' then
          begin
            Inc(i);
            numOk := ReadNum(hi, digits);
            if Ch(i) <> '}' then Exit;
            if digits = 0 then hi := RxMaxBracesArg      // {n,}
            else if not numOk then Exit;
          end
          else
            hi := lo;
          if lo > hi then Exit;                     // reeBracesMinParamGreaterMax
        end;
    end;
    lazy := Ch(i + 1) = '?';
    nonGreedy := lazy or not mods.G;
    if lazy then Inc(i);
    Inc(i);
    if Ch(i) in ['*', '+', '?', '{'] then Exit;     // reeNestedSQP

    S := RxEmptyShape();
    S.Width := (op = '+') or ((op = '{') and (hi > 0));
    S.HasLoop := a.HasLoop;

    if (op = '?') and not nonGreedy then
    begin
      { (x|) as two branches: one frame to choose, then x or nothing. }
      S.Pass := True;
      S.Nodes := a.Nodes + 2;
      S.T := a.T;
      S.T.Empty := True;
      S.T.MinLen := 0;
      S.T.A := 1 + a.T.A;
      S.U := a.U;
      S.U.Empty := True;
      S.U.MinLen := 0;
      S.U.A := 1 + a.U.A;
      Exit(True);
    end;

    if a.Simple then
    begin
      { OP_STAR / OP_PLUS / OP_BRACES and their lazy twins: one frame for the
        whole run, which regrepeat counts out in a loop. }
      CountRef();
      S.Pass := lo = 0;
      S.Nodes := 1;
      S.T.Empty := (lo = 0) or a.T.Empty;
      S.T.MinLen := lo * a.T.MinLen;
      S.T.A := 1;
      S.T.B := 0;
      S.U := S.T;
      Exit(True);
    end;

    { A group (or a non-simple atom) repeated: a branch that jumps back, or an
      OP_LOOPENTRY/OP_LOOP pair. Either way FillFirstCharSet walks into the
      body, and a body it can walk through brings it back to the loop. }
    if AReach and a.Pass then
      Refuse('a repeated group that can match nothing, at the start of the ' +
             'pattern -- TRegExpr''s compiler would recurse without end', opPos);
    S.Pass := (lo = 0) or a.Pass;
    S.Nodes := a.Nodes + 2;
    { A greedy * + over a group is a branch that jumps back, and keeps no
      count; a counted or lazy one is an OP_LOOP, whose count is only as good
      as the LoopStack slot it lives in (see TRxShape). }
    isLoop := nonGreedy or (op = '{');
    if isLoop then
    begin
      if lo > 1 then S.U := Repeated(a.U, 1, RxMaxBracesArg)
      else S.U := Repeated(a.U, lo, RxMaxBracesArg);
      if a.HasLoop then S.T := S.U                  // it holds an OP_LOOP: untrusted
      else S.T := Repeated(a.T, lo, hi);
      S.HasLoop := True;
    end
    else
    begin
      S.U := Repeated(a.U, lo, hi);
      S.T := Repeated(a.T, lo, hi);
    end;
    Result := True;
  end;

  { X then Y: the frames of a path add up, and the bytes it consumes divide
    between the two however they like, so the per-byte rate is the larger. }
  procedure Then_(var X: TRxCost; const Y: TRxCost);
  begin
    X.Empty := X.Empty and Y.Empty;
    X.MinLen := X.MinLen + Y.MinLen;
    X.A := X.A + Y.A;
    X.B := RxMax(X.B, Y.B);
    if X.Danger = '' then X.Danger := Y.Danger;
  end;

  { X or Y: a path takes one of them. }
  procedure Or_(var X: TRxCost; const Y: TRxCost);
  begin
    X.Empty := X.Empty or Y.Empty;
    if Y.MinLen < X.MinLen then X.MinLen := Y.MinLen;
    X.A := RxMax(X.A, Y.A);
    X.B := RxMax(X.B, Y.B);
    if X.Danger = '' then X.Danger := Y.Danger;
  end;

  function ParseBranch(AReach: Boolean; out S: TRxShape): Boolean;
  var p: TRxShape; reach: Boolean;
  begin
    Result := False;
    S := RxEmptyShape();
    reach := AReach;
    while (i <= n) and (Ch(i) <> '|') and (Ch(i) <> ')') do
    begin
      if not ParsePiece(reach, p) then Exit;
      S.Width := S.Width or p.Width;
      S.Pass := S.Pass and p.Pass;
      S.Nodes := S.Nodes + p.Nodes;
      S.HasLoop := S.HasLoop or p.HasLoop;
      Then_(S.T, p.T);
      Then_(S.U, p.U);
      reach := reach and p.Pass;
    end;
    Result := True;
  end;

  function ParseReg(AParen, AReach: Boolean; out S: TRxShape): Boolean;
  var saved: TRxMods; b: TRxShape; nb: Integer;
  begin
    Result := False;
    S := RxEmptyShape();
    saved := mods;
    if AParen then
    begin
      if npar >= RxNSubExp then Exit;               // reeCompParseRegTooManyBrackets
      Inc(npar);
    end;
    if not ParseBranch(AReach, S) then Exit;
    nb := 1;
    while (i <= n) and (Ch(i) = '|') do
    begin
      Inc(i);
      if not ParseBranch(AReach, b) then Exit;
      Inc(nb);
      S.Width := S.Width and b.Width;
      S.Pass := S.Pass or b.Pass;
      S.Nodes := S.Nodes + b.Nodes;
      S.HasLoop := S.HasLoop or b.HasLoop;
      Or_(S.T, b.T);
      Or_(S.U, b.U);
    end;
    if nb > 1 then
    begin
      S.T.A := S.T.A + 1;                           // the frame that tries each branch
      S.U.A := S.U.A + 1;
      S.Nodes := S.Nodes + nb;
    end;
    if AParen then
    begin
      if Ch(i) <> ')' then Exit;
      Inc(i);
      S.T.A := S.T.A + 2;                           // OP_OPEN and OP_CLOSE each recurse
      S.U.A := S.U.A + 2;
      S.Nodes := S.Nodes + 2;
    end
    else if i <= n then
      Exit;                                         // a stray ')' or junk on the end
    mods := saved;
    S.Simple := False;
    S.BackRef := 0;
    Result := True;
  end;

begin
  ABytes := 0;
  AWhy := '';
  n := Length(APattern);
  i := 1;
  mods.S := RegExprModifierS;
  mods.G := RegExprModifierG;
  mods.X := RegExprModifierX;
  npar := 1;
  ncap := 0;
  for k := Low(capEmpty) to High(capEmpty) do
  begin
    capEmpty[k] := False;
    capOpen[k] := False;
  end;
  nrefs := 0;
  refs := nil;
  danger := '';
  if ASubjectLen < 0 then ASubjectLen := 0;
  L := ASubjectLen;
  bail := not ParseReg(False, True, top);
  if bail then Exit(True);              // TRegExpr's parse rejects it, before any recursion
  { A reference to a group the pattern does not have is safe: 0.987 maps it to
    -1 and regrepeat counts nothing. }
  for k := 0 to High(refs) do
    if (k < nrefs) and (refs[k].Num <= ncap) and capEmpty[refs[k].Num] then
      Refuse('a counted backreference to a group that can capture nothing -- ' +
             'TRegExpr would read past the end of the text', refs[k].Pos);
  if danger = '' then danger := top.T.Danger;
  if danger <> '' then
  begin
    AWhy := danger;
    Exit(False);
  end;
  need := RxMax(top.Nodes, top.T.A + top.T.B * L) * RxFrameBytes + RxStackMargin;
  if need > High(Int64) / 2 then ABytes := High(Int64) div 2
  else ABytes := Round(need);
  Result := True;
end;

{ The gate every entry point asks before it builds a TRegExpr. False = do not
  run this match; Err carries the refusal.

  Charging first and judging second is deliberate: a run whose budget is already
  spent gets the ordinary "budget spent" message rather than a lecture about its
  pattern, and the charge accounts for compiling the pattern and scanning the
  subject once, which is what a WELL-BEHAVED pattern costs. }
function RegexGuard(const AFn, APattern, AText: String;
                    out Err: TPhosphorError): Boolean;
var
  why: String;
  need, left: Int64;
begin
  Err := NoError();
  Result := True;
  if BudgetActive() then
  begin
    if not BudgetCharge(Int64(Length(APattern)) + Length(AText)) then
    begin
      Err := BudgetRefusal(AFn);
      Exit(False);
    end;
    if not BudgetPatternBounded(APattern, why) then
    begin
      Err := MakeError(peLimit, AFn +
        ': this pattern cannot be bounded by an execution budget -- ' + why +
        ', and the matcher cannot be interrupted once it starts');
      Exit(False);
    end;
  end;
  { EVERY HOST, budget or not: a call that would end the process is not made.
    See the comment above RegexStackBound. }
  if not RegexStackBound(APattern, Length(AText), need, why) then
  begin
    Err := MakeError(peRuntime, 'regex error: ' + AFn + ': ' + why);
    Exit(False);
  end;
  left := RegexStackLeft();
  if need > left then
  begin
    Err := MakeError(peRuntime, 'regex error: ' + AFn + ': this pattern over ' +
      IntToStr(Length(AText)) + ' bytes of text could need ' +
      IntToStr(need div 1024) + ' KB of stack and ' + IntToStr(left div 1024) +
      ' KB are left -- TRegExpr recurses once per group, branch and repeat ' +
      'it passes, and an overflow ends the process');
    Exit(False);
  end;
end;

function t_regex_find(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr;
begin
  Result := ValStr('');
  if not RegexGuard('regex_find$', Args[0].Str, Args[1].Str, Err) then Exit;
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then Result := ValStr(r.Match[0]);
    except on E: Exception do Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
  finally
    r.Free;
  end;
end;

function t_regex_findpos(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_findpos', Args[0].Str, Args[1].Str, Err) then Exit;
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then Result := ValInt(r.MatchPos[0]);   // 1-based
    except on E: Exception do Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
  finally
    r.Free;
  end;
end;

function t_regex_findlen(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_findlen', Args[0].Str, Args[1].Str, Err) then Exit;
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then Result := ValInt(r.MatchLen[0]);
    except on E: Exception do Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
  finally
    r.Free;
  end;
end;

function t_regex_groupcount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_groupcount', Args[0].Str, Args[1].Str, Err) then Exit;
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then Result := ValInt(r.SubExprMatchCount + 1);  // + group 0
    except on E: Exception do Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
  finally
    r.Free;
  end;
end;

function t_regex_group(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr; n: Integer;
begin
  Result := ValStr('');
  if not RegexGuard('regex_group$', Args[0].Str, Args[1].Str, Err) then Exit;
  n := ArgI32(Args[2]);   // group number, 0 = whole match
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) and (n >= 0) and (n <= r.SubExprMatchCount) then
        Result := ValStr(r.Match[n]);
    except on E: Exception do Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
  finally
    r.Free;
  end;
end;

function t_regex_findall(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr; sl: TPhosphorStringList; spent: Boolean;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_findall@', Args[0].Str, Args[1].Str, Err) then Exit;
  spent := False;
  sl := TPhosphorStringList.Create();
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then
        repeat
          sl.Add(r.Match[0]);
          // RULE 2: THIS loop is ours, so it is charged as it goes. An empty-width
          // match on a long subject iterates once per character, and the list it
          // builds is one string per iteration -- neither is visible to the VM.
          if not BudgetCharge(Int64(1) + Length(r.Match[0])) then
          begin
            spent := True;
            Break;
          end;
        until not r.ExecNext;
    except
      on E: Exception do begin sl.Free; sl := nil; Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
    end;
  finally
    r.Free;
  end;
  if spent then
  begin
    sl.Free;
    sl := nil;
    Err := BudgetRefusal('regex_findall@');
  end;
  if sl <> nil then Result := ValHandle(RegisterHandle(sl));
end;

function t_regex_groups(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr; sl: TPhosphorStringList; i: Integer;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_groups@', Args[0].Str, Args[1].Str, Err) then Exit;
  sl := TPhosphorStringList.Create();
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then
        for i := 0 to r.SubExprMatchCount do sl.Add(r.Match[i]);   // group 0 first
    except
      on E: Exception do begin sl.Free; sl := nil; Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
    end;
  finally
    r.Free;
  end;
  if sl <> nil then Result := ValHandle(RegisterHandle(sl));
end;

function t_regex_split(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr; sl: TPhosphorStringList; tmp: TStringList; i: Integer;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_split@', Args[0].Str, Args[1].Str, Err) then Exit;
  sl := TPhosphorStringList.Create();
  r := TRegExpr.Create();
  tmp := TStringList.Create();
  try
    try
      r.Expression := Args[0].Str;
      r.Split(Args[1].Str, tmp);
      for i := 0 to tmp.Count - 1 do sl.Add(tmp[i]);
    except
      on E: Exception do begin sl.Free; sl := nil; Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
    end;
  finally
    r.Free;
    tmp.Free;
  end;
  if sl <> nil then Result := ValHandle(RegisterHandle(sl));
end;

procedure RegisterRegexFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('regex_find$:$$',      @t_regex_find);
  Reg.Add('regex_findpos:$$',    @t_regex_findpos);
  Reg.Add('regex_findlen:$$',    @t_regex_findlen);
  Reg.Add('regex_groupcount:$$', @t_regex_groupcount);
  Reg.Add('regex_group$:$$n',    @t_regex_group);
  Reg.Add('regex_findall@:$$',   @t_regex_findall);
  Reg.Add('regex_groups@:$$',    @t_regex_groups);
  Reg.Add('regex_split@:$$',     @t_regex_split);
end;

end.
