#!/usr/bin/env python3
"""check-seams.py -- a seam a host leaves nil is a silent answer, so say why.

THE BUG THIS EXISTS FOR. The engine offers seams and installs none of them: a host
assigns OnOutput to receive PRINT, OnInput to supply INPUT, OnBreakpoint to pause,
HostServices to provide an event pump and a clipboard. Leaving one nil is a
DESIGNED behaviour -- a headless runner has no keyboard, and `input` answering
empty is correct there. That is exactly what makes it dangerous: the nil case
looks like the working case.

The GUI host of the day assigned OnOutput and stopped. So a GUI program printed
every INPUT prompt at once and answered each with an empty string, with a console
attached and a person at it. HostServices was nil in EVERY host in the tree, so
processmessages() answered 0 and the clipboard answered "" in the one program
written to provide them. Nothing failed. Nothing could. (That host has since been
merged into `phosphor`, which fills all three -- the seam table is what keeps the
merge honest.)

WHAT THIS CHECKS. Every seam on TPhosphorEngine, against every shipped host under
host/. A host either assigns the seam, or is listed below with the reason it does
not -- and a listed reason that is no longer true (the host now assigns it) fails
too, so the table cannot rot in the other direction. A new host, or a new seam on
the engine, fails until someone answers for it. That is the point: the answer may
well be "this runner has no keyboard", but it has to be written down once.

WHAT COUNTS AS ASSIGNED. Only code, and only a value. Comments are blanked before
the scan, because a commented-out assignment is not an assignment -- it is the
exact shape of a seam somebody meant to put back. And `seam := nil` is not a
filled seam either: it produces the same silence as never writing to it, so it is
reported unless EXEMPT records why nil is right there. A host that says nil out
loud AND has the reason written down is the best case and passes.

Exit 0 = every seam of every host is either filled or explained.
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# THE SEAM TYPES, DERIVED FROM THE SOURCE.
#
# The comment that stood here said "read from the source rather than listed here,
# so a seam added to TPhosphorEngine cannot be missed" -- and the next line was a
# hand-written list of four names. The comment described the gate somebody meant
# to write; the code was the gate that got written, and a seam of a NEW type was
# invisible to it. That is the same doc-versus-code drift these gates exist to
# catch, occurring inside one of them.
#
# What a seam IS, structurally: a METHOD POINTER the host assigns -- `procedure
# (...) of object` or `function (...) of object` -- or a RECORD whose fields are
# all method pointers, which is how THostServices bundles four of them. Both are
# read out of the engine's own type declarations, so a fifth kind added tomorrow
# is picked up the day it is added rather than the day someone remembers.
# The parameter list is consumed AS A WHOLE before anything else is matched,
# because a Pascal parameter list contains semicolons of its own:
#
#     TPhosphorBreakpointProc = procedure(const AMessage: String; ALine: Integer;
#                                         const AOperands: array of TValue) of object;
#
# A `[^;]*?` between the keyword and `of object` stops at the first of those and
# never reaches the tail, so this type -- the one seam with more than one
# parameter -- was the one the pattern could not see. The gate caught that itself,
# by reporting OnBreakpoint as a seam that no longer exists.
METHOD_PTR = re.compile(
    r'(?is)\b([A-Za-z_]\w*)\s*=\s*(?:procedure|function)\s*'
    r'(?:\([^)]*\))?[^;]*?\bof\s+object\s*;')
RECORD_DECL = re.compile(
    r'(?is)\b([A-Za-z_]\w*)\s*=\s*record\b(.*?)\bend\s*;')


def seam_types():
    """Every type on which a host can hang an implementation."""
    ptrs, records = set(), {}
    for f in sorted(glob.glob(os.path.join(ROOT, 'engine', '*.pas'))):
        src = open(f, encoding='utf-8', errors='ignore').read()
        ptrs.update(m.group(1) for m in METHOD_PTR.finditer(src))
        for m in RECORD_DECL.finditer(src):
            records[m.group(1)] = m.group(2)
    out = set(ptrs)
    for name, body in records.items():
        fields = re.findall(r'^\s*\w+\s*:\s*([A-Za-z_]\w*)\s*;', body, re.M)
        # An EMPTY record is not a bundle of seams; requiring at least one field
        # keeps `record end` from reading as one vacuously.
        if fields and all(t in ptrs for t in fields):
            out.add(name)
    return out


SEAM_TYPES = tuple(sorted(seam_types()))

# reason == None means "must be assigned". A string means "deliberately not
# assigned, because ...". Keys are "<host file>:<seam>".
EXEMPT = {
    # THE ONE SHIPPED HOST HAS NO EXEMPTION LEFT, and the line that used to stand
    # here is worth remembering rather than just deleting. It read "BREAKPOINT is
    # report-and-continue; there is nowhere for a host to pause to" -- which is
    # TRUE, and was still the wrong conclusion. Report-and-continue means a host
    # must not BLOCK; it never meant a host must not REPORT. So for as long as
    # that sentence sat here, the language's only debugging statement did
    # literally nothing in the only shipped host while the language reference said
    # it reported a frame to the host debugger, and this table said that was fine.
    # phosphor.lpr now writes one line per fired breakpoint to stderr -- see
    # TConsoleHost.Breakpoint -- so it fills all four seams, HostServices only
    # when a graphical session is reachable.
    #
    # A reason that stops being true has to come OUT: the loop below fails on an
    # exemption whose host now assigns the seam, which is what makes this table
    # a check in both directions rather than a place to write an excuse once.

    # THE DEBUG SEAM, AND SIX HOSTS THAT ANSWER "NOT YET" OR "NOT EVER".
    #
    # It is the one seam in the engine that MAY BLOCK: the VM calls it at a
    # statement boundary and waits for the action it returns. That is the whole
    # reason none of these six fills it today. Five of them have no person at the
    # other end and must never park -- a runner that stopped at a breakpoint would
    # hang a suite with no console output, which is the trap this project already
    # has three names for (the REPL, app_run, and a prompting Remove-Item). The
    # sixth, `phosphor`, is where the debug adapter goes, and this line comes out
    # the day `phosphor debug --port N` lands. Leaving it here until then is the
    # honest state: the engine offers the seam, nothing in the tree drives it yet,
    # and tests/probe_step.lpr is what proves the seam works without a host.
    'phosphortest.lpr:OnDebug': 'headless: a seam that may block would hang the suite, and a .bas test has nobody to press continue',
    'phosphorguitest.lpr:OnDebug': 'same as phosphortest: a headless GUI run has nowhere to stop to',
    'phosphorpkgtest.lpr:OnDebug': 'same as phosphortest',
    'phosphorhttptest.lpr:OnDebug': 'same as phosphortest',
    'phosphorembed.lpr:OnDebug': 'the embedding demo runs to completion with nobody watching; an embedder that wants to stop installs one, which tests/probe_step.lpr demonstrates end to end',

    # The suite runners report through assertion counters and write their own
    # summary bytes, and a .bas test file cannot type at a prompt.
    'phosphortest.lpr:OnOutput': 'the runner writes its own summary bytes; a test asserts, it does not print',
    'phosphortest.lpr:OnInput': 'a test file has nobody to type for it; INPUT answering empty is what tests/suite/17 pins',
    'phosphortest.lpr:OnBreakpoint': 'headless: BREAKPOINT must be a no-op, which tests/suite/15 pins',
    'phosphortest.lpr:HostServices': 'headless by design: tests/suite/17_host_services asserts the absent-service answers',
    'phosphorguitest.lpr:OnOutput': 'same as phosphortest: assertions, not printing',
    'phosphorguitest.lpr:OnInput': 'same as phosphortest: a test file cannot type',
    'phosphorguitest.lpr:OnBreakpoint': 'a headless GUI run has nowhere to pause to',
    'phosphorpkgtest.lpr:OnOutput': 'same as phosphortest',
    'phosphorpkgtest.lpr:OnInput': 'same as phosphortest',
    'phosphorpkgtest.lpr:OnBreakpoint': 'same as phosphortest',
    'phosphorpkgtest.lpr:HostServices': 'no window in the package runner',
    'phosphorhttptest.lpr:OnOutput': 'same as phosphortest',
    'phosphorhttptest.lpr:OnInput': 'same as phosphortest',
    'phosphorhttptest.lpr:OnBreakpoint': 'same as phosphortest',
    'phosphorhttptest.lpr:HostServices': 'no window in the http runner',

    # THE LAZARUS DEMO, which this gate could not see until 2026-10-06 (d48): it is
    # a .pas outside host/, and the glob was `host/**/*.lpr`. Its first run on the
    # derived domain named these four, and they are answers an embedder COPYING the
    # demo inherits -- which is why each says what that embedder has to decide.
    # lazarus/README.md says the same beside "the nine lines".
    'phosphordemorunner.pas:OnInput': 'none of the five demo scripts reads input, so INPUT answering empty is never reached; an application whose scripts do read must hang its own prompt here (docs/embedding.md)',
    'phosphordemorunner.pas:OnBreakpoint': 'the demo shows running and failing, not pausing; BREAKPOINT is a no-op in it as in any host that installs nothing',
    'phosphordemorunner.pas:OnDebug': 'the demo does not debug; tests/probe_step.lpr is the worked example of a host that does',
    'phosphordemorunner.pas:HostServices': 'the runner holds no LCL by design (its header says why), so it has no event pump or clipboard to offer; processmessages() and the clipboard answer their documented absent values',

    # The embedding demonstration shows the API, not a terminal.
    'phosphorembed.lpr:OnInput': 'the embedding demo drives the engine from Pascal; nothing asks for a line',
    'phosphorembed.lpr:OnBreakpoint': 'an embedder that wants a pause installs one; the demo shows the seam exists',
    'phosphorembed.lpr:HostServices': 'no window and no clipboard in the embedding demo',

}

# The right-hand side is part of the question, not decoration: `eng.OnInput := nil`
# leaves the seam exactly as empty as never writing to it at all, and a host that
# says so out loud still has to say WHY -- which is what EXEMPT is for. So the
# assignment is matched up to its semicolon and the value is read.
ASSIGN = r'\.\s*%s\s*:=\s*([^;]*)'


def strip_comments(src):
    """The same text with every comment blanked to spaces, newlines kept.

    THE BUG THIS EXISTS FOR. The scan below asks a regex whether a host assigns a
    seam, and a regex cannot tell code from prose. A host that had its assignment
    commented out during a debugging session --

        // eng.OnInput := @host.ReadLine;   // TODO: put back

    -- read as a filled seam, which is the one answer that must never be given by
    accident: the whole file exists because a nil seam looks like a working one.
    Line numbers are preserved so a finding can still name a line, and string
    literals are skipped rather than blanked so an apostrophe inside a comment,
    or a '{' inside a literal, cannot throw the scan off."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "'":                        # a string literal: skipped, not blanked
            i += 1
            while i < n and src[i] != "'" and src[i] != '\n':
                i += 1
            i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                out[i] = ' '
                i += 1
            continue
        if c == '{':                        # also swallows {$...} directives
            while i < n and src[i] != '}':
                if src[i] != '\n':
                    out[i] = ' '
                i += 1
            if i < n:
                out[i] = ' '
                i += 1
            continue
        if c == '(' and i + 1 < n and src[i + 1] == '*':
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == ')'):
                if src[i] != '\n':
                    out[i] = ' '
                i += 1
            for _ in range(2):
                if i < n:
                    out[i] = ' '
                    i += 1
            continue
        i += 1
    return ''.join(out)


