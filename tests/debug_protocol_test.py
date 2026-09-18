#!/usr/bin/env python3
"""One debug-protocol session, driven the way PhosphorIDE will drive it.

THE EDITOR LISTENS AND THE DEBUGGEE CONNECTS -- that is the spec's direction, and
getting it backwards is the first thing a host implementer gets wrong. This script
stands in for the editor: it binds 127.0.0.1 on an ephemeral port, launches
`phosphor debug --port N`, and drives one whole session.

It is Python because the suite already requires Python for nine gates, and because
the other end of this protocol is a separate program in a separate repository: a
test written in the host's own language could agree with the host about something
the spec does not say.

Usage: debug_protocol_test.py <phosphor.exe> <file.bas>
"""
import json
import socket
import threading
import time
import subprocess
import io
import os
import sys
import tempfile

EXE = os.path.abspath(sys.argv[1])

# THE FIXTURE IS WRITTEN HERE, not carried as a file in a corpus: the assertions
# below name its line numbers, and a program that lives beside them cannot drift
# from them. Line 11 is inside the three-pass loop on purpose -- a breakpoint in a
# loop must fire once per pass, and the first version of this script asserted once.
PROGRAM = [
    'rem a small program with a function, for the debug protocol test',
    'total = 0',
    '',
    'function dobro(n) local r',
    '  r = n * 2',
    '  return r',
    'endfunction',
    '',
    'for i = 1 to 3',
    '  parcela = dobro(i)',
    '  total = total + parcela',
    '  println "i="; i; " parcela="; parcela',
    'next',
    '',
    'println "total="; total',
    'end',
]
WORK = tempfile.mkdtemp(prefix='phosphor-dbgproto-')
BAS = os.path.join(WORK, 'q.bas')
io.open(BAS, 'w', encoding='ascii', newline=chr(10)).write(
    chr(10).join(PROGRAM) + chr(10))

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', 0))
srv.listen(1)
port = srv.getsockname()[1]
print('editor listening on 127.0.0.1:%d' % port)

proc = subprocess.Popen([EXE, 'debug', '--port', str(port), BAS],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        stdin=subprocess.DEVNULL)

srv.settimeout(10)
conn, _ = srv.accept()
conn.settimeout(15)
print('host connected')

buf = b''
seq = 0
events = []


def send(**kw):
    global seq
    seq += 1
    kw['seq'] = seq
    line = json.dumps(kw) + '\n'
    conn.sendall(line.encode('utf-8'))
    return seq


def frames(until_seq=None, until_event=None, limit=40):
    """Read frames until the response to until_seq, or one of until_event, arrives.

    until_event takes a name or a tuple. It must, because after `continue` the
    next thing the host says is either `stopped` (it hit the line again) or
    `exited` (it finished) -- and a reader that only returns on one of those sits
    blocked while the host sits waiting for a command. That deadlock was this
    script's, not the host's.
    """
    want = ()
    if isinstance(until_event, str):
        want = (until_event,)
    elif until_event:
        want = tuple(until_event)
    global buf
    got = []
    for _ in range(limit):
        while b'\n' not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                return got
            buf += chunk
        line, buf = buf.split(b'\n', 1)
        if not line.strip():
            continue
        o = json.loads(line.decode('utf-8'))
        got.append(o)
        if 'event' in o:
            events.append(o)
            if o['event'] in want:
                return got
        elif until_seq and o.get('seq') == until_seq:
            return got
    return got


ok = []
bad = []


def check(name, cond, detail=''):
    (ok if cond else bad).append(name)
    print('  %-42s %s %s' % (name, 'PASS' if cond else 'FAIL', detail if not cond else ''))


# 1. initialize
s1 = send(cmd='initialize', protocol=1, client='editor.py')
r = [f for f in frames(until_seq=s1) if f.get('seq') == s1][0]
check('initialize answers ok', r.get('ok') is True, str(r))
check('protocol is 1', r.get('protocol') == 1, str(r.get('protocol')))
caps = r.get('capabilities', {})
check('capabilities present', isinstance(caps, dict) and len(caps) == 6, str(caps))
check('evaluate is offered', caps.get('evaluate') is True, str(caps))
check('and evaluateCalls says what it will not do',
      caps.get('evaluateCalls') is False, str(caps))
check('conditional breakpoints are offered',
      caps.get('conditionalBreakpoints') is True, str(caps))
check('setVariable is not -- the capability is reserved, there is no command',
      caps.get('setVariable') is False, str(caps))
check('stepOut and pause offered', caps.get('stepOut') and caps.get('pause'), str(caps))

# 2. setBreakpoints before launch
s2 = send(cmd='setBreakpoints', path=BAS, lines=[11])
r = [f for f in frames(until_seq=s2) if f.get('seq') == s2][0]
check('setBreakpoints answers the set', r.get('ok') is True and r.get('lines') == [11], str(r))

# 2a. THE REPLY IS WHAT WAS INSTALLED, NOT WHAT WAS ASKED FOR. The spec is explicit
#     (docs/debug-protocol.md in PhosphorIDE): a line holding no executable
#     statement has nowhere to stop, and the editor draws the difference so a
#     breakpoint that will never fire looks different from one that will. This host
#     used to echo the request straight back, so every mark looked verified.
#     Line 1 of the fixture is a `rem`, and line 3 is blank.
s2a = send(cmd='setBreakpoints', path=BAS, lines=[1, 3, 11])
r = [f for f in frames(until_seq=s2a) if f.get('seq') == s2a][0]
check('a comment and a blank line come back unverified', r.get('lines') == [11], str(r))

# 2b. AND THE SAME LINE ASKED FOR TWICE IS ANSWERED ONCE. `a = 1 : b = 2` emits two
#     statement boundaries on one line, so the engine's own set can repeat.
s2b = send(cmd='setBreakpoints', path=BAS, lines=[11, 11])
r = [f for f in frames(until_seq=s2b) if f.get('seq') == s2b][0]
check('a duplicated line is answered once', r.get('lines') == [11], str(r))

# 2c. A FRAME WITH NO `lines` KEY MUST NOT KILL THE DEBUGGEE. `lines` is optional
#     and this host reached TJSONData.Clone -- `virtual; abstract` -- through nil
#     to build its reply, so the exception escaped into the VM thread and the
#     editor saw a connection reset. One conformant frame, one dead process.
s2c = send(cmd='setBreakpoints', path=BAS)
r = [f for f in frames(until_seq=s2c) if f.get('seq') == s2c]
check('a frame with no lines key is answered, not fatal', len(r) == 1, 'no reply: the debuggee died')
if r:
    check('an absent set is the empty set', r[0].get('lines') == [], str(r[0]))

# put the real breakpoint back for the rest of the session
s2d = send(cmd='setBreakpoints', path=BAS, lines=[11])
[f for f in frames(until_seq=s2d) if f.get('seq') == s2d]

# 3. a command in the wrong state is refused, never ignored
s3 = send(cmd='stackTrace')
r = [f for f in frames(until_seq=s3) if f.get('seq') == s3][0]
check('stackTrace refused while not stopped', r.get('ok') is False and 'error' in r, str(r))

