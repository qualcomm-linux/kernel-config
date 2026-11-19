#!/usr/bin/env python3
"""Helpers for qcom-next candidate builds.

Subcommands:

  diff BEFORE AFTER
      Print the topic branches whose sha or tag differs between two
      qcom-next.yaml revisions, one per line. Used to work out which topics a
      given kernel-config PR promotes.

  blame --prs PRS_JSON [--conflicts TOPIC_CONFLICT] [--merge-log MERGE_LOG]
      Map the topics that automerge reported as conflicting back to the PRs
      that promoted them. Emits JSON on stdout:

        {
          "conflicts":    ["tech/mm/drm", ...],
          "blamed":       [{"number": 12, "topics": ["tech/mm/drm"]}, ...],
          "unattributed": ["tech/all/config", ...]
        }

      Conflicting topics are collected from two sources, so the result is the
      same whichever way automerge is invoked:

        topic_conflict   written by log-parser.sh from "Merge conflict : ..."
                         lines, which automerge only emits with --pass.
        merge.log        "Merge failed, <topic> <url> <branch>" lines, which
                         automerge emits in both modes. Without --pass it then
                         aborts the merge and exits non-zero, so this is the
                         only source available in that mode.

      `unattributed` lists conflicting topics that no PR in the batch touched.
      Those cannot be fixed by dropping a PR and must fail the run, otherwise
      the candidate would silently ship without them.
"""

from __future__ import annotations

import argparse
import json
import re
import sys


def load_yaml(path: str):
    try:
        import yaml
    except ImportError:
        print("::error title=qcom-next::PyYAML is required", file=sys.stderr)
        sys.exit(1)
    with open(path, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def topics_of(path: str) -> dict[str, dict[str, str]]:
    data = load_yaml(path)
    if not isinstance(data, dict):
        return {}
    result = {}
    for item in data.get("topics") or []:
        if not isinstance(item, dict):
            continue
        branch = item.get("branch") or item.get("name")
        if not branch:
            continue
        result[str(branch)] = {
            "sha": str(item.get("sha", "")),
            "tag": str(item.get("tag", "")),
        }
    return result


def cmd_diff(args) -> int:
    before = topics_of(args.before)
    after = topics_of(args.after)

    changed = set()
    for branch, entry in after.items():
        if before.get(branch) != entry:
            changed.add(branch)
    changed.update(set(before) - set(after))

    for branch in sorted(changed):
        print(branch)
    return 0


def read_conflicts(path: str | None) -> list[str]:
    """Parse automerge's topic_conflict file.

    Format written by log-parser.sh:

        Name                           SHA
        --------------------------------------------------------
        tech/mm/drm                    <sha>
    """
    topics: list[str] = []
    if not path:
        return topics
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        return topics

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("-") or stripped.startswith("Name"):
            continue
        topics.append(stripped.split()[0])
    return topics


def read_merge_failures(path: str | None) -> list[str]:
    """Topics from automerge's "Merge failed, <topic> <url> <branch>" lines.

    Only the three-field form names a topic. The interactive variants
    ("Merge failed, manual merge" and "Merge failed before creating
    MERGE_HEAD...") carry no topic and are ignored.
    """
    if not path:
        return []
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except FileNotFoundError:
        return []

    topics = []
    pattern = re.compile(r"^Merge failed,\s+(\S+)\s+(\S+)\s+(\S+)\s*$", re.M)
    for match in pattern.finditer(text):
        topics.append(match.group(1))
    return topics


def cmd_blame(args) -> int:
    conflicts = read_conflicts(args.conflicts) + read_merge_failures(args.merge_log)

    with open(args.prs, encoding="utf-8") as handle:
        prs = json.load(handle)

    blamed = []
    claimed = set()
    for pr in prs:
        owned = sorted(set(pr.get("topics") or []) & set(conflicts))
        if owned:
            blamed.append({"number": pr["number"], "topics": owned})
            claimed.update(owned)

    unattributed = sorted(set(conflicts) - claimed)

    json.dump(
        {
            "conflicts": sorted(set(conflicts)),
            "blamed": sorted(blamed, key=lambda item: item["number"]),
            "unattributed": unattributed,
        },
        sys.stdout,
        indent=2,
    )
    print()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    diff = sub.add_parser("diff", help="topics changed between two qcom-next.yaml")
    diff.add_argument("before")
    diff.add_argument("after")
    diff.set_defaults(func=cmd_diff)

    blame = sub.add_parser("blame", help="map conflicting topics back to PRs")
    blame.add_argument("--prs", required=True)
    blame.add_argument("--conflicts", help="automerge topic_conflict file")
    blame.add_argument("--merge-log", help="automerge merge.log")
    blame.set_defaults(func=cmd_blame)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
