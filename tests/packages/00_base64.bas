rem ---------------------------------------------------------------
rem base64 / hex encoding (opt-in host package): known vectors and
rem round-trips.
rem ---------------------------------------------------------------

test_case("base64/known vectors")
assert_eq(base64_encode$("Man"), "TWFu", "base64 of 'Man'")
assert_eq(base64_encode$("hello"), "aGVsbG8=", "base64 of 'hello'")
assert_eq(base64_decode$("aGVsbG8="), "hello", "decode reverses it")

test_case("base64/round trip")
s$ = "The quick brown fox jumps over 13 lazy dogs!"
assert_eq(base64_decode$(base64_encode$(s$)), s$, "decode(encode(s)) = s")

test_case("hex/vectors and round trip")
assert_eq(hex_encode$("AB"), "4142", "hex of 'AB'")
assert_eq(hex_decode$("4142"), "AB", "decode reverses it")
assert_eq(hex_decode$(hex_encode$("hello world")), "hello world", "hex round trip")
assert_eq(base64_encode$(hex_decode$("ff")), "/w==", "hex_decode is byte-exact for 0xFF (was corrupted to '?')")
assert_eq(hex_decode$(hex_encode$(chr$(233))), chr$(233), "a non-ASCII byte survives a full hex round trip")
