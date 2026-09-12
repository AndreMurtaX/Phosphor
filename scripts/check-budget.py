#!/usr/bin/env python3
"""check-budget.py -- no library loop or allocation escapes the execution budget.

THE RULE THIS ENFORCES. MaxSteps, TimeoutMs and MaxOutputBytes are tested in the
VM's dispatch loop, between instructions. A library call is ONE instruction, so
anything a library does is invisible to all three unless the library itself asks.
engine/PhosphorBudget.pas is what it asks; this is what says so when it doesn't.

    Every routine in engine/libs or host/packages that LOOPS or ALLOCATES over a
    quantity the VM cannot see -- a count that came from a script, a directory
    the filesystem sizes, a decompressed stream, a wait, a regex -- must name a
    Budget* function, or be listed in ALLOWED below with the reason it need not.

scripts/check-sandbox.py exists because the same shape of rule rotted once: "every
routine that touches a path asks the gate" was true until it silently was not, one
new function at a time. This file starts where that one ended up.

WHAT COUNTS AS AN AMPLIFIER (the three families, and why each is one):

  ALLOCATION over a computed size. SetLength/StringOfChar/DupeString/SetSize/
  Capacity whose size is NOT derived from something already in memory. A size
  taken from Length(s) or a list's Count is bounded by what is already allocated;
  a size taken from an ARGUMENT is bounded by nothing -- eleven characters of
  BASIC ask for two gigabytes.

  A COUNTED LOOP whose bound is likewise not derived from an existing container.
  `for i := 1 to n` where n came from the program is the string$ shape: hours of
  work inside one opCall.

  AN UN-PREEMPTABLE NATIVE. Sleep, TRegExpr, FindFirst, sqlite3_step/exec, a
  decompression stream, TZipper/TUnZipper. Once one of these is entered there is
  no line of our code that runs again until it returns, so the routine must
  either bound it before it starts (a pattern judged, a wait sliced) or charge
  each iteration of the loop AROUND it.

  A STRING PRODUCT. Pos/PosEx/StringReplace/ContainsText compare or rewrite one
  string against another, and the work is the PRODUCT of two lengths, not the sum.
  The first version of this file did not list them and, worse, counted `Pos(` as
  EVIDENCE OF BOUNDEDNESS (it was in DERIVED) -- so instr(1e6-char hay, 20001-char
  needle) spent 7250 ms inside one opCall and the gate reported nothing. One string
  in memory does bound a loop; two multiplied do not.

WHAT THE FIRST VERSION COULD NOT SEE, all three now closed:

  1. WHILE AND REPEAT. Only `for .. to/downto` was examined. The tree's other
     backtracking matcher (MatchGlob) and its O(n^2) list sort are both WHILE
     loops, and neither was counted, gated, nor exempt.
  2. STRING PRODUCTS, above.
  3. TAINT ACROSS A CALL. Only locals assigned from ArgI32/AsDouble were tainted,
     so a helper `procedure Grow(ACount: Integer)` doing SetLength(x, ACount)
     scored as bounded -- the count is a PARAMETER, and the caller's taint never
     reached it. A routine's own numeric parameters are now tainted inside it,
     which is the shape a helper always takes.

Exit 0 when every amplifier consults the budget. Exit 1 names the routine.

  python scripts/check-budget.py            check the tree
  python scripts/check-budget.py --prove    plant a violation and confirm it fails
  python scripts/check-budget.py --narrowing  the 64-bit-guard / 32-bit-narrow sweep

--narrowing is a SECOND rule in the same file because it is the same mistake in a
different coat: a guard written for one width followed by an operation of another.
int() checked InI64Range and then narrowed with Math.Floor, whose result type is
Integer, so int(3e9) answered -1294967296; json_setn@ checked Abs(d) < 9.2e18 and
then called TJSONIntegerNumber.Create, whose field is Integer, so a JSON number of
three billion was stored as -1294967296. No crash either time -- a silently wrong
answer, which is worse. The sweep lists every call in engine/libs and host/packages
to a routine known to RETURN or STORE 32 bits, and each must be listed as reviewed.

Run standalone, or through scripts/test-suite.{ps1,sh}, which run it with the
other source gates.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SCAN_DIRS = [
    os.path.join(ROOT, 'engine', 'libs'),
    os.path.join(ROOT, 'host', 'packages'),
    os.path.join(ROOT, 'host', 'console'),
]
# host/console WAS NOT SCANNED, AND A HOST SEAM IS THE SAME SHAPE AS A LIBRARY
# CALL. The rule at the top says "anything a library does is invisible to all
# three [ceilings] unless the library itself asks", and the reason is that a
# library call is ONE instruction. A seam callback -- OnOutput, OnInput,
# OnBreakpoint -- is called from inside one instruction too, by the same dispatch
# loop, so the same sentence is true of it word for word. The directory was out
# because nobody had asked the question, not because it had been answered.
#
# MEASURED, so it is a finding and not a suspicion: TConsoleHost.Breakpoint built
# its report with `s := s + Format(...)` over a script-supplied operand count with
# no ceiling on the count, on any operand's length or on the message. One
# `breakpoint` statement, operands all the same 10 000-byte string, from a 32 065
# byte source, on a host that holds one 10 KB string:
#
#     1000 operands  exit 0     396 ms   10 009 047 bytes on stderr
#     8000 operands  exit 0  65 011 ms   80 079 047 bytes on stderr
#
# It now consults three named ceilings instead and is flat at ~8 KB and ~47 ms.
#
# AND THE SILENT HALF, which is the part worth keeping: sources() below used to
# yield only `.pas`, and host/console holds two `.lpr` files and nothing else. So
# adding this directory alone -- the obvious fix, the one a reader would make --
# scanned ZERO files and printed the same confident green line as always. That is
# this project's own named trap: a filter that hides the answer reads exactly like
# a pass. sources() now yields .lpr too, and main() refuses a scan directory that
# turns out to hold nothing, so the next widening cannot be silently empty.
#
# host/gui/libs STILL STAYS OUT, for the reason set out below, which is a
# different reason: the GUI keeps a SECOND accounting (GuiChargeRoom/GuiChargeSet)
# that GATE cannot see, so code that IS guarded there reads as unguarded. Nothing
# in host/console has a second accounting; its exemptions below are all "the VM is
# not running when this runs", which is a reason, not a workaround.
# engine/*.pas itself is NOT scanned: the VM is where the ceilings are tested and
# PhosphorBudget is the thing being consulted, so neither can consult it. The
# compiler and lexer run before a budget exists at all.
#
# host/gui/libs IS NOT SCANNED EITHER, and that is a gap, not a clean bill: 17
# units live there, they are reachable from a script through registered functions
# exactly like these, and imagelist@ commits memory by a count the same way
# buffer_new@ does.
#
# THE EXPERIMENT HAS BEEN RUN, so the gap is now measured rather than suspected.
# Adding the directory names five routines, of which
#
#     host/gui/libs/PhosphorCanvasLib.pas:114
#     b.SetSize(ArgI32(A[0]), ArgI32(A[1]))
#
# is the one that matters: bitmap@(20000,20000) commits 2.35 GB and
# bitmap@(40000,40000) commits 4.78 GB, in one opCall, with no bound of any kind,
# on a host whose budget refuses buffer_new@(1073741824). The other four are
# ParsePoints, ModsOf, f_parent_set and f_app_run.
#
# The line stays out of SCAN_DIRS DELIBERATELY, and the sentence that used to end
# this paragraph -- "adding the directory here is the whole of the remaining work
# once that lands" -- was wrong. The GUI lane's guards HAVE landed, and the
# experiment was run at integration on the merged tree. Adding the directory
# reports EIGHT holes, not five:
#
#     ParsePoints, f_bitmap, ModsOf, f_parent_set, f_app_run,
#     StateStr, GuiModsStr, GuiImageFileCost
#
# and f_bitmap -- the 4.78 GB one, the whole reason the gap was named -- IS now
# guarded. It asks GuiChargeRoom before SetSize and settles with GuiChargeSet.
# The gate does not see it because GATE below matches Budget* and nothing else,
# and the GUI keeps a SECOND accounting for surface memory: GuiChargeRoom,
# GuiChargeSet, GuiImageFileReserve. Three of the eight are new this round --
# StateStr, GuiModsStr and GuiImageFileCost are flagged by the quadratic-append
# rule and build a handful of flag names, not a script-sized string.
#
# So the remaining work is a RULE, not a list: teach GATE the second accounting's
# verbs, so a door guarded by the GUI ledger reads as guarded, and then judge the
# small string builders individually. Eight exemptions written in a hurry is the
# outcome this file's own reasoning warns about -- it teaches the next reader to
# widen ALLOWED instead of fixing anything -- so the directory stays out until
# that rule exists rather than going in behind a list.

GATE = re.compile(r'\bBudget(Allows|Append|Charge|Active|Refusal|Sleep|Spent|PatternBounded|'
                  r'UnitsPerStep|UnitsPerMs)\b')

# A size or bound that is derived from something ALREADY IN MEMORY is bounded by
# memory and is not an amplifier. This is what "derived" looks like in this tree.
# Count/Size/Capacity are NOT anchored on the left, deliberately: AddressCount,
# SubExprMatchCount and HandleCount are the same fact spelled with a prefix, and a
# check that missed them would send a reader to widen ALLOWED instead.
# `Pos(` USED TO BE IN THIS LIST and that was the single worst line in the file:
# it made every routine containing a naive search read as bounded, which is how
# instr, countstr, replacestr$ and five more went uncounted. A search's RESULT is
# an offset into memory, but its COST is a product; it belongs in SEARCHES below.
DERIVED = re.compile(r'\bLength\s*\(|\bHigh\s*\(|Size\b|Count\b|Capacity\b|'
                     r'\bSizeOf\s*\(', re.I)
# A literal, or arithmetic on literals: `SetLength(r, 2)`, `for i := 0 to 255`.
LITERAL = re.compile(r'^[\s\d+\-*()]+$')
# A NUMBER that came from the program. A local assigned from one of these is
# tainted for the whole routine, however it is spelled afterwards -- which is
# the case the whole check exists for. A STRING argument is deliberately not
# tainted: it is already in memory, so its Length bounds a loop exactly as any
# other container's does, and calling `p := Args[0].Str` unbounded would have
# sent nine honest routines into ALLOWED for nothing.
TAINT = re.compile(r'\bArgI32\s*\(|\bArgI64\s*\(|\bAsDouble\s*\(|'
                   r'\bArgs?\s*\[[^\]]*\]\s*\.\s*(?:Int|Num|Hnd)\b')

# AND THE SAME TAINT, ONE CALL FURTHER IN. A routine's own numeric parameters are
# tainted inside it: a helper cannot see where its count came from, and the
# caller's taint pass stopped at the call. This is what let `SetLength(x, ACount)`
# inside a helper score as bounded.
PARAMLIST = re.compile(r'^(?:function|procedure|constructor|destructor)\s+[\w.]+\s*\(([^)]*)\)',
                       re.I | re.S)
NUMPARAM = re.compile(r':\s*(Integer|Int64|LongInt|LongWord|Cardinal|SizeInt|QWord|'
                      r'Word|Byte|SmallInt|ShortInt|Double|Single|Extended)\b', re.I)
DECOR = re.compile(r'\b(const|var|out)\b', re.I)

ALLOC = re.compile(r'\b(SetLength|StringOfChar|DupeString|SetSize)\s*\(', re.I)
FORLOOP = re.compile(r'\bfor\s+\w+\s*:=\s*(.+?)\s+(to|downto)\s+(.+?)\s+do\b',
                     re.I | re.S)
# The two loop forms the first version never looked at. Judged on the CONTROLLING
# CONDITION, the same way a for loop is judged on its high bound: a condition made
# of literals and of things already in memory is bounded, anything else is not.
WHILELOOP = re.compile(r'\bwhile\b(.+?)\bdo\b', re.I | re.S)
REPEATLOOP = re.compile(r'\brepeat\b.+?\buntil\b([^;]*)', re.I | re.S)
ASSIGN = re.compile(r'\b([A-Za-z_]\w*)\s*:=\s*([^;]+)')
NAMES = re.compile(r'[A-Za-z_]\w*')
NATIVES = [
    'Sleep(', 'TRegExpr', 'FindFirst(', 'sqlite3_step(', 'sqlite3_exec(',
    'Tdecompressionstream', 'TDecompressionStream', 'TUnZipper', 'TZipper',
]

# THE STRING PRODUCTS. Each compares or rewrites one string against another, and
# FPC's implementations are naive (a first-byte scan and a compare loop; see
# rtl/objpas/sysutils/syssr.inc for StringReplace, which additionally sizes its
# result with 32-bit arithmetic). The work is Length(hay) * Length(needle), which
# neither Length alone bounds.
SEARCHES = [
    'StringReplace(', 'PosEx(', 'AnsiPos(', 'ContainsText(', 'ContainsStr(',
    'AnsiContainsText(', 'Pos(',
]

# THE QUADRATIC APPEND -- the other half of the same wrong assumption SEARCHES
# fixed. The note above DERIVED says a String argument is not tainted because
# "its Length bounds a loop exactly as any other container's does". That is only
# true when the loop BODY is O(1), and
#
#     x := x + Copy(AText, i, 1)
#
# is not: FPC's fpc_AnsiStr_Concat reallocates, and the heap copies whenever it
# cannot extend the block in place. Three routines in the very directories this
# file scans were counted as bounded on that reasoning and ran 24-39x over a
# 2000 ms ceiling reporting SUCCESS -- IsValidBase64 (78031 ms at 160 MB),
# Utf8UpperU/Utf8LowerU (48984 ms), CpReverse (50750 ms).
#
# So an append INSIDE A LOOP is its own amplifier, judged like every other one:
# the routine must consult the budget, or say here why it need not. The tree has
# 49 such loop bodies; the ones a script can reach at scale are the family.
APPEND = re.compile(r'\b([A-Za-z_]\w*)\s*:=\s*\1\s*\+', re.I)
# Openers that a bare `end` closes, so a loop body's extent can be found without
# parsing Pascal. `record` and `object` appear in type sections, not in the
# routine bodies this walks, but cost nothing to count.
BLOCKOPEN = re.compile(r'\b(begin|case|try|record|object|asm)\b', re.I)
BLOCKCLOSE = re.compile(r'\bend\b', re.I)
LOOPSTART = re.compile(r'\b(for|while|repeat)\b', re.I)
DOWORD = re.compile(r'\bdo\b', re.I)
UNTILWORD = re.compile(r'\buntil\b', re.I)

# --narrowing: routines that RETURN or STORE 32 bits. A call to one of these,
# anywhere in engine/libs or host/packages, must be listed in NARROWING_OK with
# the reason its argument cannot exceed 32 bits -- or it is the int()/json_setn@
# defect again. Math.Floor/Ceil return Integer (rtl/objpas/math.pp:407-411);
# TJSONIntegerNumber's field is Integer (fcl-json/fpjson.pp:238).
NARROWERS = ['Floor(', 'Ceil(', 'TJSONIntegerNumber.Create(']

ROUTINE = re.compile(r'^(?:function|procedure|constructor|destructor)\s+'
                     r'([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)',
                     re.MULTILINE)

# A routine may skip the budget only for a reason written down here. The key is
# "<file>:<routine>"; the value is why. Anything not listed and not gated fails.
ALLOWED = {
    # ---- loops and allocations bounded by the LANGUAGE, not by a script -------
    'PhosphorBufferLib.pas:ReadRaw':
        'iterates the width of one integer: at most eight bytes',
    'PhosphorBufferLib.pas:WriteRaw':
        'the same eight bytes, written back',
    'PhosphorCallLib.pas:RegisterCallFuncs':
        'the registration table; MaxIndirectArgs is a constant of this unit',
    'PhosphorCrtLib.pas:CrtAssembleKey':
        'at most three continuation bytes: one UTF-8 codepoint',
    'PhosphorCrtLib.pas:KbdKeyPressed':
        'iterates the bytes one console read returned',
    'PhosphorBase64Lib.pas:f_b64_urldecode':
        'the append loop is `while (Length(s) mod 4) <> 0 do s := s + \'=\'`: at '
        'most three iterations of padding, whatever the input',
    'PhosphorPlatformLib.pas:NthNumber':
        'Linux only, and its one caller reads /proc/sys/kernel/osrelease -- a '
        'kernel version line, never a script string; the digits it appends are a '
        'handful',

    # ---- allocations bounded by data the caller already holds -----------------
    # CpStarts was here. The codepoint table moved to engine/PhosphorValue.pas
    # (as Utf8Starts) so that the `string - n` operator and PRINT USING's string
    # fields could stop cutting UTF-8 by bytes and share it. engine/*.pas is not
    # scanned by this gate (see the note at the top), so the entry would be stale
    # rather than protective; the reason it was exempt is unchanged -- one entry
    # per byte of a string already in memory, trimmed to the count found.
    'PhosphorStrListLib.pas:TPhosphorStringList.SetDelimitedText':
        'the field buffer is trimmed to the field it just read out of the input',
    'PhosphorBase64Lib.pas:f_hex_decode':
        'exactly half the input length, trimmed to the pairs actually decoded',
    'PhosphorHttpLib.pas:DoUrlDecode':
        'a decode is never longer than what it decodes',
    'PhosphorSqliteLib.pas:ColStr':
        'copies one column value, whose length sqlite reports',
    'PhosphorDateTimeLib.pas:t_dayoftheyear':
        'adds up the months before this one: at most eleven iterations',
    'PhosphorArrayLib.pas:TPhosphorArray.Create':
        'the constructor; DoDim asks the budget for exactly this element count '
        'before calling it',
    'PhosphorStrLib.pas:SplitBy':
        'one slot per separator found in a string already in memory',
    'PhosphorStrLib.pas:ToRadix':
        'a number in a base: at most 64 digits',
    'PhosphorStrListLib.pas:TPhosphorStringList.MoveItem':
        'shifts between two indices of the list, so at most Count elements',
    'PhosphorHttpLib.pas:EntIs':
        'the loop runs only when ALen equals Length(E), one of six literals of '
        'this unit, and DoHtmlDecode never offers an entity longer than ten bytes',
    'PhosphorHttpLib.pas:DoUrlEncode':
        'k is the count already written; the buffer is sized at three bytes per '
        'input byte, which is the longest an encode can make one',
    'PhosphorHttpLib.pas:DoHtmlEncode':
        'k is the count already written, and the output is bounded by the input',
    'PhosphorHttpLib.pas:DoHtmlDecode':
        'the same: a decode is never longer than what it decodes',

    # ---- guarded by the registered function that calls them -------------------
    'PhosphorZipLib.pas:TZipWriter.Create':
        'constructs an empty TZipper and binds a path; nothing is read or written yet',
    'PhosphorZipLib.pas:TZipReader.Create':
        'Examine reads the central directory only; every path that then EXPANDS '
        'an entry (ReadEntry, unzip_extract) asks ArchiveFitsBudget first',
    'PhosphorZipLib.pas:f_unzip_count':
        'reads the central directory and answers how many entries it lists',
    'PhosphorZipLib.pas:f_unzip_entry':
        'reads one entry NAME out of the central directory; nothing is expanded',
    'PhosphorZipLib.pas:f_zip_quick':
        'compresses one named file; the work is bounded by that file, which the '
        'sandbox has already had to allow, and compression only shrinks it',
    'PhosphorZipLib.pas:RegisterZipFuncs':
        'the registration table; names the zip types without opening anything',
    'PhosphorZipLib.pas:ArchiveIsSafe':
        'inspects an already-open TUnZipper entry by entry; ArchiveFitsBudget is '
        'the size half of the same inspection and does ask',

    # ---- sqlite: A SINGLE NATIVE STEP THAT CANNOT BE INTERRUPTED --------------
    # This is a real gap and it is written down rather than hidden. sqlite has an
    # interrupt seam -- sqlite3_progress_handler, which calls back every N virtual
    # machine instructions and can abort the statement -- and SQLite3Dyn does not
    # import it. Until it does, ONE sqlite3_step over a non-indexed join runs for
    # as long as it runs, with no line of our code in between. What IS charged is
    # every loop AROUND a step (sqlite_query$, sqlite_tables@, sqlite_columns@),
    # which is the part that is ours. The entries below each execute a single
    # step, so there is no loop of ours to charge.
    'PhosphorSqliteLib.pas:ExecSql':
        'sqlite3_exec runs a whole script natively; see the note above',
    'PhosphorSqliteLib.pas:DoStep':
        'advances one row; the loops that call it repeatedly do the charging',
    'PhosphorSqliteLib.pas:f_scalar_str':
        'one step, one value',
    'PhosphorSqliteLib.pas:f_scalar_num':
        'one step, one value',
    'PhosphorSqliteLib.pas:f_tableexists':
        'one step against sqlite_master',
    'PhosphorSqliteLib.pas:f_insertjson':
        'one step of an INSERT',
    'PhosphorSqliteLib.pas:f_updatejson':
        'one step of an UPDATE',

    # ---- A SEARCH WHOSE NEEDLE IS A CONSTANT OF THIS UNIT --------------------
    # The rule that put these on the list is right: Pos/StringReplace cost
    # Length(hay) * Length(needle). What makes each of these bounded is that the
    # NEEDLE is fixed here -- one character, or a three-character marker -- so the
    # product collapses to a constant times the haystack, which is already in
    # memory. Every place the needle comes from the SCRIPT (instr, countstr,
    # replacestr$, containsstr, word$, wordcount, instrrev, containstext) asks
    # BudgetAllows(SearchCost(...)) instead, and is not listed here.
    'PhosphorStrListLib.pas:TPhosphorStringList.IndexOfName':
        'the needle is NameValueSeparator: one character',
    'PhosphorStrListLib.pas:TPhosphorStringList.ValueOf':
        'the same one-character separator',
    'PhosphorStrListLib.pas:TPhosphorStringList.NameAt':
        'the same one-character separator',
    'PhosphorStrListLib.pas:TPhosphorStringList.ValueAt':
        'the same one-character separator',
    'PhosphorStrListLib.pas:TPhosphorStringList.GetDelimitedText':
        'doubles QuoteChar inside one field: a one-character needle over a string '
        'already in the list',
    'PhosphorSysLib.pas:GuidHex':
        'strips the braces and dashes of a GUID: a fixed 38-character string',
    'PhosphorSqliteLib.pas:QuoteIdent':
        'doubles one quote character inside one identifier',
    'PhosphorSqliteLib.pas:EscapeSql':
        'doubles one quote character inside one literal',
    'PhosphorZipLib.pas:SafeEntryName':
        'rewrites one-character path separators in one entry name',
    'PhosphorRagLib.pas:ContainsSub':
        'the haystack is a tag, a title or an id and the needle a query keyword; '
        'ScoreDocument, its only caller, charges once per document scored',
    'PhosphorRagLib.pas:ParseHeader':
        'the needles are the fixed front-matter markers of this format',
    'PhosphorRagLib.pas:TPhosphorRag.LoadContent':
        'one PosEx for the three-character front-matter terminator',
    'PhosphorRagLib.pas:TPhosphorRag.DetectIntent':
        'the needles are this unit''s intent words, against one query',
    'PhosphorRagLib.pas:TPhosphorRag.DetectLibraryHints':
        'the needles are this unit''s library names, against one query',
    'PhosphorRagLib.pas:TPhosphorRag.AnalyzeQuery':
        'the needles are fixed markers, against one query',

    # ---- A HELPER WHOSE CALLER ASKS, named because taint does not cross a call --
    # These now appear only because a routine's numeric parameters are tainted
    # inside it (see param_taint). That is the right rule -- it is what would have
    # caught a `procedure Grow(ACount: Integer)` -- and the answer for a helper
    # whose ONLY caller already asked is to say so here, with the caller named.
    'PhosphorBufferLib.pas:NewBuffer':
        'buffer_new@ asks BudgetAllows for exactly this size, and the 1 GiB cap, '
        'before calling in; NewBuffer has no other caller',
    'PhosphorStrListLib.pas:TPhosphorStringList.CapacitySet':
        'strings_capacity asks BudgetAllows for exactly this slot count before '
        'calling in; CapacitySet has no other caller',

    # ---- A WAIT ON THE USER, which is what a key read IS ---------------------
    # Written down rather than hidden, like the sqlite note above. KbdRead's loop
    # consumes one console input event per iteration and only goes round again for
    # an event that is not a key (key-up, mouse, focus), so the LOOP is bounded by
    # input. What is unbounded is the blocking read inside it -- and a host that
    # loads the CRT package has asked for a console that waits for a person. There
    # is no count here for a budget to bound; a key read is not "running long".
    'PhosphorCrtLib.pas:KbdRead':
        'each turn of the loop consumes one console event; the wait inside is a '
        'wait on the user, which is the whole purpose of a key read',

    # ---- host/console: THE VM IS NOT RUNNING WHEN THESE RUN ------------------
    # One discriminator covers all but two of this directory, and it is worth
    # stating as a rule rather than repeating as eight excuses: a script can only
    # reach host code through a SEAM, and this host has three -- Output, ReadLine
    # and Breakpoint. Everything else here is startup, argument handling, packing
    # or the REPL's own read loop, which run with no program executing and no
    # budget in existence to consult. A future seam is therefore the only thing in
    # this file that has to come back to this list.
    #
    # Two are seams and are answered on their own terms below: ReadLine, whose
    # sizes come from the console; and Breakpoint, which is why the directory is
    # scanned at all.
    'phosphor.lpr:TDbgReader.Execute':
        'the socket read loop of the debug protocol. It is bounded by what the '
        'editor sends, not by anything the script can do, and it refuses a frame '
        'past DBG_MAX_FRAME rather than growing -- a peer that never sends a '
        'newline closes the session instead of eating memory',
    'phosphor.lpr:TDebugProto.SetInitial':
        'copies the armed set ParseBreakList filled, which that function caps at '
        '256 -- a command line, not a script',
    'phosphor.lpr:TDebugProto.DoStackTrace':
        'the frame walk is capped at DBG_MAX_FRAMES, a constant of that routine, '
        'for the reason TDebugSession.ShowStack is',
    'phosphor.lpr:TDebugProto.OnStop':
        'the stop loop of a debugger: it turns once per frame the EDITOR sends '
        'and leaves on the first one that resumes. The seam it sits in is the one '
        'seam in this engine that MAY block, which is what a stop is',
    'phosphor.lpr:TDebugProto.Session':
        'waits for `initialize` and `launch` from the editor before anything '
        'runs; the script has not started and cannot influence it',
    'phosphor.lpr:TDebugSession.ShowStack':
        'the frame walk is capped at DBG_STACK_MAX, a constant of that routine, '
        'and says how many frames it did not print. The SCRIPT chooses the depth '
        '-- 262144 frames is reachable -- so the loop is bounded by the host and '
        'not by the program, which is what the cap is for',
    'phosphor.lpr:TDebugSession.OnStop':
        'the command loop of an interactive debugger: it iterates once per '
        'command a PERSON types and leaves on the first one that answers the '
        'seam. A script cannot make it turn, and stdin at EOF leaves it on the '
        'first pass -- which is asserted in block Q of scripts/test.{ps1,sh}',
    'phosphor.lpr:ParseBreakList':
        'splits the --break argument, which is a command line and not a script; '
        'and it refuses past 256 lines rather than growing',
    'phosphor.lpr:DebugFile':
        'copies the armed set ParseBreakList filled, which that function caps at '
        '256 -- a command line, not a script',
    'phosphor.lpr:TConsoleHost.Breakpoint':
        'the report is bounded by three named constants of this unit -- '
        'BP_MAX_MESSAGE_BYTES, BP_MAX_OPERAND_BYTES and BP_MAX_LINE_BYTES -- so '
        'neither the operand count nor any operand length decides the work; the '
        'loop stops at the line ceiling and DECLARES what it dropped, and block P '
        'of scripts/test.{ps1,sh} measures the bound rather than trusting this '
        'sentence',
    'phosphor.lpr:EscapeForDiag':
        'a StringReplace pass per escape, over text its two callers have already '
        'capped: RenderOperand cuts to BP_MAX_OPERAND_BYTES and Breakpoint to '
        'BP_MAX_MESSAGE_BYTES, both BEFORE calling in, so the haystack is at most '
        'a kilobyte and every needle is one character',
    'phosphor.lpr:TConsoleHost.ReadLine':
        'reads ONE console line into a fixed 8192-WideChar buffer; both SetLengths '
        'are sized by what ReadConsoleW reported into it, and the Pos looks for a '
        'single Ctrl+Z character in that same line',
    'phosphor.lpr:ClipRetryCopy':
        'the clipboard is a contended OS resource, so a write is retried at most '
        'six times with Sleep(15) between -- a literal bound, at most 90 ms, '
        'whatever the script asked to copy',
    'phosphor.lpr:ClipRetryPaste':
        'the same retry, three times: at most 45 ms',
    'phosphor.lpr:FindPackMark':
        'scans the running process image for its own pack mark; ACount is the size '
        'of a file already read into memory, and this runs before any program does',
    'phosphor.lpr:PayloadChecksum':
        'one FNV-1a pass over the packed payload already in memory, at startup and '
        'at pack time; no script is running either time',
    'phosphor.lpr:Repl':
        'the prompt loop: one turn per line a person types, ending at EOF. There '
        'is no count here for a budget to bound -- the same answer KbdRead gets '
        'above, and for the same reason',
    'phosphortest.lpr:NewestIn':
        'the test runner enumerating one source directory at startup to decide '
        'whether its own binary is stale; not reachable from a script at all',

    # ---- host/packages, REACHED ONLY NOW BECAUSE .lpr IS SCANNED -------------
    # This one is not in host/console: it is in host/packages, which this gate
    # has scanned all along, in a file it could not see because sources() took
    # .pas only. Widening the extension found it, which is the argument for the
    # widening in one line.
    #
    # AND READ THE KEY BEFORE BELIEVING IT. routines_of gives the LAST routine in
    # a file a body that runs to end-of-file, so in a PROGRAM the main
    # `begin .. end.` block is attributed to whatever routine was declared last.
    # WriteSummary does not sleep; the main block does, waiting for the test
    # server it just started to come up. The reason below is about that wait.
    'phosphorhttptest.lpr:WriteSummary':
        'the label is the last routine in the file, but the code is the runner\'s '
        'main block: it waits up to 3000 ms in 20 ms slices for its own loopback '
        'HTTP server to report Active before running any .bas. A literal ceiling, '
        'a fixed port, and no program executing yet',
}


def strip_comments(text):
    """Pascal comments and string literals out. A primitive named in prose is
    documentation -- and this file's own libraries explain their amplifiers at
    length, which is exactly the text that must not be mistaken for code."""
    text = re.sub(r'(?m)//.*?$', ' ', text)
    text = re.sub(r'(?s)\{.*?\}', ' ', text)
    text = re.sub(r'(?s)\(\*.*?\*\)', ' ', text)
    return re.sub(r"'(?:[^']|'')*'", "''", text)


def routines_of(text):
    """Top-level routine bodies. A nested helper's calls count against the routine
    that encloses it -- conservative on purpose, since that is where the guard
    belongs anyway."""
    marks = [(m.start(), m.group(1)) for m in ROUTINE.finditer(text)]
    for i, (pos, name) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(text)
        yield name, text[pos:end]


def balanced_arg(body, open_idx):
    """The text between the parenthesis at open_idx and its match."""
    depth = 0
    for j in range(open_idx, len(body)):
        if body[j] == '(':
            depth += 1
        elif body[j] == ')':
            depth -= 1
            if depth == 0:
                return body[open_idx + 1:j]
    return body[open_idx + 1:]


def param_taint(body):
    """A routine's own numeric parameters, tainted.

    TAINT above only reaches an ArgI32/AsDouble written in THIS body, so a helper
    that receives the count already converted -- `procedure Grow(ACount: Integer)`
    -- saw nothing tainted and its SetLength(x, ACount) read as bounded. Taint does
    not cross a call boundary, so the boundary is where it has to be re-applied:
    inside a routine, a numeric parameter is a number from somewhere unknown, which
    is exactly what the rule is about. Either the helper consults, or its caller
    does (gated_names resolves that transitively), or it is exempt by name."""
    m = PARAMLIST.match(body)
    out = set()
    if not m:
        return out
    for part in m.group(1).split(';'):
        if not NUMPARAM.search(part):
            continue
        for nm in NAMES.findall(DECOR.sub(' ', part.split(':')[0])):
            out.add(nm)
    return out


def flow(body):
    """(derived, tainted): local names assigned from something already in memory,
    and local names assigned from something the PROGRAM supplied.

    A name in both sets counts as tainted -- a size that is sometimes an argument
    is an argument. Without this pass `len := Length(S); for i := 1 to len` reads
    as unbounded and a reader learns to widen ALLOWED, which is how a rule like
    this rots."""
    derived, tainted = set(), param_taint(body)
    for m in ASSIGN.finditer(body):
        name, expr = m.group(1), m.group(2)
        if TAINT.search(expr):
            tainted.add(name)
        elif DERIVED.search(expr):
            derived.add(name)
    return derived - tainted, tainted


def bounded(expr, derived, tainted):
    """Is this size / loop bound something the machine's memory already limits?"""
    names = set(NAMES.findall(expr))
    if names & tainted:
        return False
    if LITERAL.match(expr):
        return True
    if DERIVED.search(expr):
        return True
    return bool(names & derived)


