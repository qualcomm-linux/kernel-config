#!/usr/bin/env python3
"""Plan qcom-next PR batches.

Collects open pull requests that change qcom-next.yaml, works out which topic
branches each one promotes, filters out PRs that are not ready, and groups the
remainder into batches that are safe to validate together according to
qcom-next-batching.yaml.

A PR body may name prerequisites with `Depends-on: #<pr>`. Those PRs are always
placed in the same batch, whatever safety zone they belong to, and are followed
transitively. If a dependency cannot be dispatched the whole group is held back
rather than validated without it.

Only one pipeline is allowed to run at a time: if any workflow listed under
defaults.block_on_workflows still has a queued, waiting or running run, nothing
is dispatched and the next scheduled run tries again.

Outputs (written to GITHUB_OUTPUT when present):
    batches        JSON array of {zone, prs, topics, reason}
    batch_count    number of batches selected for dispatch
    has_batches    "true" or "false"
    busy           "true" when a previous pipeline is still running

Also writes <output_dir>/batches.json and <output_dir>/summary.md.
"""

from __future__ import annotations

import fnmatch
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
CONFIG_PATH_DEFAULT = "qcom-next-batching.yaml"
TRACKED_FILE_DEFAULT = "qcom-next.yaml"

MERGEABLE_OK_DEFAULT = ("clean", "unstable", "has_hooks")

# GitHub computes mergeable_state lazily; "unknown" means "ask again shortly".
MERGEABLE_POLLS = 5
MERGEABLE_POLL_SECONDS = 2


def log(message: str) -> None:
    print(message, flush=True)


def fail(message: str) -> None:
    print(f"::error title=qcom-next batch::{message}", flush=True)
    sys.exit(1)


def load_yaml(text: str):
    try:
        import yaml
    except ImportError:  # pragma: no cover - runner images ship PyYAML
        fail("PyYAML is required to parse the batching config")
    return yaml.safe_load(text)


# --------------------------------------------------------------------- GitHub


class Client:
    def __init__(self, token: str, repo: str):
        self.token = token
        self.repo = repo

    def _request(self, url: str, accept: str = "application/vnd.github+json"):
        request = urllib.request.Request(url)
        request.add_header("Accept", accept)
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read(), response.headers
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            raise RuntimeError(f"GET {url} -> {error.code}: {detail}") from error

    def json(self, path: str, **params):
        url = f"{API}{path}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        body, _ = self._request(url)
        return json.loads(body)

    def paginate(self, path: str, **params):
        params.setdefault("per_page", 100)
        url = f"{API}{path}?{urllib.parse.urlencode(params)}"
        items = []
        while url:
            body, headers = self._request(url)
            page = json.loads(body)
            if not isinstance(page, list):
                return page
            items.extend(page)
            url = ""
            for link in headers.get("Link", "").split(","):
                if 'rel="next"' in link:
                    url = link[link.find("<") + 1 : link.find(">")]
                    break
        return items

    def raw_file(self, repo: str, path: str, ref: str) -> str | None:
        url = f"{API}/repos/{repo}/contents/{urllib.parse.quote(path)}?ref={ref}"
        try:
            body, _ = self._request(url, accept="application/vnd.github.raw")
        except RuntimeError as error:
            log(f"  note: could not read {path}@{ref[:12]} from {repo}: {error}")
            return None
        return body.decode("utf-8", "replace")


# ------------------------------------------------------------ topic extraction


def parse_topics(text: str) -> dict[str, dict[str, str]]:
    """Return {branch: {sha, tag}} from a qcom-next.yaml document."""
    if not text:
        return {}
    try:
        data = load_yaml(text)
    except Exception as error:  # noqa: BLE001 - a malformed PR must not crash us
        log(f"  note: qcom-next.yaml did not parse: {error}")
        return {}
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


def changed_topics(before: dict, after: dict) -> list[str]:
    touched = set()
    for branch, entry in after.items():
        previous = before.get(branch)
        if previous is None or previous != entry:
            touched.add(branch)
    touched.update(set(before) - set(after))
    return sorted(touched)


