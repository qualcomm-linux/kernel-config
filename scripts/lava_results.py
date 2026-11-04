#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
"""Export every LAVA suite and reject failed or incomplete test execution."""

import argparse
import json
from pathlib import Path
import re
import shlex
import time
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen

import yaml


class LavaResults:
    def __init__(self, base_url, job_id, output_dir, budget=180):
        self.base_url = base_url.rstrip("/") + "/"
        self.job_id = job_id
        self.output_dir = Path(output_dir)
        self.deadline = time.monotonic() + budget

    def fetch(self, url):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError("LAVA result collection exceeded its time budget")
        request = Request(url, headers={"Accept": "application/json", "User-Agent": "kernel-premerge-results"})
        with urlopen(request, timeout=min(30, remaining)) as response:
            return response.read().decode("utf-8")

    def pages(self, resource):
        url = urljoin(self.base_url, f"api/v0.2/jobs/{self.job_id}/{resource}/?limit=500")
        allowed = urlparse(url)
        visited = set()
        rows = []
        expected_count = None
        for page in range(100):
            if url in visited:
                raise ValueError(f"Repeated {resource} pagination URL")
            visited.add(url)
            payload = json.loads(self.fetch(url))
            (self.output_dir / f"{resource}-page-{page + 1}.json").write_text(
                json.dumps(payload, indent=2), encoding="utf-8")
            if isinstance(payload, list):
                if page:
                    raise ValueError(f"Unexpected list on a later {resource} page")
                # An unpaginated endpoint is supported only for a full response.
                if len(payload) >= 500:
                    raise ValueError(f"Cannot establish completeness of unpaginated {resource} response")
                rows.extend(payload)
                break
            if not isinstance(payload, dict) or not isinstance(payload.get("results"), list):
                raise ValueError(f"Malformed {resource} response")
            count = payload.get("count")
            if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                raise ValueError(f"Invalid {resource} count")
            if expected_count is not None and expected_count != count:
                raise ValueError(f"{resource} changed during collection")
            expected_count = count
            rows.extend(payload["results"])
            next_url = payload.get("next")
            if not next_url:
                if len(rows) != count:
                    raise ValueError(f"Incomplete {resource}: {len(rows)} of {count}")
                break
            url = urljoin(url, next_url)
            parsed = urlparse(url)
            if (parsed.scheme, parsed.netloc, parsed.path) != (allowed.scheme, allowed.netloc, allowed.path):
                raise ValueError(f"Unexpected {resource} pagination destination")
        else:
            raise ValueError(f"Too many {resource} pages")
        if any(not isinstance(row, dict) for row in rows):
            raise ValueError(f"Invalid {resource} row")
        ids = [row.get("id") for row in rows]
        if None in ids or len(set(ids)) != len(ids):
            raise ValueError(f"Missing or duplicate {resource} IDs")
        return rows

    def expected_results(self, definition_path):
        definition = yaml.safe_load(Path(definition_path).read_text(encoding="utf-8"))
        if not isinstance(definition, dict) or not isinstance(definition.get("actions"), list):
            raise ValueError("Submitted job definition is malformed")
        expected = []
        for action in definition["actions"]:
            if not isinstance(action, dict) or "test" not in action:
                continue
            for entry in action["test"].get("definitions", []):
                declared_name = entry.get("name")
                if not isinstance(declared_name, str) or not declared_name:
                    raise ValueError("Test definition has no suite name")
                if entry.get("from") == "inline":
                    source = entry.get("repository")
                else:
                    repository = urlparse(entry.get("repository", ""))
                    revision = entry.get("revision", "")
                    path = entry.get("path", "")
                    # LAVA defaults an omitted revision to a moving branch.
                    # Current source cannot establish what that completed job ran.
                    if not revision or not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
                        expected.append({"names": [declared_name], "cases": [],
                                         "source_verification": "suite-only, revision not pinned to a commit"})
                        continue
                    if repository.scheme != "https" or repository.netloc != "github.com":
                        raise ValueError("Expected-test discovery requires a public GitHub source or inline definition")
                    parts = repository.path.rstrip("/").removesuffix(".git").split("/")
                    if len(parts) != 3 or not revision or not path or ".." in path.split("/"):
                        raise ValueError("Definition source is incomplete")
                    # Use the exact submitted revision, never a local checkout.
                    source_url = f"https://raw.githubusercontent.com/{parts[1]}/{parts[2]}/{revision}/{path}"
                    source = yaml.safe_load(self.fetch(source_url))
                if not isinstance(source, dict):
                    raise ValueError("Test definition is malformed")
                names = {entry.get("name"), source.get("metadata", {}).get("name")}
                names.discard(None)
                names.discard("")
                cases = set()
                for step in source.get("run", {}).get("steps", []):
                    if not isinstance(step, str):
                        raise ValueError("Non-string test command in definition")
                    words = shlex.split(step)
                    if not any(word.endswith("/send-to-lava.sh") or word == "send-to-lava.sh" for word in words):
                        continue
                    if "--expected-testcase-id" in words:
                        position = words.index("--expected-testcase-id") + 1
                        if position >= len(words):
                            raise ValueError("Missing publication testcase name")
                        name = words[position]
                    else:
                        # Legacy result files can contain several testcase names
                        # unrelated to the filename. Do not invent a missing case.
                        continue
                    if "$" in name:
                        raise ValueError("Expected result name requires unresolved shell expansion")
                    cases.add(name)
                expected.append({"names": sorted(names), "cases": sorted(cases)})
        if not expected:
            raise ValueError("Submitted job has no expected test definitions")
        return expected

    def collect(self, definition_path, export_path):
        self.output_dir.mkdir(parents=True, exist_ok=True)
        suites = self.pages("suites")
        tests = self.pages("tests")
        expected = self.expected_results(definition_path)
        problems = []
        suite_ids = {suite["id"] for suite in suites}
        functional = [suite for suite in suites if suite.get("name") != "lava"]
        if not functional:
            problems.append("No functional test suite was reported")
        for suite in functional:
            if not any(test.get("suite") == suite["id"] for test in tests):
                problems.append(f"Suite {suite.get('name')} has no testcase results")
        for entry in expected:
            matches = [suite for suite in functional if suite_matches(suite.get("name"), entry["names"])]
            if len(matches) != 1:
                problems.append(f"Expected suite missing or ambiguous: {entry['names']}")
                continue
            reported = {test.get("name") for test in tests if test.get("suite") == matches[0]["id"]}
            for name in entry["cases"]:
                if name not in reported:
                    problems.append(f"Expected testcase missing: {matches[0]['name']}/{name}")
        for test in tests:
            if not isinstance(test.get("name"), str) or not test["name"]:
                problems.append("Testcase result has no name")
            if test.get("suite") not in suite_ids:
                problems.append(f"Unknown suite for testcase {test.get('name')}")
            status = test.get("result")
            if status not in {"pass", "skip"}:
                problems.append(f"{test.get('name')}: {status or 'missing result'}")
        exported = [{"name": test.get("name"), "result": test.get("result")}
                    for test in tests if test.get("suite") in {suite["id"] for suite in functional}]
        Path(export_path).write_text(json.dumps(exported, indent=2), encoding="utf-8")
        summary = {"job_id": self.job_id, "suites": len(suites), "tests": len(tests),
                   "expected": expected, "problems": problems}
        (self.output_dir / "verdict.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
        print(f"LAVA results: suites={len(suites)} testcases={len(tests)} problems={len(problems)}")
        for problem in problems:
            print(problem)
        return not problems


def suite_matches(name, expected_names):
    if not isinstance(name, str):
        return False
    # LAVA prefixes definitions with an execution index, such as 0_suite.
    # Preserve the remaining name, never assume a fixed index or device.
    return name in expected_names or re.sub(r"^[0-9]+_", "", name) in expected_names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://lava-oss.qualcomm.com")
    parser.add_argument("--job-id", type=int, required=True)
    parser.add_argument("--definition", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--export", required=True)
    args = parser.parse_args()
    try:
        valid = LavaResults(args.base_url, args.job_id, args.output_dir).collect(args.definition, args.export)
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as error:
        print(f"LAVA evidence collection failed: {error}")
        return 1
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