def block_end(body, start):
    """Index just past the `end` that closes the block opened at `start`."""
    depth = 0
    i = start
    while i < len(body):
        mo = BLOCKOPEN.search(body, i)
        mc = BLOCKCLOSE.search(body, i)
        if mc is None:
            return len(body)
        if mo is not None and mo.start() < mc.start():
            depth += 1
            i = mo.end()
            continue
        depth -= 1
        if depth <= 0:
            return mc.end()
        i = mc.end()
    return len(body)


def loop_spans(body):
    """(start, end) of every loop BODY in this routine, outermost text order.

    for/while run to the matching `end` when the body is a begin block and to the
    next `;` when it is one statement; repeat runs to its `until`. Approximate on
    purpose: a lint that over-reaches names a routine that then gets a written
    reason, while one that under-reaches is how three quadratic routines went
    uncounted for two rounds."""
    spans = []
    for m in LOOPSTART.finditer(body):
        word = m.group(1).lower()
        if word == 'repeat':
            u = UNTILWORD.search(body, m.end())
            spans.append((m.end(), u.start() if u else len(body)))
            continue
        d = DOWORD.search(body, m.end())
        if d is None:
            continue
        rest = body[d.end():]
        stripped = rest.lstrip()
        if stripped[:5].lower() == 'begin':
            open_at = d.end() + (len(rest) - len(stripped))
            spans.append((open_at, block_end(body, open_at)))
        else:
            semi = body.find(';', d.end())
            spans.append((d.end(), semi if semi >= 0 else len(body)))
    return spans