# ----------------------------------------------------------------- Depends-on

# `Depends-on:` lines in a PR body name the PRs that must be validated in the
# same batch. The value is a comma or space separated list; each entry may be a
# bare number, a #-prefixed number, or a full pull request URL.
DEPENDS_ON_RE = re.compile(r"^[ \t]*depends-on[ \t]*:(.*)$", re.IGNORECASE | re.MULTILINE)
PULL_URL_RE = re.compile(r"/pull/(\d+)")


def _dependency_number(token: str):
    token = token.strip().strip(".,;:)(<>[]")
    if not token:
        return None
    url = PULL_URL_RE.search(token)
    if url:
        return int(url.group(1))
    token = token.lstrip("#")
    return int(token) if token.isdigit() else None


def parse_depends_on(body: str) -> list[int]:
    """Return the PR numbers named by `Depends-on:` lines, in order."""
    found: list[int] = []
    for value in DEPENDS_ON_RE.findall(body or ""):
        for token in re.split(r"[,\s]+", value):
            number = _dependency_number(token)
            if number is not None and number not in found:
                found.append(number)
    return found


# ------------------------------------------------------------- serialisation

# A run occupying any of these states counts as still in flight. "waiting"
# covers runs paused for environment approval, "action_required" covers runs
# paused for a manual gate; both mean the pipeline has not finished.
ACTIVE_STATES = (
    "queued",
    "in_progress",
    "waiting",
    "pending",
    "requested",
    "action_required",
)


def active_runs(client: "Client", workflows: list[str]) -> list[dict]:
    """Return the runs that are still occupying the qcom-next pipeline."""
    busy = []
    for workflow in workflows:
        for state in ACTIVE_STATES:
            try:
                data = client.json(
                    f"/repos/{client.repo}/actions/workflows/{workflow}/runs",
                    status=state,
                    per_page=1,
                )
            except RuntimeError as error:
                # A disabled or deleted workflow cannot hold the lock.
                log(f"  note: {workflow} ({state}): {error}")
                continue
            if data.get("total_count", 0) <= 0:
                continue
            runs = data.get("workflow_runs") or [{}]
            busy.append(
                {
                    "workflow": workflow,
                    "status": state,
                    "count": data["total_count"],
                    "run_id": runs[0].get("id"),
                    "url": runs[0].get("html_url", ""),
                }
            )
    return busy


# ---------------------------------------------------------------------- zones


