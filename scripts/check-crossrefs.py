#!/usr/bin/env python3
"""A path this tree names in prose must be a path this tree has, and the two
suite runners must run the same probes.

WHY THIS EXISTS. Two invariants that nothing could see, both measured on
2026-09-11, both found by hand and both by accident.

FIRST: A CITATION GOES STALE WHEN THE FILE IT NAMES MOVES, and no gate reads a
sentence. Eight work-order pieces landed that day, three of them carrying a test
file whose number collided with another piece's, so the integrator renumbered
them -- and each renumber broke every comment that cited the old name.
check-manifests.py stayed green through all of it, because it compares a manifest
to a directory and a citation is neither. Four broke that day, in
engine/PhosphorValue.pas, engine/libs/PhosphorDictLib.pas, and two .bas files.
The first grep after each rename found some of them, which is exactly how the
last one survived.

The same scan then found two claims older than that day, and git said what had
happened to each: docs/roadmap-phase2.md still described `host/gui/phosphorgui.lpr`
as built, when 15187b7 had folded the interactive GUI host into the single
`phosphor` binary; and docs/roadmap.md still described `tests/suite/03a_functions.bas`
as the current state, when eb4171d had replaced that subset with the full file at
step 8. Neither was wrong when written. Both read, to somebody planning work, as
descriptions of the tree in front of them.

This is the project's oldest failure shape wearing a new hat: a completeness claim
in prose is a promise, and prose cannot fail a build.

SECOND: A PROBE REGISTERED IN ONE RUNNER RUNS ON ONE OPERATING SYSTEM. The probe
list lives twice -- scripts/test-suite.ps1 and scripts/test-suite.sh -- and
nothing compared them. A probe added to only one of them would be run on Windows
and silently never on Linux (or the reverse), with both runners printing OK. This
nearly shipped the same afternoon: merging two pieces that each added a line to
that list, the first resolution REPLACED one probe with the other in one file.

EXEMPTIONS carry a reason, the way check-seams.py's do, because the legitimate
cases are real: this project cites the Plan9Basic ORACLE's files, which are not
here and are not supposed to be, and a retired file may still be named by the
history that retired it.

Exit 0 when every citation resolves and both runners agree, non-zero with the
offending names otherwise.
"""
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Text files worth scanning: anything a human writes prose in.
TEXT_EXT = ('.pas', '.lpr', '.inc', '.md', '.bas', '.repl', '.py', '.ps1', '.sh',
            '.txt')

# A path that looks like this repository's. Anchored on the top-level directories
# that exist, so an ordinary sentence about "the engine" is not a citation.
CITE = re.compile(
    r'\b((?:tests|engine|host|scripts|docs|examples|lazarus)'
    r'/[A-Za-z0-9_./-]+\.(?:pas|lpr|inc|md|bas|repl|py|ps1|sh|txt|expected))')

# path -> why it names something this tree does not have.
EXEMPT = {
    'tests/TestLib.pas':
        "Plan9Basic's, not ours -- tests/PhosphorTestLib.pas says so in the "
        "sentence that cites it, and the oracle is not vendored here",
    'tests/negative/01_too_many_globals.bas':
        "the ORACLE's negative corpus. docs/decisions.md cites it precisely to "
        "record that it is NOT imported, and tests/suite/13_global_limit.bas "
        "says which half of the limit it guards instead",
    'host/gui/phosphorgui.lpr':
        "retired by 15187b7, which folded the interactive GUI host into the "
        "single phosphor binary. docs/roadmap-phase2.md names it to say it is "
        "gone, which is history and not a claim about the tree",
    'docs/debug-protocol.md':
        "PhosphorIDE's, not ours. It is the specification the two ends of the "
        "debug protocol agree on, it lives in C:/Dev/PhosphorIDE/docs, and this "
        "repository cites it the way it cites the Plan9Basic oracle: by name, "
        "because the name is what a reader needs to go and find it",
    'tests/suite/03a_functions.bas':
        "retired by eb4171d, which replaced the 18-assert function subset with "
        "the full 03_functions.bas at step 8. docs/roadmap.md names it to say so",
    'host/console/backup/phosphor.lpr':
        "GITIGNORED SCRATCH, and named precisely because it should not exist: "
        "docs/attack-plan.md finding n8 records that check-seams.py counts it as "
        "a seventh host and reports '12 seams filled across 7 hosts' for a tree "
        "that ships six. A citation to a path the tree deliberately does not "
        "track, made to say the gate is reading untracked scratch",
    'tests/phosphoridetest.lpr':
        "PhosphorIDE's, not ours -- the same reason docs/debug-protocol.md is "
        "exempt above. docs/attack-plan.md names it to say that the editor half "
        "of the debug protocol has a headless test which creates no widgetset, "
        "which is why one of its failure modes cannot be caught there",
    'tests/skeleton/zzz_unlisted.bas':
        "a fixture that is PLANTED and removed inside a check, never committed: "
        "docs/attack-plan.md's gate-to-leave for d54 requires check-manifests.py "
        "to exit 1 on an unlisted .bas dropped into a corpus it does not "
        "enumerate. Naming the file is how the next person reproduces it",
}


