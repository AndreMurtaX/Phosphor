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

tests/classic has no manifest and is driven straight off the directory, so there
is nothing here for it to drift from. It is listed in NO_MANIFEST rather than left
out silently, so adding a corpus with a manifest cannot be missed by this gate the
way the third was missed by the runners. tests/negative was listed there too until
2026-10-06, when each negative gained a recorded reason it is judged against
(ledger d53) and the list of reasons became its manifest -- a fifth corpus.

Exit 0 when every corpus agrees, non-zero with the offending names otherwise.
"""
import glob
import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# corpus directory -> the manifest that must name every .bas in it
CORPORA = {
    os.path.join('tests', 'suite'): 'manifest.txt',
    os.path.join('tests', 'packages'): 'manifest.txt',
    os.path.join('tests', 'gui'): 'manifest.txt',
    'examples': 'manifest.txt',
    # Since 2026-10-06 (ledger d53) a negative is judged against the REASON its
    # manifest line records, so a file with no line has nothing to be judged
    # against -- the runner fails it, and this names it before the runner does.
    os.path.join('tests', 'negative'): 'manifest.txt',
}

# Directory-driven corpora: the runner globs them, so there is no second list to
# disagree with. Named here rather than omitted, so a reader can see the choice.
NO_MANIFEST = {
    os.path.join('tests', 'classic'): 'test-classic runs every .bas it finds',
}

# Corpora whose runner names its files ONE BY ONE in its own source, so a .bas
# dropped beside them is never run -- and, until 2026-10-06, was credited by
# coverage.py all the same, because that gate reads every .bas under tests/. These
# two were in neither table above, so this gate could not see them at all (ledger
# d54). The list here is the runner's own list; a file that is not on it fails.
FIXED = {
    os.path.join('tests', 'skeleton'): (
        ['hello'],
        'test.{ps1,sh} run hello.bas by name and byte-compare it with hello.expected'),
    os.path.join('tests', 'gui', 'watchdog'): (
        ['hang'],
        'test-gui.{ps1,sh} run hang.bas by name with a short watchdog -- a file '
        'that must fail cannot sit in a corpus of files that must pass'),
    os.path.join('tests', 'gui', 'ledger'): (
        ['forgot'],
        'test-gui.{ps1,sh} run forgot.bas by name and demand that it FAIL -- the '
        'modal answer ledger must fail a run, so it cannot sit in a passing corpus'),
    os.path.join('tests', 'gui', 'hostmode'): (
        ['fails', 'gui', 'gui_sandbox', 'hello'],
        'test-gui.{ps1,sh} run each of these by name in a hostmode case of its own'),
}


def bas_dirs():
    """Every directory that holds a .bas, DERIVED rather than listed.

    THE TABLES ABOVE USED TO BE THE WHOLE WORLD. This gate iterated CORPORA and
    nothing else, so a directory in no table was in no category, and the gate
    reported green about a set of corpora somebody had written down (ledger d54).
    The candidates now come from git: tracked files plus untracked ones that are
    not ignored -- so a test written a minute ago counts, and a gitignored backup
    copy does not. None means git could not answer, which is a failure, not an
    empty tree."""
    try:
        out = subprocess.run(
            ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '--', '*.bas'],
            cwd=ROOT, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return sorted({os.path.normpath(os.path.dirname(p)) for p in out.splitlines() if p})


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
    dirs = bas_dirs()
    if dirs is None:
        print('check-manifests: git could not list the tree, so this gate cannot say '
              'which directories hold tests. Run it from a git checkout.')
        return 1
    classified = set(CORPORA) | set(NO_MANIFEST) | set(FIXED)
    for d in dirs:
        if d not in classified:
            bad.append('%s holds .bas files and is in no table here -- add it to '
                       'CORPORA, NO_MANIFEST or FIXED with how its runner finds them'
                       % d)
    # AND THE OTHER WAY: a table entry for a directory with no test in it is a
    # category that classifies nothing, which reads exactly like one that is fine.
    for d in sorted(classified):
        if not glob.glob(os.path.join(ROOT, d, '*.bas')):
            bad.append('%s is listed here but holds no .bas -- remove the entry, '
                       'or put back what it named' % d)
    for rel, (names, why) in sorted(FIXED.items()):
        on_disk = sorted(os.path.splitext(os.path.basename(p))[0]
                         for p in glob.glob(os.path.join(ROOT, rel, '*.bas')))
        total += len(on_disk)
        for n in on_disk:
            if n not in names:
                bad.append('%s/%s.bas is not one of the files its runner names (%s) '
                           '-- it never runs' % (rel, n, why))
        for n in names:
            if n not in on_disk:
                bad.append('%s/%s.bas is named by its runner but is not there' % (rel, n))
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
          'drift from; %d directories holding .bas, all classified)'
          % (total, len(CORPORA) + len(FIXED), len(NO_MANIFEST), len(dirs)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