def assignment(src, seam):
    """('filled' | 'nil' | None) for one seam in one host's source.

    'nil' when every assignment the host makes writes nil, so a host that clears a
    seam and later fills it still counts as filling it."""
    found = None
    for m in re.finditer(ASSIGN % seam, src):
        if m.group(1).strip().lower() == 'nil':
            found = found or 'nil'
        else:
            return 'filled'
    return found


def engine_seams():
    """Seam property names on TPhosphorEngine, by their declared type."""
    path = os.path.join(ROOT, 'engine', 'PhosphorEngine.pas')
    with open(path, encoding='utf-8') as fh:
        src = fh.read()
    seams = []
    for m in re.finditer(r'(?im)^\s*property\s+([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)', src):
        if m.group(2) in SEAM_TYPES:
            seams.append(m.group(1))
    return seams


# WHAT A HOST IS, DERIVED (ledger d48, n8). This used to be `host/**/*.lpr`, a glob
# that was wrong in both directions at once. It could not see
# lazarus/demo/phosphordemorunner.pas -- a .pas, outside host/, and the file
# lazarus/README.md calls the integration an embedder comes to copy, with four of
# its five seams nil -- while it COUNTED host/console/backup/phosphor.lpr, a
# gitignored editor copy, as a seventh host. Widening the glob would have been the
# instance fix and a worse one: it sweeps in a dozen Pascal probes that null seams
# on purpose, each needing exemption rows nobody reads.
#
# So a host is what the source says it is: a file git knows about (tracked, or new
# and not ignored) that CONSTRUCTS an engine. Each such file is then classified by
# where it lives, and one in an unclassified place fails -- a new kind of program
# that makes an engine has to be answered for before the gate says anything else.
CLASSES = [
    # (path prefix, kind, why)
    ('host/', 'host', 'a shipped host or one of its runners'),
    ('lazarus/', 'host', 'the Lazarus demo -- the integration lazarus/README.md tells '
                         'an embedder to copy'),
    ('tests/', 'probe', 'a Pascal probe: it installs and clears seams case by case and '
                        'asserts what each case did, so a table here would repeat it'),
    ('scripts/', 'probe', 'the same, for the probes that live beside the gates'),
]
CREATES = re.compile(r'\bTPhosphorEngine\s*\.\s*Create\b', re.I)