def appends_in_loops(body):
    """`x := x + ...` occurring inside a loop body, as short labels."""
    spans = loop_spans(body)
    if not spans:
        return []
    hits = []
    for m in APPEND.finditer(body):
        if any(lo <= m.start() < hi for lo, hi in spans):
            hits.append('%s := %s + .. in a loop' % (m.group(1), m.group(1)))
    return hits


def amplifiers(body):
    """Every amplifying construct in one routine body, as short labels."""
    derived, tainted = flow(body)
    hits = []
    for m in ALLOC.finditer(body):
        call = m.group(1)
        args = balanced_arg(body, m.end() - 1)
        # The SIZE is the last argument of each of these calls.
        size = args.rsplit(',', 1)[-1] if ',' in args else args
        if bounded(size, derived, tainted):
            continue
        hits.append('%s(... %s)' % (call, size.strip()[:34]))
    for m in FORLOOP.finditer(body):
        lo, direction, hi = m.group(1), m.group(2).lower(), m.group(3)
        # The iteration count is |hi - lo|, so the HIGH end is what bounds it: the
        # second bound counting up, the first counting down. `for i := Length(P)
        # downto AAfter + 1` runs at most Length(P) times however small AAfter is.
        limit = hi if direction == 'to' else lo
        if bounded(limit, derived, tainted):
            continue
        hits.append('for .. %s %s' % (direction, limit.strip()[:34]))
    for m in WHILELOOP.finditer(body):
        cond = m.group(1)
        if bounded(cond, derived, tainted):
            continue
        hits.append('while %s' % cond.strip()[:34])
    for m in REPEATLOOP.finditer(body):
        cond = m.group(1)
        if bounded(cond, derived, tainted):
            continue
        hits.append('repeat .. until %s' % cond.strip()[:34])
    for nat in NATIVES:
        if nat in body:
            hits.append(nat.rstrip('('))
    for sea in SEARCHES:
        if sea in body:
            hits.append(sea.rstrip('('))
    hits.extend(appends_in_loops(body))
    return sorted(set(hits))


