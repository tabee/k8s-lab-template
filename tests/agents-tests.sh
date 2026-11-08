#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
# Tests for AGENTS.md and CLAUDE.md, so the agent instructions cannot rot. No cluster, no network:
#   1. AGENTS.md exists, has the required sections, stays short and is English (no umlauts, no TODO)
#   2. every backticked path, Markdown link, `lab.sh` subcommand, `--option`, `ci-tests.sh` suite and
#      `ci-lint.sh` target named in it exists in the repository
#   3. CLAUDE.md is a thin pointer to AGENTS.md
#   4. the Argo CD UI route lists only the admin entrypoint (one of the rules in AGENTS.md)
#   5. the checker itself: a good fake tree is clean, each kind of rot in a fake tree is found
# The suite also runs against the public export (tests/public-tests.sh), where private-only blocks are gone.
# Needs: python3 (standard library only). Usage: bash tests/agents-tests.sh [repo root]
set -u
export PYTHONDONTWRITEBYTECODE=1
R=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
n=0

cat > "$T/check.py" <<'PY'
import os, re, subprocess, sys

MAX_LINES = 150
SECTIONS = ["Purpose and audience", "Repository map", "Commands", "Conventions", "Security hard rules",
            "Definition of done"]
# Named in AGENTS.md but deliberately not in the tree (git-ignored local file).
NOT_IN_TREE = {"lab.local.yaml", "infra/envs/local/lab.local.yaml"}
OVERLAY = "scripts/public/overlay"   # files that exist only in the public copy (private tree: in the overlay)
CI_LINT_TARGETS = None


def exists(root, rel):
    rel = rel.rstrip("/")
    if rel in NOT_IN_TREE:
        return True
    for base in (rel, os.path.join(OVERLAY, rel)):
        if os.path.exists(os.path.join(root, base)):
            return True
    if "/" not in rel:  # bare file name: anywhere in the tree
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x not in (".git", "node_modules", ".cache")]
            if rel in files:
                return True
    return False


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def code_units(text):
    """Inline code spans and the lines of fenced blocks, with trailing '# comment' removed from blocks."""
    units = []
    in_block = False
    for line in text.splitlines():
        if line.startswith("```"):
            in_block = not in_block
            continue
        if in_block:
            units.append((re.sub(r"\s+#.*$", "", line).strip(), True))
        else:
            for m in re.finditer(r"`([^`\n]+)`", line):
                units.append((m.group(1).strip(), False))
    return units


def lab_help(root):
    lab = os.path.join(root, "scripts", "lab.sh")
    if not os.path.isfile(lab):
        return None
    out = subprocess.run(["bash", lab, "help"], cwd=root, capture_output=True, text=True, timeout=60).stdout
    subs = set(re.findall(r"lab\.sh ([a-z][a-z-]*)", out))
    if re.search(r"\bhelp\)", read(lab)):  # accepted by the dispatcher but not listed in its own help
        subs.add("help")
    return subs


