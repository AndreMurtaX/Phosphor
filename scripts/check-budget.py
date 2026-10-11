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
#     host/gui/libs/PhosphorCanvasLib.pas#f_bitmap
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
#
# AND SCANNING IT WOULD NOT HAVE FOUND d42 (closed 2026-10-06), which is worth
# saying because the attack plan filed that defect's whole class as "gate-less by
# construction" on the strength of this exclusion. image_setbitmap@ put a full
# copy of a bitmap into an image with no GUI-ledger charge -- but the copy is
# sized by a bitmap ALREADY IN MEMORY, which this gate counts as derived and
# therefore bounded, correctly by its own rule. What d42 broke is a different
# invariant: every place that makes a GUI surface is charged to the GUI ledger.
# This gate asks whether a SCRIPT-SUPPLIED NUMBER reaches an allocation unguarded;
# it never could have asked that, in or out of SCAN_DIRS. That invariant is held
# today by one door per surface (bitmap@, image_load@, the image list, the grid,
# and now image_setbitmap@) and pinned by tests/gui/19, 20 and 23, not by a gate.

GATE = re.compile(r'\bBudget(Allows|Append|Charge|Active|Refusal|Sleep|Spent|PatternBounded|'
                  r'UnitsPerStep|UnitsPerMs|Linear\w*|Meter\w*|SearchCost)\b')