class Zones:
    def __init__(self, config: dict):
        defaults = config.get("defaults") or {}
        self.default_batch = int(defaults.get("max_batch_size", 3))
        self.max_dispatches = int(defaults.get("max_dispatches_per_run", 1))
        self.serialize = bool(defaults.get("serialize", True))
        self.require_mergeable = bool(defaults.get("require_mergeable", True))
        self.require_approval = bool(defaults.get("require_approval", True))
        self.min_approvals = int(defaults.get("min_approvals", 1))
        self.ignore_draft = bool(defaults.get("ignore_draft", True))
        self.skip_labels = {str(x) for x in defaults.get("skip_labels") or []}
        self.dispatched_label = str(defaults.get("dispatched_label", "") or "")
        self.unknown_policy = str(defaults.get("unknown_topic_policy", "solo"))
        self.mergeable_ok = {
            str(x)
            for x in defaults.get("allowed_mergeable_states")
            or MERGEABLE_OK_DEFAULT
        }
        self.block_on_workflows = [
            str(x) for x in defaults.get("block_on_workflows") or []
        ]

        self.zones = []
        for zone in config.get("zones") or []:
            self.zones.append(
                {
                    "name": str(zone.get("name") or "unnamed"),
                    "solo": bool(zone.get("solo", False)),
                    "wildcard": bool(zone.get("wildcard", False)),
                    "max_batch_size": int(
                        zone.get("max_batch_size", self.default_batch)
                    ),
                    "patterns": [str(p) for p in zone.get("topics") or []],
                }
            )

        self.conflicts = set()
        for entry in config.get("conflicts") or []:
            pair = entry.get("pair") if isinstance(entry, dict) else entry
            if not pair or len(pair) != 2:
                continue
            self.conflicts.add(frozenset(str(x) for x in pair))

    def zone_of(self, topic: str):
        for zone in self.zones:
            if any(fnmatch.fnmatchcase(topic, p) for p in zone["patterns"]):
                return zone
        return None

    def assign(self, topics: list[str]):
        """Return (zone, reason). zone is None when the PR must run solo.

        A zone marked `wildcard` may join a batch in any zone, so its topics do
        not constrain which zone a PR belongs to. A PR promoting only wildcard
        topics is returned with its wildcard zone and placed last, once the
        zoned batches are known.
        """
        if not topics:
            return None, "no topic change detected"

        found = []
        for topic in topics:
            zone = self.zone_of(topic)
            if zone is None:
                return None, f"topic '{topic}' is not in any zone"
            found.append(zone)

        # Wildcard topics are compatible with everything, so they are not
        # considered when working out the zone this PR is anchored to.
        anchors = [zone for zone in found if not zone["wildcard"]]
        if not anchors:
            zone = found[0]
            return zone, f"zone '{zone['name']}' (joins any batch)"

        names = {zone["name"] for zone in anchors}
        if len(names) > 1:
            return None, "topics span zones: " + ", ".join(sorted(names))

        zone = anchors[0]
        if zone["solo"]:
            return None, f"zone '{zone['name']}' is solo"
        return zone, f"zone '{zone['name']}'"

    def conflicting(self, left: list[str], right: list[str]):
        for a in left:
            for b in right:
                if frozenset((a, b)) in self.conflicts:
                    return (a, b)
        return None


# --------------------------------------------------------------------- planner


def eligible(pr: dict, zones: Zones, client: Client) -> tuple[bool, str]:
    number = pr["number"]
    labels = {label["name"] for label in pr.get("labels") or []}

    if zones.ignore_draft and pr.get("draft"):
        return False, "draft"

    blocked = labels & zones.skip_labels
    if blocked:
        return False, "label " + ", ".join(sorted(blocked))

    if zones.dispatched_label and zones.dispatched_label in labels:
        return False, f"already dispatched ({zones.dispatched_label})"

    detail = client.json(f"/repos/{client.repo}/pulls/{number}")

    if zones.require_mergeable:
        # GitHub computes mergeability asynchronously. The first read after a
        # change returns "unknown" and the GET itself schedules the work, so
        # poll briefly rather than skipping the PR for a whole cycle.
        attempts = 0
        while detail.get("mergeable_state") == "unknown" and attempts < MERGEABLE_POLLS:
            attempts += 1
            time.sleep(MERGEABLE_POLL_SECONDS)
            detail = client.json(f"/repos/{client.repo}/pulls/{number}")
        if attempts:
            log(
                f"  mergeable_state settled to "
                f"{detail.get('mergeable_state')} after {attempts} poll(s)"
            )

        state = detail.get("mergeable_state")
        if state not in zones.mergeable_ok:
            return False, f"mergeable_state={state}"

    if zones.require_approval:
        reviews = client.paginate(f"/repos/{client.repo}/pulls/{number}/reviews")
        latest = {}
        for review in reviews:
            user = (review.get("user") or {}).get("login")
            state = review.get("state")
            if not user or state not in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
                continue
            latest[user] = state
        if "CHANGES_REQUESTED" in latest.values():
            return False, "changes requested"
        approvals = sum(1 for state in latest.values() if state == "APPROVED")
        if approvals < zones.min_approvals:
            return False, f"{approvals}/{zones.min_approvals} approvals"

    return True, "ready"


def changed_files(client: Client, number: int) -> set[str]:
    files = client.paginate(f"/repos/{client.repo}/pulls/{number}/files")
    return {entry["filename"] for entry in files}