# 4. launch, then the stop
s4 = send(cmd='launch', program=BAS, stopAtEntry=False)
r = [f for f in frames(until_seq=s4) if f.get('seq') == s4][0]
check('launch acknowledged', r.get('ok') is True, str(r))

got = frames(until_event='stopped')
ev = [f for f in got if f.get('event') == 'stopped']
check('stopped event arrived', len(ev) == 1, str(got))
if ev:
    check('stopped at the armed line', ev[0].get('line') == 11, str(ev[0]))
    check('reason is breakpoint', ev[0].get('reason') == 'breakpoint', str(ev[0]))

# 5. stackTrace while stopped
s5 = send(cmd='stackTrace')
r = [f for f in frames(until_seq=s5) if f.get('seq') == s5][0]
fr = r.get('frames', [])
check('stackTrace answers frames', r.get('ok') is True and len(fr) >= 1, str(r))
if fr:
    check('frame 0 is innermost and has the line', fr[0].get('index') == 0 and fr[0].get('line') == 11, str(fr[0]))
    check('outermost frame is (main)', fr[-1].get('name') == '(main)', str(fr[-1]))

# 6. variables while stopped
s6 = send(cmd='variables', frame=0)
r = [f for f in frames(until_seq=s6) if f.get('seq') == s6][0]
vs = r.get('variables', [])
names = {v['name']: v for v in vs}
check('variables answers a list', r.get('ok') is True and len(vs) > 0, str(r)[:200])
check('a global is named with its value', 'total' in names, sorted(names))
if 'total' in names:
    check('kind is one of the five', names['total'].get('kind') in
          ('number', 'int', 'string', 'bool', 'handle'), str(names['total']))
    check('scope is said', names['total'].get('scope') in ('local', 'global'), str(names['total']))

# 6b. A MALFORMED ELEMENT INSIDE `lines` MUST NOT KILL THE DEBUGGEE. fpjson's
#     Integers[] converts, so a string, a JSON null and a nested array each raise
#     from inside the parse loop. An editor is a program and programs have bugs;
#     the host must not die of someone else's. A bad element is dropped, and the
#     editor learns which by what comes back -- the same mechanism that reports a
#     line no statement starts on. 11 is the loop line and stays armed.
s6b = send(cmd='setBreakpoints', path=BAS, lines=[11, 'eleven', None, [11], -1, 0])
r = [f for f in frames(until_seq=s6b) if f.get('seq') == s6b]
check('a malformed element is dropped, not fatal', len(r) == 1, 'no reply: the debuggee died')
if r:
    check('only the usable line survives', r[0].get('lines') == [11], str(r[0]))

# 6c. AND THE SET CAN BE REPLACED WHILE STOPPED, which is the state an editor is
#     always in when a person moves a breakpoint. TPhosphorEngine.ArmDebug used to
#     forward to FVM and FReplVM only -- both nil during Run -- while the live VM
#     is FLiveVM, the very object DebugVM hands the host. So this was acknowledged
#     with the right lines, armed nothing, and the program ran to the end.
#     Re-armed to 11 alone below, so the three-pass count further down still holds.
s6c = send(cmd='setBreakpoints', path=BAS, lines=[11])
r = [f for f in frames(until_seq=s6c) if f.get('seq') == s6c][0]
check('the set can be replaced while stopped', r.get('lines') == [11], str(r))

# 7. EVALUATE, at a TOP-LEVEL stop. The frame case needs an activation and gets
#    its own session at the end of this file; what belongs here is the half that
#    is about the globals of a program standing still, and the half that is about
#    what an `expr` string may not be allowed to do.
#
#    THE REFUSALS ARE THE POINT OF THIS BLOCK. `expr` is a string an editor sends
#    verbatim, so it is the one field of this protocol an attacker-shaped input
#    reaches directly, and the host's answer must come from the INSTRUCTIONS the
#    expression compiled to rather than from any rule about its text. Each line
#    below was a string that compiled cleanly.


def ev(expr, frame=0):
    sN = send(cmd='evaluate', frame=frame, expr=expr)
    a = [f for f in frames(until_seq=sN) if f.get('seq') == sN][0]
    if a.get('ok'):
        return '%s:%s' % (a.get('kind'), a.get('result'))
    return 'error:%s' % a.get('error')


# The program is stopped inside the loop at line 11, so `i` has a value and
# `total` has the sum so far. Derived from the source, not from a run: the first
# pass reaches line 11 with i=1 and parcela=dobro(1)=2, and total is still 0
# because line 11 is the statement that adds it.
check('a global', ev('parcela') == 'int:2', ev('parcela'))
check('arithmetic over two globals', ev('total + parcela') == 'int:2',
      ev('total + parcela'))
check('a comparison is a bool', ev('i = 1') == 'bool:true', ev('i = 1'))
# THE LANGUAGE'S OWN IRREGULARITIES, which is what reusing the compiler buys and
# what any second parser would get wrong: `^` is left-associative over a PRIMARY
# base, so unary minus binds looser than it does.
check('-2 ^ 2 is -4, not 4', ev('-2 ^ 2') == 'number:-4', ev('-2 ^ 2'))
check('2 ^ 3 ^ 2 is 64, not 512', ev('2 ^ 3 ^ 2') == 'number:64', ev('2 ^ 3 ^ 2'))
check('an expression that faults says why',
      ev('total / 0') == 'error:division by zero', ev('total / 0'))
check('a name the program has not got is refused, not answered as 0',
      ev('naosei') == 'error:no variable "naosei" here', ev('naosei'))

# EVERY ONE OF THESE COMPILES. The compiler's own refusals are incidental -- they
# land on a trailing fragment failing to be a statement, not on the payload -- so
# balancing the tail gets all of them past it, and only the instruction walk is
# left standing. A comment defeats any scheme that neutralises the tail by
# appending a terminator, because a comment eats the terminator.
for bad_expr, why in [
        ('total) : total = 99 : println (1', 'a second statement'),
        ('total)\ntotal = 99\n__x = (1', 'a newline'),
        ('total) : total = 99 rem ', 'a comment after the payload'),
        ("total) : total = 99 'x", 'the apostrophe comment form'),
        ('total) : println "pwned" : println (1', 'output'),
        ('total) : open "x" for output as #1 : println (1', 'a file'),
        ('total) : end : println (1', 'halting the debuggee'),
        ('total) : input a$ : println (1', 'blocking on stdin'),
        ('total) : total += 1 : println (1', 'a compound assignment'),
        ('total) : swap total, i : println (1', 'a swap'),
        ('dobro(1)', 'a user function'),
        ('len("ab")', 'a library call'),
]:
    check('refused: ' + why, ev(bad_expr).startswith('error:'), ev(bad_expr))

# AND THE PROGRAM DID NOT MOVE. Every global, after all of that.
sV = send(cmd='variables', frame=0)
rV = [f for f in frames(until_seq=sV) if f.get('seq') == sV][0]
gs = {v['name']: v['value'] for v in rV.get('variables', [])}
check('the globals are exactly where they were',
      gs.get('total') == '0' and gs.get('i') == '1' and gs.get('parcela') == '2',
      str(gs))

