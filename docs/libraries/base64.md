# base64 — bytes as text: base64, URL-safe base64 and hex

`host/packages/PhosphorBase64Lib.pas` · 10 functions · opt-in host package (the `phosphor` console host registers it; an embedder calls `RegisterBase64Funcs`)

## What it is for

Plenty of places carry text and refuse bytes: a URL, an INI value, a JSON string,
a log line, a mail header. This library moves bytes through them. It offers two
alphabets — base64 (MIME, and the URL-safe variant of RFC 4648 §5) and lowercase
hex — over a string in memory or over a whole file, and it is **byte-exact in both
directions**: `base64_decode$(base64_encode$(s$))` is `s$`, and so is the hex pair,
for any bytes at all.

The encoder emits **one continuous line**. There is no MIME 76-column wrapping and
no trailing newline, which has two consequences a caller can rely on: the library's
own output always passes `base64_valid`, and a URL-safe token never carries a stray
CR or LF into a link. Text produced *elsewhere* may be wrapped, so validation
tolerates CR and LF — it strips them before judging.

The design stance is the project's usual one: **a failure is a value, not an
event**. Nothing here raises, nothing here ends the program. That was not free —
`base64_decode$("!!!!")` once let an `EStreamError` out of the RTL and killed the
script; now it answers `""` and records the failure where `base64_error()` can read
it. But `""` is also the honest decode of an empty payload, and `0` is a real
number, so the flag is the part that distinguishes "nothing" from "could not".

Read that flag carefully: **only the four operations that can fail write it** —
`base64_decode$`, `base64_urldecode$`, `base64_encodefile$` and `base64_decodefile`.
Encoding a string, validating one, and both hex functions cannot fail, so they leave
the flag exactly as they found it. A clean `base64_encode$` does **not** clear an
earlier failure. Test `base64_error()` immediately after the call whose outcome you
care about, not at the end of a paragraph of work.

## Functions

| function | what it answers |
| --- | --- |
| `base64_encode$(s$) → str` | the bytes of `s$` as MIME base64 on a single line — no wrapping, no newline, `=` padding kept. Cannot fail; `""` in gives `""` out, and the flag is untouched |
| `base64_decode$(s$) → str` | the bytes back. When the decoder rejects the text the answer is `""` and `base64_error()` becomes `1` — the program does not end. Note that it is *more tolerant* than `base64_valid`: `"aGVsbG8g d29ybGQ="` has a space in it, so validation says `0`, yet it still decodes to `hello world` with the flag clear |
| `base64_urlencode$(s$) → str` | the same encoding in the URL-safe alphabet: `+` becomes `-`, `/` becomes `_`, and the trailing `=` padding is stripped so a link never carries one. Cannot fail |
| `base64_urldecode$(s$) → str` | the reverse — `-`/`_` mapped back and the padding recomputed, so a token that arrived without its `=` still decodes. A token it cannot decode answers `""` and sets `base64_error()` to `1` |
| `base64_encodefile$(path$) → str` | a whole file's bytes as base64, read as bytes: no text conversion, no BOM handling, no line endings touched. `""` when the file is missing, locked, or refused by the [filesystem sandbox](../embedding.md#the-filesystem-sandbox), and then `base64_error()` is `1`. An empty file answers `""` too — which is exactly why the flag exists |
| `base64_decodefile(b64$, path$) → num` | `1` when the decoded bytes reached `path$`; `0` when the text would not decode or the file could not be written (sandbox refusal included), and then `base64_error()` is `1`. The payload comes first and the destination second, and an existing file is overwritten whole |
| `base64_valid(s$) → num` | `1` when `s$` is well-formed base64: the alphabet only, a length that is a multiple of 4, at most two `=` and only at the very end. CR and LF are removed first, so MIME-wrapped text from another program passes; a space, a tab or a stray byte does not. `base64_valid("")` is `0` — empty is not a base64 document. It never sets or clears the flag |
| `base64_error() → num` | `1` if the last operation that *could* fail did fail, `0` if it succeeded. Nothing clears it but the next such operation succeeding, so read it right after the call you are checking. It starts at `0` |
| `hex_encode$(s$) → str` | every byte as two lowercase hex digits — `hex_encode$("AB")` is `"4142"`. Cannot fail, does not touch the flag, and is linear in the input, so encoding tens of megabytes is a normal thing to do |
| `hex_decode$(s$) → str` | the bytes back, byte-exact including bytes ≥ 128. It **stops at the first pair that is not two hex digits** and answers what it decoded up to there: `"41zz42"` gives `"A"`, and an odd-length `"414"` gives `"A"` as well. There is no flag for this and no complaint — if a truncated answer would matter, compare `len()` against half the input |

## A worked example

Pack a small file into one line of text — the shape you would store in a config
value or hand to another program — and unpack it again, testing the flag right
after the call that can fail.

```basic
rem Write a two-line file, carry it as text, put it back.
file_writealltext("note.txt", "PHOSPHOR" + chr$(10) + "v1")

token$ = base64_encodefile$("note.txt")
if base64_error() <> 0 then
  println "cannot read note.txt"
  end
endif

println "token    : " + token$
println "valid    : " + str$(base64_valid(token$))
println "hex      : " + hex_encode$(base64_decode$(token$))

if base64_decodefile(token$, "note_copy.txt") = 1 then
  println "restored : " + file_readalltext$("note_copy.txt")
else
  println "could not write the copy"
endif

rem The URL-safe pair strips the '=' padding, so a link never carries one.
u$ = base64_urlencode$("subject=Sales & Q3?")
println "link     : /report/" + u$
println "back     : " + base64_urldecode$(u$)
println "hex back : " + hex_decode$(hex_encode$("PHOSPHOR"))

file_delete("note.txt")
file_delete("note_copy.txt")
```

It prints:

```
token    : UEhPU1BIT1IKdjE=
valid    : 1
hex      : 50484f5350484f520a7631
restored : PHOSPHOR
v1
link     : /report/c3ViamVjdD1TYWxlcyAmIFEzPw
back     : subject=Sales & Q3?
hex back : PHOSPHOR
```

Two things worth noticing:

- **The newline survives.** The hex line ends `0a7631` — the `chr$(10)` between the
  two lines is byte `0a`, carried through the file, through base64 and back out
  unchanged. Nothing in this library normalises line endings.
- **The link has no `=` on it.** `base64_urlencode$` stripped the padding, and
  `base64_urldecode$` put it back before decoding. That token would *not* pass
  `base64_valid`, which judges strict base64 — the URL-safe form is a different
  alphabet, not a variant of the same string.

## Notes

This is a **package, not part of the engine**. It lives under `host/packages/`
because the engine stays free of every optional integration; the console host
registers it along with the other opt-in packages, so a script run by `phosphor`
simply has these names, while an embedding host gets them only if it asks.

The file pair asks the [filesystem sandbox](../embedding.md#the-filesystem-sandbox)
before touching the disk, exactly like the [io](io.md) library does. Inside a
sandboxed run, a path outside the root is not an error — it is a failure with the
usual shape: `""` or `0`, and `base64_error()` at `1`.

For making data *smaller* rather than text-safe, the gzip and zip packages sit
beside this one (`gzip_compress$`, `zip_compress`); for holding and editing raw
bytes before you encode them, see [buffer](buffer.md) and its `buffer_new@`.