def collect(
    pr: dict,
    zones: Zones,
    client: Client,
    tracked: str,
    names: set[str] | None = None,
):
    """Return (candidate, reason); candidate is None when the PR is unusable.

    `names` is the PR's changed-file set when the caller has already fetched it.
    """
    number = pr["number"]

    if names is None:
        names = changed_files(client, number)
    if tracked not in names:
        return None, f"does not change {tracked}"

    ok, reason = eligible(pr, zones, client)
    if not ok:
        return None, reason

    head = pr.get("head") or {}
    head_repo = ((head.get("repo") or {}).get("full_name")) or client.repo
    before = parse_topics(client.raw_file(client.repo, tracked, (pr["base"] or {})["sha"]))
    after = parse_topics(client.raw_file(head_repo, tracked, head["sha"]))
    topics = changed_topics(before, after)

    if not topics:
        return None, "no topic change"

    extra = names - {tracked}
    if extra:
        return None, "changes files beyond " + tracked

    return {
        "number": number,
        "topics": topics,
        "title": pr["title"],
        "deps": parse_depends_on(pr.get("body")),
    }, "ready"


# ---------------------------------------------------------------- dependencies


def resolve_dependencies(
    candidates: list[dict],
    open_prs: dict[int, dict],
    zones: Zones,
    client: Client,
    tracked: str,
    base: str,
):
    """Pull every `Depends-on:` PR into the candidate set.

    A dependency must be validated together with the PR that declares it, so it
    is pulled in even when it sits in a different safety zone and even when
    ONLY_PRS did not name it. Dependencies are followed transitively.

    Returns (by_number, edges, blocked). `blocked` maps a PR number to the
    reason its dependency could not be batched; such a PR and everything linked
    to it is held back rather than validated without its dependency.
    """
    by_number = {item["number"]: item for item in candidates}
    edges: dict[int, set[int]] = {number: set() for number in by_number}
    blocked: dict[int, str] = {}

    def link(left: int, right: int) -> None:
        edges.setdefault(left, set()).add(right)
        edges.setdefault(right, set()).add(left)

    queue = list(by_number)
    while queue:
        number = queue.pop(0)
        item = by_number.get(number)
        if item is None:
            continue

        for dep in item["deps"]:
            if dep == number or dep in by_number:
                if dep != number:
                    link(number, dep)
                continue

            pr = open_prs.get(dep)
            if pr is None:
                try:
                    pr = client.json(f"/repos/{client.repo}/pulls/{dep}")
                except RuntimeError as error:
                    blocked[number] = f"Depends-on #{dep} could not be read ({error})"
                    continue

            # A merged dependency is already in the base, so there is nothing to
            # batch and the dependent PR is free to go out on its own.
            if pr.get("merged_at"):
                log(f"  Depends-on #{dep}: already merged")
                continue

            if pr.get("state") != "open":
                blocked[number] = f"Depends-on #{dep} is closed and unmerged"
                continue

            dep_base = ((pr.get("base") or {}).get("ref")) or ""
            if dep_base != base:
                blocked[number] = (
                    f"Depends-on #{dep} targets {dep_base or 'an unknown branch'}, "
                    f"not {base}"
                )
                continue

            dep_item, reason = collect(pr, zones, client, tracked)
            if dep_item is None:
                blocked[number] = f"Depends-on #{dep} is not dispatchable ({reason})"
                continue

            log(f"  Depends-on #{dep}: pulled into the same batch")
            by_number[dep] = dep_item
            link(number, dep)
            queue.append(dep)

    return by_number, edges, blocked


def dependency_groups(by_number: dict[int, dict], edges: dict[int, set[int]]):
    """Return the connected components of the Depends-on graph, oldest first."""
    seen: set[int] = set()
    groups: list[list[int]] = []

    for number in sorted(by_number):
        if number in seen:
            continue
        seen.add(number)
        stack = [number]
        component = []
        while stack:
            current = stack.pop()
            component.append(current)
            for neighbour in sorted(edges.get(current, ())):
                if neighbour in by_number and neighbour not in seen:
                    seen.add(neighbour)
                    stack.append(neighbour)
        groups.append(sorted(component))

    return groups


