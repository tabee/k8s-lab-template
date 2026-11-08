#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Self-hosts Mermaid in a built docs site (no CDN at view time).

Usage (called by docs/build.sh after the Zensical build):
  vendor-mermaid.py SITE_DIR CACHE_DIR VERSION TARBALL_SHA512_BASE64 [TARBALL_URL]

Why: the Zensical theme loads Mermaid from unpkg.com (floating major version, no integrity hash) as soon as
the global `mermaid` is undefined. This script puts a pinned copy into the site and loads it with an SRI hash
before the theme bundle; then the theme finds `mermaid` and never contacts a CDN.

  1. Fetch the npm tarball (registry.npmjs.org, or TARBALL_URL, also file://) unless it is in CACHE_DIR.
     The tarball is checked against the pinned sha512 every time, also when it comes from the cache.
  2. Extract package/dist/mermaid.min.js to SITE_DIR/assets/vendor/mermaid/mermaid-VERSION.min.js.
  3. In every HTML page insert <script src=... integrity="sha384-..." crossorigin="anonymous"> in front of the
     theme bundle (all pages: with instant navigation a page without diagrams can be the first one loaded).

Standard library only. Idempotent. Exit code 1 on any problem; nothing half-written stays in SITE_DIR.
"""
import base64
import hashlib
import io
import re
import sys
import tarfile
import urllib.request
from pathlib import Path

BUNDLE = re.compile(r'<script src="((?:\.\./)*|\./)(assets/javascripts/bundle\.[0-9a-f]+\.min\.js)">')


def die(msg):
    print("vendor-mermaid: ABORT: " + msg, file=sys.stderr)
    sys.exit(1)


def tarball(version, sha512, url, cache):
    pinned = base64.b64decode(sha512)
    cached = cache / ("mermaid-%s.tgz" % version)
    data = cached.read_bytes() if cached.exists() else None
    if data is not None and hashlib.sha512(data).digest() != pinned:
        print("vendor-mermaid: cached tarball does not match the pin, fetching again")
        data = None
    if data is None:
        print("vendor-mermaid: fetching " + url)
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                data = r.read()
        except OSError as e:
            die("download failed: %s (MERMAID_SELF_HOST=0 builds without, the theme then uses the CDN)" % e)
        if hashlib.sha512(data).digest() != pinned:
            die("sha512 of the downloaded tarball does not match the pin (MERMAID_TGZ_SHA512 in docs/build.sh)")
        cache.mkdir(parents=True, exist_ok=True)
        tmp = cached.with_suffix(".tmp")
        tmp.write_bytes(data)
        tmp.replace(cached)
    return data


def main():
    if len(sys.argv) not in (5, 6):
        die(__doc__.split("\n")[3].strip())
    site, cache, version, sha512 = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        die("version must be exact (x.y.z), got %r" % version)
    url = sys.argv[5] if len(sys.argv) == 6 else "https://registry.npmjs.org/mermaid/-/mermaid-%s.tgz" % version
    data = tarball(version, sha512, url, cache)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        try:
            js = tf.extractfile("package/dist/mermaid.min.js").read()
        except (KeyError, AttributeError):
            die("package/dist/mermaid.min.js is not in the tarball")
    sri = "sha384-" + base64.b64encode(hashlib.sha384(js).digest()).decode()
    rel = "assets/vendor/mermaid/mermaid-%s.min.js" % version
    dest = site / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(js)
    pages = changed = 0
    for page in sorted(site.rglob("*.html")):
        text = page.read_text(encoding="utf-8")
        m = BUNDLE.search(text)
        if not m:
            continue  # no theme page (redirect stub, graph page of the plugin without bundle ...)
        pages += 1
        if rel in text:
            continue
        tag = '<script src="%s%s" integrity="%s" crossorigin="anonymous"></script>' % (m.group(1), rel, sri)
        page.write_text(text[:m.start()] + tag + text[m.start():], encoding="utf-8")
        changed += 1
    if pages == 0:
        dest.unlink()
        die("no theme page with the bundle script found in %s (theme changed?)" % site)
    print("vendor-mermaid: mermaid %s (%s) in %d of %d pages" % (version, sri[:19] + "...", changed, pages))


if __name__ == "__main__":
    main()
