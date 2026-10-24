"""Builds the CDN copy of the updatable core: dist/ = core/*.gd + core.json + core.json.sig.

python tools/core_dist.py <addons/streamember/core> <dist> <version> <private-key.pem>

core.json lists every file with its SHA-256 and is signed (RSA PKCS#1 v1.5, SHA-256) with the StreamEmber core key
(secrets/ember-core-signing.pem, GitHub secret EMBER_CORE_SIGNING_KEY). The signature is checked here against the
public key embedded in addons/streamember/boot.gd, so a key mismatch fails the release instead of every game.
Needs openssl. The result is published with .github/cdn-publish.py to components/ember-core-godot/<version>/.
"""
import base64
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

core, dist, version, key = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
live = (core / "live.gd").read_text(encoding="utf-8")
api = int(re.search(r'^const API := (\d+)', live, re.M).group(1))
if f'const VERSION := "{version}"' not in live:
    sys.exit(f"core/live.gd VERSION is not {version}")

if dist.exists():
    shutil.rmtree(dist)
dist.mkdir(parents=True)
files = []
for src in sorted(core.glob("*.gd")):
    data = src.read_bytes()
    (dist / src.name).write_bytes(data)
    files.append({"path": src.name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
info = {"schema": 1, "id": "ember-core-godot", "version": version, "api": api, "minGodot": "4.3", "files": files}
(dist / "core.json").write_bytes(json.dumps(info, indent=1).encode())

boot = (core.parent / "boot.gd").read_text(encoding="utf-8")
public = re.search(r'-----BEGIN PUBLIC KEY-----.*?-----END PUBLIC KEY-----', boot, re.S).group(0)
with tempfile.TemporaryDirectory() as tmp:
    sig, pub = pathlib.Path(tmp) / "sig", pathlib.Path(tmp) / "pub.pem"
    pub.write_text(public + "\n")
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", key, "-out", sig, dist / "core.json"], check=True)
    subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sig, dist / "core.json"], check=True)
    (dist / "core.json.sig").write_text(base64.b64encode(sig.read_bytes()).decode())
print(f"core {version} (API {api}): {len(files)} files signed in {dist}")
