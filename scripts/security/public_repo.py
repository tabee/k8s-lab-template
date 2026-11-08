#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Exact public-repository URL policy; never a general account-name exception."""
import re
from urllib.parse import urlsplit

# Approved by the operator on 2026-11-08. Changing export.conf does not grant a new exception.
APPROVED_REPO_URL = "https://github.com/tabee/k8s-lab-template"
parts = urlsplit(APPROVED_REPO_URL)
OWNER = parts.path.split("/")[1]
# Only complete URL prefixes: a similarly named repo, userinfo or an embedded URL must not pass.
BODY = (re.escape(APPROVED_REPO_URL) + r"(?:\.git)?|"
        + re.escape("git@" + parts.netloc + ":" + parts.path.lstrip("/")) + r"\.git")
LEFT = r"[^A-Za-z0-9_.:/@%+-]"
RIGHT = r"[/#?\s\"'`<>)\],;]"
APPROVED_URL = re.compile(r"(?<![A-Za-z0-9_.:/@%+-])(?:" + BODY + r")(?=$|" + RIGHT + r")")
# RE2 has no look-around. Include the adjacent delimiter in the *match*, never the whole line.
# A sequence avoids consuming the separator needed by an adjacent approved URL.
SEPARATOR = r"[\s\"'`<>)\],;]"
RE2_URL = (r"(?:^|" + LEFT + r")(?:" + BODY + r")(?:(?:" + SEPARATOR
           + r")+(?:" + BODY + r"))*(?:$|" + RIGHT + r")")


def mask_approved_urls(text):
    """Remove only the approved prefix; suffixes and unrelated text remain fully scanned."""
    return APPROVED_URL.sub("PUBLIC_REPOSITORY", text)


def replace_outside_approved_urls(text, pattern, replacement):
    """Protect exact approved URL prefixes from the private-account replacement rule."""
    result = []
    count = 0
    start = 0
    for match in APPROVED_URL.finditer(text):
        chunk, n = pattern.subn(replacement, text[start:match.start()])
        result.extend((chunk, match.group()))
        count += n
        start = match.end()
    chunk, n = pattern.subn(replacement, text[start:])
    result.append(chunk)
    return "".join(result), count + n
