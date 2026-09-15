#!/usr/bin/env python3
"""The two halves of the engine boundary check must be RIGHT, and must agree.

WHY THIS EXISTS. The boundary check -- engine/ names no host, GUI, console or OS
unit -- lived in four copies: build.sh, test-suite.sh, build.ps1, test-suite.ps1.
Nothing compared them, and on 2026-09-15 they were scored for the first time
against eleven cases whose expected answers are derived from Pascal rather than
from any implementation. They did not agree, and neither was right:

    the bash copies          8/11
    the PowerShell copies   10/11

Two defects, one of them on both platforms.

  * The bash halves never stripped (* *) at all, so a forbidden unit named inside
    a paren comment was read as a dependency: a legal file failed the build on
    Linux and passed on Windows. CLAUDE.md tells authors to reach for (* *)
    wherever a brace comment would nest, so the tree produces that shape on
    purpose.

  * All four stripped // to end-of-line BEFORE the block forms. A brace comment
    whose closing } shares a line with a // therefore lost its terminator, and the
    brace pass then ran from { to the next } anywhere later, swallowing whatever
    lay between -- INCLUDING A REAL USES CLAUSE. A boundary check that hides a
    violation is worse than none, and that one was live in both halves.

The repair is a single alternation rather than a sequence of passes, because a
sequence cannot express "whichever form opens first wins" and a regex engine
scanning left to right does it for free. Reordering was measured and is not the
fix: brace-first breaks the mirror case, a { inside a // line.

WHAT THIS GATE ASKS. Each implementation is RUN over each fixture and its verdict
compared to the manifest's. Both directions are covered by the corpus itself: six
cases must report nothing and five must report a violation, so an implementation
that answered "clean" to everything and one that answered "violation" to
everything both fail. The half this host cannot execute is named in the output
rather than passed over, because a skipped half printed as a passed half is the
failure this whole family of gates exists to stop.

Exit 0 when every implementation this host can run scores full marks.
"""
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, 'tests', 'boundary')

FORBIDDEN = ('crt video keyboard lcl lclintf lcltype forms controls dialogs '
             'graphics interfaces windows unix baseunix').split()


def cases():
    """(name, expect_violation, why) from the manifest, which carries the why."""
    out = []
    path = os.path.join(FIX, 'manifest.txt')
    for line in io.open(path, encoding='utf-8'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split('|', 2)
        if len(parts) != 3:
            print('MALFORMED MANIFEST LINE (want <name>|<True|False>|<why>):')
            print('  %s' % line)
            return None
        name, want, why = parts
        if want not in ('True', 'False'):
            print('MALFORMED EXPECTATION %r for %s' % (want, name))
            return None
        if not why.strip():
            print('%s HAS NO REASON. An expectation with no reason beside it is a '
                  'run recorded as a rule.' % name)
            return None
        out.append((name, want == 'True', why))
    return out


def violates(flat):
    low = flat.lower()
    return any(re.search(r'uses[^;]*[ ,]' + u + r'[ ,;]', low) for u in FORBIDDEN)


def run_bash(path):
    """Ask scripts/lib/boundary.sh, by sourcing it exactly as a runner does."""
    script = ('. "%s/scripts/lib/boundary.sh"; boundary_flatten "%s"'
              % (ROOT.replace('\\', '/'), path.replace('\\', '/')))
    p = subprocess.run(['bash', '-c', script], stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode('utf-8', 'replace').strip())
    return p.stdout.decode('utf-8', 'replace')


def run_powershell(path):
    """Ask scripts/lib/boundary.ps1, dot-sourced exactly as a runner does."""
    script = (". '%s\\scripts\\lib\\boundary.ps1'; Get-BoundaryFlat '%s'"
              % (ROOT, path))
    p = subprocess.run(['powershell', '-NoProfile', '-Command', script],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode('utf-8', 'replace').strip())
    return p.stdout.decode('utf-8', 'replace')


IMPLS = [('boundary.sh', run_bash), ('boundary.ps1', run_powershell)]


def main():
    todo = cases()
    if todo is None:
        return 1
    if len(todo) < 4:
        print('THE FIXTURE CORPUS IS TOO SMALL (%d) -- this gate cannot see what '
              'it guards.' % len(todo))
        return 1
    # BOTH directions must be present. Written first as `not any(...) or not
    # all(...)`, which is true whenever the corpus is healthy -- a guard that
    # refuses something legitimate, in the gate written to forbid exactly that.
    # It fires when every case wants the SAME answer.
    wants = [w for _, w, _ in todo]
    if all(wants) or not any(wants):
        print('THE FIXTURE CORPUS IS ONE-SIDED -- all %d cases expect %s, so an '
              'implementation that always says it would pass.'
              % (len(wants), wants[0]))
        return 1

    failed = 0
    ran = []
    skipped = []
    for label, fn in IMPLS:
        wrong = []
        try:
            for name, want, why in todo:
                path = os.path.join(FIX, name + '.pas')
                if not os.path.exists(path):
                    print('%s IS IN THE MANIFEST AND NOT ON DISK: %s'
                          % (name, path))
                    return 1
                got = violates(fn(path))
                if got != want:
                    wrong.append((name, want, got, why))
        except (OSError, RuntimeError) as e:
            skipped.append((label, str(e).splitlines()[0] if str(e) else 'not runnable here'))
            continue
        ran.append(label)
        if wrong:
            failed = 1
            print('%s IS WRONG ON %d OF %d FIXTURES:' % (label, len(wrong), len(todo)))
            for name, want, got, why in wrong:
                print('  %-24s expected %-5s got %-5s' % (name, want, got))
                print('      %s' % why)

    if skipped:
        print('note: %d implementation(s) not executed here; UNVERIFIED on this '
              'host:' % len(skipped))
        for label, why in skipped:
            print('      %-14s (%s)' % (label, why))
    if not ran:
        print('NEITHER IMPLEMENTATION COULD BE RUN -- this gate measured nothing.')
        return 1

    if not failed:
        print('boundary: %s answered all %d fixtures correctly'
              % (' and '.join(ran), len(todo)))
    return failed


if __name__ == '__main__':
    sys.exit(main())
