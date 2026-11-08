#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 the k8s-lab contributors
"""Prepares a working copy of a notes repo for the Zensical build.

Usage (by docs/build.sh, hook ZENSICAL_PREPARE, with the Python of the
tools):  python notes-prepare.py WORKDIR

WORKDIR is a copy without .git (the pod uses "git archive"). The
script only changes this copy, never the repo: if the folder has a .git, it aborts
es ab.

What it does (Runbook: docs/how-to/notes-sites.md):
1. Use zensical.toml of the repo. If it is missing: move everything to _notes/
   and create a default configuration (default theme).
2. Set platform values: site_url (from the host), site_dir, strict=false.
3. Exclude = delete physically (otherwise the graph plugin sees the file,
   it does not know exclude_docs): AGENTS.md, matches of exclude_docs,
   .obsidian/ and .trash/, optionally notes with "share: private".
4. Remove menu entries (nav, .nav.yml) pointing to deleted files.
5. Knowledge graph: section [project.plugins.graph] and a page with the
   placeholder, last in the menu.

Environment: SITE_URL (required), SITE_TITLE (only without zensical.toml),
PRIVATE_FILTER (true/false, Standard false).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tomllib
from pathlib import Path

import pathspec
import yaml

GRAPH_DEFAULTS = {
    "enabled": False,
    "page_path": "wissensgraph/",
    "title": "Wissensgraph",
    "min_links": 0,
    "include_orphans": True,
    "mentions": False,
}
GRAPH_PAGE = """---
hide:
  - toc
---

# Wissensgraph

Which note links to which: dots are notes, lines are links.
Click a dot to open the note.

