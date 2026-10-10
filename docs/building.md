# Building Phosphor and PhosphorIDE from source

This tutorial takes a machine with nothing on it to two working programs:

- **Phosphor** -- the interpreter: one binary, `phosphor`, that runs, compiles,
  packs and debugs Phosphor BASIC programs, and hosts GUI programs. This
  repository.
- **PhosphorIDE** -- an editor for Phosphor BASIC that drives the `phosphor`
  binary as a child process to run, check, compile, pack and debug.
  [github.com/AndreMurtaX/PhosphorIDE](https://github.com/AndreMurtaX/PhosphorIDE).

If you only want to *use* Phosphor, you do not need any of this: download a
release and read [getting-started.md](getting-started.md). Build from source
when you want to change the code, run the test suites, or build for a machine
no release covers.

Both projects are Free Pascal programs built with Lazarus, both are MIT
licensed, and both build on **Windows and Linux** (x86-64). Everything below
was measured on these platforms; where a step was not measured, it says so.

| platform | measured with |
| --- | --- |
| Windows 10 / 11, x64 | Lazarus 4.8 with FPC 3.2.2, from the official installer |
| Ubuntu 24.04 LTS, x86-64 (also under WSL2) | the official Lazarus 4.8 / FPC 3.2.2 `.deb` packages |
| Ubuntu 26.04 LTS, x86-64 (also under WSL2) | the same packages |

The CI workflows are the authoritative recipe, because they build both projects
on clean machines on every push: [.github/workflows/ci.yml](../.github/workflows/ci.yml)
here, and PhosphorIDE's
[build.yml](https://github.com/AndreMurtaX/PhosphorIDE/blob/main/.github/workflows/build.yml).
If this page and a workflow ever disagree, the workflow is the one that ran.

---

## 1. Install the toolchain

### What both projects need

| tool | version | why |
| --- | --- | --- |
| **Lazarus** (with the FPC it bundles) | **4.8**, FPC **3.2.2** | Phosphor links the LCL, so FPC alone is not enough; PhosphorIDE is an LCL and SynEdit program. PhosphorIDE also supports Lazarus 3.6. |
| **Git** | any recent | to fetch both repositories |
| **Python 3** | 3.x | the source gates and several test generators are Python. Building needs none; the test suites **fail** without it rather than skipping, on purpose. |

### Windows

1. **Lazarus 4.8 (64-bit)** from the official download,
   `lazarus-4.8-fpc-3.2.2-win64.exe` on
   [SourceForge](https://sourceforge.net/projects/lazarus/files/Lazarus%20Windows%2064%20bits/Lazarus%204.8/).
   Install it to **`C:\lazarus`**: both projects' build scripts look there
   first. Installed elsewhere, pass the directory to Phosphor's build script
   (`-Lazarus <dir>`) and put `lazbuild.exe` on the `PATH` for PhosphorIDE's.
   The CI installs the same file silently and checks its published MD5:

   ```powershell
   lazarus-4.8-fpc-3.2.2-win64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=C:\lazarus
   ```

2. **Git for Windows** and **Python 3**, both on the `PATH`.

3. *Only for Phosphor's package tests* -- two runtime libraries the `sqlite_*`
   and `https` functions load. Without them those tests are skipped on a
   developer machine (and fail in CI, where a skip is not allowed):
   - `sqlite3.dll`, 64-bit, from [sqlite.org/download.html](https://www.sqlite.org/download.html)
     (the "Precompiled Binaries for Windows" x64 DLL);
   - OpenSSL 3: `libssl-3-x64.dll` and `libcrypto-3-x64.dll`.

   Put them in one directory on the `PATH`. Name it deliberately: a machine
   that happens to have copies inside other programs' folders (a PHP install,
   a database IDE) will load those, and nothing will say which.

### Linux (Ubuntu / Debian family)

1. **Build and test dependencies**:

   ```bash
   sudo apt-get update
   sudo apt-get install -y git python3 build-essential libgtk2.0-dev libx11-dev \
       xvfb xauth x11-utils openssl libsqlite3-0
   ```

   `libgtk2.0-dev` is needed by both projects: they are LCL programs on the
   GTK 2 widgetset, and Phosphor links the LCL even for console programs.
   GTK 2 is still in the Ubuntu 26.04 archive (measured on 2026-10-10).
   `xvfb`, `xauth` and `x11-utils` are only for the GUI tests on a machine with
   no display.

2. **Lazarus 4.8 and FPC 3.2.2** -- the official packages, the ones every
   measurement above used. From
   [SourceForge, Lazarus Linux amd64 DEB, Lazarus 4.8](https://sourceforge.net/projects/lazarus/files/Lazarus%20Linux%20amd64%20DEB/Lazarus%204.8/):

   ```bash
   sha256sum fpc-laz_3.2.2-210709_amd64.deb fpc-src_3.2.2-210709_amd64.deb \
       lazarus-project_4.8.0-0_amd64.deb
   # 92000f2b831184e153aab0c910f8ae9240450e5c6d76dc189cf53116ee501d83  fpc-laz_3.2.2-210709_amd64.deb
   # 8c9e145d8056754a9ca39ce3e52e982b8e4816124984c5f542f2a874e721ad53  fpc-src_3.2.2-210709_amd64.deb
   # 401742cefb01ad99a628188034bf728fb5360d641ed2be5f91fb0ee183a301cd  lazarus-project_4.8.0-0_amd64.deb
   sudo apt-get install -y ./fpc-laz_3.2.2-210709_amd64.deb \
       ./fpc-src_3.2.2-210709_amd64.deb ./lazarus-project_4.8.0-0_amd64.deb
   fpc -iV          # 3.2.2
   which lazbuild   # /usr/bin/lazbuild
   ```

   *Not measured:* the distribution's own `lazarus` and `lcl-gtk2` packages
   (Ubuntu 26.04 carries Lazarus 4.4). Phosphor's build script searches their
   install directories too, and PhosphorIDE states support for Lazarus 3.6 and
   4.8 -- but no build of either project has been checked against them.

3. **Build and test as an ordinary user, not as root.** Both projects test
   that a read-only file is left alone; root ignores the permission, so those
   checks fail under root for a reason that is not a defect.

### Windows Subsystem for Linux

WSL2 with Ubuntu 24.04 or 26.04 is a full Linux for both projects: follow the
Linux steps inside it. It runs natively on Hyper-V. **A VirtualBox VM on a
Windows machine with Hyper-V enabled (Docker Desktop, memory integrity) is
not equivalent**: VirtualBox falls back to an emulated path ("fall back to
NEM" in its log), the guest freezes for seconds at a time, and Phosphor's
timed tests fail there for reasons that are not in the code.

---

## 2. Get the sources, side by side

Clone both repositories into the **same parent directory**:

```bash
git clone https://github.com/AndreMurtaX/Phosphor.git
git clone https://github.com/AndreMurtaX/PhosphorIDE.git
```

```
<parent>/Phosphor
<parent>/PhosphorIDE
```

The layout is not cosmetic. PhosphorIDE finds the interpreter at
`../Phosphor/bin/` with no configuration, its build checks its keyword tables
against `../Phosphor`, and its contract test runs the `phosphor` it finds
there.

---

## 3. Build Phosphor

From `Phosphor/`:

```powershell
powershell -NoProfile -File scripts\build.ps1      # Windows
```

```bash
bash scripts/build.sh                              # Linux
```

The script builds `bin/phosphor` (`bin\phosphor.exe` on Windows) with zero
warnings and zero notes -- any warning fails it -- checks that no unit under
`engine/` reaches a host or GUI unit, and ends with two lines:

```
built:  .../Phosphor/bin/phosphor
verify: Phosphor BASIC 0.1.0
```

Try it:

```bash
echo 'println "Hello from Phosphor"' > hello.bas
bin/phosphor hello.bas
```

Two things not to do with a fresh binary: **do not start `phosphor` with no
arguments and no input** from a script -- that is the REPL, and it waits for a
person -- and do not run a program that calls `app_run()` from one either; it
is a GUI message loop and waits for its window to close.

### Phosphor from inside Lazarus

`host/console/phosphor.lpi` opens in the Lazarus IDE; build mode **Release**
passes the same flags the script does. The script remains the reference: it
is the only build that also runs the engine boundary check. To link the
engine into your own program instead, see [lazarus/README.md](../lazarus/README.md)
and [embedding.md](embedding.md).

---

## 4. Test Phosphor

Each runner exists for Windows (`.ps1`) and Linux (`.sh`) under the same name:

| runner | what it checks | needs |
| --- | --- | --- |
| `test-suite` | the language suite, the probes, the negative suite, and the ten source gates | Python |
| `test-classic` | classic `#` file I/O, `PRINT USING`, the REPL | Python |
| `test-examples` | every program under `examples/` | -- |
| `test-packages` | the opt-in packages, including SQLite and HTTP/HTTPS against local servers | Python, SQLite and OpenSSL 3 runtimes |
| `test-gui` | the GUI libraries, headless | Linux: a display, or `xvfb` |
| `test` | the console host end to end: flags, packing, the debug protocol | Python; Linux: `xvfb`, `x11-utils` |

```powershell
powershell -NoProfile -File scripts\test-suite.ps1
powershell -NoProfile -File scripts\test-suite.ps1 -ProveFailure
```

```bash
bash scripts/test-suite.sh
bash scripts/test-suite.sh -ProveFailure
```

`-ProveFailure` corrupts one expectation on purpose and passes only if the
harness catches it: a harness nobody has watched fail is not known to be able
to fail.

Every golden is compared **byte for byte**, and a run ends `SUITE OK`,
`CLASSIC OK`, `PACKAGES OK` and so on. Three traps worth knowing before your
first red run:

- **Run the runner, not a test binary.** `bin/phosphortest` is built by the
  test runners, not by `build`; running it directly after editing the engine
  runs the old code.
- **One package run at a time per machine.** The HTTP test servers listen on
  fixed ports, so two `test-packages` runs at once (two checkouts, two
  terminals) fail each other.
- **On Linux under Docker Desktop's WSL kernel**, `vm.overcommit_memory` is set
  to 1 for every distro, which changes what a too-large allocation does. The
  suite accounts for it; a host you configure yourself may not.

The working rules behind all of this, and the defect behind each rule, are in
[CLAUDE.md](../CLAUDE.md) and [dev-agent-playbook.md](dev-agent-playbook.md).

---

## 5. Build PhosphorIDE

From `PhosphorIDE/`:

```powershell
powershell -NoProfile -File scripts\build.ps1      # Windows
```

```bash
xvfb-run -a bash scripts/build.sh                  # Linux, no display
bash scripts/build.sh                              # Linux, in a desktop session
```

The script runs `lazbuild` over the editor and its two test programs, then
runs them:

| program | what it answers |
| --- | --- |
| `bin/phosphoride` | the editor itself, constructed under a timeout by `--selftest` |
| `bin/phosphoridetest` | the editor's own logic, hermetic: spawns nothing, needs no other repository |
| `bin/phosphorcontract` | the shapes the editor parses, asked of the **real** `phosphor` it finds in `../Phosphor/bin` |

and three checks against the sibling checkout: the keyword and built-in tables
are current for `../Phosphor`, the icons are current, and every citation into
either repository still points at what it claims. A green run on Phosphor
0.1.0 reports 992 unit checks, and 163 contract checks on Windows, 164 on
Linux.

**Build Phosphor first.** Without `../Phosphor/bin/phosphor` the contract test
is skipped and says so; with a Phosphor checkout that has moved since
PhosphorIDE last followed it, the keyword check fails on purpose and names the
tier that changed -- regenerate with `python tools/gen-keywords.py ../Phosphor`
and decide the new counts as PhosphorIDE's own
[CLAUDE.md](https://github.com/AndreMurtaX/PhosphorIDE/blob/main/CLAUDE.md)
describes.

On Linux the editor needs `libgtk2.0-0` (or `libgtk2.0-0t64`) at run time;
`libgtk2.0-dev` from step 1 already pulls it in. PhosphorIDE's own
[getting-started.md](https://github.com/AndreMurtaX/PhosphorIDE/blob/main/docs/getting-started.md)
continues from here to a running debug session.

---

## 6. Connect the editor to the interpreter

PhosphorIDE looks for `phosphor` in this order, from the most deliberate
answer to the most incidental: the binary picked in its Preferences,
`$PHOSPHOR_HOST`, beside the `phosphoride` binary, `../Phosphor/bin/`, the
`PATH`, and the usual install directories. With the side-by-side layout of
step 2 it finds the one you built in step 3 with no configuration. To use a
different `phosphor` -- a downloaded release, say -- pick it in Preferences
or set `PHOSPHOR_HOST`.

---

## Troubleshooting

| symptom | cause |
| --- | --- |
| `fpc not found on PATH` (Linux) | Lazarus/FPC not installed, or installed outside the `PATH`: set `FPC=/path/to/fpc` |
| `LCL gtk2 units not found` (Linux) | Lazarus without its LCL, or in a place the script does not search: set `LAZARUSDIR` |
| `LCL win32 units not found` / `fpc.exe not found` (Windows) | Lazarus not in `C:\lazarus`: pass `-Lazarus <dir>` (and `-Fpc <path>` if needed) |
| `lazbuild.exe not found` (PhosphorIDE) | put Lazarus's `lazbuild` on the `PATH` |
| a Linux binary that will not start, with no message | `libgtk2.0-0` missing |
| read-only-file checks failing | running as root |
| `SKIP` lines for SQLite or HTTPS | the runtime library is not where the loader looks; see step 1 |
| timed tests failing at random on a VirtualBox VM | the VM is freezing; use WSL2 or a real machine |
| the IDE's keyword check fails after a Phosphor pull | expected: Phosphor added built-ins; regenerate, as in step 5 |