# The verbs that CHARGE. The linear pass below asks for one of these in the
# routine itself: naming BudgetRefusal or BudgetActive prices nothing.
LIN_GATE = re.compile(r'\bBudget(Allows|Append|Charge|Sleep|Linear\w*|MeterAdd|MeterEnd|'
                      r'SearchCost)\b')

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
# the case the whole check exists for. A STRING argument is not tainted HERE:
# this rule asks whether a call can be asked for more than memory holds, and a
# string's Length bounds ONE call. It does not bound a loop of such calls --
# that sentence used to end "exactly as any other container's does", and about
# fifty functions ran up to 36x past TimeoutMs behind it (round 7). The LINEAR
# PASS further down is the rule for strings and containers; see linear_scan.
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
    'phosphor.lpr:TDebugProto.Handle':
        'the debug PROTOCOL parser, which no script can reach. It sizes its '
        'breakpoint array from one JSON frame sent by the editor over loopback, '
        'and that frame is already capped at DBG_MAX_FRAME (1 MB, '
        'host/console/phosphor.lpr) by the reader that assembled it -- roughly a '
        'quarter of a million line numbers at the absolute worst, on a host '
        'thread, between statements of the program rather than inside one. The '
        'budget bounds what an untrusted SCRIPT can make the engine do; a script '
        'cannot put a byte into this array. Widening the exemption past this one '
        'routine would be wrong: everything else in this host that grows from a '
        'script-supplied count is still asked',

    # ---- loops and allocations bounded by the LANGUAGE, not by a script -------
    'PhosphorBufferLib.pas:ReadRaw':
        'iterates the width of one integer: at most eight bytes',
    'PhosphorBufferLib.pas:WriteRaw':
        'the same eight bytes, written back',
    'PhosphorCallLib.pas:RegisterCallFuncs':
        'the registration table; MaxIndirectArgs is a constant of this unit',
    'PhosphorCrtLib.pas:CrtAssembleKey':
        'at most three continuation bytes: one UTF-8 codepoint',
    'PhosphorCrtLib.pas:CrtTakePendingLine':
        'copies the unanswered presses of ONE key-down: wRepeatCount is a 16-bit '
        'field the console fills, never a number from the script',
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
    'PhosphorBase64Lib.pas:f_hex_decode':
        'exactly half the input length, trimmed to the pairs actually decoded',
    'PhosphorHttpLib.pas:DoUrlDecode':
        'a decode is never longer than what it decodes',
    'PhosphorHttpLib.pas:THostCheckedHandler.Connect':
        'the non-blocking handshake loop runs only under a deadline and leaves it '
        'the moment the deadline passes -- each wait in select() is bounded by what '
        'is left of it; the loop IS the bound (test 24 measures it at the deadline)',
    'PhosphorSqliteLib.pas:ColStr':
        'copies one column value, whose length sqlite reports',
    'PhosphorDateTimeLib.pas:t_dayoftheyear':
        'adds up the months before this one: at most eleven iterations',
    'PhosphorArrayLib.pas:TPhosphorArray.Create':
        'the constructor; DoDim asks the budget for exactly this element count '
        'before calling it',
    'PhosphorStrLib.pas:SplitBy':
        'one slot per separator found in a string already in memory',
    'phosphorhttptest.lpr:TServerThread.HandleRequest':
        'the TEST server: Pos with the constant needle "/inspect" over one request '
        'target the runner already received -- a scan, and no script reaches it',
    'PhosphorConfigLib.pas:WrapForeign':
        'Pos with a ONE-CHARACTER needle ("=") is a scan, not a product: linear in '
        'one line of a file already read into memory, once per line',
    'PhosphorConfigLib.pas:UnstorableWhy':
        'Pos with one-character needles (a line break, "=") over a section, key '
        'or value the script already holds: linear in each, and asked once per set',
    'PhosphorStrLib.pas:ToRadix':
        'a number in a base: at most 64 digits',
    'PhosphorStrListLib.pas:TPhosphorStringList.MoveItem':
        'shifts between two indices of the list, so at most Count elements in '
        'one call -- which bounds the call and not a loop of them: t_strings_move '
        'prices the slots it shifts before calling in (round 7, linear pass)',
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
    # ---- m6, IPv6: what each loop is bounded by -----------------------------------
    'PhosphorHttpLib.pas:TPlain6Handler.Recv':
        'retries ONLY a system call a signal interrupted, as FPC\'s own '
        'TSocketHandler.Recv does; the wait itself is bounded by the IO timeout '
        'TInet6Socket.Connect sets on the descriptor, which FetchCore derives '
        'from the budget\'s remaining time',
    'PhosphorHttpLib.pas:TPlain6Handler.Send':
        'the same EINTR retry, bounded the same way',
    'PhosphorHttpLib.pas:ParseIPv6':
        'one Pos with a one-character needle (":") over a URL host the script '
        'already handed over -- a scan, linear in it -- then the RTL\'s parse of it',
    # ---- 2026-10-07, redirects followed hop by hop -------------------------------
    'PhosphorHttpLib.pas:FetchHop':
        'one Pos with a one-character needle (":") over the host it dials, a scan '
        'linear in a host the script already handed over',
    'PhosphorHttpLib.pas:DotlessUrl':
        'three forward scans over one url the script already handed over, each '
        'stopping at the end of the authority -- linear in the url',
    'PhosphorHttpLib.pas:FetchCore':
        'the redirect loop: at most MaxRedirects hops, which ClientFollow clamps '
        'to 255, and each hop a request bounded by its own connect and IO '
        'timeouts and the run\'s deadline',
    'PhosphorHttpLib.pas:ResponseCookies':
        'walks the headers the SERVER answered with, one Pos per line, after '
        'reading them was bounded by the IO timeout and the run\'s deadline; '
        'nothing the script sized',
    'phosphorhttptest.lpr:QueryArg':
        'the TEST server reading a query its own test sent; no script reaches it',
    'PhosphorHttpLib.pas:HttpResolveAAAA':
        'walks what the RESOLVER answered, not anything the script sized: '
        'at most sixteen addresses from netdb, and the getaddrinfo list',
    'phosphorhttptest.lpr:TV6Server.Execute':
        'the TEST server\'s accept loop, on a thread of the runner; no script '
        'reaches it, and the process ends with Halt',
    'phosphorhttptest.lpr:TRelay.Execute':
        'the TEST relay\'s accept-and-copy loop, on a thread of the runner, '
        'trickling a TLS session for 25_http_broken; no script reaches it',
    'PhosphorHttpLib.pas:ResponseComplete':
        'one Pos over the Transfer-Encoding header\'s value, a line FPC already '
        'read whole -- not a count a script supplies',
    'PhosphorHttpLib.pas:TlsIO':
        'a TLS read or write under a deadline: the loop leaves the moment the '
        'deadline passes and each select() waits only what is left of it -- the '
        'loop IS the bound (25_http_broken measures it at the deadline)',
    'phosphorhttptest.lpr:TV6Server.Serve':
        'the TEST server reading one request the package\'s own test sent, of a '
        'few hundred bytes; no script reaches it',

    # ---- guarded by the registered function that calls them -------------------
    'PhosphorZipLib.pas:TZipWriter.Create':
        'constructs an empty TZipper and binds a path; nothing is read or written yet',
    # TZipReader.Create WAS HERE, exempted on the claim that "every path that then
    # EXPANDS an entry (ReadEntry, unzip_extract) asks ArchiveFitsBudget first".
    # Two of the three extractors did not (d47), and the one that did priced the
    # archive's own claim (d46). It now builds a TMeteredUnZipper, which charges
    # what it writes, so it is no longer a native this gate lists -- and the rule
    # UNMETERED below is what keeps an expanding door from using any other kind.
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
    'PhosphorSqliteLib.pas:TSqliteDb.CloseConn':
        'finalizes statements the PACKAGE leaked on this connection (a script\'s '
        'are children, freed before it), so no script count reaches it -- and a '
        'close cut short by the budget would leave the file held open',

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
    'PhosphorSysLib.pas:Utf8SeqAt':
        'the continuation bytes of ONE UTF-8 sequence: need is 1, 2 or 3, set by '
        'the lead byte, never by a count',
    'PhosphorSysLib.pas:Utf8Scrub':
        'shrinks the answer to the bytes written, at most 3 * Length(S) -- the size '
        'the routine allocated from the string already in memory two lines up',
    'PhosphorSysLib.pas:AskWidePath':
        'the size kernel32 says an OS path needs (GetTempPathW, '
        'GetWindowsDirectoryW, for HostTempDir): a path, which Windows caps at '
        '32767 characters, never a number from the script',
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
    'phosphor.lpr:ReadArgv':
        'n is the number of words the OS split this process\'s own command line '
        'into (CommandLineToArgvW) -- bounded by the command line, at most 32767 '
        'characters on Windows -- read once before any script exists',
    'PhosphorCryptoLib.pas:Sha256Update':
        'N is the length of a buffer already in memory -- a string being hashed, a '
        '64-byte pad or a 32-byte digest -- so the loop is linear in bytes that '
        'exist; the PBKDF2 loop that calls it a count-driven number of times '
        'charges the budget itself',
    'PhosphorCryptoLib.pas:ParseRecord':
        'the needle is the one-character field separator and the loop stops at '
        'three fields: one linear scan of a record already in memory',

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

    # ---- round 7: the linear builders the RAG analysis was rewritten onto ----
    'PhosphorRagLib.pas:SbAdd':
        'doubles the array when it is full; B.N is the count already written, '
        'so n adds copy at most 2n slots in all -- amortised O(1) per item',
    'PhosphorRagLib.pas:SbDone':
        'trims the array to B.N, the count already written',
    'PhosphorRagLib.pas:SetSlot':
        'a linear probe of a table SetAdd keeps at most half full, so it ends at '
        'an empty slot; the expected probe is O(1)',
    'PhosphorRagLib.pas:SetAdd':
        'doubles the table when it would pass half full and re-places what it '
        'holds: amortised O(1) per word added',
    'PhosphorRagLib.pas:TPhosphorRag.FunctionTotal':
        'an INTEGER sum, one addition per document -- the append rule reads '
        '`Result := Result + ...` as a string append',
    'PhosphorRagLib.pas:IndexNames':
        'the same integer sum, over the documents\' tag counts',
    'PhosphorRagLib.pas:TPhosphorRag.TagTotal':
        'the same integer sum, over the documents\' tag counts (round 8: what '
        'rag_tags$ is priced by)',

    # ---- A WAIT ON THE USER, which is what a key read IS ---------------------
    # Written down rather than hidden, like the sqlite note above. KbdRead's loop
    # consumes one console input event per iteration and only goes round again for
    # an event that is not a key (key-up, mouse, focus), so the LOOP is bounded by
    # input. What is unbounded is the blocking read inside it -- and a host that
    # loads the CRT package has asked for a console that waits for a person. There
    # is no count here for a budget to bound; a key read is not "running long".
    'PhosphorCrtLib.pas:HeadKey':
        'each turn of the loop consumes one console event or waits for one; the '
        'wait is a wait on the user, which is the whole purpose of a key read, '
        'and a call that must not block waits at most PAIR_WAIT_MS',

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
    'phosphor.lpr:TDebugProto.RefuseQueued':
        'answers the frames the EDITOR already sent behind a `disconnect`, once '
        'each, and stops when the inbox is empty -- the loop is as long as what '
        'the reader has queued, each line capped at DBG_MAX_FRAME, and no script '
        'can add to it',
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
    'phosphor.lpr:Utf8SeqLen':
        '`need` is 1, 2 or 3 -- the continuation bytes of ONE UTF-8 sequence, set '
        'by the lead byte two lines above -- never a count a script supplies',
    'phosphor.lpr:LoadCheckNames':
        'reads the file `compile --check --names` was GIVEN ON THE COMMAND LINE, '
        'one Pos per line -- a command line, not a script, like ParseBreakList',
    'phosphor.lpr:ParseBreakList':
        'splits the --break argument, which is a command line and not a script; '
        'and it refuses past 256 lines rather than growing',
    'phosphor.lpr:DebugFile':
        'copies the armed set ParseBreakList filled, which that function caps at '
        '256 -- a command line, not a script',
    'phosphor.lpr:BreakpointReport':
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
    'phosphor.lpr:ReadTerminalLine':
        'ReadLine on a Unix terminal: ONE line, a byte per read, as long as what '
        'a person typed at the terminal -- the console sizes it, never the script',
    'phosphor.lpr:TConsoleHost.ReadLine':
        'reads ONE console line into a buffer of the constant CONSOLE_READ_UNITS '
        '(32768 WideChars); the other SetLengths are sized by what ReadConsoleW '
        'reported into it, and the Pos looks for a '
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
    """Pascal comments and string literals out, in ONE left-to-right pass.

    Whichever opens first -- a string, a '//', a '{' or a '(*' -- decides how far
    that stretch runs, which is how the compiler reads it. This used to be four
    regex substitutions run in a fixed order, '//' first, so a '//' INSIDE a
    string literal -- 'http://' -- was taken for a comment and ate the closing
    quote, and every literal after it paired with the wrong partner: on
    2026-10-06 that hid PhosphorHttpLib's LocateCABundle from this gate entirely
    (ledger n26). check-boundary.py found the same ordering defect in the boundary
    checks; this is the same class, in a gate that had not been asked. Line
    breaks inside a comment are kept, so a routine header stays on its line."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    break
                if text[j] == '\n':          # a Pascal literal never spans a line
                    break
                j += 1
            out.append("''")
            i = j + 1 if j < n and text[j] == "'" else j
            continue
        if c == '/' and text.startswith('//', i):
            j = text.find('\n', i)
            i = n if j < 0 else j
            continue
        if c == '{':
            j = text.find('}', i + 1)
            end = n if j < 0 else j + 1
            out.append('\n' * text.count('\n', i, end) or ' ')
            i = end
            continue
        if c == '(' and text.startswith('(*', i):
            j = text.find('*)', i + 2)
            end = n if j < 0 else j + 2
            out.append('\n' * text.count('\n', i, end) or ' ')
            i = end
            continue
        out.append(c)
        i += 1
    return ''.join(out)


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
        # An `out` parameter carries nothing IN: it is a result, and a loop that
        # counts it up to a bound is judged by the bound (ReadColorLiteral's
        # AStop, round 8). Whatever is assigned to it is still read by flow().
        if re.match(r'\s*out\b', part, re.I):
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


LENGTH_OF = re.compile(r'\bLength\s*\(\s*([A-Za-z_][\w.\[\]]*)\s*\)', re.I)


def nested_searches(body):
    """A HAND-ROLLED SEARCH: a for loop bounded by the length of one thing, inside
    a for loop bounded by the length of ANOTHER (ledger d45).

    Each bound alone is `Length(...)`, which DERIVED rightly calls bounded -- and
    that is how IndexOfFrom in PhosphorBufferLib read as two linear loops while
    doing Length(hay) * Length(needle) comparisons, the same product SEARCHES
    names for Pos. buffer_indexof's three-argument form reached it without asking
    the budget, and nothing here could say so. A bound held in a local is read
    through the assignment that set it (`last := Length(AHay) - ...`)."""
    assigned = {}
    for m in ASSIGN.finditer(body):
        assigned.setdefault(m.group(1).lower(), m.group(2))

    def lengths(expr):
        seen = set(x.lower() for x in LENGTH_OF.findall(expr))
        for nm in NAMES.findall(expr):
            if nm.lower() in assigned:
                seen |= set(x.lower() for x in LENGTH_OF.findall(assigned[nm.lower()]))
        return seen

    loops = []
    for m in FORLOOP.finditer(body):
        limit = m.group(3) if m.group(2).lower() == 'to' else m.group(1)
        d = DOWORD.search(body, m.start())
        if d is None:
            continue
        rest = body[d.end():]
        stripped = rest.lstrip()
        if stripped[:5].lower() == 'begin':
            at = d.end() + (len(rest) - len(stripped))
            span = (at, block_end(body, at))
        else:
            semi = body.find(';', d.end())
            span = (d.end(), semi if semi >= 0 else len(body))
        loops.append((m.start(), span, lengths(limit)))
    hits = []
    for _, (lo, hi), outer in loops:
        for start, _, inner in loops:
            if lo <= start < hi and outer and inner and \
               any(a != b for a in outer for b in inner):
                hits.append('for .. Length(%s) inside for .. Length(%s)'
                            % ('/'.join(sorted(inner)), '/'.join(sorted(outer))))
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
    hits.extend(nested_searches(body))
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


#  --- an unzipper that EXPANDS must be the metered one (ledger d46, d47) --------
# The rule above asks whether a routine REACHES a consultation; it cannot ask
# whether that consultation prices the work. Both zip defects lived in that gap:
# three extractors priced an archive's own size claim or asked nothing, and two
# of them reached the unzipper through a FIELD, so no routine of theirs named a
# native at all. PhosphorZipLib's TMeteredUnZipper charges every byte it writes
# and stops when the budget does, so the question becomes mechanical: every
# name declared as a PLAIN TUnZipper -- a local, or a field -- must never be
# asked to extract. A plain one may still Examine; that reads the directory.
PLAIN_UNZIPPER = re.compile(r'\b([A-Za-z_]\w*)\s*:\s*TUnZipper\s*;', re.I)
EXPANDS = r'\bUnZip(?:AllFiles|Files|File)\b'
CLASS_UNZIP = re.compile(r'\bTUnZipper\s*\.\s*Unzip\b', re.I)
# A class body: from `= class` to the `end;` that closes it. Method DECLARATIONS
# carry no `end`, so the first one is the class's own.
CLASS_BLOCK = re.compile(r'=\s*class\b(.*?)\bend\s*;', re.I | re.S)


def unmetered(dirs):
    """Routines (or fields) that expand an archive through a plain TUnZipper."""
    bad = []
    for path in sources(dirs):
        base = os.path.basename(path)
        with open(path, encoding='utf-8') as fh:
            text = strip_comments(fh.read())
        routines = list(routines_of(text))
        # A FIELD is declared in a class body and can be used from any routine --
        # r.UZ.UnZipAllFiles is exactly that shape. Found by its class block, NOT
        # by "the text before the first routine": a unit's interface declares
        # routines too, so that span ends before the implementation's types, and
        # the first draft of this rule missed the very field d47 was about.
        for blk in CLASS_BLOCK.findall(text):
            for fld in PLAIN_UNZIPPER.findall(blk):
                if re.search(r'\b' + re.escape(fld) + r'\s*\.\s*' + EXPANDS, text, re.I):
                    bad.append('%s:field %s' % (base, fld))
        for name, body in routines:
            # A routine's span runs to the next routine, so it can swallow a type
            # section; its class fields were judged above, not as locals here.
            body = CLASS_BLOCK.sub('', body)
            for loc in PLAIN_UNZIPPER.findall(body):
                if re.search(r'\b' + re.escape(loc) + r'\s*\.\s*' + EXPANDS, body, re.I):
                    bad.append('%s:%s' % (base, name))
            # The class shortcuts build a plain unzipper of their own and expand.
            if CLASS_UNZIP.search(body):
                bad.append('%s:%s' % (base, name))
    return sorted(set(bad))


#  --- THE LINEAR PASS (adversarial round 7, 2026-10-11) -------------------------
# The note above TAINT said "a STRING argument is deliberately not tainted: it is
# already in memory, so its Length bounds a loop exactly as any other container's
# does". That is true of ONE CALL and false of a program: a length bounds what a
# call costs, not how many times the call is made, and one opCall is one VM
# instruction however long its argument is. The VM reads its clock every 4096
# instructions, so 200 calls of ucase$ over one 50 MB string -- a string the
# budget let string$ build -- ran 18344 ms under TimeoutMs 2000 and reported
# success; environ$ 72891 ms; strings_values$ over a 2-million-line list
# 12515 ms; ONE funcexists? on a 50 MB name 38906 ms. About fifty registered
# functions had that shape and this gate was green on all of them, because the
# one rule that could have seen them had been switched off by that sentence.
#
# So this is a SECOND RULE, beside the first and not instead of it (the first
# keeps its semantics, its ALLOWED and its counts). It asks one question of every
# REGISTERED function -- a name some Reg.Add/AddHost hands to the VM -- and of
# everything it calls in these directories:
#
#     does it do work LINEAR (or worse) in the size of a script-supplied string,
#     array, list, dictionary, tree or buffer -- a loop whose bound reads one, an
#     allocation sized by one, or a call to a routine known to walk one?
#
# If so, the registered function must charge the budget IN ITS OWN BODY (or
# through a helper that does nothing but ask -- see "consultation by proxy" in
# linear_scan), or every walker on the way must charge for its own walk, or the
# walker must be listed in LINEAR_ALLOWED with the reason one call of it is O(1)
# whatever the script holds. A helper that asks for some OTHER work does not
# answer for the walk beside it: that is how lfill$ hid behind RunOf. "The string
# was paid for when it was built" is NOT such a reason
# -- it was the reason for all fifty -- because the same string can be handed in
# a loop.
#
# WHAT IS SCRIPT-SUPPLIED, as a lint can see it: a routine's parameters of a
# string, value, array or object type (the registered function's `A` is one); a
# local of a class a script holds through a handle (derived below from the
# HandleObj casts, not listed); inside a METHOD of such a class, its fields; and
# anything assigned from an expression that mentions one of those -- which is how
# `s := A[0].Str`, `n := Length(s)` and `L := TPhosphorStringList(HandleObj(..))`
# all become tainted. A loop over the ARITY -- `for i := 0 to High(A)` -- is not:
# the arity is fixed by the call site, which the VM paid for one instruction per
# argument.
#
# Approximate on purpose, the same way loop_spans is: an over-reach names a routine
# that then gets a written reason; an under-reach is how the fifty went unseen.

#: the linear pass reads the two directories that REGISTER functions. host/console
#: registers none: its seams are judged by the first rule above.
LINEAR_DIRS = [os.path.join(ROOT, 'engine', 'libs'), os.path.join(ROOT, 'host', 'packages')]

LIN_PARAMTYPE = re.compile(r'\b(String|AnsiString|RawByteString|UTF8String|UnicodeString|'
                           r'WideString|TValue|TBytes|TStringDynArray|TInt64DynArray|'
                           r'TStrings|TStringList|TJSON\w+|TPhosphor\w+|TKVBag|TSqlite\w+|'
                           r'TZip\w+)\b|\barray\s+of\b', re.I)
LIN_ARRAYPARAM = re.compile(r'\barray\s+of\s+TValue\b', re.I)
# A var section: from the header to the first `begin`, `name, name: Type;`.
LIN_VARDECL = re.compile(r'\b([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*:\s*([A-Za-z_][\w.]*)\s*;')
# The class a handle is cast to. `HandleObj(x) is TFoo` and `TFoo(HandleObj(x))`.
LIN_HANDLECLASS = [re.compile(r'HandleObj\s*\([^;]*?\)\s*\)?\s*is\s+(T[A-Za-z0-9_]+)'),
                   re.compile(r'\b(T[A-Za-z0-9_]+)\s*\(\s*HandleObj\b')]
LIN_STRSRC = re.compile(r'\.\s*Str\b|\bHandleObj\s*\(|\bArgStr\s*\(', re.I)
LIN_REGISTER = re.compile(r'\b(?:Add|AddHost)\s*\([^;]*?,\s*@\s*([A-Za-z_]\w*)\s*\)')
# The same registration read off the RAW text, with its signature literal:
# 'name:sig' -- or a computed name, whose signature this cannot read.
LIN_REGSIG = re.compile(r"\b(?:Add|AddHost)\s*\(\s*(?:'[^':]*:([^']*)'|[^,;]*?)\s*,\s*@\s*"
                        r"([A-Za-z_]\w*)\s*\)")
#: the signature codes that carry a NUMBER (or a bool): an argument the
#: registry hands over as one is a value of fixed size, whatever the script.
LIN_NUMCODES = set('n%?')


def lin_numeric_args(raw_texts):
    """{registered function: set of argument positions that EVERY one of its
    registered signatures types as a number}. A function registered under a
    name this cannot read gets the empty set: nothing is assumed."""
    sigs = {}
    for text in raw_texts:
        for m in LIN_REGSIG.finditer(text):
            sigs.setdefault(m.group(2), []).append(m.group(1))
    out = {}
    for fn, ss in sigs.items():
        if any(s is None for s in ss):
            out[fn] = set()
            continue
        pos = set(range(max(len(s) for s in ss)))
        for s in ss:
            for k in list(pos):
                if k < len(s) and s[k] not in LIN_NUMCODES:
                    pos.discard(k)
        out[fn] = pos
    return out


def lin_unnumber(body, positions):
    """The body with every `A[k]`/`Args[k]` whose k is a NUMBER argument
    replaced by a literal of the same length -- positions are kept, because the
    coverage rule reads them. `ArgI32(A[1])` is a count and stays tainted for
    the first rule; for THIS rule a number is not a pass over anything."""
    if not positions:
        return body

    def sub(m):
        if int(m.group(2)) in positions:
            return '0'.ljust(len(m.group(0)))
        return m.group(0)
    return re.sub(r'\b(A|Args)\s*\[\s*(\d+)\s*\](?!\s*\.\s*Str)', sub, body)
# Routines OUTSIDE these directories, or in the RTL, whose work is linear in an
# argument. A call with a tainted argument is a linear pass. The value names which
# argument carries the size: None = any argument, or the 0-based index of it.
LINEAR_CALLS = {
    # RTL: case, trim, compare, path splitting, number parsing, environment.
    'LowerCase': None, 'UpperCase': None, 'AnsiLowerCase': None,
    'AnsiUpperCase': None, 'Trim': None, 'TrimLeft': None, 'TrimRight': None,
    'CompareStr': None, 'CompareText': None, 'SameText': None, 'SameStr': None,
    'AnsiCompareStr': None, 'AnsiCompareText': None, 'AnsiSameText': None,
    'AnsiSameStr': None,
    'ExtractFileName': None, 'ExtractFileExt': None, 'ExtractFilePath': None,
    'ExtractFileDir': None, 'ExtractFileDrive': None, 'ChangeFileExt': None,
    'ExpandFileName': None, 'IncludeTrailingPathDelimiter': None,
    'ExcludeTrailingPathDelimiter': None, 'GetEnvironmentVariable': None,
    'StrToFloat': None, 'TryStrToFloat': None, 'StrToInt': None,
    'StrToInt64': None, 'TryStrToInt': None, 'TryStrToInt64': None,
    'StrToIntDef': None, 'StrToInt64Def': None, 'StrToFloatDef': None,
    'UTF8Decode': None, 'UTF8Encode': None, 'UTF8ToString': None,
    'ReverseString': None, 'AdjustLineBreaks': None, 'QuotedStr': None,
    'AnsiQuotedStr': None, 'UniqueString': None,
    # engine/*.pas, which this gate does not scan (see SCAN_DIRS).
    'Utf8Len': None, 'Utf8Left': None, 'Utf8Right': None, 'Utf8Advance': 2,
    'Utf8SuffixStart': None, 'Utf8Starts': None, 'KnowsName': None,
    'HasName': None, 'ReadNumberText': None, 'TrimNumberSpace': None,
    # fcl-json: a deep copy, and TJSONObject's own member search, which is a
    # linear scan of the object's members (fpjson.pp, IndexOfName).
    'Clone': None, 'IndexOfName': None,
    # sized moves: the count is the argument named.
    'Move': 2, 'FillChar': 1, 'CompareByte': 2, 'CompareMem': 2, 'SetString': 2,
    # ROUND EIGHT: the searches and rewrites are linear in their haystack too.
    # The first rule names them as PRODUCTS (SEARCHES); this rule, which asks
    # about a pass over what the script holds, did not name them at all.
    'Pos': None, 'PosEx': None, 'AnsiPos': None, 'StringReplace': None,
    'ContainsText': None, 'ContainsStr': None, 'LastDelimiter': None,
    # A value spelled as text: a string value is copied whole.
    'ValToStr': None,
    # A stream written or read by a count: zip_addstr's copy of its content.
    'WriteBuffer': 1, 'ReadBuffer': 1,
}
LIN_CALL = re.compile(r'\b(' + '|'.join(sorted(LINEAR_CALLS, key=len, reverse=True)) +
                      r')\s*\(')
LIN_COPY = re.compile(r'\bCopy\s*\(', re.I)

# ROUND EIGHT: TWO SHAPES THE LINEAR PASS COULD NOT SEE, each a hole it reported
# as "0 holes".
#
# A METHOD THAT SHIFTS A CONTAINER the script holds. json_removeat@ is
# `a.Delete(z)`: TFPList.Delete moves every pointer after z, and TFPHashList's
# rehashes every name after it (fcl-base contnrs.pp, read). 50000 removals from
# the front of a million-element array ran 22219 ms under MaxSteps 1000000 and
# reported success; nothing in LINEAR_CALLS could name it, because the work is in
# the RECEIVER, not in an argument. A call of one of these on a tainted receiver
# is a linear pass. (Our own classes' methods of the same names are judged
# through the call graph, by what they do.)
LIN_METHODS = ('Delete', 'Insert', 'Remove', 'Extract', 'IndexOf', 'Sort',
               'CustomSort', 'AddStrings', 'Assign')
LIN_METHOD = re.compile(r'(\b[A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)?\.\s*(' +
                        '|'.join(LIN_METHODS) + r')\b')
# The RTL's own string Delete/Insert, called bare: they move the tail of the
# string. The value is the argument that is the string.
LIN_SHIFT = {'Delete': 0, 'Insert': 1}
LIN_SHIFT_CALL = re.compile(r'(?<![.\w])(Delete|Insert)\s*\(')
# A CONCATENATION OF A SCRIPT STRING. path_combine$ is `A + PathDelim + B`: a
# fresh copy of both arguments, no loop, no Copy, no call -- so a body made of
# one concatenation was invisible, and 2000 calls on a 100 MB string ran 19641 ms
# past a 2000 ms ceiling. A `+` with an operand that is a tainted STRING (a name
# declared of a string type, an element of a string array, or an argument's
# .Str) is a copy of that operand.
LIN_STRTYPE = re.compile(r'^\s*(String|AnsiString|RawByteString|UTF8String|UnicodeString|'
                         r'WideString|TJSONStringType)\s*$', re.I)
LIN_STRARRAY = re.compile(r'^\s*(array\s+of\s+(String|AnsiString|RawByteString)|'
                          r'TStringDynArray|TStrings|TStringList)\s*$', re.I)
LIN_OPND_L = re.compile(r'([A-Za-z_]\w*)\s*(\[[^\[\]]*\])?\s*(\.\s*Str)?\s*$')
LIN_OPND_R = re.compile(r'^\s*([A-Za-z_]\w*)\s*(\[[^\[\]]*\])?\s*(\.\s*Str\b)?')
# What COVERS a construct: a charge. BudgetMeterEnd settles what MeterAdd
# accrued and prices nothing of its own, so it covers nothing.
LIN_COVER = re.compile(r'\bBudget(Allows|Append|Charge|Sleep|Linear\w*|MeterAdd|'
                       r'SearchCost)\b')

# THE WALKERS THAT ARE O(1) PER CALL, each with the reason. Keyed like ALLOWED,
# "<file>:<routine>". A routine listed here is treated as NOT linear, so its
# callers do not inherit a pass through it. Every reason must say why one call
# costs a constant whatever the script holds -- not that the input was paid for.
LINEAR_ALLOWED = {
    # ---- bounded by the LANGUAGE ---------------------------------------------
    'PhosphorArrayLib.pas:TPhosphorArray.FlatIndex':
        'one step per DIMENSION, and DoDim takes one dimension per argument of '
        'dim@, whose registered signatures stop at three (dim@:nnn): at most '
        'three iterations whatever the array holds',
    'PhosphorArrayLib.pas:TPhosphorArray.TotalSize':
        'the same: a product over at most three dimensions',
    'PhosphorBufferLib.pas:ReadRaw':
        'reads AW bytes, and every caller has passed AW through CheckWidth '
        '(1, 2, 4 or 8) or hands it a literal 4 or 8: at most eight iterations',
    'PhosphorBufferLib.pas:WriteRaw':
        'writes AW bytes, AW checked by CheckWidth or a literal 4 or 8, as '
        'ReadRaw: at most eight iterations',
    'PhosphorBufferLib.pas:DoSetInt':
        'its one linear-looking construct is ValToStr(A[3]) in a refusal, and '
        'every signature buffer_setint is registered under types A[3] a NUMBER '
        '(n or %), which ValToStr spells in at most 24 bytes',
    'PhosphorBufferLib.pas:SetIntRefusal':
        'AWhat is IntToStr of a number or DoSetInt\'s ValToStr of a number: at '
        'most 24 bytes either way',
    'PhosphorZipLib.pas:CompareNameBytes':
        'compares two DIRECTORY-ENTRY names, the sort comparator of '
        'zip_compress\'s walk, which charges a step per entry: no filesystem '
        'this runs on allows a name component past 255 bytes',
    'PhosphorRagLib.pas:TPhosphorRag.FunctionTotal':
        'an integer sum, one addition (about a nanosecond) per indexed '
        'document; every document was charged a step (2 us) and its bytes when '
        'the rebuild read it, and each caller prices work per function that '
        'dwarfs the sum',
    'PhosphorRagLib.pas:TPhosphorRag.TagTotal':
        'the same integer sum, over the documents\' tag counts',
    'PhosphorCryptoLib.pas:ToHex':
        'hex of a DIGEST or a DERIVED KEY, never of a script string: its callers '
        'hand it 16, 20 or 32 digest bytes, or a pbkdf2 key that CountArg caps '
        'at MaxDerivedBytes (1024)',
    'PhosphorDateTimeLib.pas:Cited':
        'quotes a date text in an error message only when it is at most 40 '
        'bytes, and exits on its first line otherwise: at most 40 iterations',
    # ---- AMORTISED: each item pays for its own copy once ---------------------
    'PhosphorStrListLib.pas:TPhosphorStringList.Add':
        'doubles the slot array when it is full, so n adds copy at most 2n slots '
        'in all: O(1) per item, amortised, and the item itself is a reference',
    'PhosphorDictLib.pas:TPhosphorDict.SetVal':
        'its lookup is IndexOf, which is metered; what is left is the doubling of '
        'the three arrays and the table when full -- amortised O(1) per entry, '
        'each entry copied once per doubling it survives',
    'PhosphorDictLib.pas:TPhosphorDict.Create':
        'Reindex over FCount = 0: the eight-slot empty table, whatever comes later',
    'PhosphorDictLib.pas:TPhosphorDict.Clear':
        'sets FCount to 0 BEFORE it reindexes, so the table it rebuilds is the '
        'eight-slot empty one; the entries are released by reference count, each '
        'once, which their adds already paid for',
    'PhosphorJsonLib.pas:RegisterNode':
        'the borrowed-view table doubles when full and is rebuilt only when it '
        'holds twice the live handles plus 1024 -- amortised O(1) per handle, '
        'each registered by one json_get@-style call',
    'PhosphorJsonLib.pas:AddDocView':
        'compacts a document\'s view list only when it is full and doubles it '
        'when it is still half full: amortised O(1) per view',
    'PhosphorJsonLib.pas:t_json_free':
        'frees each view of the document once; every view id was made by one '
        'call (one instruction) and is visited once, when its document goes',
    'PhosphorJsonLib.pas:InvalidateBorrowed':
        'walks the subtree that is being REMOVED, and a node is removed (and '
        'freed) once; every way a node is made -- parse, clone, set, push -- is '
        'priced per node when it is made',
    'PhosphorJsonLib.pas:GraftTooDeep':
        'walks a node its caller has just MADE: a scalar, or a clone PricedClone '
        'charged at 60 ns a node -- an order of magnitude more than this walk '
        'costs a node',
    'PhosphorJsonLib.pas:MemberIndex':
        'refuses a name longer than JSON_MAX_NAME (255 bytes) on its first line, '
        'so the hashed lookup it makes is of at most 255 bytes',
    # ---- sqlite: bounded by what sqlite3 itself allows ----------------------
    'PhosphorSqliteLib.pas:FindCol':
        'at most SQLITE_MAX_COLUMN columns, each compared by SameText, which '
        'stops at the shorter of the two names',
    'PhosphorSqliteLib.pas:SqlTarget':
        'compares the first five bytes of the name; the path itself is priced '
        'by its callers (sqlite_open@ and sqlite_backup ask BudgetLinearOk '
        'first), and sqlite_open@ with no argument passes the constant '
        "':memory:', which never reaches it",
    'PhosphorSqliteLib.pas:BindNode':
        'reads the text of a JSON NUMBER held as a QWord -- at most twenty '
        'digits -- never a string member',
    # ---- NOT SCRIPT DATA: the OS or the host supplied it -------------------
    'PhosphorSysLib.pas:HostTempDir':
        'the size GetTempPathW (or the platform) reports for the temp path: an OS '
        'path of at most 32767 characters, not a script string',
    'PhosphorSysLib.pas:t_paramstr':
        'scrubs ParamStr(i): a word of this PROCESS\'S command line, which the '
        'host was started with (at most 32767 characters on Windows); the '
        'script chooses only the index',
}

#: Files the linear pass does not hold to the rule, with the reason. Only a TEST
#: host may be here: its registered stand-ins exist for one runner's programs.
LINEAR_TEST_HOSTS = {
    'phosphorhttptest.lpr':
        'the HTTP package\'s TEST host (tests/packages): its stand-ins resolve '
        'and rewrite URLs the package\'s own test programs hand it, under no '
        'ceilings, and no shipped binary links it',
}


def lin_split_args(text):
    """Top-level comma split of a call's argument text."""
    out, depth, cur = [], 0, []
    for ch in text:
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(''.join(cur))
            cur = []
            continue
        cur.append(ch)
    out.append(''.join(cur))
    return out


