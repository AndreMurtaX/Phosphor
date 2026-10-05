#!/usr/bin/env python3
"""What does an INTERRUPTED `phosphor pack` leave at the output name?

WHY THIS IS A SEPARATE PROBE AND NOT A SUITE BLOCK. The defect it measures is
only observable by killing the process mid-write, and a pack is about 30 ms, so
the kill has to land at a random offset inside it. That is a race, and a racing
assertion in a runner is a flake on its way to being switched off -- this tree
spent three attempts on one such case in September, and the second attempt was
green, deterministic, and measured NOTHING; only mutating the code found that out.
So the race lives here, where a person runs it on purpose, and block U of
scripts/test.ps1 (and its bash twin) pins the deterministic properties instead.

AND BLOCK U DOES NOT PIN THE DEFECT, which is measured rather than assumed: with
the repair reverted to packing straight into the final name, block U still passes.
This probe is what distinguishes the two builds. If you change PackFile, run this.

WHAT IT MEASURES. `pack` writes the stub, then the payload, then the trailer, and
stamps the packed-mark LAST, because half of what that mark records is the
finished length. Before 2026-10-04 all of it went straight into the name the user
asked for, so between the stub landing and the trailer being written the file at
that name was a BARE STUB -- and a bare stub is the CLI by design: an interpreter
prompt that reads EOF and exits 0. A crash, a Ctrl+C or a full disk in that window
replaced an application with something that runs and succeeds having done nothing
that was asked.

MEASURED, 2026-10-04, Windows, 80 trials inside a 0.027 s pack:

    before the repair   4 left a REPL at the output name
    after               0
    mutated back        3 of 60 (the repair reverted; this probe still catches it)
    Linux, after        0 of 60

The size named the window exactly: 4,942,336 bytes against a complete 4,942,519,
short by the 151-byte payload and the 32-byte trailer.

SAFETY, because this writes executables and then runs them:
  * every path it touches is under the directory given by --work (a fresh
    temporary directory by default) and nowhere else;
  * a leftover is run with stdin from DEVNULL and a timeout, ALWAYS. A bare stub
    IS the CLI, and the CLI with no arguments and a live stdin is a REPL that
    never exits and locks its own executable;
  * nothing is ever removed recursively. One named file is overwritten per trial.

    python tests/pack_interrupt_probe.py bin/phosphor.exe [trials]

Exits non-zero if any trial left something at the output name that runs and is not
the application.
"""
import os
import random
import subprocess
import sys
import tempfile
import time

MARKER = 'HELLO FROM THE PACKED APP'


def build_fixture(exe, work):
    bas = os.path.join(work, 'probe.bas')
    pbc = os.path.join(work, 'probe.pbc')
    with open(bas, 'w', newline='\n') as f:
        f.write('println "%s"\nend\n' % MARKER)
    r = subprocess.run([exe, 'compile', bas, pbc], stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=120)
    if r.returncode != 0:
        raise SystemExit('compile failed: %s' % r.stderr[:200])
    return pbc


def clean_pack_seconds(exe, pbc, work):
    """How long a whole pack takes, so the kill lands INSIDE one.

    Derived from the thing it measures rather than hard-coded: a fixed sleep that
    happened to be longer than a pack would make every trial a no-op and the probe
    would report clean for ever.
    """
    best = None
    for i in range(3):
        out = os.path.join(work, 'timing%d.out' % i)
        t0 = time.time()
        r = subprocess.run([exe, 'pack', pbc, out], stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=120)
        el = time.time() - t0
        if r.returncode != 0:
            raise SystemExit('a clean pack failed: %s' % r.stderr[:200])
        if best is None or el < best:
            best = el
    return best


def classify(path):
    """What IS the file sitting at the output name?"""
    if not os.path.exists(path):
        return 'absent', 0, None, b''
    size = os.path.getsize(path)
    if size == 0:
        return 'empty', 0, None, b''
    try:
        r = subprocess.run([path], stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=25)
    except subprocess.TimeoutExpired:
        return 'HUNG', size, None, b''
    except OSError:
        # not executable: on Unix a temporary that never reached the move
        return 'not-executable', size, None, b''
    out = r.stdout + r.stderr
    if MARKER.encode() in out:
        return 'complete', size, r.returncode, out
    if r.returncode == 0:
        return 'RUNS-EXIT-0', size, r.returncode, out
    return 'refused', size, r.returncode, out


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__.strip().splitlines()[-3].strip())
    exe = os.path.abspath(sys.argv[1])
    trials = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    work = tempfile.mkdtemp(prefix='phosphor-packprobe-')
    random.seed(20261004)       # repeatable: the same offsets every run

    pbc = build_fixture(exe, work)
    span = clean_pack_seconds(exe, pbc, work)
    out = os.path.join(work, 'victim.out')
    print('a clean pack takes %.3f s; killing inside that window' % span)
    print('working in %s (left in place, as this tree does not remove trees)' % work)
    print('')

    buckets, examples = {}, {}
    for _ in range(trials):
        if os.path.exists(out):
            os.remove(out)      # one named file, never a tree
        p = subprocess.Popen([exe, 'pack', pbc, out], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(random.uniform(0.0, span * 1.25))
        p.kill()
        try:
            p.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            pass
        kind, size, code, text = classify(out)
        buckets[kind] = buckets.get(kind, 0) + 1
        examples.setdefault(kind, (size, code, text[:80]))

    print('%d trials:' % trials)
    for k in sorted(buckets, key=lambda x: -buckets[x]):
        size, code, text = examples[k]
        print('  %-14s %3d   e.g. %d bytes, exit %s, %r'
              % (k, buckets[k], size, code, text))
    bad = buckets.get('RUNS-EXIT-0', 0) + buckets.get('HUNG', 0)
    print('')
    print('LEFT SOMETHING AT THE OUTPUT NAME THAT RUNS AND IS NOT THE APPLICATION: '
          '%d of %d' % (bad, trials))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
