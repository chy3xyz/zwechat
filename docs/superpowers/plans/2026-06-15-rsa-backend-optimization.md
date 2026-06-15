# RSA backend optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optimize the existing RSA backend by adding PKCS#8 private-key parsing, RSAES-PKCS1-v1_5 decrypt, and CRT-based signing, with full regression tests.

**Architecture:** Keep `src/util/rsa.zig` as the public facade and `src/util/rsa_impl.zig` as the implementation. Extend `rsa_impl.zig` with a PKCS#8 DER parser, a CRT-based signing path, and a decrypt primitive. Update `rsa.zig` to expose `rsaDecrypt`/`rsaDecryptBase64` and widen the error set.

**Tech Stack:** Zig 0.17, `std.math.big.int.Managed`, `std.crypto.hash.sha2.Sha256`, existing `src/util/asn1.zig`.

---

## File Structure

- Modify: `src/util/rsa_impl.zig` — add PKCS#8 parser, decrypt, CRT signing.
- Modify: `src/util/rsa.zig` — expose decrypt, update error set, add tests.
- Modify: `docs/architecture.md` (or `CHANGELOG.md`) — update the RSA/TLS status note.
- No new files.

## Task 1: Add PKCS#8 private-key parsing

**Files:**
- Modify: `src/util/rsa_impl.zig:65-142` (`PemKind`, `detectPemKind`, `parsePrivateKeyPem`)

- [ ] **Step 1: Extend `PemKind` and detection**

```zig
const PemKind = enum {
    rsa_private_key, // PKCS#1
    private_key,     // PKCS#8
    rsa_public_key,  // PKCS#1
    public_key,      // SubjectPublicKeyInfo (X.509)
};

fn detectPemKind(pem: []const u8) ?PemKind {
    if (std.mem.indexOf(u8, pem, "BEGIN RSA PRIVATE KEY") != null) return .rsa_private_key;
    if (std.mem.indexOf(u8, pem, "BEGIN PRIVATE KEY") != null) return .private_key;
    if (std.mem.indexOf(u8, pem, "BEGIN RSA PUBLIC KEY") != null) return .rsa_public_key;
    if (std.mem.indexOf(u8, pem, "BEGIN PUBLIC KEY") != null) return .public_key;
    return null;
}
```

- [ ] **Step 2: Add `parsePkcs8PrivateKeyDer` after `parseSubjectPublicKeyInfoDer`**

```zig
fn parsePkcs8PrivateKeyDer(allocator: std.mem.Allocator, der: []const u8) Error!PrivateKey {
    var r = asn1.Reader.init(der);
    const tag = try r.readTag();
    if (tag.number != 0x10 or !tag.constructed) return error.InvalidPemKey;
    const len = try r.readLength();
    const seq = try r.readSequenceContent(len);
    var inner = asn1.Reader.init(seq);

    // version INTEGER 0
    const version = try inner.readInteger();
    if (version.len != 1 or version[0] != 0) return error.UnsupportedKeyFormat;

    // AlgorithmIdentifier SEQUENCE { OID rsaEncryption, NULL }
    const alg_tag = try inner.readTag();
    if (alg_tag.number != 0x10 or !alg_tag.constructed) return error.UnsupportedKeyFormat;
    const alg_len = try inner.readLength();
    const alg_seq = try inner.readSequenceContent(alg_len);
    var alg = asn1.Reader.init(alg_seq);
    const oid = try alg.readObjectIdentifier();
    if (!std.mem.eql(u8, oid, RSA_ENCRYPTION_OID)) return error.UnsupportedKeyFormat;
    if (alg.remaining() > 0) try alg.readNull();

    // privateKey OCTET STRING contains PKCS#1 RSAPrivateKey DER
    const pkcs1_der = try inner.readOctetString();
    return try parseRsaPrivateKeyDer(allocator, pkcs1_der);
}
```

- [ ] **Step 3: Update `parsePrivateKeyPem`**