def lin_header(body):
    """(params, arity-arrays): tainted parameter names, and the `array of TValue`
    ones whose High/Length is an arity."""
    m = PARAMLIST.match(body)
    tainted, arity = set(), set()
    if not m:
        return tainted, arity
    for part in m.group(1).split(';'):
        if ':' not in part:
            continue
        names, typ = part.split(':', 1)
        if not LIN_PARAMTYPE.search(typ):
            continue
        nms = NAMES.findall(DECOR.sub(' ', names))
        tainted |= set(nms)
        if LIN_ARRAYPARAM.search(typ):
            arity |= set(nms)
    return tainted, arity


def lin_params(body):
    """[(name, type, is_out)] of a routine's parameters, in order."""
    m = PARAMLIST.match(body)
    out = []
    if not m:
        return out
    for part in m.group(1).split(';'):
        names, typ = (part.split(':', 1) + [''])[:2]
        is_out = bool(re.search(r'\bout\b', names, re.I))
        for nm in NAMES.findall(DECOR.sub(' ', names)):
            out.append((nm, typ.strip(), is_out))
    return out


#: Calls whose RESULT is a short string whatever their argument: a number
#: spelled out. An argument built from one carries no script-supplied size,
#: however many tainted names the number was computed from.
LIN_BOUNDED = re.compile(r'\b(IntToStr|Int64ToStr|UIntToStr|FloatToStr|NumToInv|BoolToStr|'
                         r'HexStr|IntToHex|Ord|Chr)\s*\(')