def tracked():
    """Files that are in the tree, or are about to be.

    Tracked PLUS untracked-but-not-ignored, because a citation written in the same
    edit as the file it names would otherwise read as stale for the length of the
    window between writing and committing -- which is exactly when this gate runs.
    Ignored files stay out: a citation to build output or scratch is a real defect."""
    out = subprocess.check_output(['git', 'ls-files'], cwd=ROOT)
    new = subprocess.check_output(
        ['git', 'ls-files', '--others', '--exclude-standard'], cwd=ROOT)
    return (out.decode('utf-8', 'replace').splitlines() +
            new.decode('utf-8', 'replace').splitlines())


# --- WHERE in a file, not just WHICH file (ledger n12) -------------------------
# The rule above checks that a cited PATH exists and never looked at what followed
# it. A `path:LINE` citation is the one shape no gate can check: a line number stays
# in range while the code moves under it, so it goes on pointing somewhere, just not
# where it meant. Measured when this landed: of seven line citations in live
# sources, four pointed at the wrong place -- line 372 of the language reference was
# cited twice for "Strings are 1-based and Unicode-aware" and holds `return n * r`,
# and line 435 for PRINT USING's `!` and holds string splicing. None was past the end of its
# file, so a range check would have passed all four.
#
# So a citation names a PLACE by its name: `path#Name`, where Name is a heading's
# slug in a .md, or a routine the file defines -- both things this gate can look up,
# and both of which survive an edit above them. PhosphorIDE reached the same rule by
# the same road (tools/check-citations.py there).
#
# DATED records keep their line numbers. The playbook's ledger and the attack plan
# say what was where ON THE DAY they were written; rewriting each anchor to today's
# line would make the record wrong about its own date. A line there must still be
# INSIDE the file -- the one thing a line number can be checked for -- and an open
# item that a reader will act on carries a name anchor beside it.
NAMED = re.compile(CITE.pattern + r'#([A-Za-z0-9_-]+)')
LINED = re.compile(CITE.pattern + r':(\d+)')
DATED = {
    'docs/dev-agent-playbook.md',
    'docs/attack-plan.md',
}


def md_slug(heading):
    """GitHub's anchor for a markdown heading: lowercase, punctuation dropped,
    spaces to hyphens (so an em dash between two words leaves two hyphens)."""
    s = heading.strip().lower()
    s = re.sub(r'[^\w\- ]', '', s)
    return s.replace(' ', '-')


def anchors_of(rel, cache={}):
    """The names a `path#Name` citation may use for this file."""
    if rel in cache:
        return cache[rel]
    try:
        text = io.open(os.path.join(ROOT, rel), encoding='utf-8', errors='replace').read()
    except (IOError, OSError):
        cache[rel] = set()
        return cache[rel]
    if rel.endswith('.md'):
        names = {md_slug(m.group(1)) for m in re.finditer(r'(?m)^#+\s+(.+?)\s*#*\s*$', text)}
    else:
        names = set()
        for pat in (r'(?im)^\s*(?:class\s+)?(?:procedure|function|constructor|destructor)'
                    r'\s+(?:[A-Za-z_]\w*\.)?([A-Za-z_]\w*)',      # Pascal, PowerShell, BASIC
                    r'(?m)^\s*def\s+([A-Za-z_]\w*)',             # Python
                    r'(?m)^\s*([A-Za-z_]\w*)\s*\(\)\s*\{'):      # shell
            names |= set(re.findall(pat, text))
    cache[rel] = {n.lower() for n in names}
    return cache[rel]


def line_count(rel):
    try:
        return io.open(os.path.join(ROOT, rel), encoding='utf-8',
                       errors='replace').read().count('\n') + 1
    except (IOError, OSError):
        return 0