#: what a scan directory can hold. `.lpr` was missing and that was the silent
#: half of the host/console blindness: a directory of programs scanned as empty
#: and reported as clean. Keep the two together.
SOURCE_EXTS = ('.pas', '.lpr')


def sources(dirs):
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if fn.lower().endswith(SOURCE_EXTS):
                yield os.path.join(d, fn)


def gated_names(routines):
    """Routine names in this file that consult the budget, DIRECTLY OR THROUGH A
    HELPER OF THEIR OWN.

    A unit is allowed to put its consultation in one place -- RegexGuard in
    PhosphorRegexLib, WalkStep in PhosphorIoLib -- and a check that could not see
    that would push every caller into ALLOWED, which is where exemptions go to
    stop meaning anything. Resolved to a fixed point, so a helper calling a helper
    still counts."""
    gated = set()
    for name, body in routines:
        if GATE.search(body):
            gated.add(name.split('.')[-1])
    changed = True
    while changed:
        changed = False
        for name, body in routines:
            short = name.split('.')[-1]
            if short in gated:
                continue
            called = set(NAMES.findall(body)) - {short}
            if called & gated:
                gated.add(short)
                changed = True
    return gated


def scan(dirs, allowed):
    """(holes, gated, used-exemptions)."""
    holes = []
    gated = 0
    used = set()
    for path in sources(dirs):
        base = os.path.basename(path)
        with open(path, encoding='utf-8') as fh:
            text = strip_comments(fh.read())
        routines = list(routines_of(text))
        consults = gated_names(routines)
        for name, body in routines:
            hits = amplifiers(body)
            if not hits:
                continue
            key = '%s:%s' % (base, name)
            if key in allowed:
                used.add(key)
                continue
            if name.split('.')[-1] in consults:
                gated += 1
                continue
            holes.append((key, hits))
    return holes, gated, used


