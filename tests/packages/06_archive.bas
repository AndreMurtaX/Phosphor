rem ---------------------------------------------------------------
rem archive (opt-in host packages): zip create/add/list/extract, gzip
rem string+file round-trips with a size/ratio check, and base64 file
rem encode/decode. Mirrors oracle 23 (23_archive.bas) in Phosphor's
rem own package style -- functional equivalence, not a byte port:
rem handle type '@' (not '#'), zip_*/gzip_*/base64_* names, and
rem Phosphor's 1-based/0-absent instr. Everything lives under bin\ ,
rem which git ignores. gzip here also completes oracle 11's gzip half.
rem ---------------------------------------------------------------

z$ = "bin/p9b_arc.zip"
src$ = "bin/p9b_arc_src.txt"
out$ = "bin/p9b_arc_out.txt"
gz$ = "bin/p9b_arc.gz"

file_delete(z$)
file_delete(src$)
file_delete(out$)
file_delete(gz$)
file_delete("bin/p9b_b64_out.txt")
if dir_exists("bin/p9b_ex") <> 0 then dir_delete("bin/p9b_ex", 1)
if dir_exists("bin/p9b_all") <> 0 then dir_delete("bin/p9b_all", 1)
if dir_exists("bin/p9b_unq") <> 0 then dir_delete("bin/p9b_unq", 1)

rem A payload that actually compresses, so the ratio means something.
body$ = ""
for i = 1 to 40
  body$ = body$ + "the quick brown fox jumps over the lazy dog" + chr$(10)
next
file_writealltext(src$, body$)

test_case("zip/create-and-add")
a@ = zip_create@(z$)
assert_true(probe_is_handle(a@), "zip_create@ answers a handle")
zip_addfile(a@, src$, "doc/source.txt")
zip_addstr(a@, "hello from a string", "doc/inline.txt")
zip_close(a@)
assert_true(file_exists(z$), "the archive is on disk after zip_close")

test_case("zip/read-back")
r@ = zip_open@(z$)
assert_true(probe_is_handle(r@), "zip_open@ answers a handle")
assert_eq(zip_count(r@), 2, "both entries are there")
assert_true(zip_exists(r@, "doc/inline.txt"), "zip_exists finds an entry")
assert_false(zip_exists(r@, "doc/absent.txt"), "and does not invent one")
assert_eq(zip_read$(r@, "doc/inline.txt"), "hello from a string", "zip_read$ answers the content")
assert_eq(zip_entrysize(r@, "doc/inline.txt"), 19, "zip_entrysize answers the uncompressed size")
names$ = zip_list$(r@)
assert_true(instr(names$, "doc/source.txt"), "zip_list$ names an entry it holds")

test_case("zip/extract")
rem The third argument is a DIRECTORY; the entry keeps its path inside it.
zip_extract(r@, "doc/inline.txt", "bin/p9b_ex")
assert_eq(file_readalltext$("bin/p9b_ex/doc/inline.txt"), "hello from a string", "zip_extract writes the entry under the directory it was given")
zip_extractall(r@, "bin/p9b_all")
assert_true(file_exists("bin/p9b_all/doc/source.txt"), "zip_extractall recreates the tree")
zip_close(r@)

test_case("zip/quick")
rem The one-call form, which is what most programs will reach for.
file_delete(z$)
zip_quick(src$, z$)
assert_true(file_exists(z$), "zip_quick makes an archive from one file")
q@ = zip_open@(z$)
assert_eq(zip_count(q@), 1, "holding that one file")
zip_close(q@)
rem zip_quick stores the bare file name, so the entry has no directory.
unzip_extract(z$, "bin/p9b_unq")
assert_true(file_exists("bin/p9b_unq/p9b_arc_src.txt"), "unzip_extract puts it back")

test_case("zip/quick-entry-name")
rem A forward-slash source stores the bare name -- ExtractFileName splits on
rem both slashes here, so the archive's shape does not follow which slash the
rem programmer typed (the wart the reference had).
file_delete("bin/p9b_sep.zip")
zip_quick(src$, "bin/p9b_sep.zip")
sep@ = zip_open@("bin/p9b_sep.zip")
assert_eq(zip_list$(sep@), "p9b_arc_src.txt", "a forward-slash source stores the bare name")
zip_close(sep@)
file_delete("bin/p9b_sep.zip")

