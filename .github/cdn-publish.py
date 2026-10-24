#!/usr/bin/env python3
"""Publish a package folder to cdn.streamember.com (Bunny Storage) as an immutable version folder.

usage: cdn-publish.py <local-dir> <cdn-dir> <version> [--target game] [--requires id,id] [--externals file.json]
       e.g.  pkg  components/gtav-runtime-scripthook  1.2.5
env:   BUNNY_STORAGE_API_URL   https://storage.bunnycdn.com/<zone>
       BUNNY_STORAGE_PASSWORD  storage zone password
       CDN_BASE_URL            https://cdn.streamember.com
       BUNNY_API_KEY           optional: account API key; purges latest.json from the CDN cache

Order: files -> <version>/manifest.json -> latest.json (the only file that ever changes) -> purge ->
delete every older version folder except the previous one (a launcher may still be downloading it).
Every upload carries its SHA-256, so Bunny rejects a corrupted file. A version that already has a
manifest is never uploaded again; a rerun only finishes latest.json and cleanup.

--externals: files the launcher downloads from their official source instead of our CDN (licensed or third-party
files such as Modrinth mods). JSON list of {"path", "url", "size", one of "sha1"/"sha256"/"sha512"}; every entry is
downloaded once here and checked, so a wrong pin never reaches the CDN. They go to manifest.json as "externals".
"""
import argparse, datetime, fnmatch, hashlib, json, os, posixpath, re, sys, time, urllib.error, urllib.parse, urllib.request

# Not needed at runtime: config files get code defaults (and are never overwritten for the user), manifests
# are only read by the local build.ps1 install, notes and licenses are documentation.
SKIP = ['StreamEmber/Licenses/*', 'StreamEmber/Manifests/*', 'StreamEmber/Config/*',
        '*LICENSE*', '*.md', '*.pdb', '*.sha256', '.nojekyll']

API = os.environ['BUNNY_STORAGE_API_URL'].rstrip('/')
KEY = os.environ['BUNNY_STORAGE_PASSWORD']
CDN = os.environ['CDN_BASE_URL'].rstrip('/')
PURGE_KEY = os.environ.get('BUNNY_API_KEY', '')


def http(method, url, body=None, headers=None, missing_ok=False):
    """body: bytes or a local file path. Retries network errors and 5xx."""
    for attempt in range(3):
        is_file = isinstance(body, str)
        data = open(body, 'rb') if is_file else body
        h = dict(headers or {})
        if is_file:
            h['Content-Length'] = str(os.path.getsize(body))
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=600) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404 and missing_ok:
                return None
            if e.code < 500 or attempt == 2:
                sys.exit(f'{method} {url}: HTTP {e.code} {e.read()[:300]!r}')
        except OSError as e:
            if attempt == 2:
                sys.exit(f'{method} {url}: {e}')
        finally:
            if is_file:
                data.close()
        time.sleep(5 * (attempt + 1))


def storage(method, path, body=None, sha=None, missing_ok=False):
    headers = {'AccessKey': KEY, 'Accept': 'application/json'}
    if body is not None:
        headers['Content-Type'] = 'application/octet-stream'
        headers['Checksum'] = sha.upper()
    return http(method, f'{API}/{urllib.parse.quote(path)}', body, headers, missing_ok)


def sha256(data):
    h = hashlib.sha256()
    if isinstance(data, bytes):
        h.update(data)
    else:
        with open(data, 'rb') as f:
            for block in iter(lambda: f.read(1 << 20), b''):
                h.update(block)
    return h.hexdigest()


HASHES = ('sha512', 'sha256', 'sha1')