def report(holes):
    print('BUDGET HOLES -- these can run long without consulting the budget:')
    for key, hits in holes:
        print('  %-56s %s' % (key, ', '.join(hits)))
    print('')
    print('Each must call a Budget* function from engine/PhosphorBudget.pas --')
    print('BudgetAllows(count) before an operation whose size its arguments fix,')
    print('BudgetCharge(units) inside a loop whose length they do not -- or be listed')
    print('in ALLOWED in scripts/check-budget.py with the reason it need not.')


# --narrowing: every call to a 32-bit-returning routine in the scanned tree, and
# why its argument cannot exceed 32 bits. A call not listed here fails the sweep.
NARROWING_OK = {
    'PhosphorJsonLib.pas:NumNode:TJSONIntegerNumber.Create(':
        'guarded one line above by Low(Integer) <= v <= High(Integer); anything '
        'outside that range takes TJSONInt64Number instead',
}


def narrowing_sweep(dirs, reviewed):
    """(unreviewed calls, reviewed-keys-used).

    THE SECOND RULE, and the same mistake as the first: a guard of one width
    followed by an operation of another. int() checked InI64Range and narrowed
    with Math.Floor (Integer); json_setn@ checked Abs(d) < 9.2e18 and stored
    through TJSONIntegerNumber (Integer field). Both answered silently wrong
    numbers on both platforms. This lists every remaining call to a routine known
    to return or store 32 bits, so a third one cannot arrive unremarked.
    """
    bad, used = [], set()
    for path in sources(dirs):
        base = os.path.basename(path)
        with open(path, encoding='utf-8') as fh:
            text = strip_comments(fh.read())
        for name, body in routines_of(text):
            for nar in NARROWERS:
                if nar not in body:
                    continue
                key = '%s:%s:%s' % (base, name, nar)
                if key in reviewed:
                    used.add(key)
                else:
                    bad.append(key)
    return bad, used