s7 = send(cmd='evaluate', frame=9)
r = [f for f in frames(until_seq=s7) if f.get('seq') == s7][0]
check('a missing expr is refused, not treated as empty', r.get('ok') is False, str(r))

# 8. continue to the end
s8 = send(cmd='continue')
r = [f for f in frames(until_seq=s8) if f.get('seq') == s8][0]
check('continue acknowledged', r.get('ok') is True, str(r))

# The armed line is inside a three-pass loop, so it stops once per pass: answer
# each one. The first version of this sent one `continue` and waited for `exited`,
# which is the editor's mistake and not the host's.
ex = []
for _ in range(6):
    got = frames(until_event=('exited', 'stopped'), limit=20)
    ex = [f for f in got if f.get('event') == 'exited']
    if ex:
        break
    if [f for f in got if f.get('event') == 'stopped']:
        sN = send(cmd='continue')
        frames(until_seq=sN)
stops = [f for f in events if f.get('event') == 'stopped']
check('exited event arrived', len(ex) == 1, str(got)[:200])
if ex:
    check('exitCode is 0', ex[0].get('exitCode') == 0, str(ex[0]))
check('the loop line stopped once per pass', len(stops) == 3, '%d stops' % len(stops))

out, err = proc.communicate(timeout=15)
check('process exited 0', proc.returncode == 0, 'rc=%s err=%s' % (proc.returncode, err[:200]))
check("the program's own stdout is untouched",
      out.replace(b'\r\n', b'\n') == b'i=1 parcela=2\ni=2 parcela=4\ni=3 parcela=6\ntotal=12\n',
      repr(out))

conn.close()
srv.close()

# ---------------------------------------------------------------------------
# SECOND SESSION: PAUSE A PROGRAM THAT NEVER STOPS ON ITS OWN.
#
# It needs its own session and its own fixture because no other case in this file
# has the shape: no breakpoint anywhere, and long enough to still be running when
# the editor asks. `pause` was advertised `true` in the handshake from the day the
# protocol shipped and could not fire -- while the program ran, NOTHING READ THE
# SOCKET, so the frame sat in the inbox and the next thing the editor saw was
# `exited`. A capability that lies is worse than one that is absent.
#
# This is thread timing, so it is the case that has to pass on Linux too.
# ---------------------------------------------------------------------------
BAS2 = os.path.join(WORK, 'loop.bas')
with open(BAS2, 'w', newline='\n') as f:
    f.write('t = 0\nfor i = 1 to 6000000\n  t = t + i\nnext\nprintln "t="; t\nend\n')

