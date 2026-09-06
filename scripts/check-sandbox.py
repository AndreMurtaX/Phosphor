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
import glob
import io
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
    # An INI file is a file. These were missing, and PhosphorConfigLib opened one
    # by path with no guard at all -- a sandboxed script could read and write an
    # .ini anywhere on the disk while file_writealltext to the same path was
    # refused. Found by an agent READING the library to document it, not by any
    # check: the gate only knows the primitives it is told about.
    'TIniFile.Create', 'TMemIniFile.Create', 'TCustomIniFile.Create',
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



# --- no test may name a filesystem root and a removal in the same breath -------
_SEP = r'\\/'          # both separators, spelled once
ROOT_ARG = re.compile(
    r'dir_delete\s*\(\s*(?:'
    r'"\s*"'                          # the empty path, or whitespace only
    r'|"[' + _SEP + r']+"'            # a bare separator: the filesystem root
    r'|"[A-Za-z]:[' + _SEP + r']*"'   # C:  C:\  C:/  C:\\ ...
    r'|"[A-Za-z]:"\s*\+'              # "C:" + something
    r'|bs\$'                          # the bare-separator variable this tree uses
    r')')


def no_root_deletes():
    """A test must never CALL the recursive remover on a drive or filesystem root.

    Not because such a call would succeed -- the perilous-path rule refuses it,
    and has since the rule was written -- but because a file that contains the
    call spelled against a root is one edit, or one regression in that rule, away
    from being the disaster it was written to prove against. This project has
    already lost thirteen working trees to a defective dir_delete.

    The property is proven where it can be ASKED instead of attempted:
    tests/probe_sandbox.lpr calls SandboxAllows and IsPerilousPath, both pure
    functions that answer True or False and touch nothing.

    Comment lines are exempt -- prose explaining the history is not a call -- but
    the spelling is discouraged even there.
    """
    bad = []
    for pat in ('tests/**/*.bas', 'tests/**/*.lpr', 'examples/**/*.bas'):
        for path in glob.glob(os.path.join(ROOT, pat), recursive=True):
            for n, line in enumerate(io.open(path, encoding='utf-8',
                                             errors='ignore'), 1):
                stripped = line.strip()
                if stripped.startswith(('rem ', "'", '//', '{', '*')):
                    continue
                if ROOT_ARG.search(line):
                    rel = os.path.relpath(path, ROOT).replace(os.sep, '/')
                    bad.append((rel, n, stripped[:88]))
    if bad:
        print('A TEST CALLS THE RECURSIVE REMOVER ON A FILESYSTEM ROOT:')
        for rel, n, text in bad:
            print('  %s:%d  %s' % (rel, n, text))
        print('')
        print('Ask the gate instead of attempting the removal: SandboxAllows and')
        print('IsPerilousPath both answer True or False and touch nothing. See the')
        print('block in tests/probe_sandbox.lpr for the shape.')
        return False
    return True


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

    # The second rule this file carries: no test may CALL the recursive remover
    # on a root. See no_root_deletes for why a passing test is not enough.
    if not no_root_deletes():
        return 1
    print('and no test calls a recursive removal on a filesystem root.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
