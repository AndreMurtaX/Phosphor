# gzip — real gzip streams, as strings and as files

`host/packages/PhosphorGzipLib.pas` · 8 functions · opt-in host package, linked into the shipped console host

## What it is for

This library packs and unpacks **real gzip** — RFC 1952, not a private format. What
it writes is the 10-byte gzip header, a raw DEFLATE body, and the CRC32 + ISIZE
trailer, so a file from `gzip_compressfile` is a `.gz` that a system `gunzip`, a
browser, or any other gzip reader opens. It reads that shape back too, including
the optional header fields a foreign producer may set (FEXTRA, FNAME, FCOMMENT,
FHCRC) — a `.gz` written by the `gzip` command reads back through
`gzip_decompressfile` unchanged. The DEFLATE codec is FPC's paszlib, which ships
with the compiler, so this needs no external runtime library and behaves the same
on both OSes.

The design stance is the engine's I/O contract: **a failure is a value, not an
event**. Nothing here raises, so `on error goto` never sees a gzip problem. A
string function that could not do what was asked answers `""`, a file function
answers `0`, and either way `gzip_error()` becomes `1`. Because the string
functions answer `""` on failure, and because gzipping an empty string and
unpacking it again legitimately answers `""` as well, **`""` is a real answer** —
`gzip_error()` is what separates "the original was empty" (`0`) from "that was
not a gzip stream" (`1`).

Two things about the measurements would otherwise surprise you. First,
`gzip_size` and `gzip_csize` perform *the same* computation: the byte length of
the string you hand them. Neither one compresses anything, and neither one
inspects a gzip header — `gzip_csize(plain$)` cheerfully answers the plain
length. The two names record which side of a comparison you meant, and
`gzip_ratio` is the comparison itself. Second, none of the three measuring
functions can fail, and none of them clears `gzip_error()`: the code always
belongs to the last *compress or decompress* that ran, not to the last call.

Some smaller facts worth knowing before you rely on them. The writer sets no
optional header fields and stores MTIME as 0, so output is **deterministic** —
the same input yields the same bytes, run to run and machine to machine. The
`level` argument is bucketed into four zlib settings rather than nine distinct
ones (`0` or less stores uncompressed and makes the output *larger*; 1–2 fastest;
3–8 default; 9 or more maximum), and an out-of-range value is clamped, not
rejected. The trailer this library writes is honest, but on reading it is
**stripped and not verified** — the CRC32 and length are there for other readers;
a corrupt body that still inflates comes back without complaint. And the two file
functions move raw bytes with no text conversion and no BOM handling, read the
whole file into memory, and go through the [filesystem
sandbox](../embedding.md#the-filesystem-sandbox) — a path the sandbox refuses
answers `0` and code `1`, exactly like a file that is not there.

## Functions

| function | what it answers |
| --- | --- |
| `gzip_compress$(s$) → str`, `gzip_compress$(s$, level) → str` | `s$` as a complete gzip stream — header, DEFLATE body, trailer. `level` is the zlib effort 0–9 (default 6); `0` stores rather than compresses, so the result is longer than the input. `""` if the codec threw, with `gzip_error()` set to `1`. Gzipping `""` is not a failure: it answers a valid 19-byte stream |
| `gzip_decompress$(s$) → str` | the original bytes behind a gzip stream. `""` when `s$` is shorter than a header plus trailer, does not start `1F 8B`, names a compression method other than DEFLATE, or fails to inflate — and then `gzip_error()` is `1`. `""` with `gzip_error()` still `0` means the stream really did hold nothing |
| `gzip_compressfile(src$, dst$) → num`, `gzip_compressfile(src$, dst$, level) → num` | `1` when `dst$` was written; `0` when `src$` could not be read or `dst$` could not be written — missing, locked, or outside the sandbox — with `gzip_error()` set to `1`. `dst$` is overwritten if it exists |
| `gzip_decompressfile(src$, dst$) → num` | `1` when the unpacked bytes reached `dst$`; `0` if `src$` is unreadable, is not a gzip stream, or `dst$` could not be written, with `gzip_error()` set to `1`. On failure `dst$` may already have been created and truncated |
| `gzip_size(s$) → num` | the byte length of `s$`, meant for the *original* side of a comparison. Never fails; `0` for `""` |
| `gzip_csize(s$) → num` | the byte length of `s$`, meant for the *packed* side. Identical arithmetic to `gzip_size` — it does not check that `s$` is a gzip stream, and answers the plain length if you pass plain text |
| `gzip_ratio(orig$, packed$) → num` | `len(packed$) / len(orig$)` — below `1` when it shrank, above `1` when packing cost more than it saved. `0` when `orig$` is empty, rather than a division error |
| `gzip_error() → num` | `0` when the last compress or decompress was clean, `1` when it failed. Only ever those two values; there is no message form. Reading it does not clear it — the next compress or decompress does |

## A worked example

Packing a log file, reporting what that bought, and reading it back. The last
part is the important half: a bad stream does not stop the program, it answers.

```basic
rem Pack a log file, say what that saved, and read it back -- then show
rem what a failure looks like, because gzip answers failures instead of
rem raising them.

src$ = "app.log"
gz$  = "app.log.gz"

text$ = ""
for i = 1 to 200
  text$ = text$ + "2026-09-06 12:00:00 INFO  request " + str$(i) + " served" + chr$(10)
next
file_writealltext(src$, text$)

if gzip_compressfile(src$, gz$, 9) = 0 then
  println "could not write " + gz$ + " -- gzip_error " + str$(gzip_error())
  end
endif

packed$ = gzip_compress$(text$, 9)
println "plain  "; gzip_size(text$); " bytes"
println "packed "; gzip_csize(packed$); " bytes"
println "that is "; round(gzip_ratio(text$, packed$) * 100); "% of the original"

back$ = gzip_decompress$(packed$)
if gzip_error() = 0 and back$ = text$ then println "string round trip: identical"

rem A failure is a value: "" and a code, not a trapped error.
junk$ = gzip_decompress$("this was never a gzip stream")
println "junk decompress: len="; len(junk$); "  gzip_error="; gzip_error()

rem The file on disk is a real .gz -- `gunzip app.log.gz` opens it too.
if gzip_decompressfile(gz$, "app.log.back") = 1 then
  println "unpacked "; len(file_readalltext$("app.log.back")); " bytes back"
endif
```

It prints 8892 bytes down to 558, "6% of the original", the round trip, then
`len=0  gzip_error=1` for the junk, then 8892 bytes back out of the file.

Two observations. The failing `gzip_decompress$` sits in the ordinary flow of the
program — no handler, no `resume` — and the line after it reads the code and
carries on; that is the whole contract. And the check after the *successful*
decompress tests `gzip_error()` before comparing, because a program that only
tested `back$ <> ""` would read a legitimately empty payload as a failure.

## Notes

- **The string and file halves are the same container.** `gzip_compressfile` is
  `gzip_compress$` over the file's bytes, so a string you packed in memory can be
  written to a `.gz` yourself and a `.gz` from anywhere can be read with
  `file_readalltext$` and handed to `gzip_decompress$`.
- **This is a package, not engine core.** It is registered by
  `RegisterGzipFuncs`, which the console host calls along with the other opt-in
  packages; an embedding host that does not call it will report these eight names
  as unknown functions. See [embedding.md](../embedding.md).
- For the other compressed container, see the `zip_*` family, which builds
  multi-entry archives instead of a single stream.
