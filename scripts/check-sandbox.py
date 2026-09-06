#!/usr/bin/env python3
"""check-sandbox.py -- no filesystem call escapes the sandbox gate.

The engine has four execution ceilings. Three of them (MaxSteps, TimeoutMs,
MaxOutputBytes) are enforced in one place each, in the VM, so they cannot be
forgotten. The fourth -- the filesystem root -- is enforced at every call that
touches a path, which is exactly the kind of rule that rots: the next library
function that opens a file is one `SandboxAllows` away from being a hole, and
nothing would say so.

This is what says so. Every routine in engine/ and host/packages/ that reaches an
OS filesystem primitive must also ask the gate (PhosphorSandbox.SandboxAllows),
or be listed below with the reason it does not have to be.

Exit 0 = every filesystem call is gated. Exit 1 = a hole; the routine is named.

Run standalone, or through scripts/test-suite.{ps1,sh} which runs it before the
suite.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The OS calls that reach the filesystem. Reads are here too: with a root set, a
# script must not be able to read outside it either.
PRIMITIVES = [
    'DeleteFile', 'RemoveDir', 'CreateDir', 'ForceDirectories', 'RenameFile',
    'SetCurrentDir', 'FindFirst', 'TFileStream.Create', 'FileExists',
    'DirectoryExists', 'FileAge', 'FileSetDate', 'AssignFile', 'LoadFromFile',
    'SaveToFile', 'FileCreate', 'FileOpen',
    'GetTempFileName', 'GetTempDir', 'GetUserDir',
]
# DeleteTree and CopyTree are NOT in that list: they are this project's own
# helpers and they ask the gate themselves, at every level of their recursion.

GATE = re.compile(r'\bSandbox(Allows|Active|ScratchPath|Root)\b')

# A routine may skip the gate only for a reason written down here. The key is
# "<file>:<routine>"; the value is why. Anything not listed and not gated fails.
ALLOWED = {
    # The gate itself: these three ARE the check, so they cannot ask it.
    'PhosphorSandbox.pas:FollowLinks': 'resolves the path the gate then judges',
    'PhosphorSandbox.pas:SetSandboxRoot': 'installs the root; host-only, no script reaches it',
    'PhosphorSandbox.pas:SandboxScratchPath': 'creates the scratch dir INSIDE the root',
    # Reads of a fixed OS-owned path, with no script-supplied component: a script
    # cannot steer these anywhere, so a root would bound nothing.
    'PhosphorPlatformLib.pas:ReadFirstLine': 'reads /etc/os-release and friends; the path is a constant in this unit',
    'PhosphorHttpLib.pas:LocateCABundle': 'probes the platform CA bundle list, a constant array',
}

SCAN_DIRS = [
    os.path.join(ROOT, 'engine'),
    os.path.join(ROOT, 'engine', 'libs'),
    os.path.join(ROOT, 'host', 'packages'),
]
# The hosts are deliberately NOT scanned. The sandbox bounds the SCRIPT, not the
# program that chose to run one: a host reading the file named on its own command
# line is doing its job, before any script exists to be bounded. What is scanned
# is everything a script can reach through a registered function.
SCAN_FILES = []

ROUTINE = re.compile(r'^(?:function|procedure|constructor|destructor)\s+'
                     r'([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)',
                     re.MULTILINE)


def strip_comments(text):
    """Pascal comments out. A primitive named in prose is documentation."""
    text = re.sub(r'(?m)//.*?$', ' ', text)
    text = re.sub(r'(?s)\{.*?\}', ' ', text)
    text = re.sub(r'(?s)\(\*.*?\*\)', ' ', text)
    return re.sub(r"'(?:[^']|'')*'", "''", text)   # and string literals


def routines_of(text):
    """Split into top-level routine bodies. A nested helper's calls count against
    the routine that encloses it -- conservative on purpose: the enclosing
    routine is where the guard belongs anyway."""
    marks = [(m.start(), m.group(1)) for m in ROUTINE.finditer(text)]
    for i, (pos, name) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(text)
        yield name, text[pos:end]


def sources():
    seen = set()
    for d in SCAN_DIRS:
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if fn.endswith('.pas'):
                p = os.path.join(d, fn)
                if p not in seen:
                    seen.add(p)
                    yield p
    for p in SCAN_FILES:
        if os.path.isfile(p) and p not in seen:
            seen.add(p)
            yield p


def main():
    holes = []
    gated = 0
    unused = set(ALLOWED)
    for path in sources():
        base = os.path.basename(path)
        with open(path, encoding='utf-8') as fh:
            text = strip_comments(fh.read())
        for name, body in routines_of(text):
            hits = [p for p in PRIMITIVES if p in body]
            if not hits:
                continue
            key = '%s:%s' % (base, name)
            if key in ALLOWED:
                unused.discard(key)
                continue
            if GATE.search(body):
                gated += 1
                continue
            holes.append((key, sorted(set(hits))))

    if holes:
        print('SANDBOX HOLES -- these reach the filesystem without asking the gate:')
        for key, hits in holes:
            print('  %-52s %s' % (key, ', '.join(hits)))
        print('')
        print('Add SandboxAllows(<path>, puRead|puWrite|puDelete) to each, or list it')
        print('in ALLOWED in scripts/check-sandbox.py with the reason it is exempt.')
        return 1

    print('sandbox gate: %d routines reach the filesystem, all %d gated, '
          '%d exempt by name' % (gated + len(ALLOWED) - len(unused),
                                 gated, len(ALLOWED) - len(unused)))
    if unused:
        # A stale exemption is a rule nobody is checking any more.
        print('STALE EXEMPTIONS -- listed in ALLOWED but no longer present:')
        for key in sorted(unused):
            print('  ' + key)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