def check_places(files):
    """`path#Name` must name something there; `path:LINE` is refused outside the
    dated records, and inside them must at least be inside the file."""
    bad = []
    for rel in files:
        if not rel.endswith(TEXT_EXT):
            continue
        try:
            text = io.open(os.path.join(ROOT, rel), encoding='utf-8',
                           errors='replace').read()
        except (IOError, OSError):
            continue
        for m in NAMED.finditer(text):
            path, name = m.group(1), m.group(2)
            if path in EXEMPT or not os.path.isfile(os.path.join(ROOT, path)):
                continue      # a missing path is reported by check_citations
            if name.lower() not in anchors_of(path):
                bad.append('%s cites %s#%s, and %s has no heading or routine by that '
                           'name' % (rel, path, name, path))
        for m in LINED.finditer(text):
            path, line = m.group(1), int(m.group(2))
            if path in EXEMPT or not os.path.isfile(os.path.join(ROOT, path)):
                continue
            if rel not in DATED:
                bad.append('%s cites %s:%d -- a line number cannot be checked and '
                           'drifts in silence; cite %s#Name (a heading or a routine)'
                           % (rel, path, line, path))
            elif line > line_count(path):
                bad.append('%s cites %s:%d, past the end of a %d-line file'
                           % (rel, path, line, line_count(path)))
    if bad:
        print('CITATIONS THAT DO NOT SAY WHERE:')
        for b in bad:
            print('  ' + b)
        print('')
        return 1
    return 0


def check_citations(files):
    """Every repo path named in a text file must exist, or be exempt with a reason."""
    on_disk = set(files)
    bad = {}
    for rel in files:
        if not rel.endswith(TEXT_EXT):
            continue
        try:
            text = io.open(os.path.join(ROOT, rel), encoding='utf-8',
                           errors='replace').read()
        except (IOError, OSError):
            continue
        for m in CITE.finditer(text):
            path = m.group(1)
            if '*' in path or path in on_disk or path in EXEMPT:
                continue
            bad.setdefault(path, set()).add(rel)

    if bad:
        print('STALE CITATIONS -- a file is named that this tree does not have:')
        for path in sorted(bad):
            print('  %s' % path)
            for where in sorted(bad[path]):
                print('      cited in %s' % where)
        print('')
        print('Repoint it, or say what happened to it and add it to EXEMPT in')
        print('scripts/check-crossrefs.py with the reason. A citation that names')
        print('nothing is read as a description of the tree by the next person.')
        return 0, 1

    scanned = sum(1 for f in files if f.endswith(TEXT_EXT))
    return scanned, 0


PS_PROBE = re.compile(r"name\s*=\s*'([A-Za-z0-9_]+)'\s*;\s*src\s*=\s*'([^']+)'")
SH_PROBE = re.compile(r'"([A-Za-z0-9_]+):([^":]+\.lpr)"')


def check_probes():
    """Both suite runners must build the same set of probes from the same sources."""
    ps = io.open(os.path.join(ROOT, 'scripts', 'test-suite.ps1'),
                 encoding='utf-8', errors='replace').read()
    sh = io.open(os.path.join(ROOT, 'scripts', 'test-suite.sh'),
                 encoding='utf-8', errors='replace').read()

    win = {n: s.replace('\\', '/') for n, s in PS_PROBE.findall(ps)}
    nix = {n: s for n, s in SH_PROBE.findall(sh)}

    if not win or not nix:
        print('PROBE LISTS NOT FOUND -- this gate cannot see what it guards:')
        print('  test-suite.ps1 matched %d, test-suite.sh matched %d.' %
              (len(win), len(nix)))
        print('  The list moved or changed shape; fix the patterns here rather')
        print('  than letting the check quietly measure nothing.')
        return 0, 1

    failed = 0
    only_win = sorted(set(win) - set(nix))
    only_nix = sorted(set(nix) - set(win))
    if only_win or only_nix:
        print('PROBE LISTS DISAGREE -- a probe in one runner never runs on the '
              'other operating system:')
        for n in only_win:
            print('  %s is built by test-suite.ps1 only (Linux never runs it)' % n)
        for n in only_nix:
            print('  %s is built by test-suite.sh only (Windows never runs it)' % n)
        failed = 1

    for n in sorted(set(win) & set(nix)):
        if win[n] != nix[n]:
            print('PROBE %s IS BUILT FROM TWO DIFFERENT SOURCES:' % n)
            print('  test-suite.ps1: %s' % win[n])
            print('  test-suite.sh : %s' % nix[n])
            failed = 1

    for n, src in sorted(nix.items()):
        if not os.path.exists(os.path.join(ROOT, src)):
            print('PROBE %s NAMES A SOURCE THAT IS NOT THERE: %s' % (n, src))
            failed = 1

    return len(nix), failed