srv2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv2.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv2.bind(('127.0.0.1', 0))
srv2.listen(1)
port2 = srv2.getsockname()[1]
proc2 = subprocess.Popen([EXE, 'debug', '--port', str(port2), BAS2],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
srv2.settimeout(10)
conn2, _ = srv2.accept()
conn2.settimeout(30)

seq2 = [0]
buf2 = [b'']


def send2(**kw):
    seq2[0] += 1
    kw['seq'] = seq2[0]
    conn2.sendall((json.dumps(kw) + '\n').encode('utf-8'))
    return seq2[0]


def recv2(timeout=30):
    conn2.settimeout(timeout)
    while b'\n' not in buf2[0]:
        try:
            chunk = conn2.recv(65536)
        except socket.timeout:
            return None
        if not chunk:
            return None
        buf2[0] += chunk
    line, buf2[0] = buf2[0].split(b'\n', 1)
    return json.loads(line.decode('utf-8'))


def until2(pred, timeout=30, tries=60):
    for _ in range(tries):
        m = recv2(timeout)
        if m is None:
            return None
        if pred(m):
            return m
    return None


s = send2(cmd='initialize')
until2(lambda m: m.get('seq') == s)
s = send2(cmd='setBreakpoints', path=BAS2, lines=[])
until2(lambda m: m.get('seq') == s)
s = send2(cmd='launch', stopAtEntry=False)
until2(lambda m: m.get('seq') == s)

# The host arms stop-at-entry ALWAYS, because a stop is the only thread-safe
# moment to take the running VM. The editor said it did not want to stop there,
# so that entry stop must be invisible: nothing may arrive unasked.
check('a silent entry resume sends nothing', recv2(timeout=1.0) is None)

s = send2(cmd='pause')
r = until2(lambda m: m.get('seq') == s, timeout=15)
check('pause is answered while the program runs', r is not None and r.get('ok') is True, str(r))

ev = until2(lambda m: m.get('event') in ('stopped', 'exited'), timeout=15)
check('pause actually stops the program',
      ev is not None and ev.get('event') == 'stopped', str(ev))
if ev and ev.get('event') == 'stopped':
    check('the stop says it was a pause', ev.get('reason') == 'pause', str(ev))
    s = send2(cmd='variables', frame=0)
    r = until2(lambda m: m.get('seq') == s, timeout=15)
    got = {v['name']: v for v in (r.get('variables') or [])} if r else {}
    check('the paused frame reads its variables mid-flight', 't' in got, sorted(got))
    s = send2(cmd='continue')
    until2(lambda m: m.get('seq') == s, timeout=15)

ex2 = until2(lambda m: m.get('event') == 'exited', timeout=60)
check('the paused program runs on to exit', ex2 is not None and ex2.get('exitCode') == 0, str(ex2))
out2, _ = proc2.communicate(timeout=60)
check('and finished its own work after being paused',
      b't=18000003000000' in out2.replace(b'\r\n', b'\n'), repr(out2[:60]))
conn2.close()
srv2.close()

# ---------------------------------------------------------------------------
# THIRD SESSION: A LOOP WHOSE BODY IS ONE LINE.
#
# This shape exists because it caught a regression that nothing else could see.
# When the reader thread began nudging the VM so `pause` could work, it nudged for
# EVERY frame -- including the `continue` that arrives while the program is
# already stopped and already reading its inbox. That nudge then fired at the
# first boundary after the resume, as a pause stop nobody asked for, and the drain
# resumed silently from it.
#
# Harmless when that boundary is an ordinary line. NOT harmless when it is the
# armed one -- and with a ONE-LINE BODY it always is, because the boundary after
# the body is the body again. A three-pass loop reported two stops, in both `for`
# and `while`, while every two-line body was unaffected. 39 protocol assertions
# and both byte-exact suites passed straight through it.
# ---------------------------------------------------------------------------
BAS3 = os.path.join(WORK, 'tight.bas')
with open(BAS3, 'w', newline='\n') as f:
    f.write('t = 0\nfor i = 1 to 3\n  t = t + i\nnext\nprintln "t="; t\nend\n')

srv3 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv3.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv3.bind(('127.0.0.1', 0))
srv3.listen(1)
port3 = srv3.getsockname()[1]
proc3 = subprocess.Popen([EXE, 'debug', '--port', str(port3), BAS3],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
srv3.settimeout(10)
conn3, _ = srv3.accept()
conn3.settimeout(30)

seq3 = [0]
buf3 = [b'']


def send3(**kw):
    seq3[0] += 1
    kw['seq'] = seq3[0]
    conn3.sendall((json.dumps(kw) + '\n').encode('utf-8'))
    return seq3[0]


def recv3(timeout=30):
    conn3.settimeout(timeout)
    while b'\n' not in buf3[0]:
        try:
            chunk = conn3.recv(65536)
        except socket.timeout:
            return None
        if not chunk:
            return None
        buf3[0] += chunk
    line, buf3[0] = buf3[0].split(b'\n', 1)
    return json.loads(line.decode('utf-8'))


def until3(pred, timeout=30, tries=80):
    for _ in range(tries):
        m = recv3(timeout)
        if m is None:
            return None
        if pred(m):
            return m
    return None


s = send3(cmd='initialize')
until3(lambda m: m.get('seq') == s)
# Line 3 is the whole body. Lines 1 and 5 are statements too, so the reply must
# carry exactly what was asked for -- this case is about the COUNT, not filtering.
s = send3(cmd='setBreakpoints', path=BAS3, lines=[3])
r = until3(lambda m: m.get('seq') == s)
check('the single body line is installed', r is not None and r.get('lines') == [3], str(r))
s = send3(cmd='launch')
until3(lambda m: m.get('seq') == s)

tight = 0
gone = False
for _ in range(12):
    ev = until3(lambda m: m.get('event') in ('stopped', 'exited'), timeout=20)
    if ev is None:
        break
    if ev.get('event') == 'exited':
        gone = True
        break
    tight += 1
    s = send3(cmd='continue')
    until3(lambda m: m.get('seq') == s, timeout=20)

check('a one-line loop body stops once per pass, not once less', tight == 3,
      '%d stops' % tight)
check('and the program then exits', gone)
out3, _ = proc3.communicate(timeout=60)
check('having done all three passes of its own work',
      b't=6' in out3.replace(b'\r\n', b'\n'), repr(out3[:40]))
conn3.close()
srv3.close()

# ---------------------------------------------------------------------------
# FOURTH SESSION: THE FIRST EXECUTED STATEMENT, AND A LINE FOR EVERY FRAME.
#
# Two defects PhosphorIDE found by driving this host, both reported on
# 2026-09-16 and both invisible to the 52 assertions above.
#
# (a) A breakpoint on the first EXECUTED STATEMENT was answered installed and
#     never fired. Not line 1: this file's own main fixture opens with a `rem`,
#     so it was line 2 that could not be stopped on -- which is exactly why
#     nobody noticed. Every fixture anyone writes has a comment at the top.
#
#     The mechanism was three sites each right on its own. This host always arms
#     with stop-at-entry, because a stop is the only thread-safe moment to take
#     FRunVM; the engine's DebugPoll tests entry BEFORE breakpoints and guards
#     the second with `if (not stop)`; and OnStop then resumed silently from an
#     entry the editor had not asked for. The user's breakpoint went with it.
#
# (b) stackTrace gave a line only to the innermost frame. The fixtures below are
#     recursive on purpose: every caller is the SAME line, so an off-by-one that
#     reported the callee's line instead of the call site would still look
#     plausible -- `(main)` is what separates them, and it must carry the line of
#     the outermost call and not the function's own.
# ---------------------------------------------------------------------------
BAS4 = os.path.join(WORK, 'first.bas')
with open(BAS4, 'w', newline='\n') as f:
    # Line 1 IS the first statement here -- no comment to hide behind.
    f.write('a = 1\nb = 2\nprintln "s="; a + b\nend\n')

srv4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv4.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv4.bind(('127.0.0.1', 0))
srv4.listen(1)
port4 = srv4.getsockname()[1]
proc4 = subprocess.Popen([EXE, 'debug', '--port', str(port4), BAS4],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
srv4.settimeout(10)
conn4, _ = srv4.accept()
conn4.settimeout(30)

seq4 = [0]
buf4 = [b'']


def send4(**kw):
    seq4[0] += 1
    kw['seq'] = seq4[0]
    try:
        conn4.sendall((json.dumps(kw) + '\n').encode('utf-8'))
    except OSError:
        pass          # the peer is gone; the assertions below say so
    return seq4[0]


def recv4(timeout=30):
    conn4.settimeout(timeout)
    while b'\n' not in buf4[0]:
        try:
            chunk = conn4.recv(65536)
        except socket.timeout:
            return None
        except OSError:
            # A HOST THAT HAS GONE IS NOT A CRASH IN THE HARNESS. After `exited`
            # this host closes the socket, and Windows answers the next recv with
            # WSAECONNABORTED rather than with an orderly zero-length read -- so a
            # session that ends EARLIER than the script expects (which is exactly
            # what a broken fix looks like) killed the script instead of failing
            # its assertions. Seen on 2026-09-16 while watching these very checks
            # fail under a deliberate mutation: two FAILs printed and the
            # remaining six never ran. A harness must be able to report a failure,
            # not only to have one.
            return None
        if not chunk:
            return None
        buf4[0] += chunk
    line, buf4[0] = buf4[0].split(b'\n', 1)
    return json.loads(line.decode('utf-8'))


def until4(pred, timeout=30, tries=60):
    for _ in range(tries):
        m = recv4(timeout)
        if m is None:
            return None
        if pred(m):
            return m
    return None


s = send4(cmd='initialize')
until4(lambda m: m.get('seq') == s)
s = send4(cmd='setBreakpoints', path=BAS4, lines=[1])
r = until4(lambda m: m.get('seq') == s)
check('line 1 is installed when line 1 is a statement',
      r is not None and r.get('lines') == [1], str(r))
s = send4(cmd='launch', stopAtEntry=False)
until4(lambda m: m.get('seq') == s)

ev = until4(lambda m: m.get('event') in ('stopped', 'exited'), timeout=15)
check('a breakpoint on the FIRST executed statement fires',
      ev is not None and ev.get('event') == 'stopped' and ev.get('line') == 1,
      str(ev))
check('and says breakpoint, not entry',
      ev is not None and ev.get('reason') == 'breakpoint', str(ev))
s = send4(cmd='continue')
until4(lambda m: m.get('seq') == s)
ev = until4(lambda m: m.get('event') in ('stopped', 'exited'), timeout=15)
check('it fires ONCE -- the program runs to the end after it',
      ev is not None and ev.get('event') == 'exited', str(ev))
try:
    out4, _ = proc4.communicate(timeout=60)
except subprocess.TimeoutExpired:
    proc4.kill()
    out4 = b''
check('and the program did its own work',
      b's=3' in out4.replace(b'\r\n', b'\n'), repr(out4[:40]))
conn4.close()
srv4.close()

# ONE EVENT, NOT TWO, when the editor asks for BOTH an entry stop and a
# breakpoint on that same first statement. The fix for (a) turns an unasked entry
# into a breakpoint; it must not also turn an ASKED-FOR entry into a second stop.
# Re-arming mid-run produced exactly that shape once before (a three-pass loop
# reporting four stops), so it is pinned here rather than argued about.
srv5 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv5.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv5.bind(('127.0.0.1', 0))
srv5.listen(1)
port5 = srv5.getsockname()[1]
proc5 = subprocess.Popen([EXE, 'debug', '--port', str(port5), BAS4],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
srv5.settimeout(10)
conn5, _ = srv5.accept()
conn5.settimeout(30)
seq4[0] = 0
buf4[0] = b''
conn4 = conn5          # reuse the helpers above on the new socket
s = send4(cmd='initialize')
until4(lambda m: m.get('seq') == s)
s = send4(cmd='setBreakpoints', path=BAS4, lines=[1])
until4(lambda m: m.get('seq') == s)
s = send4(cmd='launch', stopAtEntry=True)
until4(lambda m: m.get('seq') == s)
ev = until4(lambda m: m.get('event') in ('stopped', 'exited'), timeout=15)
check('stopAtEntry plus a breakpoint on that line reports entry',
      ev is not None and ev.get('reason') == 'entry' and ev.get('line') == 1,
      str(ev))
s = send4(cmd='continue')
until4(lambda m: m.get('seq') == s)
ev = until4(lambda m: m.get('event') in ('stopped', 'exited'), timeout=15)
check('and exactly once -- no second stop on the same statement',
      ev is not None and ev.get('event') == 'exited', str(ev))
proc5.communicate(timeout=60)
conn5.close()
srv5.close()

# --- (b) a line for every frame -------------------------------------------
BAS6 = os.path.join(WORK, 'deep.bas')
with open(BAS6, 'w', newline='\n') as f:
    f.write('rem recursion, so the stack has callers to name\n'      # 1
            'function down(n) local r\n'                             # 2
            '  if n <= 0 then\n'                                     # 3
            '    println "bottom"\n'                                 # 4
            '    return 0\n'                                         # 5
            '  endif\n'                                              # 6
            '  r = down(n - 1)\n'                                    # 7
            '  return r + n\n'                                       # 8
            'endfunction\n'                                          # 9
            '\n'                                                     # 10
            'total = down(3)\n'                                      # 11
            'println "total="; total\n'                              # 12
            'end\n')                                                 # 13

srv6 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv6.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv6.bind(('127.0.0.1', 0))
srv6.listen(1)
port6 = srv6.getsockname()[1]
proc6 = subprocess.Popen([EXE, 'debug', '--port', str(port6), BAS6],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
srv6.settimeout(10)
conn6, _ = srv6.accept()
conn6.settimeout(30)
seq4[0] = 0
buf4[0] = b''
conn4 = conn6
s = send4(cmd='initialize')
until4(lambda m: m.get('seq') == s)
s = send4(cmd='setBreakpoints', path=BAS6, lines=[4])
until4(lambda m: m.get('seq') == s)
s = send4(cmd='launch', stopAtEntry=False)
until4(lambda m: m.get('seq') == s)
ev = until4(lambda m: m.get('event') in ('stopped', 'exited'), timeout=15)
check('stopped at the bottom of the recursion',
      ev is not None and ev.get('line') == 4, str(ev))

s = send4(cmd='stackTrace')
r = until4(lambda m: m.get('seq') == s)
fr = (r or {}).get('frames', [])
check('four calls and (main)', len(fr) == 5, '%d frames' % len(fr))
if len(fr) == 5:
    check('the innermost frame carries the stop line',
          fr[0].get('line') == 4, str(fr[0]))
    # `down` calls itself on line 7, so every caller but main is standing there.
    check('every caller carries its own call site',
          [f.get('line') for f in fr[1:4]] == [7, 7, 7],
          str([f.get('line') for f in fr]))
    # THE ASSERTION THAT SEPARATES A RIGHT ANSWER FROM A SHIFTED ONE: main called
    # down from line 11, and down's own body is nowhere near it.
    check('(main) carries the outermost call, not the callee',
          fr[4].get('name') == '(main)' and fr[4].get('line') == 11, str(fr[4]))
    check('no frame is left without a line',
          all(f.get('line', 0) > 0 for f in fr),
          str([f.get('line') for f in fr]))

# The frame index still selects the right activation -- the lines must not have
# come at the cost of what was already right.
s = send4(cmd='variables', frame=3)
r = until4(lambda m: m.get('seq') == s)
vs = {v['name']: v['value'] for v in (r or {}).get('variables', [])}
check('frame 3 is the outermost down, called with 3',
      vs.get('n') == '3', str(vs))

s = send4(cmd='continue')
until4(lambda m: m.get('seq') == s)
until4(lambda m: m.get('event') == 'exited', timeout=15)
out6, _ = proc6.communicate(timeout=60)
check('the recursion produced its own answer',
      b'total=6' in out6.replace(b'\r\n', b'\n'), repr(out6[:60]))
conn6.close()
srv6.close()

# ---------------------------------------------------------------------------
# SEVENTH SESSION: EVALUATE IN A NAMED FRAME, AND THE ONE CALL THAT IS NOT A CALL.
#
# Roadmap item 25's done-when names three cases, and only one of them needs an
# activation: a LOCAL in a named frame. It needs its own session because every
# other fixture in this file stops at the top level.
#
# Three rules are pinned here that nothing else can witness:
#
#  * A LOCAL SHADOWS A GLOBAL OF THE SAME NAME, and the answer depends on which
#    frame was asked. The expected values are derived from the source -- passo(21)
#    sets its own `soma` to 42 while the global stays 1000 -- and never from a run.
#
#  * `a@[i]` REACHES A CALL, because the compiler lowers bracket sugar to
#    `arr_get` (PhosphorCompiler.pas:1035). Every other registered name is
#    refused, so this is the one place a call is allowed and it has to be shown
#    working, or the allowance is untested code.
#
#  * AND THE ALLOWANCE IS SHADOWABLE. opCall asks the program's own functions
#    before the registry, so a program defining `function arr_get(...)` would turn
#    `a@[1]` in a watch box into arbitrary user code. Removing that one guard was
#    measured turning four of these assertions red, which is the only evidence
#    that they can fail at all.
# ---------------------------------------------------------------------------
BAS7 = os.path.join(WORK, 'eval.bas')
with open(BAS7, 'w', newline='\n') as f:
    f.write('rem evaluate, in a frame\n'          # 1
            'const lim = 10\n'                    # 2
            'soma = 1000\n'                       # 3
            'fora$ = "outside"\n'                 # 4
            'lista@ = dim@(3)\n'                  # 5
            'lista@[1] = 10\n'                    # 6
            'lista@[2] = 20\n'                    # 7
            'lista@[3] = 30\n'                    # 8
            'marca = 0\n'                         # 9
            'function arr_get(a@, k)\n'           # 10  shadows the lowering
            '  marca = 999\n'                     # 11
            '  arr_get = -1\n'                    # 12
            'endfunction\n'                       # 13
            'function passo(n) local soma, etapa$\n'   # 14
            '  soma = n * 2\n'                    # 15
            '  etapa$ = "step"\n'                 # 16
            '  parada = 1\n'                      # 17  <- the stop
            '  return soma\n'                     # 18
            'endfunction\n'                       # 19
            'on error goto aqui\n'                # 20
            'resultado = passo(21)\n'             # 21
            'println "resultado="; resultado\n'   # 22
            'println "err="; err(); "/"; errmsg$()\n'   # 23
            'end\n'                               # 24
            'aqui:\n'                             # 25
            'println "THE HANDLER RAN"\n'         # 26
            'resume next\n')                      # 27

srv7 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv7.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv7.bind(('127.0.0.1', 0))
srv7.listen(1)
port7 = srv7.getsockname()[1]
proc7 = subprocess.Popen([EXE, 'debug', '--port', str(port7), BAS7],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
srv7.settimeout(10)
conn7, _ = srv7.accept()
conn7.settimeout(30)
seq7 = [0]
buf7 = [b'']


def send7(**kw):
    seq7[0] += 1
    kw['seq'] = seq7[0]
    try:
        conn7.sendall((json.dumps(kw) + '\n').encode('utf-8'))
    except OSError:
        pass
    return seq7[0]


def until7(pred, timeout=30, tries=60):
    conn7.settimeout(timeout)
    for _ in range(tries):
        while b'\n' not in buf7[0]:
            try:
                chunk = conn7.recv(65536)
            except (socket.timeout, OSError):
                return None
            if not chunk:
                return None
            buf7[0] += chunk
        line, buf7[0] = buf7[0].split(b'\n', 1)
        if not line.strip():
            continue
        m = json.loads(line.decode('utf-8'))
        if pred(m):
            return m
    return None


def ev7(expr, frame=0):
    sN = send7(cmd='evaluate', frame=frame, expr=expr)
    a = until7(lambda m: m.get('seq') == sN)
    if a is None:
        return 'error:no answer'
    if a.get('ok'):
        return '%s:%s' % (a.get('kind'), a.get('result'))
    return 'error:%s' % a.get('error')


s = send7(cmd='initialize')
until7(lambda m: m.get('seq') == s)
s = send7(cmd='setBreakpoints', path=BAS7, lines=[17])   # inside passo
until7(lambda m: m.get('seq') == s)
send7(cmd='launch')
st = until7(lambda m: m.get('event') == 'stopped')
check('stopped inside the function', (st or {}).get('line') == 17, str(st))

check('a LOCAL in a named frame', ev7('etapa$') == 'string:step', ev7('etapa$'))
check('a local shadows a global of the same name',
      ev7('soma') == 'int:42', ev7('soma'))
check('and the same name at (main) is the global',
      ev7('soma', frame=1) == 'int:1000', ev7('soma', frame=1))
check('the parameter', ev7('n') == 'int:21', ev7('n'))
check('a GLOBAL from inside the frame',
      ev7('fora$ + etapa$') == 'string:outsidestep', ev7('fora$ + etapa$'))
# A const reaches NO table at runtime -- the compiler folds it at the use site --
# so an evaluator resolving names against the program's tables would have to
# answer "no such variable". Compiling the whole source gets it right for free.
check('a const, which reaches no table at runtime',
      ev7('lim * 2') == 'int:20', ev7('lim * 2'))
check('a local named from (main) is not there',
      ev7('etapa$', frame=1) == 'error:no variable "etapa$" here',
      ev7('etapa$', frame=1))
check('a frame that is not there is refused',
      ev7('soma', frame=99).startswith('error:'), ev7('soma', frame=99))

# THE SHADOW. This program defines arr_get, so the lowering is refused here.
check('a@[i] is refused where a user function shadows arr_get',
      ev7('lista@[2]', frame=1).startswith('error:'), ev7('lista@[2]', frame=1))
check('  and the refusal names it',
      'arr_get' in ev7('lista@[2]', frame=1), ev7('lista@[2]', frame=1))
check('s$[[n]] still works -- strchar$ is not shadowed here',
      ev7('fora$[[1]]') == 'string:o', ev7('fora$[[1]]'))

s = send7(cmd='variables', frame=0)
r = until7(lambda m: m.get('seq') == s)
vs = {(v['name'], v['scope']): v['value'] for v in (r or {}).get('variables', [])}
check('the frame and the globals are untouched by all of that',
      vs.get(('soma', 'local')) == '42' and vs.get(('soma', 'global')) == '1000'
      and vs.get(('marca', 'global')) == '0', str(vs))

# AN `ON ERROR` HANDLER IS INSTALLED AND IT MUST NOT HAVE FIRED. This is the
# shape the whole thing turns on. Evaluating `soma / 0` above raised a real
# division-by-zero, and a design that ran it in the debuggee's own VM would have
# dispatched it to the program's handler -- running the program's own code from
# inside a watch box, and leaving err()/errmsg$() answering the DEBUGGER's fault
# to the resumed script. A fault in a VM the host created and freed reaches
# neither: the handler pc, the handler flag and the three error fields all belong
# to the VM object that was thrown away.
#
# It is also the exact shape that hid a defect. TPhosphorVM.Create left
# FErrHandler at 0 -- a valid pc -- so a fresh VM carried a phantom handler, and a
# fault in an evaluation jumped to instruction 0 and re-ran the program from the
# top. See probe_bytecode's CheckFreshVMHasNoHandler.
sX = send7(cmd='evaluate', frame=0, expr='soma / 0')
rX = until7(lambda m: m.get('seq') == sX)
check('a faulting evaluation is reported, not handled',
      (rX or {}).get('ok') is False
      and 'division by zero' in ((rX or {}).get('error') or ''), str(rX))

s = send7(cmd='continue')
until7(lambda m: m.get('seq') == s)
until7(lambda m: m.get('event') == 'exited', timeout=15)
out7, _ = proc7.communicate(timeout=60)
clean7 = out7.replace(b'\r\n', b'\n')
check('the program ran on to its own answer',
      b'resultado=42' in clean7, repr(clean7[:80]))
check("the program's own ON ERROR handler never ran",
      b'THE HANDLER RAN' not in clean7, repr(clean7[:120]))
check('and err()/errmsg$() answer nothing at all afterwards',
      b'err=0/\n' in clean7 or b'err=0/' in clean7, repr(clean7[:120]))
conn7.close()
srv7.close()

# ---------------------------------------------------------------------------
# EIGHTH SESSION: A BREAKPOINT WITH A CONDITION.
#
# The fixture is a loop with a mark on its body, because a condition only means
# anything on a line that is hit more than once.
#
# FOUR RULES ARE PINNED HERE AND EACH ONE IS A DECISION THAT COULD HAVE GONE THE
# OTHER WAY:
#
#  * A condition that is FALSE is not a stop, and the editor is told nothing --
#    no event, no round trip. That is the whole point of doing this in the host.
#
#  * A condition that DOES NOT COMPILE is refused in the setBreakpoints REPLY,
#    with the line it was typed on, and the breakpoint is installed UNCONDITIONAL.
#    Refusing at reply time is what lets an editor put the message beside the line
#    while the person is still looking at it; installing it unconditional is the
#    lesser of two evils, because a mark that is visible and never honoured is
#    worse than one that fires too often.
#
#  * A condition that compiles and then CANNOT BE EVALUATED -- a name that is not
#    in scope at that line -- STOPS, and says why in the stop event's `text`. It
#    cannot be caught at reply time because scope is a frame and there is no frame
#    yet. Stopping puts the mistake in front of the person who made it; the
#    alternative is a breakpoint that silently never fires.
#
#  * A condition that is not a BOOLEAN is the same case. `if` in this language
#    refuses a non-boolean outright, so `i% + 1` as a condition is not a
#    truthiness question a debugger gets to answer differently from the language.
# ---------------------------------------------------------------------------
BAS8 = os.path.join(WORK, 'cond.bas')
with open(BAS8, 'w', newline='\n') as f:
    f.write('rem a loop with a conditional breakpoint\n'   # 1
            'total = 0\n'                                  # 2
            'for i = 1 to 20\n'                            # 3
            '  total = total + i\n'                        # 4  <- the mark
            'next\n'                                       # 5
            'println "total="; total\n')                    # 6
COND_LINE = 4


def cond_session(condition, label):
    """One whole session with one conditional breakpoint. Answers
    (reply, [stop events], stdout)."""
    srv8 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv8.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv8.bind(('127.0.0.1', 0))
    srv8.listen(1)
    p8 = srv8.getsockname()[1]
    pr = subprocess.Popen([EXE, 'debug', '--port', str(p8), BAS8],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    srv8.settimeout(15)
    c8, _ = srv8.accept()
    c8.settimeout(30)
    buf8 = [b'']
    sq = [0]

    def snd(**kw):
        sq[0] += 1
        kw['seq'] = sq[0]
        try:
            c8.sendall((json.dumps(kw) + '\n').encode('utf-8'))
        except OSError:
            pass
        return sq[0]

    def frm(until_seq=None, until_event=None, limit=120):
        out = []
        for _ in range(limit):
            while b'\n' not in buf8[0]:
                try:
                    chunk = c8.recv(65536)
                except (socket.timeout, OSError):
                    return out
                if not chunk:
                    return out
                buf8[0] += chunk
            line, buf8[0] = buf8[0].split(b'\n', 1)
            if not line.strip():
                continue
            m = json.loads(line.decode('utf-8'))
            out.append(m)
            if until_seq is not None and m.get('seq') == until_seq:
                return out
            if until_event is not None and m.get('event') == until_event:
                return out
        return out

    s = snd(cmd='initialize')
    frm(until_seq=s)
    payload = dict(cmd='setBreakpoints', path=BAS8, lines=[COND_LINE])
    if condition is not None:
        payload['conditions'] = [condition]
    s = snd(**payload)
    reply = {}
    for m in frm(until_seq=s):
        if m.get('seq') == s:
            reply = m
    snd(cmd='launch')
    stops = []
    for _ in range(40):
        got = frm(until_event='stopped', limit=40)
        st = [m for m in got if m.get('event') == 'stopped']
        if [m for m in got if m.get('event') == 'exited'] or not st:
            break
        stops.append(st[0])
        sc = snd(cmd='continue')
        frm(until_seq=sc)
    out8 = pr.communicate(timeout=30)[0].replace(b'\r\n', b'\n')
    c8.close()
    srv8.close()
    return reply, stops, out8


r8, st8, o8 = cond_session(None, 'no condition')
check('a mark with no condition stops on every pass', len(st8) == 20, str(len(st8)))
check('  and the reply has nothing to reject', 'rejected' not in r8, str(r8))

r8, st8, o8 = cond_session('i = 7', 'true once')
check('a condition true once stops once', len(st8) == 1, str(len(st8)))
check('  on the pass it names', st8 and st8[0].get('line') == COND_LINE, str(st8[:1]))
check('  and the program still finishes its own work',
      b'total=210' in o8, repr(o8[:40]))

r8, st8, o8 = cond_session('i > 99', 'never true')
check('a condition never true never stops', len(st8) == 0, str(len(st8)))
check('  and the program runs to the end anyway', b'total=210' in o8, repr(o8[:40]))

r8, st8, o8 = cond_session('i >', 'does not compile')
rj = r8.get('rejected') or []
check('a condition that does not compile is refused in the REPLY',
      len(rj) == 1, str(r8))
check('  naming the line it was typed on',
      rj and rj[0].get('line') == COND_LINE, str(rj))
check('  and quoting the condition back', rj and rj[0].get('condition') == 'i >', str(rj))
check('  with the host\'s own wording',
      rj and 'unexpected token' in (rj[0].get('error') or ''), str(rj))
check('  and the breakpoint is installed UNCONDITIONAL, not dropped',
      r8.get('lines') == [COND_LINE] and len(st8) == 20, '%s %d' % (r8.get('lines'), len(st8)))

r8, st8, o8 = cond_session('len("ab") > 1', 'calls a function')
rj = r8.get('rejected') or []
check('a condition that calls a function is refused too', len(rj) == 1, str(r8))
check('  and the refusal names the function', rj and '"len"' in (rj[0].get('error') or ''), str(rj))

r8, st8, o8 = cond_session('nosuch% = 1', 'a name nobody has')
check('a name out of scope CANNOT be caught at reply time',
      'rejected' not in r8, str(r8))
check('  so it stops instead of firing silently', len(st8) == 20, str(len(st8)))
check('  and the stop says why',
      st8 and 'nosuch%' in (st8[0].get('text') or ''), str(st8[:1]))

r8, st8, o8 = cond_session('i + 1', 'not a boolean')
check('a condition that is not a boolean stops', len(st8) == 20, str(len(st8)))
check('  and says that is what it is',
      st8 and 'not a true or false' in (st8[0].get('text') or ''), str(st8[:1]))

# ---------------------------------------------------------------------------
# A FRAME ARRIVING MID-RUN, WITH A BREAKPOINT ACTUALLY ARMED.
#
# The second session above sends `setBreakpoints ... lines=[]` at the only moment
# a frame reaches a RUNNING program, and the third arms a line but sends nothing
# while it runs. So the one construction that matters -- a frame landing on a
# boundary the editor had marked -- was covered by neither, and a defect that
# lost roughly a quarter of all breakpoint hits under ordinary editor traffic sat
# under a green suite.
#
# DebugPoll decided the reason by source order rather than by specificity: the
# interrupt a frame sets was tested before the armed line and before a pending
# step, and each later test carried `if (not stop)`. So a frame arriving on an
# armed boundary reported `pause`, the host's drain saw nothing that asked to
# stop, and resumed -- and because the flag is consumed in the same operation,
# the hit was gone rather than deferred.
#
# Measured on the build before the repair: 762, 751 and 753 stops out of 1000
# with one unrelated frame every half millisecond. The program finished all 1000
# iterations every time; only the stops vanished.
# ---------------------------------------------------------------------------
BAS4 = os.path.join(WORK, 'traffic.bas')
with open(BAS4, 'w', newline='\n') as f:
    f.write('t = 0\nfor i = 1 to 40\n  t = t + i\n  u = t\nnext\nprintln "t="; t\nend\n')

srv4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv4.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv4.bind(('127.0.0.1', 0))
srv4.listen(1)
port4 = srv4.getsockname()[1]
proc4 = subprocess.Popen([EXE, 'debug', '--port', str(port4), BAS4],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
srv4.settimeout(10)
conn4, _ = srv4.accept()
conn4.settimeout(30)

seq4 = [0]
buf4 = [b'']


def send4(**kw):
    seq4[0] += 1
    kw['seq'] = seq4[0]
    conn4.sendall((json.dumps(kw) + '\n').encode('utf-8'))
    return seq4[0]


def recv4(timeout=30):
    conn4.settimeout(timeout)
    while b'\n' not in buf4[0]:
        try:
            chunk = conn4.recv(65536)
        except socket.timeout:
            return None
        if not chunk:
            return None
        buf4[0] += chunk
    line, buf4[0] = buf4[0].split(b'\n', 1)
    return json.loads(line.decode('utf-8'))


def until4(pred, timeout=30, tries=200):
    for _ in range(tries):
        m = recv4(timeout)
        if m is None:
            return None
        if pred(m):
            return m
    return None


s = send4(cmd='initialize')
until4(lambda m: m.get('seq') == s)
# Line 3 is armed and the loop runs 40 passes, so 40 stops are owed.
s = send4(cmd='setBreakpoints', path=BAS4, lines=[3])
r = until4(lambda m: m.get('seq') == s)
check('the traffic fixture arms its line', r is not None and r.get('lines') == [3], str(r))
s = send4(cmd='launch', stopAtEntry=False)
until4(lambda m: m.get('seq') == s)

# THE TRAFFIC HAS TO ARRIVE WHILE THE PROGRAM RUNS, and answering a stop is not
# that. The reader deliberately does not nudge a VM that is parked in the seam
# (host/console/phosphor.lpr:1388, the 2026-09-15 repair), so every `continue`
# lands on a stopped program and sets no interrupt at all. Written that way first,
# this case PASSED against the binary that loses a quarter of its hits -- a test
# that cannot fail, which is the class this suite exists to refuse.
#
# So a second thread sends an unrelated frame every half millisecond while the
# program is running. `ping` is not a command this host knows; it is answered with
# a refusal, changes no state, and its only effect is the one that matters -- the
# reader parses a line and nudges the VM. That nudge is what used to land on the
# armed boundary and erase the hit.
#
# Its seq numbers start at 900000 so they cannot collide with the session's, and
# it writes straight to the socket rather than through send4, which would race on
# the shared counter.
noise_stop = threading.Event()


def noise4():
    n = 900000
    while not noise_stop.is_set():
        n += 1
        try:
            conn4.sendall((json.dumps({'seq': n, 'cmd': 'ping'}) + chr(10)).encode('utf-8'))
        except Exception:
            return
        time.sleep(0.0005)


hits = 0
gone4 = False
noise_thread = threading.Thread(target=noise4, daemon=True)
noise_thread.start()
for _ in range(120):
    ev = until4(lambda m: m.get('event') in ('stopped', 'exited'), timeout=20)
    if ev is None:
        break
    if ev.get('event') == 'exited':
        gone4 = True
        break
    if ev.get('reason') == 'breakpoint' and ev.get('line') == 3:
        hits += 1
    s = send4(cmd='continue')
    until4(lambda m: m.get('seq') == s, timeout=20)

noise_stop.set()
noise_thread.join(timeout=2)
check('a hot breakpoint keeps every hit while frames arrive mid-run', hits == 40,
      '%d of 40' % hits)
check('and the program then exits', gone4)
out4, _ = proc4.communicate(timeout=60)
check('having done all forty passes of its own work',
      b't=820' in out4.replace(b'\r\n', b'\n'), repr(out4[:40]))
conn4.close()
srv4.close()

# ---------------------------------------------------------------------------
# A STEP ASKED FOR AFTER A PAUSE.
#
# The file sends no step command at all today -- `stepOver`, `stepInto` and
# `stepOut` appear once between them, in the capabilities check. The pending step
# was guarded out by the same `if (not stop)` as the armed line, and a host cannot
# repair that half from outside: FDbgMode is private to the VM with no accessor.
# ---------------------------------------------------------------------------
srv5 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv5.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv5.bind(('127.0.0.1', 0))
srv5.listen(1)
port5 = srv5.getsockname()[1]
proc5 = subprocess.Popen([EXE, 'debug', '--port', str(port5), BAS2],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
srv5.settimeout(10)
conn5, _ = srv5.accept()
conn5.settimeout(30)

seq5 = [0]
buf5 = [b'']


def send5(**kw):
    seq5[0] += 1
    kw['seq'] = seq5[0]
    conn5.sendall((json.dumps(kw) + '\n').encode('utf-8'))
    return seq5[0]


def recv5(timeout=30):
    conn5.settimeout(timeout)
    while b'\n' not in buf5[0]:
        try:
            chunk = conn5.recv(65536)
        except socket.timeout:
            return None
        if not chunk:
            return None
        buf5[0] += chunk
    line, buf5[0] = buf5[0].split(b'\n', 1)
    return json.loads(line.decode('utf-8'))


def until5(pred, timeout=30, tries=200):
    for _ in range(tries):
        m = recv5(timeout)
        if m is None:
            return None
        if pred(m):
            return m
    return None


s = send5(cmd='initialize')
until5(lambda m: m.get('seq') == s)
s = send5(cmd='setBreakpoints', path=BAS2, lines=[])
until5(lambda m: m.get('seq') == s)
s = send5(cmd='launch', stopAtEntry=False)
until5(lambda m: m.get('seq') == s)

s = send5(cmd='pause')
until5(lambda m: m.get('seq') == s, timeout=15)
paused = until5(lambda m: m.get('event') in ('stopped', 'exited'), timeout=15)
check('the loop fixture pauses', paused is not None and paused.get('event') == 'stopped',
      str(paused))

if paused and paused.get('event') == 'stopped':
    s = send5(cmd='stepOver')
    r = until5(lambda m: m.get('seq') == s, timeout=15)
    check('stepOver is accepted after a pause', r is not None and r.get('ok') is True, str(r))
    ev = until5(lambda m: m.get('event') in ('stopped', 'exited'), timeout=15)
    # The step must land, and land as a STEP. Before the precedence repair the
    # host was handed `pause` here -- the step had been skipped and the editor was
    # told its Step Over did not happen.
    check('a step after a pause stops, and says it was a step',
          ev is not None and ev.get('event') == 'stopped' and ev.get('reason') == 'step',
          str(ev))
    if ev and ev.get('event') == 'stopped':
        s = send5(cmd='disconnect', terminate=True)
        until5(lambda m: m.get('seq') == s, timeout=10)

try:
    proc5.wait(timeout=30)
except Exception:
    proc5.kill()
conn5.close()
srv5.close()

print('')
print('PASS %d   FAIL %d' % (len(ok), len(bad)))
if bad:
    print('failed: ' + ', '.join(bad))
sys.exit(1 if bad else 0)
