#!/usr/bin/env python3
"""Generate cryptographic reference vectors for the Swift port.

These reproduce, byte-for-byte, the behaviour of the dpt-rp1-py reference
implementation (dptrp1.py wrap/unwrap, pyDH Diffie-Hellman group 14, the PBKDF2
key derivation, and HMAC-SHA256). The Swift test suite asserts its own
implementations reproduce these exact outputs.

Uses only the `cryptography` package + stdlib, so pycryptodome is not required;
AES-CBC / PBKDF2 / HMAC are standard algorithms whose outputs are
implementation-independent for identical inputs.
"""
import json
import hashlib
import hmac as hmaclib
import os

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

OUT = os.path.join(os.path.dirname(__file__), "..", "DigitalPaperKitTests", "Resources", "vectors.json")

# RFC 3526 group 14 prime (2048-bit), generator 2 — must match pyDH.py.
P = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA6"
    "3B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
    "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F2411"
    "7C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
    "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08"
    "CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9"
    "DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFF"
    "FFFFFFFF",
    16,
)
G = 2


def pkcs7_pad(b, k=16):
    val = k - (len(b) % k)
    return b + bytes([val] * val)


def pkcs7_unpad(b, k=16):
    return b[: -b[-1]]


def wrap(data, authKey, keyWrapKey, iv):
    kwa = hmaclib.new(authKey, data, hashlib.sha256).digest()[:8]
    cipher = Cipher(algorithms.AES(keyWrapKey), modes.CBC(iv))
    enc = cipher.encryptor()
    wrapped = enc.update(pkcs7_pad(data + kwa)) + enc.finalize()
    return wrapped + iv


def h(b):
    return b.hex()


vectors = {}

# --- HMAC-SHA256 ---
hk = bytes(range(32))
hm = b"the quick brown fox"
vectors["hmac_sha256"] = {
    "key": h(hk),
    "message": h(hm),
    "digest": h(hmaclib.new(hk, hm, hashlib.sha256).digest()),
}

# --- PBKDF2-HMAC-SHA256 (registration params + a fast one) ---
zz = bytes((i * 7 + 3) % 256 for i in range(256))  # stand-in for DH shared secret
salt = bytes(range(48))
derived = hashlib.pbkdf2_hmac("sha256", zz, salt, 10000, dklen=48)
vectors["pbkdf2"] = {
    "password": h(zz),
    "salt": h(salt),
    "iterations": 10000,
    "length": 48,
    "derived": h(derived),
    "authKey": h(derived[:32]),
    "keyWrapKey": h(derived[32:]),
}

# --- Diffie-Hellman group 14 ---
a = bytes((i * 3 + 1) % 256 for i in range(32))  # fixed private exponent bytes
a_int = int.from_bytes(a, "big")
ya = pow(G, a_int, P)
# fixed peer public key (as device would send): pick a deterministic exponent
b = bytes((i * 5 + 2) % 256 for i in range(32))
yb = pow(G, int.from_bytes(b, "big"), P)
shared = pow(yb, a_int, P)
vectors["dh"] = {
    "privateKey": h(a),
    "publicKey": h(ya.to_bytes(256, "big")),       # ya as 256-byte big-endian
    "peerPublicKey": h(yb.to_bytes(256, "big")),
    "sharedSecret": h(shared.to_bytes(256, "big")),
}

# --- wrap / unwrap ---
data = b"hello digital paper registration payload"
authKey = derived[:32]
keyWrapKey = derived[32:]
iv = bytes(range(16))
wrapped = wrap(data, authKey, keyWrapKey, iv)
vectors["wrap"] = {
    "data": h(data),
    "authKey": h(authKey),
    "keyWrapKey": h(keyWrapKey),
    "iv": h(iv),
    "wrapped": h(wrapped),
}

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    json.dump(vectors, f, indent=2)
print("wrote", os.path.normpath(OUT))