<div id="zensical-graph"></div>
"""
GENERATED_DIR = "_notes"
JUNK_DIRS = {".obsidian", ".trash"}
# Without own zensical.toml: these folders are templates, not notes.
TEMPLATE_DIRS = {"templates", "vorlagen", "_templates"}  # lang-allow: "vorlagen" is an existing folder name in user note repos
FRONT_MATTER = re.compile(r"\A---\s*\n(.*?)\n---\s*(\n|\Z)", re.S)
BARE_KEY = re.compile(r"^[A-Za-z0-9_-]+$")


def log(msg: str) -> None:
    print(f"notes-prepare: {msg}", flush=True)


# ---------- write TOML (tomllib can only read) ----------
def _key(k: str) -> str:
    return k if BARE_KEY.match(k) else json.dumps(k, ensure_ascii=False)


def _val(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ", ".join(_val(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{_key(k)} = {_val(x)}" for k, x in v.items()) + "}"
    return json.dumps(str(v), ensure_ascii=False)  # e.g. a date


def dump_toml(data: dict, prefix: str = "") -> str:
    lines, tables = [], []
    for k, v in data.items():
        if isinstance(v, dict):
            tables.append((k, v))
        else:
            lines.append(f"{_key(k)} = {_val(v)}")
    out = ""
    # Empty table (e.g. [project.plugins.tags]) = plugin on: keep the head.
    if lines or (prefix and not tables):
        out += (f"[{prefix}]\n" if prefix else "") + "".join(f"{l}\n" for l in lines) + "\n"
    for k, v in tables:
        out += dump_toml(v, f"{prefix}.{_key(k)}" if prefix else _key(k))
    return out


# ---------- Helpers ----------
def front_matter(path: Path) -> dict:
    try:
        m = FRONT_MATTER.match(path.read_text(encoding="utf-8"))
        data = yaml.safe_load(m.group(1)) if m else None
    except (UnicodeDecodeError, yaml.YAMLError):
        return {}
    return data if isinstance(data, dict) else {}


def remove(path: Path, docs: Path, removed: set[str], why: dict, reason: str) -> None:
    rel = path.relative_to(docs).as_posix()
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()
    removed.add(rel)
    why[reason] = why.get(reason, 0) + 1


def is_removed(target: str, base: str, removed: set[str]) -> bool:
    if re.match(r"^[a-z]+://", target):
        return False
    rel = os.path.normpath(os.path.join(base, target)).replace(os.sep, "/").strip("/")
    return any(rel == r or rel.startswith(r + "/") for r in removed)


def prune_nav(items, base: str, removed: set[str]) -> tuple[list, int]:
    """Removes entries that point to deleted files/folders."""
    out, dropped = [], 0
    for item in items:
        if isinstance(item, str):
            if is_removed(item, base, removed):
                dropped += 1
                continue
        elif isinstance(item, dict) and len(item) == 1:
            title, target = next(iter(item.items()))
            if isinstance(target, str) and is_removed(target, base, removed):
                dropped += 1
                continue
            if isinstance(target, list):
                target, n = prune_nav(target, base, removed)
                dropped += n
                item = {title: target}
        out.append(item)
    return out, dropped


def mentions(items, page: str) -> bool:
    return page in json.dumps(items, ensure_ascii=False)


# ---------- Main part ----------
def main(work: Path) -> int:
    site_url = os.environ.get("SITE_URL", "")
    if not site_url:
        sys.exit("notes-prepare: ERROR: SITE_URL is missing")
    if (work / ".git").exists():
        sys.exit(f"notes-prepare: ERROR: {work} has .git (working copies only, never the repo)")
    private_filter = os.environ.get("PRIVATE_FILTER", "false").lower() == "true"
    cfg_file = work / "zensical.toml"

    # 1. Configuration of the repo or default
    if cfg_file.exists():
        cfg = tomllib.loads(cfg_file.read_text(encoding="utf-8"))
        project = cfg.setdefault("project", {})
        log("zensical.toml des Repos")
        templates = False
    else:
        target = work / GENERATED_DIR
        target.mkdir()
        for entry in list(work.iterdir()):
            if entry != target:
                shutil.move(str(entry), str(target / entry.name))
        title = os.environ.get("SITE_TITLE") or "Notes"
        cfg = {"project": {
            "site_name": title,
            "docs_dir": GENERATED_DIR,
            "theme": {"language": "de", "features": [
                "navigation.instant", "navigation.tracking",
                "search.highlight", "content.code.copy"]},
        }}
        project = cfg["project"]
        log(f"no zensical.toml: default configuration (default theme, title {title!r})")
        templates = True
    docs = work / project.get("docs_dir", "docs")
    if not docs.is_dir():
        sys.exit(f"notes-prepare: ERROR: docs_dir {docs} is missing")

    # 2. Platform values
    if project.get("strict"):
        log("strict=true in the repo -> false (links to excluded pages are warnings, not an abort)")
    project["strict"] = False
    project["site_url"] = site_url
    project["site_dir"] = "site"

    # 3. Exclude
    removed: set[str] = set()
    why: dict[str, int] = {}
    spec = pathspec.PathSpec.from_lines(
        "gitwildmatch", str(project.get("exclude_docs", "")).splitlines())
    for path in sorted(docs.rglob("*"), key=lambda p: len(p.parts)):
        if not os.path.lexists(path):
            continue  # folder already gone
        rel = path.relative_to(docs).as_posix()
        if path.is_dir() and path.name in JUNK_DIRS:
            remove(path, docs, removed, why, path.name)
        elif path.name.lower() == "agents.md":
            remove(path, docs, removed, why, "AGENTS.md")
        elif spec.match_file(rel + ("/" if path.is_dir() else "")):
            remove(path, docs, removed, why, "exclude_docs")
        elif templates and path.is_dir() and path.name.lower() in TEMPLATE_DIRS:
            remove(path, docs, removed, why, "Templates")
        elif private_filter and path.suffix == ".md" and \
                str(front_matter(path).get("share", "")).lower() == "private":
            remove(path, docs, removed, why, "share: private")
    log("excluded: " + (", ".join(f"{k} {v}" for k, v in sorted(why.items())) or "nothing")
        + (" (filter share: private on)" if private_filter else " (notes with share: private stay)"))

    # 4. Clean up menu
    dropped = 0
    if isinstance(project.get("nav"), list):
        project["nav"], n = prune_nav(project["nav"], "", removed)
        dropped += n
    for nav_file in docs.rglob(".nav.yml"):
        data = yaml.safe_load(nav_file.read_text(encoding="utf-8")) or {}
        if isinstance(data, dict) and isinstance(data.get("nav"), list):
            base = nav_file.parent.relative_to(docs).as_posix()
            data["nav"], n = prune_nav(data["nav"], "" if base == "." else base, removed)
            if n:
                dropped += n
                nav_file.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True),
                                    encoding="utf-8")
    if dropped:
        log(f"menu: {dropped} entry/entries pointing to excluded files removed")

    # 5. Knowledge graph
    plugins = project.setdefault("plugins", {})
    graph = plugins.get("graph")
    if not isinstance(graph, dict):
        graph = plugins["graph"] = dict(GRAPH_DEFAULTS)
        log("knowledge graph: platform default (repo has no section [project.plugins.graph])")
    if graph.get("enabled", True):
        page_dir = str(graph.get("page_path", "graph/")).strip("/")
        page = f"{page_dir}.md"
        title = graph.get("title", "Wissensgraph")
        if not (docs / page).exists() and not (docs / page_dir / "index.md").exists():
            (docs / page).parent.mkdir(parents=True, exist_ok=True)
            (docs / page).write_text(GRAPH_PAGE.replace("# Wissensgraph", f"# {title}"),
                                     encoding="utf-8")
            log(f"knowledge graph: page {page} created")
        root_nav = docs / ".nav.yml"
        if isinstance(project.get("nav"), list):
            if not mentions(project["nav"], page):
                project["nav"].append({title: page})
        elif root_nav.exists():
            data = yaml.safe_load(root_nav.read_text(encoding="utf-8")) or {}
            if isinstance(data.get("nav"), list) and not mentions(data["nav"], page):
                data["nav"].append({title: page})
                root_nav.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True),
                                    encoding="utf-8")
                log("knowledge graph: last in the menu (.nav.yml)")
    if not any((docs / n).exists() for n in ("index.md", "README.md")):
        (docs / "index.md").write_text(
            f"# {project.get('site_name', 'Notes')}\n\nAll notes are in the menu. "
            f"How they connect: [Knowledge graph]({graph.get('page_path', 'graph/').strip('/')}.md).\n",
            encoding="utf-8")
        log("no start page in the repo: index.md created")

    text = dump_toml(cfg)
    if tomllib.loads(text) != cfg:
        sys.exit("notes-prepare: ERROR: TOML output differs (bug in the script)")
    cfg_file.write_text("# Generated by notes-prepare.py (working copy, not in the repo)\n" + text,
                        encoding="utf-8")
    pages = sum(1 for _ in docs.rglob("*.md"))
    log(f"ready: {pages} Markdown pages in {docs.relative_to(work)}/")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: notes-prepare.py WORKDIR")
    sys.exit(main(Path(sys.argv[1]).resolve()))