```zig
pub fn parsePrivateKeyPem(allocator: std.mem.Allocator, pem: []const u8) Error!PrivateKey {
    const kind = detectPemKind(pem) orelse return error.InvalidPemKey;
    const b64 = try stripPemArmor(pem);
    const der = try base64Decode(allocator, b64);
    defer allocator.free(der);

    return switch (kind) {
        .rsa_private_key => try parseRsaPrivateKeyDer(allocator, der),
        .private_key => try parsePkcs8PrivateKeyDer(allocator, der),
        else => error.UnsupportedKeyFormat,
    };
}
```

- [ ] **Step 4: Run existing RSA tests**

Run: `zig build test`
Expected: PASS (PKCS#1 tests unchanged).

## Task 2: Add RSA PKCS#1 v1.5 decrypt

**Files:**
- Modify: `src/util/rsa_impl.zig` (error set + new function)
- Modify: `src/util/rsa.zig` (error set + new functions)

- [ ] **Step 1: Add `InvalidCiphertext` to both error sets**

In `src/util/rsa_impl.zig`:
```zig
pub const Error = error{
    InvalidPemKey,
    InvalidSignature,
    UnsupportedKeyFormat,
    OutOfMemory,
    EncodingFailed,
    InvalidDer,
    UnsupportedTag,
    InvalidCiphertext,
};
```

In `src/util/rsa.zig`:
```zig
pub const RsaError = error{
    RsaNotImplemented,
    InvalidPemKey,
    InvalidSignature,
    InvalidCiphertext,
    OutOfMemory,
};
```

- [ ] **Step 2: Add `decrypt` to `src/util/rsa_impl.zig` after `verifySha256`**

```zig
pub fn decrypt(allocator: std.mem.Allocator, private_key: PrivateKey, ciphertext: []const u8) Error![]u8 {
    const k = byteLenOfModulus(private_key.n.toConst());
    if (ciphertext.len != k) return error.InvalidCiphertext;

    var c = try bigIntFromBytes(allocator, ciphertext);
    defer c.deinit();

    var m = try std.math.big.int.Managed.init(allocator);
    defer m.deinit();
    try powMod(allocator, &m, c.toConst(), private_key.d.toConst(), private_key.n.toConst());

    const em = try bigIntToBytes(allocator, m.toConst(), k);
    defer allocator.free(em);

    // EM = 0x00 || 0x02 || PS || 0x00 || M
    if (em.len < 11 or em[0] != 0 or em[1] != 2) return error.InvalidCiphertext;
    var i: usize = 2;
    while (i < em.len and em[i] != 0) : (i += 1) {}
    if (i == em.len or i < 10) return error.InvalidCiphertext;

    return allocator.dupe(u8, em[i + 1 ..]);
}
```

- [ ] **Step 3: Expose `rsaDecrypt` and `rsaDecryptBase64` in `src/util/rsa.zig`**

```zig
pub fn rsaDecrypt(
    allocator: std.mem.Allocator,
    ciphertext: []const u8,
    private_key_pem: []const u8,
) RsaError![]u8 {
    var pk = rsa_impl.parsePrivateKeyPem(allocator, private_key_pem) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPemKey,
    };
    defer pk.deinit();

    return rsa_impl.decrypt(allocator, pk, ciphertext) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCiphertext,
    };
}

pub fn rsaDecryptBase64(
    allocator: std.mem.Allocator,
    ciphertext_b64: []const u8,
    private_key_pem: []const u8,
) RsaError![]u8 {
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(ciphertext_b64) catch return error.InvalidCiphertext;
    const cipher = allocator.alloc(u8, len) catch return error.OutOfMemory;
    defer allocator.free(cipher);
    decoder.decode(cipher, ciphertext_b64) catch return error.InvalidCiphertext;

    return rsaDecrypt(allocator, cipher, private_key_pem);
}
```

- [ ] **Step 4: Add decrypt test vector**

Append to the tests section of `src/util/rsa.zig`:

```zig
const test_ciphertext_b64 =
    "jt3dup80IEd7jeUrH9glmjeoVxRcjww3MgFdmmwvxUmgVPubOhKrww0bs7Xobhkm3F99zAXlrjXvdPQZOgqt5DjMI+Agy3I0D8Z7VXdKExXWJCnsxlVWLGxjMLsvmTQ2pXCma8S6ckuNxmXygR8Mq0uqxzGW6r2dVlf1SFAnN3A=";

test "rsaDecryptBase64 decrypts PKCS#1 v1.5 ciphertext" {
    const allocator = std.testing.allocator;
    const plain = try rsaDecryptBase64(allocator, test_ciphertext_b64, test_private_key_pkcs1);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("hello, zwechat decrypt", plain);
}
```

- [ ] **Step 5: Run tests**

Run: `zig build test`
Expected: PASS.

## Task 3: Add CRT signing path

**Files:**
- Modify: `src/util/rsa_impl.zig`

- [ ] **Step 1: Add `signSha256Crt` helper before `signSha256`**

```zig
fn signSha256Crt(allocator: std.mem.Allocator, private_key: PrivateKey, message: []const u8) Error![]u8 {
    const k = byteLenOfModulus(private_key.n.toConst());

    const em = try emsaPkcs1V15EncodeSha256(allocator, message, k);
    defer allocator.free(em);

    var m = try bigIntFromBytes(allocator, em);
    defer m.deinit();

    const p = private_key.p orelse return error.UnsupportedKeyFormat;
    const q = private_key.q orelse return error.UnsupportedKeyFormat;
    const dp = private_key.dp orelse return error.UnsupportedKeyFormat;
    const dq = private_key.dq orelse return error.UnsupportedKeyFormat;
    const qinv = private_key.qinv orelse return error.UnsupportedKeyFormat;

    var s1 = try std.math.big.int.Managed.init(allocator);
    defer s1.deinit();
    var s2 = try std.math.big.int.Managed.init(allocator);
    defer s2.deinit();
    try powMod(allocator, &s1, m.toConst(), dp.toConst(), p.toConst());
    try powMod(allocator, &s2, m.toConst(), dq.toConst(), q.toConst());

    var h = try std.math.big.int.Managed.init(allocator);
    defer h.deinit();
    try h.sub(&s1, &s2);

    var q_tmp = try std.math.big.int.Managed.init(allocator);
    defer q_tmp.deinit();
    var r_tmp = try std.math.big.int.Managed.init(allocator);
    defer r_tmp.deinit();
    try std.math.big.int.Managed.divTrunc(&q_tmp, &r_tmp, &h, &p);
    h.swap(&r_tmp);

    var t = try std.math.big.int.Managed.init(allocator);
    defer t.deinit();
    try t.mul(&h, &qinv);
    try std.math.big.int.Managed.divTrunc(&q_tmp, &r_tmp, &t, &p);
    t.swap(&r_tmp);

    var s = try std.math.big.int.Managed.init(allocator);
    defer s.deinit();
    try s.mul(&t, &q);
    try s.add(&s, &s2);
    try std.math.big.int.Managed.divTrunc(&q_tmp, &r_tmp, &s, &private_key.n);
    s.swap(&r_tmp);

    return try bigIntToBytes(allocator, s.toConst(), k);
}
```

- [ ] **Step 2: Update `signSha256` to use CRT when possible**

```zig
pub fn signSha256(allocator: std.mem.Allocator, private_key: PrivateKey, message: []const u8) Error![]u8 {
    const has_crt = private_key.p != null and private_key.q != null and
        private_key.dp != null and private_key.dq != null and private_key.qinv != null;
    if (has_crt) {
        return signSha256Crt(allocator, private_key, message);
    }

    const k = byteLenOfModulus(private_key.n.toConst());
    const em = try emsaPkcs1V15EncodeSha256(allocator, message, k);
    defer allocator.free(em);

    var m = try bigIntFromBytes(allocator, em);
    defer m.deinit();

    var s = try std.math.big.int.Managed.init(allocator);
    defer s.deinit();
    try powMod(allocator, &s, m.toConst(), private_key.d.toConst(), private_key.n.toConst());

    return try bigIntToBytes(allocator, s.toConst(), k);
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: PASS. The CRT path must produce signatures that still verify against the existing test vectors.

## Task 4: Add PKCS#8 integration test

**Files:**
- Modify: `src/util/rsa.zig` (tests section)

- [ ] **Step 1: Append PKCS#8 test key and test**

```zig
const test_private_key_pkcs8 =
    "-----BEGIN PRIVATE KEY-----\n" ++
    "MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAN4R80FQzwt1WDJs\n" ++
    "KZ4/LOqrgrgl4hM7S1IjdyMtUhTRY2Of79ldCSnbCfFHDLut6Om1xnnZVKKwGRnb\n" ++
    "g7aeZDWaCBFDraoeIyo4l18EKvl5ghwL6cGFlMwJd6iTMZc1CBYdJhJ6q6PdvQhA\n" ++
    "tb9Qm6jLguyEbr37de1w5YVOK2PrAgMBAAECgYAOGJWYT8jUsV4n1TXPFbOEMd7a\n" ++
    "UY1IKztcu2OUmAvdxmzIph5TbdRnE8BN0HS+dQuTyjYPBfyZVxRAz+5MaUFzB0lJ\n" ++
    "gcODGb8AtAsWT8dad1Bk+FEbht44+6V4D+6cvLIj5YKz+RxN+RJUvHJaF3yZ992U\n" ++
    "9zzMncF5Oxwq7J70AQJBAPe18VORF7dFcRglitglN9yOpj9VCc2ag4INxGRn2Fx/\n" ++
    "rn7TR10bLYdUBiBtAgrSRJ5bmH3127F8HVD/+fd6fPMCQQDlgFpVtd9e3BhybUDL\n" ++
    "rIKuAXkzl29Z1tio/F7tZIj7ED7HRWjpXNOLj4sQGBdAc6PmyAP5kEcOCCb7IjgX\n" ++
    "EVspAkEA3PFc0hPNWnvG1ynNQONZgxF9eWnJN6lE+UB8Vq5FTqPYKWkb8xDluBoa\n" ++
    "6NsyAiLwb2r1hgxAK3uvzmqzM6j+PwJAG3uLVcg5v3pL0ygSIlG+NGgow2zXAMMh\n" ++
    "ntrZ40Ouw6HmYqaFMazUCFpgJMU9w5IVhoVdNH16hMulH12xqdGCQQJAFnlBdFGf\n" ++
    "mbeuLfe8S5AxUHj7M3j9ZOyhNqOMiwCq5hLM1iQKDSMVyvHvZu57W+LpeO4UIQHZ\n" ++
    "2QDcFxyhCMX49A==\n" ++
    "-----END PRIVATE KEY-----";

test "rsaSign accepts PKCS#8 private key" {
    const allocator = std.testing.allocator;
    const sig = try rsaSign(allocator, "hello, zwechat rsa", test_private_key_pkcs8);
    defer allocator.free(sig);
    try std.testing.expectEqual(@as(usize, 128), sig.len);

    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(sig.len);
    const sig_b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(sig_b64);
    _ = encoder.encode(sig_b64, sig);
    const ok = try rsaVerify(allocator, "hello, zwechat rsa", sig_b64, test_public_key_x509);
    try std.testing.expect(ok);
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test`
Expected: PASS.

## Task 5: Update docs and commit

- [ ] **Step 1: Update `docs/architecture.md`**

Find the line that says the RSA backend uses `std.math.big.int.Managed` without CRT/Montgomery and/or that a faster backend is future work. Replace with:

```markdown
- `src/util/rsa_impl.zig` now supports PKCS#1 / PKCS#8 private keys, RSASSA-PKCS1-v1_5-SHA256 sign/verify, RSAES-PKCS1-v1_5 decrypt, and a CRT signing path for keys that include `p`/`q`/`dp`/`dq`/`qinv`.
```

- [ ] **Step 2: Commit**

```bash
git add src/util/rsa_impl.zig src/util/rsa.zig docs/architecture.md
git commit -m "feat(util/rsa): PKCS#8 parse, RSA decrypt, CRT signing"
```

## Verification

Run: `zig build test`
Expected: all tests pass, zero leaks.