def narrowing():
    bad, used = narrowing_sweep(SCAN_DIRS, NARROWING_OK)
    if bad:
        print('NARROWING -- a 32-bit operation whose argument is not shown to fit:')
        for key in bad:
            print('  ' + key)
        print('')
        print('Use the 64-bit form (Floor64/Ceil64/TJSONInt64Number), or add the')
        print('call to NARROWING_OK in scripts/check-budget.py with the guard that')
        print('bounds it. int(3e9) answered -1294967296 for want of this.')
        return 1
    stale = set(NARROWING_OK) - used
    if stale:
        print('STALE NARROWING ENTRIES -- listed but no longer present:')
        for key in sorted(stale):
            print('  ' + key)
        return 1
    print('narrowing sweep: no unreviewed 32-bit narrowing in %d directories'
          % len(SCAN_DIRS))
    return 0


def prove():
    """Plant a violation and confirm the check reports it.

    A gate is worth exactly what it has been SEEN to catch. This writes a routine
    with the string$ defect -- a loop over a script-supplied count, no budget
    consulted -- into a scratch unit, scans the scratch directory, and fails if
    the check stays quiet. Nothing in the tree is touched.
    """
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, 'PhosphorPlantedLib.pas'), 'w',
                  encoding='utf-8') as fh:
            fh.write('unit PhosphorPlantedLib;\n'
                     'interface\n'
                     'implementation\n'
                     'function f_planted(const A: array of TValue;\n'
                     '  out E: TPhosphorError): TValue;\n'
                     'var n, i: Integer; r: String;\n'
                     'begin\n'
                     '  n := ArgI32(A[0]);\n'
                     '  r := 0;\n'
                     '  for i := 1 to n do r := r + 1;\n'
                     '  SetLength(r, n);\n'
                     '  Result := ValStr(r);\n'
                     'end;\n'
                     'end.\n')
        holes, _, _ = scan([d], {})
        names = [k for k, _ in holes]
        if 'PhosphorPlantedLib.pas:f_planted' not in names:
            print('PROVE FAILED: the planted violation was NOT reported.')
            print('  reported: %s' % (names or '(nothing)'))
            return 1
        print('prove: the planted violation was reported --')
        for key, hits in holes:
            print('  %-56s %s' % (key, ', '.join(hits)))
        # And the same routine WITH a consultation must go quiet, or the check is
        # not measuring the consultation at all.
        with open(os.path.join(d, 'PhosphorPlantedLib.pas'), 'w',
                  encoding='utf-8') as fh:
            fh.write('unit PhosphorPlantedLib;\n'
                     'interface\n'
                     'implementation\n'
                     'function f_planted(const A: array of TValue;\n'
                     '  out E: TPhosphorError): TValue;\n'
                     'var n, i: Integer; r: String;\n'
                     'begin\n'
                     '  n := ArgI32(A[0]);\n'
                     '  if not BudgetAllows(n) then Exit(ValStr(0));\n'
                     '  r := 0;\n'
                     '  for i := 1 to n do r := r + 1;\n'
                     '  SetLength(r, n);\n'
                     '  Result := ValStr(r);\n'
                     'end;\n'
                     'end.\n')
        holes, gated, _ = scan([d], {})
        if holes or gated != 1:
            print('PROVE FAILED: the GUARDED version was not accepted '
                  '(holes=%s gated=%d)' % ([k for k, _ in holes], gated))
            return 1
        print('prove: the same routine with BudgetAllows is accepted.')

        # AND EACH OF THE THREE RULES THE FIRST VERSION DID NOT HAVE, planted
        # separately -- a rule that has never been seen to fire is not a rule.
        widened = [
            ('a while loop over a script-supplied count',
             'f_planted_while',
             'var n, i: Integer;\n'
             'begin\n'
             '  n := ArgI32(A[0]);\n'
             '  i := 0;\n'
             '  while i < n do Inc(i);\n'
             '  Result := ValInt(i);\n'
             'end;\n'),
            ('a string product',
             'f_planted_search',
             'begin\n'
             '  Result := ValInt(Pos(A[1].Str, A[0].Str));\n'
             'end;\n'),
            ('a helper allocating over its own parameter',
             'Grow',
             'begin\n'
             '  SetLength(GBuf, ACount);\n'
             'end;\n'),
            # ROUND THREE. Planted with a loop that IS bounded (`for i := 1 to
            # Length(s)`), no allocation, no native and no search in it, so
            # nothing but the new append rule can report it. A rule proved by a
            # case another rule would also have caught proves only that the
            # other rule works.
            ('a quadratic append inside a bounded loop',
             'f_planted_append',
             'var i: Integer; r, s: String;\n'
             'begin\n'
             '  s := A[0].Str;\n'
             "  r := '';\n"
             '  for i := 1 to Length(s) do r := r + Copy(s, i, 1);\n'
             '  Result := ValStr(r);\n'
             'end;\n'),
        ]
        for label, fname, tail in widened:
            head = ('unit PhosphorPlantedLib;\ninterface\nimplementation\n')
            if fname == 'Grow':
                sig = 'procedure Grow(ACount: Integer);\n'
            else:
                sig = ('function %s(const A: array of TValue;\n'
                       '  out E: TPhosphorError): TValue;\n' % fname)
            with open(os.path.join(d, 'PhosphorPlantedLib.pas'), 'w',
                      encoding='utf-8') as fh:
                fh.write(head + sig + tail + 'end.\n')
            holes, _, _ = scan([d], {})
            names = [k for k, _ in holes]
            if 'PhosphorPlantedLib.pas:%s' % fname not in names:
                print('PROVE FAILED: %s was NOT reported.' % label)
                print('  reported: %s' % (names or '(nothing)'))
                return 1
            if fname == 'f_planted_append' and \
               not any('in a loop' in h for h in holes[0][1]):
                print('PROVE FAILED: the planted append was reported by some '
                      'OTHER rule (%s), so the append rule is unproven.'
                      % holes[0][1])
                return 1
            print('prove: %s is reported (%s).' % (label, holes[0][1]))

        # And the narrowing sweep, seen failing too.
        with open(os.path.join(d, 'PhosphorPlantedLib.pas'), 'w',
                  encoding='utf-8') as fh:
            fh.write('unit PhosphorPlantedLib;\ninterface\nimplementation\n'
                     'function f_planted_int(const A: array of TValue;\n'
                     '  out E: TPhosphorError): TValue;\n'
                     'begin\n'
                     '  Result := ValInt(Floor(AsDouble(A[0])));\n'
                     'end;\n'
                     'end.\n')
        bad, _ = narrowing_sweep([d], {})
        if not bad:
            print('PROVE FAILED: the planted 32-bit narrowing was NOT reported.')
            return 1
        print('prove: a planted 32-bit narrowing is reported (%s).' % bad[0])
        bad, _ = narrowing_sweep([d], {bad[0]: 'planted, for the prove run'})
        if bad:
            print('PROVE FAILED: the REVIEWED narrowing was not accepted (%s).' % bad)
            return 1
        print('prove: the same narrowing, listed as reviewed, is accepted.')
        return 0