def check(root, strict=True):
    errs = []
    path = os.path.join(root, "AGENTS.md")
    if not os.path.isfile(path):
        return ["AGENTS.md is missing"]
    raw = read(path)
    if len(raw.splitlines()) > MAX_LINES:
        errs.append("AGENTS.md has %d lines (max %d): move detail into docs/" % (len(raw.splitlines()), MAX_LINES))
    for s in SECTIONS:
        if not re.search(r"^## " + re.escape(s), raw, re.M):
            errs.append("section missing: " + s)
    if re.search(r"[\u00e4\u00f6\u00fc\u00c4\u00d6\u00dc\u00df]", raw):
        errs.append("AGENTS.md must be English: umlaut or sharp s found")
    if re.search(r"\b(TODO|FIXME|XXX)\b", raw):
        errs.append("AGENTS.md contains a TODO marker")
    text = re.sub(r"<!--.*?-->", "", raw, flags=re.S)  # private-only markers are comments
    subs = lab_help(root)
    lab_src = ""
    scripts_dir = os.path.join(root, "scripts")
    if os.path.isdir(scripts_dir):
        for f in os.listdir(scripts_dir):
            fp = os.path.join(scripts_dir, f)
            if os.path.isfile(fp):
                try:
                    lab_src += read(fp)
                except UnicodeDecodeError:
                    pass
    for unit, block in code_units(text):
        # lab.sh subcommands: "lab.sh up|down" and "lab.sh status"
        for m in re.finditer(r"lab\.sh ([a-z][a-z|-]*)", unit):
            for sub in m.group(1).split("|"):
                if sub and subs is not None and sub not in subs:
                    errs.append("unknown lab.sh subcommand: " + sub)
        m = re.search(r"ci-tests\.sh((?: [a-z][a-z0-9-]*)+)\s*$", unit)
        if m:
            for suite in m.group(1).split():
                if not os.path.isfile(os.path.join(root, "tests", suite + "-tests.sh")):
                    errs.append("unknown test suite: " + suite)
        m = re.search(r"ci-lint\.sh ([a-z]+)\s*$", unit)
        if m:
            lint = read(os.path.join(root, "scripts", "ci-lint.sh")) if os.path.isfile(
                os.path.join(root, "scripts", "ci-lint.sh")) else ""
            if not re.search(r"^\s*(?:[a-z]+ \| )*" + m.group(1) + r"(?: \| [a-z]+)*\)", lint, re.M):
                errs.append("unknown ci-lint.sh target: " + m.group(1))
        for word in unit.split():
            word = word.strip(",;:()'\"")
            if re.fullmatch(r"--[a-z][a-z-]*", word):
                if word not in lab_src:
                    errs.append("unknown option: " + word)
                continue
            if word.startswith(("~", "/", "http", "#")) or re.search(r"[<>*$|{}=…\[\]]", word):
                continue
            word = word.rstrip(".")
            if "/" in word or re.fullmatch(r"[A-Za-z0-9_.-]+\.(sh|py|md|yml|yaml|toml|txt|tsv|conf|tf)", word):
                if not exists(root, word):
                    errs.append("path does not exist: " + word)
    for fname in ("AGENTS.md", "CLAUDE.md"):
        fp = os.path.join(root, fname)
        if not os.path.isfile(fp):
            continue
        for m in re.finditer(r"\[[^\]]*\]\(([^)\s]+)\)", re.sub(r"<!--.*?-->", "", read(fp), flags=re.S)):
            target = m.group(1).split("#")[0]
            if target and not target.startswith(("http://", "https://", "mailto:")):
                if not exists(root, target):
                    errs.append(fname + ": broken link: " + target)
    claude = os.path.join(root, "CLAUDE.md")
    if os.path.isfile(claude):
        c = read(claude)
        if "AGENTS.md" not in c or len(c.strip().splitlines()) > 5:
            errs.append("CLAUDE.md must be a thin pointer (at most 5 lines) to AGENTS.md")
    route = os.path.join(root, "gitops", "workloads", "argocd", "ingressroute.yaml")
    if os.path.isfile(route):
        m = re.search(r"entryPoints:\n((?:\s+- \S+\n)+)", read(route))
        eps = re.findall(r"- (\S+)", m.group(1)) if m else []
        if eps != ["admin"]:
            errs.append("Argo CD IngressRoute entryPoints must be exactly [admin], is %s" % eps)
    elif strict:
        errs.append("gitops/workloads/argocd/ingressroute.yaml is missing")
    return errs


def report(name, errs):
    if errs:
        print("FAIL %s" % name)
        for e in errs[:10]:
            print("     " + e)
    else:
        print("OK   %s" % name)


