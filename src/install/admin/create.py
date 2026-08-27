import hashlib
import os
import plistlib
import secrets
import shlex
import sys
import uuid

out, username, password, autologin = sys.argv[1:]
generated_uid = str(uuid.uuid4()).upper()

iterations = 30000 + secrets.randbelow(20000)
salt = secrets.token_bytes(32)
entropy = hashlib.pbkdf2_hmac(
    "sha512", password.encode("utf-8"), salt, iterations, dklen=128
)

shadow = {
    "SALTED-SHA512-PBKDF2": {
        "entropy": entropy,
        "iterations": iterations,
        "salt": salt,
    }
}
shadow_data = plistlib.dumps(shadow, fmt=plistlib.FMT_BINARY)

writers = [
    "_writers_hint",
    "_writers_jpegphoto",
    "_writers_passwd",
    "_writers_picture",
    "_writers_realname",
    "_writers_UserCertificate",
]

user = {
    "name": [username],
    "uid": ["501"],
    "gid": ["20"],
    "home": [f"/Users/{username}"],
    "realname": [username],
    "shell": ["/bin/bash"],
    "generateduid": [generated_uid],
    "passwd": ["********"],
    "authentication_authority": [
        ";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>"
    ],
    "ShadowHashData": [shadow_data],
}
for key in writers:
    user[key] = [username]

with open(os.path.join(out, "user.plist"), "wb") as handle:
    plistlib.dump(user, handle, fmt=plistlib.FMT_XML, sort_keys=False)

with open(os.path.join(out, "config"), "w", encoding="utf-8") as handle:
    handle.write("USERNAME=" + shlex.quote(username) + "\n")
    handle.write("UUID=" + shlex.quote(generated_uid) + "\n")
    handle.write("AUTOLOGIN=" + shlex.quote(autologin) + "\n")

if autologin.lower() in ("1", "true", "yes", "y", "on"):
    key = [125, 137, 82, 35, 210, 188, 221, 234, 163, 185, 31]
    data = [ord(char) for char in password] + [0]
    remainder = len(data) % 12
    if remainder:
        data.extend([0] * (12 - remainder))
    for offset in range(0, len(data), len(key)):
        for index in range(offset, min(offset + len(key), len(data))):
            data[index] ^= key[index - offset]
    if not data:
        data = [125] + [0] * 11
    with open(os.path.join(out, "kcpassword"), "wb") as handle:
        handle.write(bytes(data))
