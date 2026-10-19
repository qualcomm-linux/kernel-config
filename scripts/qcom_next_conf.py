#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Turn qcom-next.yaml into the flat conf ci-merge wants, plus the pin list.

qcom-next.yaml is the source of truth. ci-merge reads a three-column file
(name url branch), so that file is generated here and thrown away afterwards.

Two subcommands:

    conf --local-repo DIR   the ci-merge conf
    pins                    TSV: kind, name, sha  (base, rerere, topic)

Why every conf row points at one local repository
-------------------------------------------------
ci-merge pins a topic if a ref called override/<name> exists, which the tree
script creates. The baseline has no such hook: ci-merge re-fetches the baseline
remote and uses remotes/<name>/<branch>, so a locally moved ref does not
survive. Pointing the baseline row at a local clone whose branch already sits on
base.sha is what pins it. Doing the same for the topic rows costs nothing, pins
them a second way, and turns ~50 network fetches into local ones.
"""

from __future__ import annotations

import argparse
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("error: PyYAML is required (pip install pyyaml)")

SHA = re.compile(r"^[0-9a-f]{40}$")


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}

    base = cfg.get("base") or {}
    topics = cfg.get("topics") or []
    problems = []

    if not SHA.match(str(base.get("sha", ""))):
        problems.append(f"base.sha is not a full 40-hex sha: {base.get('sha')!r}")
    if not base.get("repo"):
        problems.append("base.repo is missing")
    if not topics:
        problems.append("no topics are configured")

    seen = set()
    for i, t in enumerate(topics):
        name = t.get("name")
        if not name:
            problems.append(f"topics[{i}] has no name")
            continue
        if name in seen:
            problems.append(f"duplicate topic: {name}")
        seen.add(name)
        if not SHA.match(str(t.get("sha", ""))):
            problems.append(f"{name}: sha is not a full 40-hex sha: {t.get('sha')!r}")
        if not t.get("repo"):
            problems.append(f"{name}: repo is missing")

    if problems:
        for p in problems:
            sys.stderr.write(f"error: {p}\n")
        sys.exit(1)

    return cfg


def cmd_conf(cfg: dict, args) -> None:
    base = cfg["base"]
    rerere = cfg.get("rerere_cache") or {}
    local = f"file://{args.local_repo}"

    lines = [
        "# Generated from qcom-next.yaml. Disposable: never commit this.",
        "#",
        "# Every row points at the local clone, where the tree script has already",
        "# reset each branch onto its pinned sha. That is what pins the baseline,",
        "# which ci-merge cannot pin any other way.",
        f"{args.baseline_name:<26} {local:<60} {args.baseline_branch}",
    ]
    for t in cfg["topics"]:
        lines.append(f"{t['name']:<26} {local:<60} {t['name']}")

    text = "\n".join(lines) + "\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(text)
        sys.stderr.write(
            f"wrote {args.output}: 1 baseline + {len(cfg['topics'])} topics"
            f"{' (rerere ' + rerere.get('ref', '?') + ')' if rerere else ''}\n")
    else:
        sys.stdout.write(text)


def cmd_pins(cfg: dict, args) -> None:
    base = cfg["base"]
    rerere = cfg.get("rerere_cache") or {}
    out = [f"base\t{base['repo']}\t{base['sha']}\t{base.get('branch') or ''}"]
    if rerere.get("repo"):
        out.append(f"rerere\t{rerere['repo']}\t{rerere.get('ref') or 'master'}\t")
    for t in cfg["topics"]:
        out.append(f"topic\t{t['repo']}\t{t['sha']}\t{t['name']}")
    sys.stdout.write("\n".join(out) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", default="qcom-next.yaml")
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("conf", help="write the ci-merge conf")
    c.add_argument("--local-repo", required=True,
                   help="path to the clone every row should point at")
    c.add_argument("--baseline-name", default="baseline")
    c.add_argument("--baseline-branch", default="qcom-next-base")
    c.add_argument("--output")

    sub.add_parser("pins", help="TSV: kind, repo, sha, name")

    args = ap.parse_args()
    cfg = load(args.config)
    {"conf": cmd_conf, "pins": cmd_pins}[args.cmd](cfg, args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