def selftest():
    import shutil, tempfile
    base = tempfile.mkdtemp()
    good = (
        "# AGENTS.md\n\n## Purpose and audience\n\nx\n\n## Repository map\n\n| `scripts/lab.sh` | `up`, `status` |\n\n"
        "## Commands\n\n```bash\nbash scripts/ci-tests.sh demo   # note\nbash scripts/lab.sh status\n```\n\n"
        "## Conventions\n\nSee [guide](docs/guide.md) and `tests/demo-tests.sh`.\n\n## Security hard rules\n\n"
        "Use `--yes` never.\n\n## Definition of done\n\nx\n")
    labsh = ("#!/usr/bin/env bash\ncase \"${1:-}\" in\n  help)\n    echo '  bash scripts/lab.sh up        x'\n"
             "    echo '  bash scripts/lab.sh status    y'\n    echo '  # --yes mentioned here'\n;;\nesac\n")
    cases = [
        ("good tree is clean", good, False, []),
        ("missing path is found", good + "\nRun `scripts/nope.sh`.\n", True, ["path does not exist"]),
        ("unknown subcommand is found", good + "\nRun `bash scripts/lab.sh frobnicate`.\n", True,
         ["unknown lab.sh subcommand"]),
        ("unknown suite is found", good + "\n`bash scripts/ci-tests.sh nosuch`\n", True, ["unknown test suite"]),
        ("unknown option is found", good + "\nUse `--nosuchflag`.\n", True, ["unknown option"]),
        ("broken link is found", good + "\n[x](docs/missing.md)\n", True, ["broken link"]),
        ("too long is found", good + "\n" * 200, True, ["lines (max"]),
        ("umlaut is found", good + "\nGr\u00fcsse\n", True, ["must be English"]),
        ("missing section is found", good.replace("## Commands", "## Other"), True, ["section missing"]),
    ]
    results = []
    for name, agents, _bad, want in cases:
        d = os.path.join(base, str(len(results)))
        os.makedirs(os.path.join(d, "scripts"))
        os.makedirs(os.path.join(d, "docs"))
        os.makedirs(os.path.join(d, "tests"))
        for rel, body in (("scripts/lab.sh", labsh), ("scripts/ci-tests.sh", "#!/usr/bin/env bash\n"),
                          ("docs/guide.md", "x\n"), ("tests/demo-tests.sh", "#!/usr/bin/env bash\n"),
                          ("AGENTS.md", agents)):
            with open(os.path.join(d, rel), "w", encoding="utf-8") as fh:
                fh.write(body)
        errs = check(d, strict=False)
        okay = (not errs) if not want else all(any(w in e for e in errs) for w in want)
        results.append((name, [] if okay else ["unexpected result: %s" % errs[:3]]))
    shutil.rmtree(base)
    return results


if __name__ == "__main__":
    root = sys.argv[1]
    if len(sys.argv) > 2 and sys.argv[2] == "selftest":
        for name, errs in selftest():
            report("checker: " + name, errs)
    else:
        errs = check(root)
        groups = [("AGENTS.md: sections, length, language", ["section missing", "lines (max", "must be English", "TODO"]),
                  ("AGENTS.md: every referenced path exists", ["path does not exist", "broken link"]),
                  ("AGENTS.md: lab.sh subcommands, options, suites exist",
                   ["unknown lab.sh", "unknown option", "unknown test suite", "unknown ci-lint", "is missing"]),
                  ("CLAUDE.md: thin pointer to AGENTS.md", ["CLAUDE.md must"]),
                  ("Argo CD UI route: admin entrypoint only", ["entryPoints", "ingressroute"])]
        used = set()
        for name, keys in groups:
            sel = [e for e in errs if any(k in e for k in keys)]
            used.update(sel)
            report(name, sel)
        rest = [e for e in errs if e not in used]
        if rest:
            report("AGENTS.md: other findings", rest)
PY

OUT=$(python3 "$T/check.py" "$R"; python3 "$T/check.py" "$R" selftest)
while IFS= read -r l; do
  case $l in
    OK*|FAIL*) n=$((n + 1)); echo "$l"; case $l in FAIL*) fail=$((fail + 1)) ;; esac ;;
    *) echo "$l" ;;
  esac
done <<< "$OUT"

echo
echo "$n checks, $fail failures"
[ "$fail" = 0 ]
