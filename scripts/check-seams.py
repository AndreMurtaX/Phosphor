#!/usr/bin/env python3
"""check-seams.py -- a seam a host leaves nil is a silent answer, so say why.

THE BUG THIS EXISTS FOR. The engine offers seams and installs none of them: a host
assigns OnOutput to receive PRINT, OnInput to supply INPUT, OnBreakpoint to pause,
HostServices to provide an event pump and a clipboard. Leaving one nil is a
DESIGNED behaviour -- a headless runner has no keyboard, and `input` answering
empty is correct there. That is exactly what makes it dangerous: the nil case
looks like the working case.

`phosphorgui` assigned OnOutput and stopped. So `phosphor --gui interactive.bas`
printed every prompt at once and answered every INPUT with an empty string, in a
host with a console attached and a person at it. HostServices was nil in EVERY
host in the tree, so processmessages() answered 0 and the clipboard answered ""
in the one program written to provide them. Nothing failed. Nothing could.

WHAT THIS CHECKS. Every seam on TPhosphorEngine, against every shipped host under
host/. A host either assigns the seam, or is listed below with the reason it does
not -- and a listed reason that is no longer true (the host now assigns it) fails
too, so the table cannot rot in the other direction. A new host, or a new seam on
the engine, fails until someone answers for it. That is the point: the answer may
well be "this runner has no keyboard", but it has to be written down once.

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
    # The console host: no window, so no event loop and no widgetset clipboard.
    'phosphor.lpr:OnBreakpoint': 'a console run has nowhere to pause to; BREAKPOINT reports and continues',
    'phosphor.lpr:HostServices': 'no event loop and no widgetset clipboard in a console binary',

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

    # phosphorgui fills the three that reach a person. BREAKPOINT is report-only
    # by design (the engine never blocks on it), and a windowed host has no more
    # to say about it than a console one.
    'phosphorgui.lpr:OnBreakpoint': 'BREAKPOINT is report-and-continue; a window adds nothing the console host does not have',
}

ASSIGN = r'\.\s*%s\s*:='


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
            src = fh.read()
        for seam in seams:
            key = '%s:%s' % (base, seam)
            assigned = re.search(ASSIGN % seam, src) is not None
            if key in EXEMPT:
                unused.discard(key)
                if assigned:
                    problems.append(
                        '%-44s is listed as deliberately unassigned, but it IS '
                        'assigned now -- remove the exemption' % key)
                continue
            if not assigned:
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
