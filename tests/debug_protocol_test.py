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
check('capabilities present', isinstance(caps, dict) and len(caps) == 5, str(caps))
check('evaluate is false in v1', caps.get('evaluate') is False, str(caps))
check('stepOut and pause offered', caps.get('stepOut') and caps.get('pause'), str(caps))

# 2. setBreakpoints before launch
s2 = send(cmd='setBreakpoints', path=BAS, lines=[11])
r = [f for f in frames(until_seq=s2) if f.get('seq') == s2][0]
check('setBreakpoints answers the set', r.get('ok') is True and r.get('lines') == [11], str(r))

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

# 7. evaluate is refused because the capability says false
s7 = send(cmd='evaluate', frame=0, expr='1+1')
r = [f for f in frames(until_seq=s7) if f.get('seq') == s7][0]
check('evaluate refused, matching its capability', r.get('ok') is False, str(r))

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
print('')
print('PASS %d   FAIL %d' % (len(ok), len(bad)))
if bad:
    print('failed: ' + ', '.join(bad))
sys.exit(1 if bad else 0)