def tracked_sources():
    """Pascal sources git knows about, as repo-relative '/' paths; None when git
    cannot answer -- a failure, never an empty tree."""
    try:
        out = subprocess.run(
            ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '--',
             '*.pas', '*.lpr'],
            cwd=ROOT, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return sorted(p for p in out.splitlines() if p)


def engine_creators(rels):
    """The sources among rels that construct a TPhosphorEngine -- in code, not in
    a comment, and not the constructor's own definition."""
    out = []
    for rel in rels:
        with open(os.path.join(ROOT, rel), encoding='utf-8', errors='ignore') as fh:
            src = strip_comments(fh.read())
        for m in CREATES.finditer(src):
            if not re.search(r'\bconstructor\s*$', src[:m.start()], re.I):
                out.append(rel)
                break
    return out


def classify(rel):
    for prefix, kind, why in CLASSES:
        if rel.startswith(prefix):
            return kind
    return None


def hosts():
    rels = tracked_sources()
    if rels is None:
        return None, []
    found, unclassified = [], []
    for rel in engine_creators(rels):
        kind = classify(rel)
        if kind == 'host':
            found.append(os.path.join(ROOT, rel))
        elif kind is None:
            unclassified.append(rel)
    return found, unclassified


def main():
    seams = engine_seams()
    if not seams:
        print('check-seams: found no seam properties on TPhosphorEngine -- the '
              'parser or the engine changed shape; fix this check before trusting it.')
        return 1

    problems = []
    filled = 0
    unused = set(EXEMPT)
    found, unclassified = hosts()
    if found is None:
        print('check-seams: git could not list the tree, so this gate cannot say '
              'which programs are hosts. Run it from a git checkout.')
        return 1
    for rel in unclassified:
        problems.append('%-44s constructs an engine and lives nowhere CLASSES names '
                        '-- say whether it is a host or a probe' % rel)
    for path in found:
        base = os.path.basename(path)
        with open(path, encoding='utf-8') as fh:
            src = strip_comments(fh.read())
        for seam in seams:
            key = '%s:%s' % (base, seam)
            state = assignment(src, seam)
            if key in EXEMPT:
                unused.discard(key)
                if state == 'filled':
                    problems.append(
                        '%-44s is listed as deliberately unassigned, but it IS '
                        'assigned now -- remove the exemption' % key)
                # state == 'nil' is the exemption written in code as well as in
                # the table, which is the best case, not a problem.
                continue
            if state == 'nil':
                problems.append(
                    '%-44s is explicitly set to nil, and no reason is recorded. '
                    'Writing nil is not filling the seam.' % key)
            elif state is None:
                problems.append(
                    '%-44s is never assigned, and no reason is recorded. A nil '
                    'seam answers silently.' % key)
            else:
                filled += 1

    for key in sorted(unused):
        problems.append('%-44s is exempt in check-seams.py but that host or seam '
                        'no longer exists' % key)

    if problems:
        print('SEAMS LEFT SILENT:')
        for p in problems:
            print('  ' + p)
        print('')
        print('Assign the seam in the host, or add "<host>:<seam>" to EXEMPT in')
        print('scripts/check-seams.py with the reason it is right to leave it nil.')
        return 1

    print('seam gate: %d seams filled across %d hosts, %d deliberately nil with a '
          'reason' % (filled, len(found), len(EXEMPT)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
