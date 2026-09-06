# rag — a local retrieval index over a folder of markdown files

`engine/libs/PhosphorRagLib.pas` · 14 functions · always available

## What it is for

Despite the name, nothing here goes anywhere: no network, no HTTP, no embedding
model, no vector database. A rag index is a **local retrieval index over a folder
of markdown documents**, each carrying a YAML-style front matter header between
`---` markers (id, title, category, tags, functions, complexity, platform …),
scored against a question by a multi-signal keyword rule. It answers a plain
string a program can print, save, or hand to something else. The scoring is fixed
arithmetic over the header fields, so the same question over the same folder
always brings back the same documents in the same order, byte for byte.

An index is a handle, validated through the same registry every other Phosphor
handle uses, and that is where the library takes its stance: **a refusal is a
value, not an event**. A fabricated handle (`pointer@(n)`), or one already passed
to `rag_free`, is never dereferenced — the call answers `0`, `""` or `[]`, and
`rag_error()` answers `1` so a program can tell "nothing matched" from "you
handed me something that is not an index". Where the Delphi reference this was
ported from raised on a bad handle, Phosphor answers.

One function deliberately breaks that pattern, and it is worth knowing before it
surprises you: **`rag_doc$` reports in band**. A missing id answers the text
`Error: document not found: <id>`, not an empty string, and a bad handle answers
`Error: invalid RAG handle`. That channel is kept from the reference on purpose,
so a caller of `rag_doc$` must read the answer as text rather than test it for
emptiness. `rag_error()` does not report a missing id — it reports handle faults
only.

Two more things a caller would otherwise trip over. `rag@` reads nothing: it
remembers a base path and hands back an empty index, and the folder is not
scanned until `rag_rebuild@` — forgetting that is the commonest way to get an
empty retrieval that looks like a fault. And a folder that does not exist, that
the sandbox denies, or that holds no `.md` files is **zero documents, not an
error**: an empty index is a real answer, and the scan is of that one folder
only, never its subfolders.

## Functions

### The index

| function | what it answers |
| --- | --- |
| `rag@(basepath$) → handle` | a new, empty index over that folder. Always a handle, even for a folder that does not exist — nothing is read yet, so nothing can fail yet |
| `rag_rebuild@(idx@) → handle` | scans `basepath$` for top-level `*.md`, parses each header, and replaces whatever was indexed before; answers **the same handle back**, so calls chain. A missing, denied or empty folder leaves zero documents and no error. A bad handle is handed straight back unread, with `rag_error()` at `1` |
| `rag_free(idx@) → num` | releases the index and its cached document text: `1` when it did, `0` when the handle was not a live index (already freed, or fabricated) — and `rag_error()` is `1` in that case |
| `rag_count(idx@) → num` | how many documents the last rebuild indexed. `0` before any rebuild, `0` for an empty folder, `0` for a bad handle — `rag_error()` separates the last case from the first two |
| `rag_funccount(idx@) → num` | how many distinct function names, compared case-insensitively, the indexed headers declare between them. `0` when no header names any, and `0` for a bad handle |
| `rag_error() → num` | `0`, or `1` when the last call that took a handle was given something that was not a live index. One engine-wide slot shared by every index, set by every call above; it reports **handle faults only** — never a missing folder, a missing document id, or a retrieval that matched nothing |

### Retrieval

| function | what it answers |
| --- | --- |
| `rag_retrieve$(idx@, query$) → str` | the documents that clear the relevance floor, best first, rendered as `### Title` followed by the document body, blocks separated by a blank line, with `(truncated)` appended to any block cut to fit the default 6000-token budget. `""` when nothing scored — and also `""` for a bad handle, which is what `rag_error()` is for |
| `rag_retrieve_budget$(idx@, query$, maxtokens) → str` | the same retrieval under an explicit budget, a token counted as 4 characters; `maxtokens` of `0` or less means the default 6000. Blocks here carry **no** `(truncated)` note. A tight budget cuts a local copy only, so asking small first never costs you the whole document afterwards. `""` when nothing scored or the handle is bad |
| `rag_retrieve_json$(idx@, query$) → str` | the same retrieval as a JSON array — id, title, category, score, tokens, truncated and content per document. `[]` when nothing scored, and `[]` for a bad handle |
| `rag_analyze$(idx@, query$) → str` | what the engine made of the question *before* scoring anything, as a JSON object: the keywords left after stop words are dropped, the function names it recognised, the library ids the question named outright, a guessed intent (gui, data, network, database, game …), and whether it reads as a follow-up. A question it made nothing of is still an object, with empty arrays and an empty intent; only a bad handle answers `""` |

### Lookup and description

