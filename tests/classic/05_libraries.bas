rem Every shipped library is reachable through the `phosphor` host. Round-trips
rem keep the output deterministic (the RTL-backed packages work on every desktop;
rem the sqlite/http packages are also linked in, and are exercised by the package
rem suite where their runtime libraries are present).

rem engine libraries
println "str: "; ucase$("phosphor"); " "; len("phosphor")
println "num: "; abs(0 - 5); " "; max(3, 9)
d@ = dict@()
dict_set@(d@, "answer", 42)
println "dict: "; dict_get(d@, "answer")
j@ = json_parse@("{\"n\": 7}")
println "json: "; json_getn(j@, "n")

rem opt-in packages (base64, gzip, zip -- all RTL-backed)
println "base64: "; base64_decode$(base64_encode$("Phosphor"))
println "gzip: "; gzip_decompress$(gzip_compress$("hello world hello world"))

z$ = path_combine$(temppath$(), "phosphor_classic.zip")
zbuild@ = zip_create@(z$)
zip_addstr(zbuild@, "zipped!", "note.txt")
zip_close(zbuild@)
zread@ = zip_open@(z$)
println "zip: "; zip_count(zread@); " "; zip_read$(zread@, "note.txt")
zip_close(zread@)
ok% = file_delete(z$)
println "done: "; ok%
