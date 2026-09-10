#!/usr/bin/env python3
"""check-examples.py -- every BASIC example in the documentation compiles.

WHAT THIS EXISTS FOR. coverage.py already refuses a documented name that is not
registered, in prose and inside code blocks. It cannot refuse a block whose names
are all real and whose SYNTAX is wrong, and that is not hypothetical: on
2026-09-06 four examples in the tree did not compile, two of them written that
same day, and one of them was the worked example on the dictionary page — the one
a reader is most likely to copy. Every function it called existed. `case "x" :
println …` simply is not how a case label is written, and nothing said so.

So each ```basic block is handed to the compiler. Compiled, not run: an example
may open a file, fetch a URL or show a window, and none of that belongs in a
gate. What is checked is that a reader who copies the block gets a program the
compiler accepts.

A CHEAT SHEET IS NOT A PROGRAM. A block fenced ```basic notation is a summary of
syntax rather than something to run, and is skipped. The marker rides on the
fence, so it moves with the block and cannot rot the way a list of file:line
exemptions would -- and because a renderer highlights on the first word of the
fence, the block still reads as BASIC on the page.

Exit 0 = every example compiles. Exit 1 = one does not, and it is named with the
compiler's own message.
"""
import glob
import io
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOTATION = '```basic notation'


SOURCE_DIRS = [
    ('engine',), ('engine', 'libs'),
    ('host', 'console'), ('host', 'packages'), ('host', 'gui', 'libs'),
]


def newest_source():
    """When the compiler this gate uses was last changed, and which file did it."""
    newest, who = 0.0, None
    for parts in SOURCE_DIRS:
        d = os.path.join(ROOT, *parts)
        for pat in ('*.pas', '*.lpr'):
            for f in glob.glob(os.path.join(d, pat)):
                t = os.path.getmtime(f)
                if t > newest:
                    newest, who = t, os.path.relpath(f, ROOT)
    return newest, who


def phosphor():
    """The binary to compile with. Built by scripts/build; a missing one is a
    FAILURE and not a skip -- a gate that quietly does not run reads as a pass.

    AND SO IS A STALE ONE, which is the harder half. scripts/test-suite does not
    build bin/phosphor.exe -- that is scripts/build's job -- but it RUNS this
    gate, so after an engine edit the gate would compile every documentation
    example with the compiler as it was BEFORE the edit and report a pass on it.
    That is the same trap CLAUDE.md records for bin/phosphortest.exe, which is
    built by the test runners and not by build.ps1, and which produced four wrong
    conclusions in one day by being run unrebuilt.

    A binary older than the newest source it was built from is therefore an
    ERROR, not a warning: it says which file is newer, so the reader knows the
    answer is to build rather than to look for a defect. It does not build the
    binary itself -- a gate that repairs what it is measuring cannot report on
    it."""
    exe = os.path.join(ROOT, 'bin', 'phosphor.exe' if os.name == 'nt' else 'phosphor')
    if not os.path.isfile(exe):
        return None, None
    newest, who = newest_source()
    if newest > os.path.getmtime(exe):
        return None, who
    return exe, None


def docfiles():
    out = [os.path.join(ROOT, 'README.md')]
    out += sorted(glob.glob(os.path.join(ROOT, 'docs', '*.md')))
    out += sorted(glob.glob(os.path.join(ROOT, 'docs', 'libraries', '*.md')))
    return out


def blocks(path):
    """(first line number, body, is_notation) for each BASIC block."""
    lines = io.open(path, encoding='utf-8', errors='ignore').read().split('\n')
    i = 0
    while i < len(lines):
        fence = lines[i].strip().lower()
        if fence == '```basic' or fence == NOTATION:
            j = i + 1
            body = []
            while j < len(lines) and not lines[j].strip().startswith('```'):
                body.append(lines[j])
                j += 1
            yield i + 2, body, fence == NOTATION
            i = j
        i += 1


def main():
    exe, stale = phosphor()
    if not exe:
        if stale:
            print('FAIL  check-examples: bin/phosphor is OLDER than %s' % stale)
            print('      It would compile every example with the compiler as it')
            print('      was before that edit, and report a pass on it. Run')
            print('      scripts/build first.')
        else:
            print('FAIL  check-examples: no phosphor binary -- run scripts/build first')
        return 1

    tmp = tempfile.mkdtemp(prefix='phosphor-examples-')
    src = os.path.join(tmp, 'block.bas')
    out = os.path.join(tmp, 'block.pbc')
    total = compiled = skipped = 0
    bad = []

    for doc in docfiles():
        for first, body, notation in blocks(doc):
            total += 1
            if notation:
                skipped += 1
                continue
            io.open(src, 'w', encoding='utf-8', newline='\n').write('\n'.join(body) + '\n')
            r = subprocess.run([exe, 'compile', src, out],
                               capture_output=True, text=True)
            if r.returncode == 0:
                compiled += 1
            else:
                msg = (r.stderr or r.stdout).strip().split('\n')[-1]
                msg = re.sub(r'^.*block\.bas:', '', msg)
                rel = os.path.relpath(doc, ROOT).replace(os.sep, '/')
                bad.append((rel, first, msg.strip()))

    if bad:
        print('EXAMPLES THAT DO NOT COMPILE:')
        for rel, first, msg in bad:
            print('  %s:%d  %s' % (rel, first, msg))
        print('')
        print('The line number in the message counts from the start of the block.')
        print('If the block is a syntax summary rather than a program, fence it')
        print('%s instead.' % NOTATION)
        return 1

    print('examples: %d of %d BASIC blocks compile, %d fenced as notation'
          % (compiled, total, skipped))
    return 0


if __name__ == '__main__':
    sys.exit(main())
