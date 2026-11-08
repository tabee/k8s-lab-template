#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Turns the private deny list into a gitleaks config with anonymous rule ids (pii-001, pii-002, ...).

Why: the public repository must be checked for the private names and identifiers (real name, domain, home IP, ...),
but the list must not be public. In CI it comes from a secret (PII_DENYLIST, same format as scripts/public/denylist.txt:
"name<TAB>regex", '#' and empty lines skipped, case-insensitive). The generated config has no names in the rule ids or
descriptions, and scripts/security-scan.sh runs gitleaks with --redact, so a finding in a public log shows only the
file, the line and "pii-007", never the value.

  PII_DENYLIST="$(cat scripts/public/denylist.txt)" python3 scripts/security/pii-config.py OUT.toml
  python3 scripts/security/pii-config.py OUT.toml --file scripts/public/denylist.txt

A rule with look-around is skipped with a warning (RE2 has none); write it without look-around for the CI secret.
Exit code: 0 written (prints only the number of rules), 2 no list or a rule that is not a valid regular expression.
"""
import argparse
import os
import re
import sys

from public_repo import OWNER, RE2_URL


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--file")
    a = ap.parse_args()
    text = open(a.file, encoding="utf-8").read() if a.file else os.environ.get("PII_DENYLIST", "")
    rules = []
    skipped = 0
    for nr, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        rx = parts[1].strip() if len(parts) > 1 else parts[0].strip()
        if not rx:
            continue
        if "'''" in rx:
            print("pii-config: a rule contains three single quotes (not allowed in a TOML literal string)", file=sys.stderr)
            return 2
        try:
            re.compile(rx)
        except re.error:
            print("pii-config: rule %d is not a valid regular expression" % (len(rules) + 1), file=sys.stderr)
            return 2
        if re.search(r"\(\?[=!<]", rx):
            # Python-only syntax (the export guard understands it, gitleaks does not). Say so, never skip silently.
            print("pii-config: WARNING: line %d uses look-around (not RE2): skipped here, the export guard still checks it" % nr, file=sys.stderr)
            skipped += 1
            continue
        approved_url = len(parts) > 1 and parts[0] == "github-owner" and rx == OWNER
        rules.append((rx, approved_url))
    if not rules:
        print("pii-config: no rules (PII_DENYLIST empty and no --file)", file=sys.stderr)
        return 2
    out = [
        'title = "private deny list (generated, do not commit)"',
        "",
        "[[allowlists]]",
        'description = "git metadata (config, logs) is not part of the repository content"',
        "paths = ['''(^|/)\\.git/''']",
        "",
    ]
    for i, (rx, approved_url) in enumerate(rules, 1):
        content_rx = "(?:%s|%s)" % (RE2_URL, rx) if approved_url else rx
        out += [
            "[[rules]]",
            'id = "pii-%03d"' % i,
            'description = "private identifier"',
            "regex = '''(?i)%s'''" % content_rx,
            "",
        ]
        if approved_url:
            out += [
                "[[rules.allowlists]]",
                'description = "exact approved public repository URL match, not the account or line"',
                'regexTarget = "match"',
                "regexes = ['''^%s$''']" % RE2_URL,
                "",
            ]
        out += [
            "[[rules]]",
            'id = "pii-%03d-path"' % i,
            'description = "private identifier in a file name"',
            "path = '''(?i)%s'''" % rx,
            "",
        ]
    fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print("pii-config: %d rules written, %d skipped (look-around)" % (len(rules), skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
