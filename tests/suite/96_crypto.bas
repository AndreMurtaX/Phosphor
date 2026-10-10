rem ---------------------------------------------------------------
rem  CRYPTO: digests, HMAC, PBKDF2 and the password record
rem  (engine/libs/PhosphorCryptoLib.pas, docs/libraries/crypto.md).
rem
rem  EXPECTED VALUES, independent of the engine. Each one is the
rem  published test vector of the standard that defines the function,
rem  and each was checked against Python's hashlib/hmac -- a second
rem  implementation -- before it was written here:
rem   - SHA-256: FIPS 180-2 appendix B ("abc", the 448-bit message,
rem     a million "a"), and the empty string.
rem   - SHA-1 "abc": RFC 3174 section 7.3. MD5: RFC 1321 appendix A.5.
rem   - HMAC-SHA256: RFC 4231 test cases 1, 2 and 6 (case 6 has a
rem     131-byte key, longer than a block, so the key is hashed first).
rem   - PBKDF2-HMAC-SHA256: RFC 7914 section 11, both vectors.
rem   - The password record is Django's format. The one below was
rem     made by hashlib.pbkdf2_hmac with that salt and 1000 rounds and
rem     base64-encoded, so verifying it is verifying interoperability.
rem  Bytes above 127 are built with bytestr$: chr$ ENCODES a code point.
rem ---------------------------------------------------------------