| function | what it answers |
| --- | --- |
| `rag_doc$(idx@, id$) → str` | the body of the document with that id, matched case-insensitively, front matter stripped. **The exception in this library**: a missing id answers `Error: document not found: <id>` and a bad handle `Error: invalid RAG handle` — a message, never `""` |
| `rag_functions$(idx@, names$) → str` | the documents that **declare** those functions in their header, names separated by commas or spaces and matched whole and case-insensitively, suffix included (`button_onclick@`, not `button_onclick`). Rendered without scores. `""` when no document declares any of them. It takes function names, not a document id, and it does not search document text |
| `rag_tags$(idx@, tags$) → str` | the documents carrying any of those comma-separated tags, trimmed and lowercased before comparing. Rendered **with** the score in the heading — `### Title (score: 3.0)` — where `rag_functions$` renders without. `""` when no document carries them |
| `rag_summary$(idx@) → str` | a human-readable block naming the base path, the document count, the distinct functions and tags indexed, and the default token budget. `""` only for a bad handle: an empty index still describes itself |

## A worked example

A knowledge base of two documents, written to disk by the program itself, indexed,
and then asked the same question four different ways. Nothing leaves the machine.

```basic
rem Build the base: two documents about deliberately different things.
kb$ = "bin/kb_demo"
if dir_exists(kb$) = 0 then dir_create(kb$)

d$ = "---" + chr$(10)
d$ = d$ + "id: buttondoc" + chr$(10)
d$ = d$ + "title: Buttons" + chr$(10)
d$ = d$ + "category: library" + chr$(10)
d$ = d$ + "tags: button, click, gui" + chr$(10)
d$ = d$ + "functions: button@, button_onclick@" + chr$(10)
d$ = d$ + "---" + chr$(10)
d$ = d$ + "# Buttons" + chr$(10)
d$ = d$ + "A button is a control that answers a click." + chr$(10)
file_writealltext(kb$ + "/buttondoc.md", d$)

s$ = "---" + chr$(10)
s$ = s$ + "id: sounddoc" + chr$(10)
s$ = s$ + "title: Sound" + chr$(10)
s$ = s$ + "category: library" + chr$(10)
s$ = s$ + "tags: audio, sound, media" + chr$(10)
s$ = s$ + "functions: media_player@, media_play" + chr$(10)
s$ = s$ + "---" + chr$(10)
s$ = s$ + "# Sound" + chr$(10)
s$ = s$ + "A media player holds a track and plays it." + chr$(10)
file_writealltext(kb$ + "/sounddoc.md", s$)

rem rag@ only remembers the folder. rag_rebuild@ is what reads it.
kb@ = rag@(kb$)
rag_rebuild@(kb@)
println "indexed " + str$(rag_count(kb@)) + " documents, " + str$(rag_funccount(kb@)) + " function names"
println rag_summary$(kb@)

rem A question, scored by tag, title, function name and id.
println rag_retrieve$(kb@, "how do I handle a button click")

rem What it made of that question, before scoring anything.
println rag_analyze$(kb@, "how do I handle a button click")

rem The same index, asked three narrower ways.
println rag_tags$(kb@, "audio")
println rag_functions$(kb@, "button_onclick@")
println rag_doc$(kb@, "sounddoc")

rem The retrieval a caller feeds to something with a size limit.
println rag_retrieve_budget$(kb@, "button click", 40)
println rag_retrieve_json$(kb@, "button click")

rem A missing id is the one in-band error here: a message, not "".
answer$ = rag_doc$(kb@, "nosuchdoc")
if instr(answer$, "Error:") = 1 then println "no such document"

rag_free(kb@)

rem The handle is gone. The next call refuses it as a VALUE.
println "count after free: " + str$(rag_count(kb@)) + ", rag_error = " + str$(rag_error())
dir_delete(kb$, 1)
```

Two things worth noticing:

- **The last two lines print `0` and `1`, and the program keeps running.** A dead
  handle does not abort anything and is never followed; the answer is the same
  `0` an empty index gives, and `rag_error()` is the only thing that tells them
  apart. Read it right after the call you doubt — the next call overwrites it.
- **`rag_tags$` and `rag_functions$` are not searches.** They match the `tags:`
  and `functions:` lines of the header exactly. `rag_functions$(kb@, "button")`
  finds nothing, because what the header declares is `button@`.

## Notes

**The header it reads.** Between the opening `---` and the next `---`, one
`key: value` per line. The keys it understands are id, title, category,
subcategory, tags, functions, depends, complexity, platform and summary; tags,
functions and depends are comma-separated lists (surrounding brackets are
tolerated). Any other key, and any line without a colon, is ignored rather than
rejected. A `.md` file with **no** front matter is still indexed, taking its id
and title from the filename stem, category `library`, and a single tag equal to
that stem — so a folder of ordinary markdown notes is usable as it stands.

**What the score is made of.** A function-name match weighs 5.0, a library id the
question named outright 10.0, a tag 3.0, an id 3.0, a title keyword 2.5, and any
`category: language` document gets a 0.5 baseline (1.5 when its id is
`conventions` or `syntax`). A document under 1.0 is not returned; at most 40 come
back; only a document at 8.0 or above is admitted over the token budget, and then
it is the one that gets truncated. Scores are rendered with an invariant decimal
point, so an index answers `score: 3.0` on every machine and never `score: 3,0`.

**Reading is sandboxed.** Files and folders are read through the same permission
check `io` uses, so a base path outside the sandbox indexes as empty rather than
failing loudly. The behaviour of the whole library, including the cache that
survives a tight budget, is pinned by `tests/suite/33_rag.bas`.