def main():
    if '--prove' in sys.argv:
        return prove()
    if '--narrowing' in sys.argv:
        return narrowing()
    # A SCAN DIRECTORY THAT YIELDS NOTHING IS A GREEN LINE ABOUT NOTHING. This is
    # not hypothetical: host/console holds two .lpr files and sources() yielded
    # only .pas, so adding the directory without also widening the extensions
    # would have scanned zero files and still printed "budget gate: ... exempt by
    # name". Asked here rather than left to a reader, because a filter that hides
    # the answer is indistinguishable from a pass.
    for d in SCAN_DIRS:
        if not any(sources([d])):
            print('SCAN DIRECTORY YIELDS NO SOURCE -- this gate would report '
                  'nothing about it:')
            print('  %s' % d)
            print('')
            print('Either the path is wrong, or it holds a file extension')
            print('SOURCE_EXTS does not list (%s). A directory scanned as empty'
                  % ', '.join(SOURCE_EXTS))
            print('reads exactly like a directory with nothing wrong in it.')
            return 1
    holes, gated, used = scan(SCAN_DIRS, ALLOWED)
    if holes:
        report(holes)
        return 1
    print('budget gate: %d routines can run long, all %d consult the budget, '
          '%d exempt by name' % (gated + len(used), gated, len(used)))
    unused = set(ALLOWED) - used
    if unused:
        # A stale exemption is a rule nobody is checking any more -- the same
        # failure check-sandbox.py names.
        print('STALE EXEMPTIONS -- listed in ALLOWED but no longer present:')
        for key in sorted(unused):
            print('  ' + key)
        return 1
    # The narrowing sweep runs on every plain invocation too: a second rule that
    # has to be REMEMBERED is a rule half the runs do not have.
    return narrowing()


if __name__ == '__main__':
    sys.exit(main())