def lin_neutral(expr):
    """expr with every LIN_BOUNDED call replaced by a literal."""
    while True:
        m = LIN_BOUNDED.search(expr)
        if not m:
            return expr
        inner = balanced_arg(expr, m.end() - 1)
        expr = expr[:m.start()] + ' 0 ' + expr[m.end() + len(inner) + 1:]


def lin_taint(name, body, containers, fields, seed=None):
    """The names in this routine that carry script-supplied size.

    seed: None for a routine whose callers are not all in view (a registered
    function, a callback, a routine nothing here calls) -- every parameter of a
    data type is tainted, as before. Otherwise the parameters some caller in
    view passes script-supplied data in (linear_scan propagates it): AFn in
    `MakeError(peRuntime, AFn + ': not a buffer')` is the caller's literal
    function name, at every call site, and is not a pass over anything the
    script holds."""
    tainted, arity = lin_header(body)
    if seed is not None:
        tainted = set(seed)
    hdr_end = body.find('begin')
    decls = body[:hdr_end] if hdr_end >= 0 else ''
    for m in LIN_VARDECL.finditer(decls):
        if m.group(2) in containers:
            tainted |= set(NAMES.findall(m.group(1)))
    if '.' in name:
        cls = name.split('.')[0]
        if cls in containers:
            tainted |= set(fields.get(cls, {}))
            tainted.add('Self')
    assigns = [(m.group(1), m.group(2)) for m in ASSIGN.finditer(body)]
    changed = True
    while changed:
        changed = False
        for nm, expr in assigns:
            if nm in tainted:
                continue
            if LIN_STRSRC.search(expr) or (set(NAMES.findall(expr)) & tainted):
                tainted.add(nm)
                changed = True
    return tainted, arity