def build_items(
    by_number: dict[int, dict],
    edges: dict[int, set[int]],
    blocked: dict[int, str],
):
    """Turn dependency groups into the atomic units the planner batches.

    Returns (items, held); `held` lists the PRs withheld because something in
    their dependency group could not be batched.
    """
    items = []
    held: list[dict] = []

    for group in dependency_groups(by_number, edges):
        unusable = [(number, blocked[number]) for number in group if number in blocked]
        if unusable:
            detail = "; ".join(f"#{number}: {reason}" for number, reason in unusable)
            for number in group:
                if number in blocked:
                    reason = blocked[number]
                elif len(group) > 1:
                    reason = f"held with its dependency group ({detail})"
                else:
                    reason = detail
                log(f"  held: #{number}: {reason}")
                held.append({"number": number, "reason": reason})
            continue

        topics: list[str] = []
        for number in group:
            topics.extend(by_number[number]["topics"])

        duplicated = sorted({t for t in topics if topics.count(t) > 1})
        if duplicated:
            # Stacked promotions of one topic are expected to share a branch
            # ancestry, so they are kept together and left to the merge.
            log(
                "  note: dependency group "
                + ", ".join(f"#{n}" for n in group)
                + " promotes "
                + ", ".join(duplicated)
                + " more than once"
            )

        items.append({"numbers": group, "topics": sorted(set(topics))})

    return items, held


def _fits(batch: dict, item: dict, limit: int, zones: Zones) -> bool:
    """Whether this unit can join the batch."""
    if len(batch["prs"]) + len(item["numbers"]) > limit:
        return False

    # Two PRs promoting the same topic edit the same sha/tag lines in
    # qcom-next.yaml, so merging the second one would conflict.
    if set(batch["topics"]) & set(item["topics"]):
        return False

    return zones.conflicting(batch["topics"], item["topics"]) is None


def _add(batch: dict, item: dict) -> None:
    batch["prs"] = sorted(set(batch["prs"]) | set(item["numbers"]))
    batch["topics"] = sorted(set(batch["topics"]) | set(item["topics"]))


def _reason(item: dict, detail: str) -> str:
    if len(item["numbers"]) == 1:
        return detail
    linked = ", ".join(f"#{number}" for number in item["numbers"])
    return f"Depends-on group {linked}; {detail}"


def plan(items: list[dict], zones: Zones) -> list[dict]:
    grouped: dict[str, list[dict]] = {}
    wildcards: list[tuple[dict, dict]] = []
    batches: list[dict] = []

    for item in items:
        zone, reason = zones.assign(item["topics"])
        if zone is None:
            # A Depends-on group stays in one batch even when its topics span
            # zones or would otherwise be solo: the PRs have to be validated
            # together or not at all.
            batches.append(
                {
                    "zone": "depends" if len(item["numbers"]) > 1 else "solo",
                    "prs": sorted(item["numbers"]),
                    "topics": item["topics"],
                    "reason": _reason(item, reason),
                }
            )
        elif zone["wildcard"]:
            # Held back until the zoned batches exist, then slotted into one.
            wildcards.append((item, zone))
        else:
            grouped.setdefault(zone["name"], []).append(item)

    by_name = {zone["name"]: zone for zone in zones.zones}

    for name, units in grouped.items():
        limit = by_name[name]["max_batch_size"]
        units.sort(key=lambda entry: min(entry["numbers"]))
        open_batches: list[dict] = []

        for item in units:
            placed = False
            for batch in open_batches:
                if _fits(batch, item, limit, zones):
                    _add(batch, item)
                    placed = True
                    break
            if not placed:
                # A group larger than max_batch_size is still kept whole.
                open_batches.append(
                    {
                        "zone": name,
                        "prs": sorted(item["numbers"]),
                        "topics": sorted(set(item["topics"])),
                        "reason": _reason(item, f"zone '{name}'"),
                    }
                )

        batches.extend(open_batches)

    # Wildcard PRs join an existing batch in any zone, oldest batch first so a
    # wildcard rides along with work that is already going out. Solo batches
    # never accept a passenger.
    wildcards.sort(key=lambda entry: min(entry[0]["numbers"]))
    leftover: list[tuple[dict, dict]] = []
    for item, wildcard_zone in wildcards:
        host = None
        for batch in sorted(batches, key=lambda b: min(b["prs"])):
            if batch["zone"] == "solo":
                continue
            zone = by_name.get(batch["zone"])
            if zone is None or zone["solo"]:
                continue
            if _fits(batch, item, zone["max_batch_size"], zones):
                host = batch
                break
        if host is None:
            leftover.append((item, wildcard_zone))
            continue
        _add(host, item)

    # Anything left over batches with the other wildcards.
    spares: list[dict] = []
    for item, wildcard_zone in leftover:
        placed = False
        for batch in spares:
            if _fits(batch, item, wildcard_zone["max_batch_size"], zones):
                _add(batch, item)
                placed = True
                break
        if not placed:
            spares.append(
                {
                    "zone": wildcard_zone["name"],
                    "prs": sorted(item["numbers"]),
                    "topics": sorted(set(item["topics"])),
                    "reason": _reason(item, f"zone '{wildcard_zone['name']}'"),
                }
            )
    batches.extend(spares)

    # Oldest PR first so nothing starves.
    batches.sort(key=lambda batch: min(batch["prs"]))
    return batches


