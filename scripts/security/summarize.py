#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Prints scanner reports without the secret values (logs of a public CI are public).

  python3 summarize.py gitleaks REPORT.json [--hide-path-rules]   gitleaks JSON report (rule, file:line, commit)
  trufflehog ... --json | python3 summarize.py trufflehog          trufflehog JSON lines (detector, file:line, commit)

Prints one line per finding and the count; exit code 1 when there is at least one finding, 0 when none, 2 on bad input.
With --hide-path-rules a finding of a rule whose id ends in "-path" (file name matches a private pattern) prints no
path, because the path itself would be the private word.
"""
import json
import sys


def gitleaks(path, hide):
    try:
        data = json.load(open(path, encoding="utf-8")) or []
    except (OSError, ValueError) as e:
        print("summarize: cannot read the gitleaks report: %s" % e.__class__.__name__, file=sys.stderr)
        return 2
    # A private word can sit in a file name. A "-path" rule fires on exactly such a file; every other finding in the same
    # file then hides the path too (the content rule would print the name otherwise).
    hidden = {f.get("File") for f in data if hide and f.get("RuleID", "").endswith("-path")}
    for f in data:
        rule = f.get("RuleID", "?")
        if hide and (rule.endswith("-path") or f.get("File") in hidden):
            where = "<path hidden>"
        else:
            where = "%s:%s" % (f.get("File", "?"), f.get("StartLine", "?"))
        commit = f.get("Commit") or ""
        print("  %-28s %s%s" % (rule, where, ("  commit " + commit[:10]) if commit else ""))
    print("%d finding(s)" % len(data))
    return 1 if data else 0


def trufflehog():
    n = 0
    for line in sys.stdin:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            j = json.loads(line)
        except ValueError:
            continue
        if "DetectorName" not in j:
            continue
        data = (j.get("SourceMetadata") or {}).get("Data") or {}
        meta = data.get("Git") or data.get("Filesystem") or {}
        commit = meta.get("commit") or ""
        print("  %-28s %s:%s%s" % (j.get("DetectorName"), meta.get("file", "?"), meta.get("line", "?"), ("  commit " + commit[:10]) if commit else ""))
        n += 1
    print("%d finding(s)" % n)
    return 1 if n else 0


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "gitleaks":
        return gitleaks(sys.argv[2], "--hide-path-rules" in sys.argv[3:])
    if len(sys.argv) == 2 and sys.argv[1] == "trufflehog":
        return trufflehog()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