def lin_reads(expr, tainted, arity):
    """Does this expression read the size of something script-supplied?"""
    for a in arity:
        expr = re.sub(r'\b(?:High|Length)\s*\(\s*' + re.escape(a) + r'\s*\)', ' 0 ', expr)
    # SizeOf is a constant of the TYPE, whatever the variable holds.
    expr = re.sub(r'\bSizeOf\s*\([^()]*\)', ' 0 ', expr, flags=re.I)
    names = set(NAMES.findall(expr))
    return bool(names & tainted) or bool(LIN_STRSRC.search(expr))


def lin_types(name, body, ftypes):
    """Declared type of every name this routine can see: its parameters, its
    locals, its own Result, and -- in a method -- its class's fields."""
    types = {}
    if '.' in name:
        types.update(ftypes.get(name.split('.')[0], {}))
    m = PARAMLIST.match(body)
    if m:
        for part in m.group(1).split(';'):
            if ':' in part:
                nms, typ = part.split(':', 1)
                for nm in NAMES.findall(DECOR.sub(' ', nms)):
                    types[nm] = typ.strip()
    r = re.match(r'^function\b[^;]*?\)\s*:\s*([A-Za-z_][\w.]*)\s*;', body, re.I | re.S) or \
        re.match(r'^function\s+[\w.]+\s*:\s*([A-Za-z_][\w.]*)\s*;', body, re.I)
    if r:
        types['Result'] = r.group(1)
    hdr_end = body.find('begin')
    for d in LIN_VARDECL.finditer(body[:hdr_end] if hdr_end >= 0 else ''):
        for nm in NAMES.findall(DECOR.sub(' ', d.group(1))):
            types[nm] = d.group(2)
    for d in re.finditer(r'\b([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*:\s*(array\s+of\s+\w+)\s*;',
                         body[:hdr_end] if hdr_end >= 0 else '', re.I):
        for nm in NAMES.findall(d.group(1)):
            types[nm] = d.group(2)
    return types


def lin_string_operand(nm, index, dotstr, tainted, types):
    """Is this operand of a `+` a script-supplied STRING?"""
    if dotstr:
        return nm in tainted or nm in ('A', 'Args')
    if nm not in tainted:
        return False
    typ = types.get(nm, '')
    if index:
        return bool(LIN_STRARRAY.match(typ))
    return bool(LIN_STRTYPE.match(typ))


def lin_concats(body, tainted, types):
    """(pos, label) of every `+` with a script-supplied string operand."""
    out = []
    for m in re.finditer(r'\+', body):
        k = m.start()
        left = LIN_OPND_L.search(body[max(0, k - 160):k])
        right = LIN_OPND_R.match(body[k + 1:k + 161])
        for op in (left, right):
            if op and lin_string_operand(op.group(1), op.group(2), op.group(3),
                                         tainted, types):
                out.append((k, '%s + ..' % op.group(1)))
                break
    return out


def lin_direct(name, body, containers, fields, ours=frozenset(), seed=None):
    """Linear constructs written in this routine, as short labels."""
    return sorted(set(lab for _, lab in lin_constructs(name, body, containers, fields,
                                                        ours, seed)))


def lin_loop_spans(body):
    """{position of a loop's keyword: (start, end) of its body}."""
    spans = {}
    for m in LOOPSTART.finditer(body):
        if m.group(1).lower() == 'repeat':
            u = UNTILWORD.search(body, m.end())
            spans[m.start()] = (m.end(), u.start() if u else len(body))
            continue
        d = DOWORD.search(body, m.end())
        if d is None:
            continue
        rest = body[d.end():]
        stripped = rest.lstrip()
        if stripped[:5].lower() == 'begin':
            open_at = d.end() + (len(rest) - len(stripped))
            spans[m.start()] = (open_at, block_end(body, open_at))
        else:
            semi = body.find(';', d.end())
            spans[m.start()] = (d.end(), semi if semi >= 0 else len(body))
    return spans


def lin_cover(body, proxies=frozenset()):
    """(upfront, regions): whether this body charges the budget OUTSIDE every
    loop -- a charge that answers for the routine -- and the loop bodies that
    charge INSIDE themselves, each of which answers only for itself.

    THE RULE THE ROUND-7 PASS DID NOT HAVE (round 8). It asked whether a body
    consults the budget ANYWHERE, so MatchGlob -- `n := LowerCase(AName)` over
    the whole name, then a loop that charges per 4096 comparisons -- read as
    consulting, and its up-front case fold was free. With the pattern "x", the
    loop ends at its first comparison and charges nothing, so 2000 calls on a
    100 MB name ran 45859 ms under a 2000 ms ceiling. A charge inside a loop
    prices that loop's iterations; it does not price the pass before it."""
    spans = list(lin_loop_spans(body).values())
    cons = [m.start() for m in LIN_COVER.finditer(body)]
    for p in proxies:
        cons += [m.start() for m in re.finditer(r'\b' + re.escape(p) + r'\b', body)]
    # A charge inside a NESTED routine is made where that routine is CALLED --
    # MatchGlob's Tick sits textually before the main body, outside every
    # loop, and read by position it answered for the whole routine.
    nested = []
    for m in re.finditer(r'\n[ \t]+(?:function|procedure)\s+([A-Za-z_]\w*)', body):
        b = re.search(r'\bbegin\b', body[m.end():])
        if b:
            at = m.end() + b.start()
            nested.append((m.group(1), m.start(), block_end(body, at)))
    if nested:
        moved = []
        for q in cons:
            owner = [n for n in nested if n[1] <= q < n[2]]
            if not owner:
                moved.append(q)
                continue
            nm, lo, hi = owner[0]
            for c in re.finditer(r'\b' + re.escape(nm) + r'\b', body):
                if not any(o[1] <= c.start() < o[2] for o in nested if o[0] == nm):
                    moved.append(c.start())
        cons = moved
    upfront, regions = False, []
    for q in cons:
        inside = [s for s in spans if s[0] <= q < s[1]]
        if not inside:
            upfront = True
        else:
            regions.append(min(inside, key=lambda s: s[1] - s[0]))
    return upfront, regions


