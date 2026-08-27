import plistlib
import sys

path, expected = sys.argv[1:]
with open(path, "rb") as handle:
    user = plistlib.load(handle)

assert user["name"] == [expected]
assert user["uid"] == ["501"]
assert user["gid"] == ["20"]
assert user["realname"] == [expected]
assert user["authentication_authority"] == [
    ";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>"
]

shadow = plistlib.loads(user["ShadowHashData"][0])
record = shadow["SALTED-SHA512-PBKDF2"]
assert 30000 <= record["iterations"] < 50000
assert len(record["salt"]) == 32
assert len(record["entropy"]) == 128
