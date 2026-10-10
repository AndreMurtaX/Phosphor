# crypto — digests, HMAC, PBKDF2 and password records

`engine/libs/PhosphorCryptoLib.pas` · 8 functions · always available

## What it is for

Three jobs a program meets sooner or later:

- **A fingerprint of some bytes** — to notice that a file changed, to name a
  cache entry by its content, to match a checksum another program published:
  `sha256$`, and `sha1$`/`md5$` for the checksums the world still prints.
- **Proof that a message came from someone holding a key** — a webhook
  signature, a signed token: `hmac_sha256$`, compared with `crypto_equal?`.
- **Keeping a password without keeping the password** — `password_hash$` turns
  it into a record that is safe to store, and `password_verify?` answers whether
  a typed password matches that record.

Every function reads a string's **bytes exactly as they are stored**. Phosphor
strings are UTF-8, so `sha256$("é")` hashes the two bytes C3 A9 — the same
answer any other language gives for the UTF-8 text. Nothing is transcoded. For
binary data, build the string with `bytestr$` (`chr$` *encodes* a code point and
is not a byte constructor). Every digest is returned as **lowercase hex**.

## Storing passwords

```basic
rem When an account is created, or its password changed:
record$ = password_hash$("correct horse battery staple")
rem ... store record$ in the database; never store the password ...

rem At login:
if password_verify?(typed$, record$) = true then
  println "welcome"
else
  println "user name or password is wrong"
end if
```

The record looks like this, and it is **Django's format**, field for field:

```
pbkdf2_sha256$600000$9f86d081884c7d659a2feaa0c55ad015$Ot3...base64...=
algorithm     cost   salt (32 hex digits)             PBKDF2-HMAC-SHA256 of the password, base64
```

What that buys:

- **A fresh salt every time.** Hashing the same password twice gives two
  different records, so two users with the same password are not visible as
  such, and a precomputed table of common passwords is useless. The salt is 128
  bits from one `CreateGUID` — the operating system's random UUID, 122 of whose
  bits are random. A salt has to be unique, not secret, and that is far more than
  uniqueness needs.
- **A deliberate cost.** 600 000 rounds of HMAC-SHA256 is OWASP's current figure
  for PBKDF2 and Django 4.2's default. It costs about a third of a second per call
  — nothing at a login, and a great deal to someone trying a billion guesses.
- **A record that describes itself.** The algorithm and the cost travel inside
  it, so raising the cost later (`password_hash$(pw$, 1200000)`) leaves every old
  record verifiable — re-hash a user's password with the new cost the next time
  they log in successfully.
- **Interoperability.** A record made here verifies in Django, and a record
  Django made with its PBKDF2-SHA256 hasher verifies here. The test suite
  verifies one made by Python's `hashlib`.

`password_verify?` compares the derived key in **constant time**, so how long it
takes does not reveal how much of a guess was right.

## Functions

| function | what it answers |
| --- | --- |
| `sha256$(s$) → str` | the SHA-256 digest (FIPS 180-4) of `s$`'s bytes, as 64 lowercase hex digits. `sha256$("")` is `e3b0c442…b855`, the standard's own value |
| `sha1$(s$) → str` | the SHA-1 digest, 40 hex digits. **SHA-1 is broken for collision resistance**: use it to match a checksum someone else published, never to protect anything |
| `md5$(s$) → str` | the MD5 digest, 32 hex digits. The same warning, more so |
| `hmac_sha256$(key$, msg$) → str` | HMAC-SHA256 (RFC 2104) of `msg$` under `key$`, 64 hex digits. A key longer than 64 bytes is hashed first, as the RFC says. Check a received signature with `crypto_equal?`, not `=` |
| `pbkdf2_sha256$(password$, salt$, iterations, bytes) → str` | PBKDF2-HMAC-SHA256 (RFC 8018) — the raw key derivation, `bytes` long, in hex (`2 * bytes` digits). `iterations` must be a whole number from 1 to 2147483647 and `bytes` one from 1 to 1024; anything else **raises**. Each 32 bytes of output costs the full iteration count again |
| `password_hash$(password$) → str` | a new password record at the default cost of 600 000 rounds, with a fresh salt |
| `password_hash$(password$, iterations) → str` | the same at the cost you choose, 1 to 2147483647; anything else raises. A low cost is for tests, not for storage |
| `password_verify?(password$, record$) → bool` | `true` when `password$` is the password the record was made from. A record that is not one — empty, another algorithm, a missing field, a cost of 0 or past 2147483647, a hash that is not base64 — answers `false` and raises nothing: for a damaged record the honest answer to "is this the password?" is no |
| `crypto_equal?(a$, b$) → bool` | `true` when the two strings hold the same bytes. Its running time depends only on the lengths, never on where the first difference is — which a `=` that stops at the first mismatching byte leaks to someone timing many attempts. NUL is an ordinary byte |

## A worked example

Sign a message with a shared secret and check the signature on arrival — the
shape of a webhook.

```basic
secret$ = "s3cr3t-shared-with-the-sender"
body$ = "{" + chr$(34) + "order" + chr$(34) + ":42}"

rem the sender computes this and sends it beside the body
sig$ = hmac_sha256$(secret$, body$)

rem the receiver recomputes it from what actually arrived
if crypto_equal?(sig$, hmac_sha256$(secret$, body$)) = true then
  println "genuine"
else
  println "rejected"
end if

println sha256$(body$)
```

## Notes

- **The cost is what the caller names, and a record names its own.**
  `password_verify?` runs the round count written inside the record, and a
  record is data — it may have come from a database someone else could write.
  Every PBKDF2 loop charges the [execution budget](../embedding.md) as it runs,
  so a host that set `MaxSteps` or `TimeoutMs` stops a record naming two billion
  rounds within its own limit. With no budget installed, such a record takes as
  long as it says it will. The default cost fits comfortably inside the budget
  `embedding.md` prescribes (`MaxSteps = 1000000`) — twice, hash and verify.
- **Why SHA-256 is written out in the engine.** Free Pascal 3.2.2's `hash`
  package stops at SHA-1; MD5 and SHA-1 here come from it, SHA-256 is this
  unit's own, and all three are held to the published vectors and to a sweep of
  490 inputs against Python's `hashlib` and `hmac`.
- **What is not here.** Encryption, and a random-bytes source for secrets. The
  engine may not reach the operating system's random generator directly; the
  password salt comes from `CreateGUID`, which is the runtime library's portable
  door to it and is enough for a salt. A key or a token that must be
  unguessable deserves an API built for that, and this library does not pretend
  to be one.
