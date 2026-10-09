#!/usr/bin/env python3
"""A GENERATED sweep of HTTP responses: every shape, cut at every structural point,
ended every way, over plain HTTP and TLS -- each verdict derived from how the
case was BUILT, never from a run.

WHY IT EXISTS (2026-10-08). Four adversarial rounds in one day found the same
class over and over, one instance per round: an answer that did not arrive whole
handed back as if it had -- a body short of its Content-Length, a chunked body
before its last chunk, headers cut by the close (with 4096 bytes FPC's buffer
held), a TLS record trickled inside itself. Each was a case somebody thought
of. docs/proof-axes.md rule 0.1: a sweep is GENERATED, not chosen. This one
crosses the axes instead of picking points on them.

THE REFERENCE is RFC 9112, applied to the bytes each case sends:
  * the headers are complete only if the blank line was sent;
  * a Content-Length body is complete when that many bytes were sent -- what
    the peer does afterwards does not matter, the client has stopped reading;
  * a chunked body is complete when the last chunk and its CRLF were sent;
  * a body with neither ends at the close, so it is complete only when the
    close is a clean one: a FIN (6.3), and over TLS a close_notify first --
    an abrupt TLS close is an "incomplete close" (9.8), which a client may
    accept only for a body whose length it knew.
An incomplete answer is http_error() 5 when the peer closed or reset (it broke
off); when it went SILENT, 4 if the run's deadline cut it and 5 if the client's
own response timeout did. A complete one is a status of 200, the exact body,
and error 0. Every request must end inside a second and a half -- a case with
the right verdict that ran late is run once more and judged on that run, because
a whole machine can stall (see main); a wrong verdict is never run again.

TWO MODES, because a host takes one of two paths and they share almost no code:
  * deadline -- the run has a budget, so every request runs under a deadline
    (one second here, through the http_test_deadline seam) and reads through
    the library's own non-blocking loop. A budgeted host: the test runners,
    the embedding sample.
  * client   -- NO deadline, and the client's own one-second response timeout:
    the path FPC's handlers read on, and the one the console host takes when
    it runs a script, because it installs no budget. The first version of this
    sweep ran only the first mode, and the second held a defect of its own.

Usage: http_sweep.py <phosphorhttptest> [--list]
Exit 0 when every verdict matches; 1 with each mismatch named.
"""
import os
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, 'tests', 'packages')
BODY = b'0123456789abcdefghij'          # 20 bytes, distinct, so a wrong slice shows
DEADLINE_MS = 1000
BOUND_MS = 1500


# --- the shapes --------------------------------------------------------------
def shapes():
    """name -> (response bytes, framing, index where the body starts, the body
    bytes, the index where the message is COMPLETE). Built here, so every cut
    point below is a position in a message this file wrote."""
    out = {}
    head = b'HTTP/1.1 200 OK\r\nX-Pad: ' + b'p' * 40 + b'\r\nConnection: close\r\n'
    # Content-Length, exact
    h = head + b'Content-Length: %d\r\n\r\n' % len(BODY)
    out['cl'] = (h + BODY, 'cl', len(h), BODY, len(h) + len(BODY))
    # Content-Length that promises more than is ever sent
    h = head + b'Content-Length: %d\r\n\r\n' % (len(BODY) + 30)
    out['cl_short'] = (h + BODY, 'cl', len(h), None, None)
    # chunked, two chunks and the last
    h = head + b'Transfer-Encoding: chunked\r\n\r\n'
    body = b'a\r\n' + BODY[:10] + b'\r\n' + b'a\r\n' + BODY[10:] + b'\r\n' + b'0\r\n\r\n'
    out['chunked'] = (h + body, 'chunked', len(h), BODY, len(h) + len(body))
    # close-delimited: no length, no chunking
    h = head + b'\r\n'
    out['close'] = (h + BODY, 'close', len(h), BODY, None)
    return out


def cut_points(name, data, body_at):
    """(label, index): where the stream stops. 'whole' sends everything."""
    pts = [('status', 9), ('header', body_at - 20), ('before_blank', body_at - 2),
           ('after_headers', body_at)]
    if name.startswith('chunked'):
        pts += [('chunk_size', body_at + 1), ('chunk_data', body_at + 6),
                ('before_last', len(data) - 5)]
    else:
        pts += [('body', body_at + 7)]
    pts.append(('whole', len(data)))
    return pts


def expected(name, data, body_at, body, complete_at, cut, end, tls, mode):
    """The verdict RFC 9112 gives the bytes [0, cut) followed by `end`:
    ('ok', body) | ('err', 4) | ('err', 5)."""
    silent = 4 if mode == 'deadline' else 5
    headers_done = cut >= body_at
    if headers_done and complete_at is not None and cut >= complete_at:
        return ('ok', body)                       # length known, all of it here
    if headers_done and name == 'close':
        # A close-delimited body IS whatever came before the close -- at ANY cut
        # after the headers -- provided the close is a clean one. (The first
        # draft of this reference expected the whole BODY only at the whole
        # message, and called seven correct answers wrong.)
        if end == 'fin':
            return ('ok', data[body_at:cut])
        return ('err', silent if end == 'silent' else 5)
    return ('err', silent if end == 'silent' else 5)