def lin_covered(pos, cover):
    upfront, regions = cover
    return upfront or any(lo <= pos < hi for lo, hi in regions)


def lin_constructs(name, body, containers, fields, ours=frozenset(), seed=None):
    """Linear constructs written in this routine, as (position, label). `ours`
    is the set of names this body calls that resolve to a routine in these
    directories: a LINEAR_CALLS name that is one of ours
    (TPhosphorStringList.IndexOfName, not fcl-json's) is judged through the call
    graph instead, by what it does. A LOOP's position is the first character of
    its body, so a charge inside the loop is a charge beside it."""
    tainted, arity = lin_taint(name, body, containers, fields, seed)
    if not tainted:
        return []
    spans = lin_loop_spans(body)

    def at_loop(m):
        sp = spans.get(m.start())
        return sp[0] if sp else m.start()
    hits = []
    for m in FORLOOP.finditer(body):
        limit = m.group(3) if m.group(2).lower() == 'to' else m.group(1)
        if lin_reads(limit, tainted, arity):
            hits.append((at_loop(m), 'for .. %s' % ' '.join(limit.split())[:40]))
    for m in WHILELOOP.finditer(body):
        if lin_reads(m.group(1), tainted, arity):
            hits.append((at_loop(m), 'while %s' % ' '.join(m.group(1).split())[:40]))
    for m in REPEATLOOP.finditer(body):
        if lin_reads(m.group(1), tainted, arity):
            hits.append((at_loop(m), 'repeat .. until %s' % ' '.join(m.group(1).split())[:40]))
    for m in ALLOC.finditer(body):
        args = lin_split_args(balanced_arg(body, m.end() - 1))
        if lin_reads(args[-1], tainted, arity):
            hits.append((m.start(), '%s(.., %s)' % (m.group(1), ' '.join(args[-1].split())[:30])))
    for m in LIN_CALL.finditer(body):
        if m.group(1) in ours:
            continue
        args = lin_split_args(balanced_arg(body, m.end() - 1))
        which = LINEAR_CALLS[m.group(1)]
        look = args if which is None else args[which:which + 1]
        if any(lin_reads(a, tainted, arity) for a in look):
            hits.append((m.start(), '%s(..)' % m.group(1)))
    for m in LIN_SHIFT_CALL.finditer(body):
        args = lin_split_args(balanced_arg(body, m.end() - 1))
        which = LIN_SHIFT[m.group(1)]
        if len(args) > which and lin_reads(args[which], tainted, arity):
            hits.append((m.start(), '%s(..)' % m.group(1)))
    for m in LIN_METHOD.finditer(body):
        if m.group(2) in ours:
            continue
        if m.group(1) in tainted:
            hits.append((m.start(), '%s.%s' % (m.group(1), m.group(2))))
    hits.extend(lin_concats(body, tainted, lin_types(name, body, fields)))
    for m in LIN_COPY.finditer(body):
        args = lin_split_args(balanced_arg(body, m.end() - 1))
        if len(args) == 2:
            size = args[0]        # Copy(s, i): to the end of s
        elif len(args) >= 3:
            size = args[2]
            if LITERAL.match(size):
                continue
            if re.search(r'\b(MaxInt|High)\b', size):
                size = args[0]
        else:
            continue
        if lin_reads(size, tainted, arity):
            hits.append((m.start(), 'Copy(.., %s)' % ' '.join(size.split())[:30]))
    # Nothing in the routine's own header is a construct: `function
    # TPhosphorStringList.IndexOfName(` is a declaration, not a call.
    hm = PARAMLIST.match(body)
    hdr = hm.end() if hm else 0
    return sorted(set(h for h in hits if h[0] >= hdr))


def lin_classes(texts):
    """(containers, fields): the classes a script holds through a handle, derived
    from the casts, and each one's field names."""
    containers = set()
    for text in texts:
        for rx in LIN_HANDLECLASS:
            containers |= set(rx.findall(text))
    fields = {}
    for text in texts:
        for m in re.finditer(r'\b(T[A-Za-z0-9_]+)\s*=\s*class\b(.*?)\bend\s*;', text, re.S):
            if m.group(1) not in containers:
                continue
            fs = {}
            for line in m.group(2).split(';'):
                ln = line.strip()
                if not ln or re.match(r'(?i)(procedure|function|constructor|destructor|'
                                      r'property|class|public|private|protected|'
                                      r'published|strict)\b', ln):
                    ln = re.sub(r'(?is)^(public|private|protected|published|strict)\s+', '', ln)
                    if not ln or re.match(r'(?i)(procedure|function|constructor|destructor|'
                                          r'property|class)\b', ln):
                        continue
                if ':' in ln:
                    nms, typ = ln.split(':', 1)
                    for nm in NAMES.findall(nms):
                        fs[nm] = typ.strip()
            fields[m.group(1)] = fs
    return containers, fields


_LIN_INDEX = {}


def lin_index(routines):
    """(free routines by name, methods by class then name), built once per scan."""
    ident = id(routines)
    if _LIN_INDEX.get('id') != ident:
        free, meth = {}, {}
        for key, short, _ in routines:
            name = key.split(':', 1)[1]
            if '.' in name:
                cls = name.split('.')[0]
                meth.setdefault(cls, {}).setdefault(short, []).append(key)
            else:
                free.setdefault(short, []).append(key)
        _LIN_INDEX.clear()
        _LIN_INDEX.update({'id': ident, 'free': free, 'meth': meth})
    return _LIN_INDEX['free'], _LIN_INDEX['meth']


LIN_MEMBER = re.compile(r'(\b[A-Za-z_]\w*|\))\s*\.\s*([A-Za-z_]\w*)')
#: never resolved through an untyped receiver: every class has one.
LIN_UBIQUITOUS = {'Create', 'Free', 'Destroy'}


def lin_callees(key, body, routines):
    """The routines in these directories this body calls -- resolved by class
    where the source says which class, rather than by bare name: `Create` and
    `IndexOf` are a method of half the classes here, and a name match sent the
    walk of every constructor to every routine that builds anything."""
    free, meth = lin_index(routines)
    name = key.split(':', 1)[1]
    own = name.split('.')[0] if '.' in name else None
    types = {}
    m = PARAMLIST.match(body)
    heads = [m.group(1)] if m else []
    hdr_end = body.find('begin')
    for part in ';'.join(heads).split(';') + [body[:hdr_end] if hdr_end >= 0 else '']:
        for d in LIN_VARDECL.finditer(part + ';'):
            for nm in NAMES.findall(DECOR.sub(' ', d.group(1))):
                types[nm] = d.group(2)
        if ':' in part and part.count(':') == 1:
            nms, typ = part.split(':')
            for nm in NAMES.findall(DECOR.sub(' ', nms)):
                types[nm] = typ.strip()
    out = set()
    members = set()
    for mm in LIN_MEMBER.finditer(body):
        recv, mem = mm.group(1), mm.group(2)
        members.add(mm.start(2))
        cands = []
        if recv in meth:
            cands = meth[recv].get(mem, [])
        elif types.get(recv) in meth:
            cands = meth[types[recv]].get(mem, [])
        elif recv == 'Self' and own in meth:
            cands = meth[own].get(mem, [])
        elif recv not in types and mem not in LIN_UBIQUITOUS:
            for cls in meth:
                cands = cands + meth[cls].get(mem, [])
        out |= set(cands)
    for nm in NAMES.finditer(body):
        if nm.start() in members:
            continue
        word = nm.group(0)
        out |= set(free.get(word, []))
        if own in meth:
            out |= set(meth[own].get(word, []))
    out.discard(key)
    return sorted(out)


#: the last scan's uncovered routines, helpers included, for the report.
LAST_UNCOVERED = {}