test_case("sha256/FIPS 180-2 vectors")
assert_eq(sha256$(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "the empty string")
assert_eq(sha256$("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "one block")
assert_eq(sha256$("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "448 bits: the padding needs a second block")
assert_eq(sha256$(string$(1000000, 97)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "a million a")
assert_eq(sha256$("é"), "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c", "the UTF-8 bytes C3 A9 are what is hashed")
assert_eq(len(sha256$("x")), 64, "64 hex digits")

test_case("sha1 and md5/RFC vectors")
assert_eq(sha1$("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d", "RFC 3174 abc")
assert_eq(md5$(""), "d41d8cd98f00b204e9800998ecf8427e", "RFC 1321 empty")
assert_eq(md5$("abc"), "900150983cd24fb0d6963f7d28e17f72", "RFC 1321 abc")

test_case("hmac_sha256/RFC 4231")
assert_eq(hmac_sha256$(string$(20, 11), "Hi There"), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "case 1")
assert_eq(hmac_sha256$("Jefe", "what do ya want for nothing?"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "case 2")
k$ = ""
for i = 1 to 131
  k$ = k$ + bytestr$(170)
next
assert_eq(hmac_sha256$(k$, "Test Using Larger Than Block-Size Key - Hash Key First"), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "case 6: a key longer than a block")

test_case("pbkdf2_sha256/RFC 7914 section 11")
assert_eq(pbkdf2_sha256$("passwd", "salt", 1, 64), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783", "c = 1, two blocks")
assert_eq(pbkdf2_sha256$("Password", "NaCl", 80000, 64), "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d", "c = 80000")
assert_eq(pbkdf2_sha256$("passwd", "salt", 1, 20), left$("55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783", 40), "a shorter key is a prefix of the longer one")

test_case("pbkdf2_sha256/bad counts are refused")
e = 0
on error goto refused
k$ = pbkdf2_sha256$("pw", "s", 0, 32)
on error goto 0
assert_eq(e, 1, "zero iterations")
e = 0
on error goto refused
k$ = pbkdf2_sha256$("pw", "s", 1.5, 32)
on error goto 0
assert_eq(e, 1, "a fractional count")
e = 0
on error goto refused
k$ = pbkdf2_sha256$("pw", "s", 1, 1025)
on error goto 0
assert_eq(e, 1, "a key past 1024 bytes")
assert_true(instr(m$, "bytes must be a whole number from 1 to 1024") > 0, "and the message says the range")
e = 0
on error goto refused
r$ = password_hash$("pw", -3)
on error goto 0
assert_eq(e, 1, "password_hash$ refuses a negative cost too")

test_case("password_hash$/the record")
r$ = password_hash$("Pässwörd", 1000)
assert_eq(left$(r$, 19), "pbkdf2_sha256$1000$", "algorithm and cost lead the record")
assert_eq(len(r$), 19 + 32 + 1 + 44, "a 32-hex-digit salt and a 44-character base64 hash")
assert_true(password_verify?("Pässwörd", r$) = true, "the password verifies")
assert_true(password_verify?("Passwörd", r$) = false, "one letter off does not")
assert_true(password_verify?("", r$) = false, "nor does nothing")
r2$ = password_hash$("Pässwörd", 1000)
assert_true(r2$ <> r$, "the same password twice gets two salts")
assert_true(password_verify?("Pässwörd", r2$) = true, "and both verify")
assert_true(password_verify?("x", password_hash$("x")) = true, "the default cost round-trips")
assert_true(instr(password_hash$("x", 1), "pbkdf2_sha256$1$") = 1, "the cost written is the cost given")

test_case("password_verify?/Django interoperability")
dj$ = "pbkdf2_sha256$1000$0123456789abcdef0123456789abcdef$fKvpGQPgU9Wt13upSc4fzCYYv13WKDTG8raoAwVtEOE="
assert_true(password_verify?("Pässwörd", dj$) = true, "a record made by hashlib verifies")
assert_true(password_verify?("Passwörd", dj$) = false, "and still refuses the wrong one")

test_case("password_verify?/only Django's own record is a record")
rem The hash fields below are Python's: hashlib.pbkdf2_hmac over the same
rem password and salt, 1000 rounds, base64 -- the 32-byte one is dj$ above.
rem Django re-encodes with dklen=32 and compares the whole record, so
rem every one of these is refused there; they used to be accepted here,
rem and the 16-byte one compared only 16 bytes.
assert_true(password_verify?("Pässwörd", "pbkdf2_sha256$1000$0123456789abcdef0123456789abcdef$fKvpGQPgU9Wt13upSc4fzA==") = false, "a hash cut to 16 bytes is refused, even with the right password")
assert_true(password_verify?("Pässwörd", "pbkdf2_sha256$1000$0123456789abcdef0123456789abcdef$fKvpGQPgU9Wt13upSc4fzCYYv13WKDTG8raoAwVtEOFI") = false, "33 bytes is refused")
assert_true(password_verify?("Pässwörd", "pbkdf2_sha256$1000$0123456789abcdef0123456789abcdef$fKvpGQPgU9Wt13upSc4fzCYYv13WKDTG8raoAwVtEOE") = false, "the base64 without its padding is refused")
assert_true(password_verify?("Pässwörd", "pbkdf2_sha256$01000$0123456789abcdef0123456789abcdef$fKvpGQPgU9Wt13upSc4fzCYYv13WKDTG8raoAwVtEOE=") = false, "a count with a leading zero is refused")

test_case("password_verify?/a damaged record is no match, not a fault")
assert_true(password_verify?("pw", "") = false, "empty")
assert_true(password_verify?("pw", "garbage") = false, "not a record")
assert_true(password_verify?("pw", "pbkdf2_sha1$1000$s$AAAA") = false, "another algorithm")
assert_true(password_verify?("pw", "pbkdf2_sha256$0$s$AAAA") = false, "zero rounds")
assert_true(password_verify?("pw", "pbkdf2_sha256$-5$s$AAAA") = false, "a sign")
assert_true(password_verify?("pw", "pbkdf2_sha256$99999999999$s$AAAA") = false, "eleven digits")
rem A record of the right shape whose count is 2^31: it reaches the range
rem check (ParseRecord's High(Integer) test) and nothing before it.
assert_true(password_verify?("pw", "pbkdf2_sha256$2147483648$0123456789abcdef0123456789abcdef$umIjVO6Qwr9OcUfz/QIrPTKOrqwI5byN1h3U4PYdKQk=") = false, "a count of 2^31, the range check itself")
assert_true(password_verify?("pw", "pbkdf2_sha256$10$$AAAA") = false, "no salt")
assert_true(password_verify?("pw", "pbkdf2_sha256$10$s$") = false, "no hash")
assert_true(password_verify?("pw", "pbkdf2_sha256$10$s$AAAA$x") = false, "a fifth field")

test_case("crypto_equal?")
assert_true(crypto_equal?("abc", "abc") = true, "same bytes")
assert_true(crypto_equal?("abc", "abd") = false, "last byte differs")
assert_true(crypto_equal?("abc", "abcd") = false, "a prefix is not equal")
assert_true(crypto_equal?("", "") = true, "two empties")
assert_true(crypto_equal?(bytestr$(0) + "a", bytestr$(0) + "b") = false, "a NUL does not end the comparison")
end

refused:
e = 1
m$ = errmsg$()
resume next