# ----------------------------------------------------------------- reporting


def busy_summary(busy: list[dict]) -> str:
    lines = [
        "### qcom-next batch dispatch",
        "",
        "Skipped: a qcom-next pipeline is still in flight, and only one runs at "
        "a time.",
        "",
        "| Workflow | Status | Run |",
        "| --- | --- | --- |",
    ]
    for item in busy:
        run = f"[{item['run_id']}]({item['url']})" if item["url"] else item["run_id"]
        lines.append(f"| `{item['workflow']}` | {item['status']} | {run} |")
    lines += [
        "",
        "The next scheduled run will dispatch the following batch once this one "
        "completes. Use `ignore_in_flight` to override.",
    ]
    return "\n".join(lines) + "\n"


def emit(
    output_dir: str,
    payload: dict,
    summary: str,
    selected: list[dict],
    busy: bool,
) -> None:
    os.makedirs(output_dir, exist_ok=True)
    with open(os.path.join(output_dir, "batches.json"), "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
    with open(os.path.join(output_dir, "summary.md"), "w", encoding="utf-8") as handle:
        handle.write(summary)

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as handle:
            handle.write(f"batches={json.dumps(selected)}\n")
            handle.write(f"batch_count={len(selected)}\n")
            handle.write(f"has_batches={'true' if selected else 'false'}\n")
            handle.write(f"busy={'true' if busy else 'false'}\n")

    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as handle:
            handle.write(summary)


# ------------------------------------------------------------------------ main


def main() -> None:
    repo = os.environ.get("GITHUB_REPOSITORY") or fail("GITHUB_REPOSITORY is required")
    token = os.environ.get("GH_TOKEN", "")
    config_path = os.environ.get("CONFIG_FILE", CONFIG_PATH_DEFAULT)
    tracked = os.environ.get("TRACKED_FILE", TRACKED_FILE_DEFAULT)
    base = os.environ.get("BASE_BRANCH", "")
    output_dir = os.environ.get("OUTPUT_DIR", ".")
    only = {
        int(x)
        for x in re.split(r"[,\s]+", os.environ.get("ONLY_PRS", "").strip())
        if x.isdigit()
    }

    if not os.path.exists(config_path):
        fail(f"batching config not found: {config_path}")
    zones = Zones(load_yaml(open(config_path, encoding="utf-8").read()) or {})

    override = os.environ.get("MAX_DISPATCHES", "").strip()
    if override.isdigit():
        zones.max_dispatches = int(override)

    client = Client(token, repo)
    if not base:
        base = client.json(f"/repos/{repo}").get("default_branch", "main")
    else:
        # An explicit base is usually a human testing from a branch. A typo
        # would otherwise just report "no PRs" and look like there is no work.
        try:
            client.json(f"/repos/{repo}/branches/{urllib.parse.quote(base)}")
        except RuntimeError as error:
            fail(f"base branch '{base}' was not found in {repo}: {error}")
    log(f"repo={repo} base={base} tracked={tracked}")

    # One pipeline at a time. Check before doing any planning work.
    ignore_in_flight = os.environ.get("IGNORE_IN_FLIGHT", "").lower() == "true"
    busy = []
    if zones.serialize and not ignore_in_flight:
        busy = active_runs(client, zones.block_on_workflows)
        if busy:
            log("")
            log("a previous qcom-next pipeline is still in flight:")
            for item in busy:
                log(
                    f"  {item['workflow']} {item['status']}"
                    f" (run {item['run_id']}) {item['url']}"
                )
            emit(
                output_dir,
                {"base": base, "busy": busy, "batches": [], "selected": []},
                busy_summary(busy),
                [],
                busy=True,
            )
            return
    elif ignore_in_flight:
        log("serialisation bypassed for this run")

    pulls = client.paginate(
        f"/repos/{repo}/pulls", state="open", base=base, sort="created", direction="asc"
    )
    log(f"open PRs against {base}: {len(pulls)}")

    open_prs = {pr["number"]: pr for pr in pulls}
    candidates = []
    rejected = []

    for pr in pulls:
        number = pr["number"]
        if only and number not in only:
            continue

        names = changed_files(client, number)
        if tracked not in names:
            continue

        log(f"PR #{number}: {pr['title'][:70]}")

        item, reason = collect(pr, zones, client, tracked, names)
        if item is None:
            log(f"  skipped: {reason}")
            rejected.append({"number": number, "reason": reason})
            continue

        log(f"  topics: {', '.join(item['topics'])}")
        if item["deps"]:
            log(f"  depends-on: {', '.join('#' + str(d) for d in item['deps'])}")
        candidates.append(item)

    # A Depends-on PR must ride in the same batch, whatever zone it belongs to.
    by_number, edges, blocked = resolve_dependencies(
        candidates, open_prs, zones, client, tracked, base
    )
    items, held = build_items(by_number, edges, blocked)
    rejected.extend(held)

    withheld = {entry["number"] for entry in held}
    candidates = [
        by_number[number] for number in sorted(by_number) if number not in withheld
    ]

    batches = plan(items, zones)
    selected = batches[: zones.max_dispatches]

    log("")
    log(f"candidates={len(candidates)} batches={len(batches)} dispatching={len(selected)}")
    for batch in batches:
        mark = "->" if batch in selected else "  "
        prs = ", ".join(f"#{n}" for n in batch["prs"])
        log(f" {mark} [{batch['zone']}] {prs}  ({batch['reason']})")

    lines = ["### qcom-next batch plan", ""]
    if selected:
        lines += ["| Dispatch | Zone | PRs | Topics |", "| --- | --- | --- | --- |"]
        for batch in batches:
            mark = "yes" if batch in selected else "queued"
            prs = ", ".join(f"#{n}" for n in batch["prs"])
            topics = ", ".join(f"`{t}`" for t in batch["topics"])
            lines.append(f"| {mark} | `{batch['zone']}` | {prs} | {topics} |")
        if len(batches) > len(selected):
            lines += [
                "",
                f"{len(batches) - len(selected)} further batch(es) are queued and "
                "will be dispatched once this pipeline finishes.",
            ]
    else:
        lines.append("No batch was eligible for dispatch.")
    if rejected:
        lines += ["", "<details><summary>Skipped PRs</summary>", ""]
        lines += [f"- #{item['number']}: {item['reason']}" for item in rejected]
        lines += ["", "</details>"]

    emit(
        output_dir,
        {
            "base": base,
            "busy": busy,
            "candidates": candidates,
            "rejected": rejected,
            "batches": batches,
            "selected": selected,
        },
        "\n".join(lines) + "\n",
        selected,
        busy=False,
    )


if __name__ == "__main__":
    main()
