#!/usr/bin/env python3
"""Every .bas in a manifest-driven corpus is listed, and every listed one exists.

WHY THIS EXISTS. Four corpora are driven by a manifest.txt -- tests/suite,
tests/packages, tests/gui and examples -- and the runners read the manifest and
run what it names. Nothing read the DIRECTORY. So a .bas file that was never
added to its manifest simply never ran, and the runner printed OK.

Measured before this was written: a file containing `assert_int(1, 2)` -- an
assertion that cannot pass -- was dropped into tests/packages/ and
`scripts/test-packages.ps1` printed PACKAGES OK. Nothing in the tree noticed it
was there, and nothing would have noticed if it had been a real test somebody
forgot to list.

This is the same shape as every other gate here: a rule that held only while
somebody remembered it. The manifest is a promise that it names the corpus, and
prose cannot fail a build.

BOTH DIRECTIONS, because both have a way to go wrong:
  - a .bas on disk that the manifest does not name  -- a test nothing runs
  - a name in the manifest with no .bas on disk     -- a run that silently skips

tests/classic and tests/negative have no manifest and are driven straight off the
directory, so there is nothing here for them to drift from. They are listed in
NO_MANIFEST rather than left out silently, so adding a fifth corpus with a
manifest cannot be missed by this gate the way the third was missed by the
runners.

Exit 0 when every corpus agrees, non-zero with the offending names otherwise.
"""
import glob
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# corpus directory -> the manifest that must name every .bas in it
CORPORA = {
    os.path.join('tests', 'suite'): 'manifest.txt',
    os.path.join('tests', 'packages'): 'manifest.txt',
    os.path.join('tests', 'gui'): 'manifest.txt',
    'examples': 'manifest.txt',
}

# Directory-driven corpora: the runner globs them, so there is no second list to
# disagree with. Named here rather than omitted, so a reader can see the choice.
NO_MANIFEST = {
    os.path.join('tests', 'classic'): 'test-classic runs every .bas it finds',
    os.path.join('tests', 'negative'): 'test-suite rejects every .bas it finds',
}


def listed(path):
    """The basenames a manifest names. A line may carry a '|mode' suffix."""
    out = []
    for line in io.open(path, encoding='utf-8', errors='ignore'):
        line = line.split('#')[0].strip()
        if not line:
            continue
        out.append(line.split('|')[0].strip())
    return out


def main():
    bad = []
    total = 0
    for rel, mf in sorted(CORPORA.items()):
        d = os.path.join(ROOT, rel)
        mpath = os.path.join(d, mf)
        if not os.path.isfile(mpath):
            bad.append('%s: no %s, but this gate expects one -- add it, or move '
                       'the corpus to NO_MANIFEST with the reason' % (rel, mf))
            continue
        names = listed(mpath)
        on_disk = sorted(os.path.splitext(os.path.basename(p))[0]
                         for p in glob.glob(os.path.join(d, '*.bas')))
        total += len(on_disk)

        for n in on_disk:
            if n not in names:
                bad.append('%s/%s.bas is NOT in %s -- it never runs, and the '
                           'runner prints OK anyway' % (rel, n, mf))
        for n in names:
            if n not in on_disk:
                bad.append('%s names %s in %s, but %s.bas is not there -- that '
                           'entry silently runs nothing' % (rel, n, mf, n))

    # A duplicate line runs a file twice and reads as two passes.
    for rel, mf in sorted(CORPORA.items()):
        mpath = os.path.join(ROOT, rel, mf)
        if not os.path.isfile(mpath):
            continue
        names = listed(mpath)
        for n in sorted(set(names)):
            if names.count(n) > 1:
                bad.append('%s lists %s %d times in %s'
                           % (rel, n, names.count(n), mf))

    if bad:
        print('A CORPUS AND ITS MANIFEST DISAGREE:')
        for b in bad:
            print('  ' + b)
        print('')
        print('A test nothing runs is not a test, and a manifest entry with no')
        print('file behind it is a skip nobody asked for. Fix whichever is wrong.')
        return 1

    print('manifests: %d test files across %d corpora, every one listed and '
          'every listing real (%d directory-driven corpora have no manifest to '
          'drift from)' % (total, len(CORPORA), len(NO_MANIFEST)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
