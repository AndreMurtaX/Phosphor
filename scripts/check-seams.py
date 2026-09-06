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
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The seam types the engine exposes as assignable properties. Read from the source
# rather than listed here, so a seam added to TPhosphorEngine cannot be missed.
SEAM_TYPES = ('TPhosphorOutputProc', 'TPhosphorInputProc',
              'TPhosphorBreakpointProc', 'THostServices')

# reason == None means "must be assigned". A string means "deliberately not
# assigned, because ...". Keys are "<host file>:<seam>".
EXEMPT = {
    # The one shipped host. It fills OnOutput, OnInput and HostServices -- the last
    # only when a graphical session is reachable, which is the point of the merge.
    'phosphor.lpr:OnBreakpoint': 'BREAKPOINT is report-and-continue; there is nowhere for a host to pause to',

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


def hosts():
    out = []
    for p in sorted(glob.glob(os.path.join(ROOT, 'host', '**', '*.lpr'), recursive=True)):
        out.append(p)
    return out


def main():
    seams = engine_seams()
    if not seams:
        print('check-seams: found no seam properties on TPhosphorEngine -- the '
              'parser or the engine changed shape; fix this check before trusting it.')
        return 1

    problems = []
    filled = 0
    unused = set(EXEMPT)
    for path in hosts():
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
          'reason' % (filled, len(hosts()), len(EXEMPT)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