def cases():
    out = []
    for name, (data, framing, body_at, body, complete_at) in sorted(shapes().items()):
        for label, cut in cut_points(name, data, body_at):
            for tls in (False, True):
                ends = ['fin', 'rst', 'silent'] + (['abrupt'] if tls else [])
                for end, mode in [(e, m) for e in ends for m in ('deadline', 'client')]:
                    exp = expected(name, data, body_at, body, complete_at, cut, end, tls, mode)
                    # A RESET after a COMPLETE message races the client's last read:
                    # whether the data or the reset arrives first is the kernel's.
                    # The verdict would be the race's, so the case is not made.
                    if end == 'rst' and exp[0] == 'ok':
                        continue
                    cid = '%s.%s.%s.%s.%s' % (name, label, 'tls' if tls else 'plain', end, mode)
                    out.append((cid, data[:cut], end, tls, exp, mode))
    return out


# --- the peer ----------------------------------------------------------------
CASES = {}


def read_head(c):
    d = b''
    while b'\r\n\r\n' not in d:
        x = c.recv(4096)
        if not x:
            break
        d += x
    return d


def serve_plain(c):
    try:
        h = read_head(c)
        cid = h.split(b' ', 2)[1].decode()[1:]
        data, end = CASES[cid][0], CASES[cid][1]
        c.sendall(data)
        if end == 'silent':
            time.sleep(DEADLINE_MS / 1000.0 + 1.0)
        elif end == 'rst':
            c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        else:
            c.shutdown(socket.SHUT_WR)
            time.sleep(0.2)
        c.close()
    except Exception:
        c.close()


def serve_tls(c, ctx):
    """Every end acts on the TLS socket itself. `wrap_socket` DETACHES the plain
    one, so closing it does nothing -- the first draft of this peer did that, and
    its resets and abrupt closes were really the connection lingering until the
    thread was collected, which the client saw as silence (and answered 4)."""
    t = None
    try:
        t = ctx.wrap_socket(c, server_side=True)
        t.settimeout(5)
        h = read_head(t)
        cid = h.split(b' ', 2)[1].decode()[1:]
        data, end = CASES[cid][0], CASES[cid][1]
        if data:
            t.sendall(data)
        if end == 'silent':
            time.sleep(DEADLINE_MS / 1000.0 + 1.0)
            t.close()
        elif end == 'rst':
            t.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
            t.close()
        elif end == 'abrupt':
            t.close()                             # a FIN with no close_notify before it
        else:
            raw = t.unwrap()                      # close_notify, then the FIN
            raw.shutdown(socket.SHUT_WR)
            time.sleep(0.2)
            raw.close()
    except Exception:
        if t is not None:
            try:
                t.close()
            except Exception:
                pass
        else:
            c.close()