def check_externals(path):
    """Reads and verifies the externals list (download + size + hash)."""
    entries = json.load(open(path, encoding='utf-8'))
    out = []
    for e in entries:
        rel, url = e.get('path', ''), e.get('url', '')
        kind = next((k for k in HASHES if e.get(k)), None)
        if not re.fullmatch(r'[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*', rel) or '..' in rel.split('/'):
            sys.exit(f'externals: bad path {rel!r}')
        if not url.startswith('https://') or kind is None or not isinstance(e.get('size'), int):
            sys.exit(f'externals: {rel} needs an https url, an int size and one of {HASHES}')
        data = http('GET', url, headers={'User-Agent': 'StreamEmber-cdn-publish'})
        digest = hashlib.new(kind, data).hexdigest()
        if len(data) != e['size'] or digest != e[kind].lower():
            sys.exit(f'externals: {rel} does not match {url} (size {len(data)}, {kind} {digest})')
        out.append({'path': rel, 'url': url, 'size': e['size'], kind: digest})
        print(f'  = {rel} ← {url}')
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument('local_dir')
    p.add_argument('cdn_dir')
    p.add_argument('version')
    p.add_argument('--target', default='game', help='where the launcher installs the files')
    p.add_argument('--requires', default='', help='comma separated component ids')
    p.add_argument('--externals', default='', help='JSON list of files downloaded from their official source')
    a = p.parse_args()
    local_dir, cdn_dir, version = a.local_dir.rstrip('/\\'), a.cdn_dir.strip('/'), a.version
    if not re.fullmatch(r'\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?', version):
        sys.exit(f'bad version: {version}')
    if not re.fullmatch(r'[a-z0-9]+(-[a-z0-9]+)*(/[a-z0-9]+(-[a-z0-9]+)*)+', cdn_dir):
        sys.exit(f'bad cdn dir: {cdn_dir}')

    files = {}
    for root, _, names in os.walk(local_dir) if os.path.isdir(local_dir) else ():
        for n in names:
            full = os.path.join(root, n)
            rel = os.path.relpath(full, local_dir).replace(os.sep, '/')
            if not any(fnmatch.fnmatch(rel, pat) for pat in SKIP):
                files[rel] = full
    externals = check_externals(a.externals) if a.externals else []
    if not files and not externals:
        sys.exit(f'{local_dir}: package is empty')

    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    base = f'{cdn_dir}/{version}'
    print(f'CDN → {CDN}/{base}/  ({len(files)} files)')

    if storage('GET', f'{base}/manifest.json', missing_ok=True) is None:
        entries = []
        for rel in sorted(files):
            sha = sha256(files[rel])
            storage('PUT', f'{base}/{rel}', files[rel], sha)
            entries.append({'path': rel, 'size': os.path.getsize(files[rel]), 'sha256': sha})
            print(f'  + {rel}')
        manifest = {'schema': 1, 'id': posixpath.basename(cdn_dir), 'version': version, 'publishedAt': now,
                    'target': a.target, 'requires': [r for r in a.requires.split(',') if r],
                    'totalSize': sum(e['size'] for e in entries + externals), 'files': entries}
        if externals:
            manifest['externals'] = externals
        body = json.dumps(manifest, indent=2).encode()
        storage('PUT', f'{base}/manifest.json', body, sha256(body))
    else:
        print(f'  {version} is already published; finishing latest.json')

    previous = storage('GET', f'{cdn_dir}/latest.json', missing_ok=True)
    previous = json.loads(previous)['version'] if previous else None
    body = json.dumps({'schema': 1, 'version': version, 'publishedAt': now}, indent=2).encode()
    storage('PUT', f'{cdn_dir}/latest.json', body, sha256(body))
    print(f'  latest.json: {previous} → {version}')

    if PURGE_KEY:
        http('POST', 'https://api.bunny.net/purge?url=' + urllib.parse.quote(f'{CDN}/{cdn_dir}/latest.json', safe=''),
             b'', {'AccessKey': PURGE_KEY})
        print('  latest.json purged')
    else:
        print('::warning::BUNNY_API_KEY is not set, so latest.json was not purged: the CDN keeps serving the old one until its cache expires')

    served = json.loads(http('GET', f'{CDN}/{base}/manifest.json'))
    if served.get('version') != version:
        sys.exit(f'CDN check failed: {CDN}/{base}/manifest.json has version {served.get("version")}')

    if previous and previous != version:
        for o in json.loads(storage('GET', f'{cdn_dir}/')):
            if o['IsDirectory'] and o['ObjectName'] not in (version, previous):
                storage('DELETE', f'{cdn_dir}/{o["ObjectName"]}/')
                print(f'  - {o["ObjectName"]}/')
    print(f'OK: {CDN}/{cdn_dir}/latest.json → {version}')


if __name__ == '__main__':
    main()