PS_BOUND = re.compile(r'^\$TestTimeoutS\s*=\s*(\d+)\s*$', re.M)
SH_BOUND = re.compile(r'^test_timeout_s=(\d+)\s*$', re.M)


def check_bound():
    """Both suite runners bound each test by the same number of seconds.

    The bound was added on 2026-10-07, after a compiler mutation hung the suite
    for eight minutes with nothing on screen. It lives twice, and a bound changed
    in one runner only would let a hang that Windows reports run forever on
    Linux, or the reverse, with nothing comparing them."""
    ps = io.open(os.path.join(ROOT, 'scripts', 'test-suite.ps1'),
                 encoding='utf-8', errors='replace').read()
    sh = io.open(os.path.join(ROOT, 'scripts', 'test-suite.sh'),
                 encoding='utf-8', errors='replace').read()
    win, nix = PS_BOUND.findall(ps), SH_BOUND.findall(sh)
    if len(win) != 1 or len(nix) != 1:
        print('PER-TEST BOUND NOT FOUND EXACTLY ONCE -- this gate cannot see what it guards:')
        print('  test-suite.ps1 has %d "$TestTimeoutS = N" lines, test-suite.sh has %d '
              '"test_timeout_s=N" lines; each must have one.' % (len(win), len(nix)))
        return 0, 1
    if win[0] != nix[0]:
        print('THE SUITE RUNNERS BOUND A TEST DIFFERENTLY:')
        print('  test-suite.ps1: %s s' % win[0])
        print('  test-suite.sh : %s s' % nix[0])
        return 0, 1
    return int(win[0]), 0


BOGUS = '--zz-not-a-flag'

# A runner must refuse an argument it does not know, and it must do so BEFORE it
# builds anything -- so this budget is generous for a refusal and far too small
# for a compile. A runner that builds first blows it, which is the answer we want.
REFUSAL_BUDGET_S = 25


def _runner_family(files):
    """scripts/test*.sh and scripts/test*.ps1, derived from the tree.

    Derived and not listed, because a literal list goes blind the day a seventh
    runner ships -- which is exactly how check-seams.py missed lazarus/demo."""
    sh, ps = {}, {}
    for rel in files:
        d, base = os.path.split(rel)
        if d != 'scripts' or not base.startswith('test'):
            continue
        stem, ext = os.path.splitext(base)
        if ext == '.sh':
            sh[stem] = rel
        elif ext == '.ps1':
            ps[stem] = rel
    return sh, ps


def _ask(cmd):
    """Run a refusal probe. Returns (returncode, said_it, timed_out), or None
    when this host cannot run that interpreter at all.

    `said_it` -- whether the output names the argument it is refusing -- is not
    decoration. Measured on the unpatched tree: test-classic.sh answered exit 2
    for the bogus flag and had never looked at it. Its line 18 exits 2 when
    build.sh fails, and build.sh fails on a host with no fpc. Exit code alone
    handed a pass to a script that does not read $1, which is this project's
    named trap -- an exit code answers the question the tool asked, not the one
    you meant."""
    try:
        p = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=REFUSAL_BUDGET_S)
        said = BOGUS in p.stdout.decode('utf-8', 'replace')
        return (p.returncode, said, False)
    except subprocess.TimeoutExpired:
        return (None, False, True)
    except (OSError, ValueError):
        return None


def _interpreter_runs(cmd):
    """Can this host execute this interpreter at all?

    ASKED ONCE, BEFORE ANY RUNNER, because "the interpreter is not here" and "the
    runner answered wrongly" are the same exit code otherwise. On Windows `bash`
    on PATH is very often C:\\Windows\\System32\\bash.exe -- the WSL launcher --
    and with no distro installed it does not fail to START: it runs, prints
    `execvpe(/bin/bash) failed`, and exits 1. Measured on 2026-09-16 on a machine
    where Git Bash runs all six .sh runners correctly (exit 2, naming the
    argument): this gate reported every one of them as broken, and the repair
    would have been to the six innocent scripts.

    The probe is an exit code the interpreter can only produce by having run
    something. A launcher that cannot find its shell cannot produce 7."""
    try:
        p = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=REFUSAL_BUDGET_S)
        return p.returncode == 7
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