test_case("zip/error")
rem zip_error answers a code, not a message.
bad@ = zip_open@("bin/p9b_does_not_exist.zip")
assert_true(zip_error(), "a failed open leaves a non-zero code behind")

test_case("gzip/string-roundtrip")
packed$ = gzip_compress$(body$)
assert_eq(gzip_decompress$(packed$), body$, "gzip_compress$ and gzip_decompress$ are a round trip")
assert_true(len(packed$), "the packed form is not empty")

test_case("gzip/level")
rem gzip_compress$ takes an optional level. Both ends of the range come back
rem as what went in; which one is smaller is zlib's business, not this suite's.
fast$ = gzip_compress$(body$, 1)
best$ = gzip_compress$(body$, 9)
assert_eq(gzip_decompress$(fast$), body$, "level 1 round-trips")
assert_eq(gzip_decompress$(best$), body$, "level 9 round-trips")

test_case("gzip/files")
gzip_compressfile(src$, gz$)
assert_true(file_exists(gz$), "gzip_compressfile writes the packed file")
gzip_decompressfile(gz$, out$)
assert_eq(file_readalltext$(out$), body$, "gzip_decompressfile puts the text back")
file_delete(gz$)
gzip_compressfile(src$, gz$, 9)
assert_true(file_exists(gz$), "gzip_compressfile writes it at a stated level")

test_case("gzip/sizes")
rem gzip_size measures the original text, gzip_csize the packed form, and
rem gzip_ratio compares the two.
assert_eq(gzip_size(body$), len(body$), "gzip_size measures the original text")
assert_true(gzip_csize(packed$), "gzip_csize measures the packed form")
ratio = gzip_ratio(body$, packed$)
assert_true(ratio, "gzip_ratio answers a number")
if ratio < 1 then smaller = 1
assert_true(smaller, "and forty repeated lines pack down rather than up")
assert_eq(gzip_error(), 0, "nothing above failed, so the code is clear")

test_case("base64/no-line-breaks")
rem Phosphor's base64_encode$ emits a continuous line -- no MIME 76-char wrap --
rem so nothing under it carries a stray CR or LF, and its own output is valid.
long$ = ""
for i = 1 to 10
  long$ = long$ + "abcdefghij"
next

wide$ = base64_encode$(long$)
assert_eq(len(wide$), 136, "100 bytes encode to exactly 136 characters, with nothing added")
assert_eq(instr(wide$, chr$(13)), 0, "no carriage return")
assert_eq(instr(wide$, chr$(10)), 0, "no line feed")
assert_eq(base64_valid(wide$), 1, "and the library calls its own output valid")
assert_eq(base64_decode$(wide$), long$, "which still round-trips")

url$ = base64_urlencode$(long$)
assert_eq(instr(url$, chr$(10)), 0, "a URL-safe string has no line feed in it")
assert_eq(base64_urldecode$(url$), long$, "and round-trips too")

test_case("base64/validity")
rem Validation tolerates the CR/LF that MIME wrapping produces, but a space is
rem not part of any base64 convention and stays invalid.
wrapped$ = "aGVsbG8g" + chr$(13) + chr$(10) + "d29ybGQ="
assert_eq(base64_valid(wrapped$), 1, "wrapped base64 from elsewhere is still valid")
assert_eq(base64_decode$(wrapped$), "hello world", "and decodes to what it holds")
assert_eq(base64_valid("aGVsbG8g d29ybGQ="), 0, "but a space is still invalid")

test_case("base64/files")
enc$ = base64_encodefile$(src$)
assert_true(len(enc$), "base64_encodefile$ answers text")
assert_eq(base64_valid(enc$), 1, "and that text is valid base64")
base64_decodefile(enc$, "bin/p9b_b64_out.txt")
assert_eq(file_readalltext$("bin/p9b_b64_out.txt"), body$, "base64_decodefile puts the bytes back")
assert_eq(base64_error(), 0, "nothing above failed, so the code is clear")

rem clean up the scratch tree
file_delete(z$)
file_delete(src$)
file_delete(out$)
file_delete(gz$)
file_delete("bin/p9b_b64_out.txt")
if dir_exists("bin/p9b_ex") <> 0 then dir_delete("bin/p9b_ex", 1)
if dir_exists("bin/p9b_all") <> 0 then dir_delete("bin/p9b_all", 1)
if dir_exists("bin/p9b_unq") <> 0 then dir_delete("bin/p9b_unq", 1)