def listener(handler, *extra):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', 0))
    s.listen(64)

    def loop():
        while True:
            c, _ = s.accept()
            threading.Thread(target=handler, args=(c,) + extra, daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()
    return s.getsockname()[1]


# --- the program the host runs -----------------------------------------------
def program(order, plain_port, tls_port, out_rel):
    q = chr(34)
    lines = ['rem GENERATED by tests/http_sweep.py -- one request per case, results to a file',
             'ca$ = http_ca_file$(' + q + os.path.join(PKG, 'tls_test_ca.pem').replace(chr(92), '/') + q + ')',
             'open ' + q + out_rel + q + ' for output as #1']
    for cid in order:
        tls, mode = CASES[cid][2], CASES[cid][4]
        base = ('https' if tls else 'http') + '://127.0.0.1:%d' % (tls_port if tls else plain_port)
        if mode == 'deadline':
            lines += ['x = http_test_deadline(%d)' % DEADLINE_MS,
                      't0 = now()',
                      'b$ = http_get$(' + q + base + '/' + cid + q + ')',
                      'e = http_error()']
        else:
            # -1: no deadline at all, as under a host with no budget
            lines += ['x = http_test_deadline(-1)',
                      'c@ = http_client@(' + q + base + q + ')',
                      'x = http_responsetimeout(c@, %d)' % DEADLINE_MS,
                      't0 = now()',
                      'b$ = http_get$(c@, ' + q + '/' + cid + q + ')',
                      'e = http_error()',
                      'x = http_free(c@)']
        lines += ['ms = millisecondsbetween(now(), t0)',
                  'x = http_test_deadline(0)',
                  'println #1, ' + q + cid + '|' + q + ' + str$(e) + ' + q + '|' + q +
                  ' + str$(ms) + ' + q + '|' + q + ' + b$']
    lines.append('close #1')
    return '\n'.join(lines) + '\n'


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    unknown = [a for a in sys.argv[2:] if a != '--list']
    if unknown:
        print('http_sweep.py: unknown argument %s' % unknown[0])
        return 2
    exe = os.path.abspath(sys.argv[1])
    for cid, data, end, tls, exp, mode in cases():
        CASES[cid] = (data, end, tls, exp, mode)
    if '--list' in sys.argv[2:]:
        for cid in sorted(CASES):
            print(cid, CASES[cid][3])
        return 0

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(PKG, 'tls_test_ip_cert.pem'),
                        os.path.join(PKG, 'tls_test_ip_key.pem'))
    plain_port = listener(serve_plain)
    tls_port = listener(serve_tls, ctx)

    order = sorted(CASES)
    # Named per process: two runs at once (two worktrees, two runners) must not
    # share a scratch file -- the PowerShell runners lost runs to exactly that.
    # A batch that fails leaves its program behind in bin/, as the evidence.
    out_rel = 'bin/http_sweep.%d.out' % os.getpid()
    paths = (out_rel, os.path.join(ROOT, out_rel),
             os.path.join(ROOT, 'bin', 'http_sweep.%d.bas' % os.getpid()))
    got, fail = run_cases(exe, order, plain_port, tls_port, paths)
    if fail:
        print(fail)
        return 1

    # A case whose VERDICT was right but which ran past the bound is run ONCE
    # more, and judged on that run. Measured 2026-10-08 on the Linux VM: a
    # process sleeping 10 ms there woke 2633 ms later, fourteen stalls over
    # 200 ms in seven minutes -- the whole machine stops, and a request that
    # straddles it reads as a request that waited. A wait the CODE makes comes
    # back every time (the double response timeout this sweep found took two
    # seconds on every run); a stall does not. A wrong verdict is never re-run.
    late = [cid for cid in order if cid in got and judge(cid, got[cid]) == 'late']
    if late:
        again, fail = run_cases(exe, late, plain_port, tls_port, paths)
        if fail:
            print(fail)
            return 1
        got.update(again)
    os.remove(paths[2])

    bad = []
    for cid in order:
        if cid not in got:
            bad.append('%s: no result' % cid)
            continue
        if judge(cid, got[cid]) != 'ok':
            err, ms, body = got[cid]
            bad.append('%s: wanted %s; got error %d, %d bytes, %d ms'
                       % (cid, wanted(cid), err, len(body), ms))
    if bad:
        print('FAIL  http sweep: %d of %d cases disagree with RFC 9112' % (len(bad), len(order)))
        for b in bad:
            print('        ' + b)
        return 1
    print('PASS  http sweep: %d generated cases -- %d shapes, every cut point, '
          'fin/rst/silent (and an abrupt TLS close), plain and TLS, under a deadline '
          'and without one -- all as RFC 9112 says%s'
          % (len(order), len(shapes()),
             ' (%d ran past %d ms once and were bounded when run again)' % (len(late), BOUND_MS)
             if late else ''))
    return 0


def wanted(cid):
    exp = CASES[cid][3]
    if exp[0] == 'ok':
        return 'complete: the %d-byte body, error 0, inside %d ms' % (len(exp[1]), BOUND_MS)
    return 'no body, error %d, inside %d ms' % (exp[1], BOUND_MS)


def judge(cid, result):
    """'ok', 'late' (the right verdict past the bound) or 'wrong'."""
    err, ms, body = result
    exp = CASES[cid][3]
    if exp[0] == 'ok':
        right = err == 0 and body == exp[1]
    else:
        right = err == exp[1] and body == b''
    if not right:
        return 'wrong'
    return 'ok' if ms < BOUND_MS else 'late'


def run_cases(exe, order, plain_port, tls_port, paths):
    """Run `order` through the host; answers ({cid: (err, ms, body)}, failure line or '')."""
    out_rel, out, bas = paths
    # IN BATCHES, because the runner is budgeted (MaxSteps 1000000, about 25.6 s of
    # waiting) and a network wait is charged to it: one process for all the
    # silent cases would spend its budget halfway and refuse the rest. A batch
    # holds at most 15 cases that wait out the deadline.
    batches, cur, waits = [], [], 0
    for cid in order:
        w = 1 if CASES[cid][1] == 'silent' else 0
        if cur and waits + w > 15:
            batches.append(cur)
            cur, waits = [], 0
        cur.append(cid)
        waits += w
    if cur:
        batches.append(cur)
    got = {}
    for batch in batches:
        with open(bas, 'w', newline='\n') as f:
            f.write(program(batch, plain_port, tls_port, out_rel))
        if os.path.exists(out):
            os.remove(out)
        budget = 60 + len(batch) * 4
        try:
            r = subprocess.run([exe, bas], cwd=ROOT, capture_output=True, timeout=budget,
                               stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return got, ('FAIL  http sweep: the host did not finish a batch of %d cases in %d s'
                         % (len(batch), budget))
        if not os.path.exists(out):
            return got, ('FAIL  http sweep: the host wrote no results (exit %d): %s'
                         % (r.returncode, r.stderr.decode('utf-8', 'replace')[-400:]))
        with open(out, 'rb') as f:
            for line in f.read().decode('latin-1').splitlines():
                parts = line.split('|', 3)
                if len(parts) == 4:
                    got[parts[0]] = (int(parts[1]), int(parts[2]), parts[3].encode('latin-1'))
        os.remove(out)
    return got, ''


if __name__ == '__main__':
    sys.exit(main())