def check_runners(files):
    """Every runner refuses an argument it does not know, and the twins agree
    about whether they have a prove mode.

    WHY THIS EXISTS. On 2026-09-15 a survey measured that `-ProveFailure` -- the
    project's own canonical spelling, and one of the five conditions CLAUDE.md
    lists for calling anything done -- was a SILENT FULL RUN on five of six bash
    runners. test-examples.sh read only `--prove-failure`; test-classic.sh read
    only `--prove`/`-ProveFailure` and so ignored its neighbour's spelling;
    test.sh, test-packages.sh and test-gui.sh never read $1 at all. Each of them
    printed OK and exited 0, which reads exactly like a proof that happened.

    test-suite.sh was the one that refused, and its own comment says why -- "it
    already cost a false report once". The rule was written down in one file and
    nowhere else, which is this project's oldest shape: a promise in prose that
    nothing could fail.

    THE CHECK IS BEHAVIOURAL, NOT TEXTUAL. Grepping for a parser would pass a
    parser that does nothing. So each runner is actually invoked with an argument
    that cannot mean anything, and must answer 2 -- and must answer it before it
    builds, which the time budget enforces. A runner that refuses only after a
    four-minute compile is not refusing, it is arriving late.

    The half this host cannot execute is checked structurally and SAID SO in the
    output, because a skipped half printed as a passed half is the failure this
    whole file exists to stop."""
    sh, ps = _runner_family(files)
    if not sh or not ps:
        print('RUNNER FAMILY NOT FOUND -- this check cannot see what it guards:')
        print('  matched %d bash and %d PowerShell runners under scripts/.' %
              (len(sh), len(ps)))
        return 0, 1

    failed = 0
    asked = 0
    structural = []

    have_bash = _interpreter_runs(['bash', '-c', 'exit 7'])
    have_ps = _interpreter_runs(['powershell', '-NoProfile', '-Command', 'exit 7'])

    for stem in sorted(set(sh) | set(ps)):
        for rel, cmd, usable in (
                (sh.get(stem), ['bash', sh.get(stem, ''), BOGUS], have_bash),
                (ps.get(stem), ['powershell', '-NoProfile', '-File',
                                ps.get(stem, ''), BOGUS], have_ps)):
            if rel is None:
                continue
            if not usable:
                structural.append(rel)
                continue
            got = _ask(cmd)
            if got is None:
                structural.append(rel)
                continue
            asked += 1
            code, said, timed_out = got
            if timed_out:
                print('%s DID NOT REFUSE %s -- still running after %ds, so it '
                      'started work on an argument it does not understand'
                      % (rel, BOGUS, REFUSAL_BUDGET_S))
                failed = 1
            elif code != 2:
                print('%s ANSWERED %s WITH EXIT %d -- a runner must refuse an '
                      'argument it does not know with exit 2, or a mistyped '
                      '-ProveFailure is a silent full run' % (rel, BOGUS, code))
                failed = 1
            elif not said:
                print('%s EXITED 2 FOR %s WITHOUT NAMING IT -- that is the exit '
                      'code of something else (a failed build, a missing fpc), '
                      'not a refusal. Parse arguments FIRST, before any lookup '
                      'that can fail on the machine.' % (rel, BOGUS))
                failed = 1

    # Parity: a prove mode is a promise about the pair, not about one file.
    for stem in sorted(set(sh) & set(ps)):
        sh_txt = io.open(os.path.join(ROOT, sh[stem]), encoding='utf-8',
                         errors='replace').read()
        ps_txt = io.open(os.path.join(ROOT, ps[stem]), encoding='utf-8',
                         errors='replace').read()
        sh_has = 'runner_prove' in sh_txt
        ps_has = bool(re.search(r'\[switch\]\s*\$ProveFailure', ps_txt))
        if sh_has != ps_has:
            owner = sh[stem] if sh_has else ps[stem]
            other = ps[stem] if sh_has else sh[stem]
            print('PROVE MODE EXISTS ON ONE SIDE ONLY: %s has one and %s does '
                  'not, so the proof runs on one operating system' % (owner, other))
            failed = 1

    if structural:
        print('note: %d runner(s) not executed here (no interpreter on this '
              'host); refusal UNVERIFIED for them:' % len(structural))
        for rel in sorted(structural):
            print('      %s' % rel)

    return asked, failed


def main():
    files = tracked()
    scanned, bad_cites = check_citations(files)
    bad_places = check_places(files)
    probes, bad_probes = check_probes()
    bound, bad_bound = check_bound()
    runners, bad_runners = check_runners(files)

    if bad_cites or bad_places or bad_probes or bad_bound or bad_runners:
        return 1

    print('crossrefs: every cited path in %d text files exists (%d retired or '
          'oracle paths exempt with a reason), every path#Name names something '
          'there and no live text cites a line, both suite runners build the '
          'same %d probes and bound each test at %d s, and %d runners refused '
          'an argument they do not know'
          % (scanned, len(EXEMPT), probes, bound, runners))
    return 0


if __name__ == '__main__':
    sys.exit(main())