def linear_scan(dirs, allowed, test_hosts=None):
    """(holes, consulting-entries, used-exemptions, flagged-walkers).

    holes: registered functions that reach a linear pass and consult nothing,
    each with the chain that reaches it."""
    files, raws = [], []
    for path in sources(dirs):
        with open(path, encoding='utf-8') as fh:
            raw = fh.read()
        raws.append(raw)
        files.append((os.path.basename(path), strip_comments(raw)))
    containers, fields = lin_classes([t for _, t in files])
    numargs = lin_numeric_args(raws)
    routines = []          # (key, short, body)
    entries = set()
    consults = set()
    for base, text in files:
        rs = list(routines_of(text))
        entries |= set(LIN_REGISTER.findall(text))
        for name, body in rs:
            body = lin_unnumber(body, numargs.get(name, set()))
            key = '%s:%s' % (base, name)
            routines.append((key, name.split('.')[-1], body))
            # DIRECT, not resolved through helpers the way the first rule's
            # gated_names is. lfill$ calls RunOf, which consults -- for the pad
            # it builds -- and so the first rule counts lfill$ as consulting;
            # the CpLen of a 50 MB argument two lines earlier was charged
            # nothing, and 200 calls ran 4015 ms past a 2000 ms ceiling. A
            # consultation answers for the work beside it, not for the routine.
            if LIN_GATE.search(body):
                consults.add(key)
    calls = {key: lin_callees(key, body, routines) for key, _, body in routines}
    # WHICH PARAMETERS CARRY SCRIPT DATA (round 8), propagated from the call
    # sites in view. A routine whose callers are not all in view -- registered,
    # taken as a callback, or called from nowhere here -- keeps the round-7
    # reading: every data parameter is tainted.
    alltext = '\n'.join(t for _, t in files)
    callbacks = set(re.findall(r'@\s*([A-Za-z_]\w*)', alltext))
    called = set(c for k in calls for c in calls[k])
    params = {key: lin_params(body) for key, _, body in routines}
    seed = {}
    for key, short, _ in routines:
        if short in entries or short in callbacks or key not in called:
            seed[key] = None
        else:
            seed[key] = set()
    bodies = {key: body for key, _, body in routines}
    changed = True
    while changed:
        changed = False
        for key, short, body in routines:
            name = key.split(':', 1)[1]
            tainted, arity = lin_taint(name, body, containers, fields, seed[key])
            if not tainted:
                continue
            for callee in calls[key]:
                if seed[callee] is None:
                    continue
                cshort = callee.split(':', 1)[1].split('.')[-1]
                for m in re.finditer(r'\b' + re.escape(cshort) + r'\s*\(', body):
                    if m.start() == 0 or body[:m.start()].rstrip().endswith(
                            ('function', 'procedure')):
                        continue
                    args = lin_split_args(balanced_arg(body, m.end() - 1))
                    for i, (pn, _, is_out) in enumerate(params[callee]):
                        if i >= len(args) or is_out or pn in seed[callee]:
                            continue
                        if lin_reads(lin_neutral(args[i]), tainted, arity):
                            seed[callee].add(pn)
                            changed = True
    direct, used = {}, set()
    for key, short, body in routines:
        name = key.split(':', 1)[1]
        ours = frozenset(c.split(':', 1)[1].split('.')[-1] for c in calls[key])
        d = lin_constructs(name, body, containers, fields, ours, seed[key])
        if d:
            if key in allowed:
                used.add(key)
                continue
            direct[key] = d
    # A CONSULTATION BY PROXY. A helper that asks the budget and does no linear
    # work of its own -- DigestAllowed, which prices a hash for its caller and
    # sets the caller's error -- is the caller asking, spelled once. A helper
    # that asks AND works (RunOf asks for the pad it builds) answers only for
    # its own work, which is the lfill$ lesson above; it does not count.
    wrappers = set(k for k in consults
                   if k not in direct and not any(c in direct for c in calls[k]))
    # WHAT ANSWERS FOR A CONSTRUCT IS A CHARGE BESIDE IT (round 8). A charge
    # outside every loop answers for the routine; a charge inside a loop
    # answers for that loop's body only (lin_cover). A construct no charge
    # answers for is UNCOVERED, and so is a call to an uncovered routine that no
    # charge in the caller answers for. A registered function with anything
    # uncovered is a hole -- however many charges it makes for OTHER work.
    bodies = {key: body for key, _, body in routines}
    cover = {}
    for key, _, body in routines:
        proxies = set(c.split(':', 1)[1].split('.')[-1] for c in calls[key] if c in wrappers)
        cover[key] = lin_cover(body, proxies)
    uncovered = {}
    for key, cons in direct.items():
        labs = sorted(set(lab for pos, lab in cons if not lin_covered(pos, cover[key])))
        if labs:
            uncovered[key] = labs

    def call_sites(key, callee):
        short = callee.split(':', 1)[1].split('.')[-1]
        body = bodies[key]
        hdr = body.find('(')
        return [m.start() for m in re.finditer(r'\b' + re.escape(short) + r'\b', body)
                if m.start() > (hdr if hdr >= 0 else 0)]
    # Fixed point over the call graph.
    changed = True
    while changed:
        changed = False
        for key, short, _ in routines:
            if key in allowed:
                continue
            for callee in calls[key]:
                if callee not in uncovered:
                    continue
                if all(lin_covered(p, cover[key]) for p in call_sites(key, callee)):
                    continue
                lab = 'via %s' % callee.split(':', 1)[1]
                cur = uncovered.setdefault(key, [])
                if lab not in cur:
                    cur.append(lab)
                    changed = True
    # Linear at all, covered or not: for the count the green line reports.
    linear = set(direct)
    changed = True
    while changed:
        changed = False
        for key, short, _ in routines:
            if key in allowed or key in linear:
                continue
            if any(c in linear for c in calls[key]):
                linear.add(key)
                changed = True
    # An exemption is USED only while the routine it names would be linear
    # without it -- by its own walk or through a callee -- so an entry whose
    # reason has stopped being needed is reported stale, like ALLOWED's.
    for key, short, _ in routines:
        if key in allowed and any(c in uncovered for c in calls[key]):
            used.add(key)
    holes, ok = [], 0
    for key, short, _ in routines:
        if short not in entries or key not in linear:
            continue
        if key not in uncovered:
            ok += 1
            continue
        base = key.split(':', 1)[0]
        if test_hosts and base in test_hosts:
            used.add(base)
            continue
        holes.append((key, uncovered[key]))
    LAST_UNCOVERED.clear()
    LAST_UNCOVERED.update(uncovered)
    flagged = sorted((k, sorted(set(lab for _, lab in v))) for k, v in direct.items())
    return holes, ok, used, flagged


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
            # THE STRIPPER ITSELF (n26). A '//' inside a string literal, then an
            # amplifier, then another literal: the old order-dependent stripper
            # took the '//' for a comment, lost the closing quote, and paired the
            # first quote with the last -- swallowing the loop between them.
            ('a loop after a string holding //',
             'f_planted_url',
             "var i, n: Integer; u: String;\n"
             'begin\n'
             "  u := 'http://x';\n"
             '  n := ArgI32(A[0]);\n'
             '  for i := 1 to n do u := u;\n'
             "  Result := ValStr('');\n"
             'end;\n'),
            # ROUND FOUR (d45). Both loops bounded by a Length, no allocation, no
            # native, no RTL search and no append -- only the nested-search rule
            # can see it, the way only it could see IndexOfFrom. The outer bound
            # goes through a local, as IndexOfFrom's did.
            ('a hand-rolled nested search',
             'f_planted_search2',
             'var i, j, last: Integer; h, n: String;\n'
             'begin\n'
             '  h := A[0].Str; n := A[1].Str;\n'
             '  last := Length(h) - Length(n) + 1;\n'
             '  for i := 1 to last do\n'
             '    for j := 1 to Length(n) do\n'
             '      if h[i + j - 1] <> n[j] then Break;\n'
             '  Result := ValInt(0);\n'
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
            if fname == 'f_planted_search2' and \
               not all(' inside for ' in h for h in holes[0][1]):
                print('PROVE FAILED: the planted nested search was reported by '
                      'another rule as well (%s), so the nested-search rule is '
                      'unproven.' % holes[0][1])
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

        # ROUND SEVEN: THE LINEAR PASS, in the three shapes that decide it. A
        # registered function reaching a byte loop over its STRING argument
        # through a helper (the ucase$ shape: no count, no allocation the first
        # rule could see); the same with the entry pricing the pass (quiet); and
        # the lfill$ shape -- the entry calls a helper that asks the budget for
        # work of its OWN, which must not count for the walk beside it.
        lin_cases = [
            ('a registered function walking its string through a helper',
             'begin\n  Result := ValStr(Up(A[0].Str));\nend;\n', True),
            ('the same, priced before the walk',
             'begin\n'
             "  if not BudgetLinearOk('up$', Length(A[0].Str), BudgetMilliRewrite, E) then Exit;\n"
             '  Result := ValStr(Up(A[0].Str));\nend;\n', False),
            ('the same, beside a helper that asks for its own work only',
             # lfill$'s own shape: the pad RunOf builds is the script's
             # (since round 8 a helper handed only literals reads as a pure
             # proxy, which it then is).
             "begin\n  Pad(A[0].Str, 3);\n  Result := ValStr(Up(A[0].Str));\nend;\n", True),
        ]
        for label, body, want in lin_cases:
            with open(os.path.join(d, 'PhosphorPlantedLib.pas'), 'w',
                      encoding='utf-8') as fh:
                fh.write('unit PhosphorPlantedLib;\ninterface\nimplementation\n'
                         'function Up(const S: String): String;\n'
                         'var i: Integer;\n'
                         'begin\n'
                         '  Result := S;\n'
                         '  for i := 1 to Length(Result) do Result[i] := UpCase(Result[i]);\n'
                         'end;\n'
                         # RunOf's shape: it asks, for the run of F it builds.
                         'procedure Pad(const F: String; N: Integer);\n'
                         'var r: String;\n'
                         'begin\n'
                         '  if not BudgetAllows(N * Length(F)) then Exit;\n'
                         "  r := '';\n"
                         '  SetLength(r, N * Length(F));\n'
                         'end;\n'
                         'function f_planted_up(const A: array of TValue;\n'
                         '  out E: TPhosphorError): TValue;\n' + body +
                         'procedure RegisterPlanted(Reg: TPhosphorRegistry);\n'
                         'begin\n'
                         "  Reg.Add('up$:$', @f_planted_up);\n"
                         'end;\n'
                         'end.\n')
            holes, _, _, _ = linear_scan([d], {})
            got = 'PhosphorPlantedLib.pas:f_planted_up' in [k for k, _ in holes]
            if got != want:
                print('PROVE FAILED: the linear pass on "%s" reported %s, wanted %s'
                      % (label, [k for k, _ in holes] or 'nothing',
                         'f_planted_up' if want else 'nothing'))
                return 1
            print('prove: linear pass, %s -> %s.'
                  % (label, 'reported' if want else 'quiet'))

        # ROUND EIGHT: the shapes the round-7 pass read as consulting or could
        # not see at all, each planted with a twin that must go quiet, so each
        # rule is seen both to fire and to be satisfiable. Every planted body is
        # registered, and none has a loop over a count, an allocation over a
        # count or a native -- nothing the first rule could report instead.
        r8_head = ('unit PhosphorPlantedLib;\ninterface\nimplementation\n'
                   'type TPlantedBox = class\n  Items: array of String;\n'
                   '  procedure Delete(I: Integer);\nend;\n'
                   # MatchGlob's shape: a fold of the whole name, then a loop that
                   # charges per comparison -- and stops at the first one.
                   'function Glob(const AName, APat: String): Boolean;\n'
                   'var n: String; i, t: Integer;\n'
                   'begin\n'
                   '  n := LowerCase(AName);\n'
                   '  i := 1; t := 0;\n'
                   '  while i <= Length(n) do\n'
                   '  begin\n'
                   '    Inc(t);\n'
                   '    if not BudgetCharge(1) then Exit(False);\n'
                   '    if n[i] <> APat[1] then Exit(False);\n'
                   '    Inc(i);\n'
                   '  end;\n'
                   '  Result := True;\n'
                   'end;\n'
                   # Combine2's shape: one concatenation, nothing else.
                   'function Join2(const A, B: String): String;\n'
                   'begin\n'
                   "  Result := A + '/' + B;\n"
                   'end;\n'
                   # A helper whose string parameter only ever receives a
                   # literal: its concatenation is not a pass over script data.
                   'function Named(const AFn: String): String;\n'
                   'begin\n'
                   "  Result := AFn + ': refused';\n"
                   'end;\n')
        r8_cases = [
            ('a fold before a loop that charges for its OWN iterations only',
             'f_planted_glob',
             'begin\n  Result := ValInt(Ord(Glob(A[0].Str, A[1].Str)));\nend;\n', True),
            ('the same, the fold priced by the caller',
             'f_planted_glob',
             "begin\n  if not BudgetLinearOk('glob', Length(A[0].Str), BudgetMilliRewrite, E) then Exit;\n"
             '  Result := ValInt(Ord(Glob(A[0].Str, A[1].Str)));\nend;\n', False),
            ('a body whose only charge is inside a loop, beside a copy',
             'f_planted_beside',
             'var s: String; i: Integer;\n'
             'begin\n  s := Copy(A[0].Str, 2, MaxInt);\n'
             '  for i := 1 to Length(A[1].Str) do\n'
             '    if not BudgetCharge(1) then Exit;\n'
             '  Result := ValStr(s);\nend;\n', True),
            ('a concatenation of two script strings',
             'f_planted_join',
             'begin\n  Result := ValStr(Join2(A[0].Str, A[1].Str));\nend;\n', True),
            ('the same, priced',
             'f_planted_join',
             "begin\n  if not BudgetLinearOk('join$', Length(A[0].Str) + Length(A[1].Str), BudgetMilliCopy, E) then Exit;\n"
             '  Result := ValStr(Join2(A[0].Str, A[1].Str));\nend;\n', False),
            ('a concatenation of a literal function name, whatever the script holds',
             'f_planted_named',
             "begin\n  E := MakeError(peRuntime, Named('named'));\n  Result := ValStr(A[0].Str);\nend;\n",
             False),
            ('a shift of a container the script holds (json_removeat@)',
             'f_planted_shift',
             'var a: TPlantedBox;\n'
             'begin\n  a := TPlantedBox(HandleObj(A[0].Hnd));\n'
             '  a.Delete(ArgI32(A[1]));\n  Result := A[0];\nend;\n', True),
            ('the same, priced',
             'f_planted_shift',
             'var a: TPlantedBox;\n'
             'begin\n  a := TPlantedBox(HandleObj(A[0].Hnd));\n'
             "  if not BudgetLinearOk('shift@', Length(a.Items), BudgetMilliItem, E) then Exit;\n"
             '  a.Delete(ArgI32(A[1]));\n  Result := A[0];\nend;\n', False),
        ]
        for label, fname, body, want in r8_cases:
            with open(os.path.join(d, 'PhosphorPlantedLib.pas'), 'w',
                      encoding='utf-8') as fh:
                fh.write(r8_head +
                         'function %s(const A: array of TValue;\n'
                         '  out E: TPhosphorError): TValue;\n' % fname + body +
                         'procedure RegisterPlanted(Reg: TPhosphorRegistry);\n'
                         'begin\n'
                         "  Reg.Add('planted:$$', @%s);\n"
                         'end;\n'
                         'end.\n' % fname)
            holes, _, _, _ = linear_scan([d], {})
            got = 'PhosphorPlantedLib.pas:%s' % fname in [k for k, _ in holes]
            if got != want:
                print('PROVE FAILED: the linear pass on "%s" reported %s, wanted %s'
                      % (label, [k for k, _ in holes] or 'nothing',
                         fname if want else 'nothing'))
                return 1
            # Reported for the RIGHT reason: in Glob the loop that charges is
            # covered and the fold before it is not.
            if fname == 'f_planted_glob' and want and \
               LAST_UNCOVERED.get('PhosphorPlantedLib.pas:Glob') != ['LowerCase(..)']:
                print('PROVE FAILED: Glob was reported for %s, wanted the fold alone'
                      % LAST_UNCOVERED.get('PhosphorPlantedLib.pas:Glob'))
                return 1
            print('prove: linear pass, %s -> %s.'
                  % (label, 'reported (%s)' % ', '.join(holes[0][1]) if want else 'quiet'))

        # And the unzip rule, in both of the shapes d47 had: a LOCAL plain
        # unzipper asked to extract, and a FIELD reached through a handle. Then
        # the same two declared metered, which must go quiet.
        for kind in ('TUnZipper', 'TMeteredUnZipper'):
            with open(os.path.join(d, 'PhosphorPlantedLib.pas'), 'w',
                      encoding='utf-8') as fh:
                # The interface DECLARES a routine before the implementation's
                # type section, as every real unit does -- the shape that hid the
                # field from the first draft of this rule.
                fh.write('unit PhosphorPlantedLib;\ninterface\n'
                         'procedure ViaLocal(const P: String);\n'
                         'implementation\n'
                         'type TPlantedReader = class\n'
                         '  Z: %s;\n'
                         'end;\n'
                         'procedure ViaLocal(const P: String);\n'
                         'var u: %s;\n'
                         'begin\n'
                         '  u := %s.Create();\n'
                         '  u.UnZipAllFiles;\n'
                         'end;\n'
                         'procedure ViaField(r: TPlantedReader);\n'
                         'begin\n'
                         '  r.Z.UnZipFiles(nil);\n'
                         'end;\n'
                         'end.\n' % (kind, kind, kind))
            bad = unmetered([d])
            want = ['PhosphorPlantedLib.pas:ViaLocal',
                    'PhosphorPlantedLib.pas:field Z'] if kind == 'TUnZipper' else []
            if sorted(bad) != sorted(want):
                print('PROVE FAILED: the unzip rule over %s reported %s, wanted %s'
                      % (kind, bad, want))
                return 1
            print('prove: the unzip rule over %s reports %s.' % (kind, bad or 'nothing'))
        return 0


def linear(sites=False):
    """The linear pass, as the plain run and --linear run it. With sites=True it
    first lists EVERY routine it finds walking script-supplied data -- the
    work-list the round-7 fix was made from -- and what answers for each."""
    holes, ok, used, flagged = linear_scan(LINEAR_DIRS, LINEAR_ALLOWED,
                                           LINEAR_TEST_HOSTS)
    if sites:
        for key, hits in flagged:
            print('  %-56s %s' % (key, ', '.join(hits)))
        print('linear sites: %d routines walk script-supplied data' % len(flagged))
    if holes:
        print('LINEAR HOLES -- registered functions whose work grows with a script-')
        print('supplied string, array, list, dictionary, tree or buffer, and that')
        print('consult nothing that answers for it:')
        for key, hits in holes:
            print('  %-56s %s' % (key, ', '.join(hits)))
        # WHERE EACH CHAIN ENDS: the uncovered constructs themselves, so a
        # reader does not have to re-derive them from a list of helper names.
        ends = set()
        todo = [h[4:] for _, hits in holes for h in hits if h.startswith('via ')]
        while todo:
            name = todo.pop()
            if name in ends:
                continue
            ends.add(name)
            for key, labs in LAST_UNCOVERED.items():
                if key.split(':', 1)[1] == name:
                    todo += [h[4:] for h in labs if h.startswith('via ')]
        if ends:
            print('')
            print('...where each chain ends (the uncovered constructs):')
            for key in sorted(LAST_UNCOVERED):
                if key.split(':', 1)[1] in ends:
                    own = [h for h in LAST_UNCOVERED[key] if not h.startswith('via ')]
                    if own:
                        print('  %-56s %s' % (key, ', '.join(own)))
        print('')
        print('One call is one VM instruction however long its argument is, and the')
        print('VM reads its clock every 4096 of them. Price the pass before it runs')
        print('(BudgetLinearOk with a measured BudgetMilli* price), meter a walk whose')
        print('length only the walk finds (BudgetMeterAdd), or list the walker in')
        print('LINEAR_ALLOWED with the reason ONE call of it is O(1).')
        return 1
    stale = (set(LINEAR_ALLOWED) | set(LINEAR_TEST_HOSTS)) - used
    if stale:
        print('STALE LINEAR EXEMPTIONS -- listed but no longer reached:')
        for key in sorted(stale):
            print('  ' + key)
        return 1
    print('linear gate: %d registered functions do linear work, all consult the '
          'budget; %d walkers exempt by name' % (ok, len(used)))
    return 0


def main():
    if '--prove' in sys.argv:
        return prove()
    if '--narrowing' in sys.argv:
        return narrowing()
    if '--linear' in sys.argv:
        return linear(sites=True)
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
    plain = unmetered(SCAN_DIRS)
    if plain:
        print('AN ARCHIVE EXPANDED THROUGH AN UNMETERED UNZIPPER:')
        for key in plain:
            print('  ' + key)
        print('')
        print('Declare it TMeteredUnZipper (host/packages/PhosphorZipLib.pas), which')
        print('charges every byte it writes. A plain TUnZipper prices nothing it')
        print('inflates, and an archive decides how much that is (ledger d46).')
        return 1
    print('unzip gate: no archive is expanded through an unmetered unzipper')
    # The linear pass and the narrowing sweep run on every plain invocation too:
    # a second rule that has to be REMEMBERED is a rule half the runs do not have.
    if linear():
        return 1
    return narrowing()


if __name__ == '__main__':
    sys.exit(main())
