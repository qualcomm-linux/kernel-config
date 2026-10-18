#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Record a green candidate tree as the publishable tree for its config digest.
#
# Publication happens after the config PR is merged, in a separate workflow run
# that has no link back to the PR run that tested anything. It therefore needs
# to answer one question from the merged config alone:
#
#     which commit, exactly, passed the gates for this configuration?
#
# Nothing durable answered that before. The candidate ref name encodes a PR
# number and short sha, the tested-set is an artifact that expires, and run
# history is awkward to query by config state. This script writes the mapping
# as a git ref in the candidate repository:
#
#     refs/qcom-next-tested/<digest>
#
# The ref points at a commit whose **first parent is the candidate commit** and
# whose tree holds manifest.json plus the tested-set. That shape matters:
#
#   * it keeps the candidate commit reachable, so the tested tree survives even
#     after prune-qcom-next-candidates.yml removes the candidate branch;
#   * it is outside refs/heads/, so it is not a branch, is not pruned, and does
#     not appear in branch listings;
#   * it is keyed by digest, so the publisher looks it up with no knowledge of
#     which PR produced it.
#
# Only a run whose gates are green may call this. Recording an untested tree
# would make it publishable.
#
# Exit status:
#   0  manifest recorded (and pushed unless --no-push)
#   1  recording failed
#   2  usage error or missing prerequisite
set -u
set -o pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SELF_DIR/qcom_next_config.py"

KERNEL_DIR=""
TESTED_SET=""
CANDIDATE_REPO=""
CANDIDATE_REF=""
CANDIDATE_SHA=""
CONFIG_REPO=""
CONFIG_SHA=""
PR_NUMBER="0"
RUN_URL=""
STATUSES=""
REF_NS="refs/qcom-next-tested"
PUSH=1
QUIET=0

die()  { printf 'error: %s\n' "$*" >&2; exit 2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
step() { [ "$QUIET" -eq 1 ] || printf '\n==> %s\n' "$*"; }

usage() {
    cat <<'EOF'
Record a tested candidate tree as publishable for its config digest.

Options:
  --kernel-dir DIR        repo containing the candidate commit (required)
  --tested-set PATH       tested-set.txt written by generation (required)
  --candidate-repo R      OWNER/REPO holding the candidate ref (required)
  --candidate-sha SHA     the tested commit, full 40-hex (required)
  --candidate-ref REF     candidate branch name, for the record
  --config-repo R         kernel-config repo the config came from
  --config-sha SHA        kernel-config commit the config came from
  --pr N                  PR number that produced the candidate
  --run-url URL           workflow run that tested it
  --statuses LIST         comma-separated gate checks proven green
  --ref-namespace NS      ref namespace (default: refs/qcom-next-tested)
  --no-push               build the manifest locally without pushing
  -q, --quiet             only report the verdict
  -h, --help              this help

Pushing requires GH_PUSH_TOKEN in the environment.

Exit 0 recorded, 1 failure, 2 usage error.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel-dir)     KERNEL_DIR="${2:?}"; shift 2 ;;
        --tested-set)     TESTED_SET="${2:?}"; shift 2 ;;
        --candidate-repo) CANDIDATE_REPO="${2:?}"; shift 2 ;;
        --candidate-ref)  CANDIDATE_REF="${2:?}"; shift 2 ;;
        --candidate-sha)  CANDIDATE_SHA="${2:?}"; shift 2 ;;
        --config-repo)    CONFIG_REPO="${2:?}"; shift 2 ;;
        --config-sha)     CONFIG_SHA="${2:?}"; shift 2 ;;
        --pr)             PR_NUMBER="${2:?}"; shift 2 ;;
        --run-url)        RUN_URL="${2:?}"; shift 2 ;;
        --statuses)       STATUSES="${2:?}"; shift 2 ;;
        --ref-namespace)  REF_NS="${2:?}"; shift 2 ;;
        --no-push)        PUSH=0; shift ;;
        -q|--quiet)       QUIET=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[ -n "$KERNEL_DIR" ]     || die "--kernel-dir is required"
[ -n "$TESTED_SET" ]     || die "--tested-set is required"
[ -n "$CANDIDATE_REPO" ] || die "--candidate-repo is required"
[ -n "$CANDIDATE_SHA" ]  || die "--candidate-sha is required"
[ -f "$TESTED_SET" ]     || die "tested-set not found: $TESTED_SET"
[ -f "$HELPER" ]         || die "helper not found: $HELPER"
command -v git >/dev/null 2>&1     || die "git not found in PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"

case "$CANDIDATE_REPO" in */*) ;; *) die "--candidate-repo must be OWNER/REPO: $CANDIDATE_REPO" ;; esac
case "$CANDIDATE_SHA" in
    [0-9a-f]*) [ "${#CANDIDATE_SHA}" -eq 40 ] || die "--candidate-sha must be a full 40-hex sha" ;;
    *) die "--candidate-sha must be lowercase 40-hex: $CANDIDATE_SHA" ;;
esac

git -C "$KERNEL_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git repository: $KERNEL_DIR"

# --------------------------------------------------------------------------
step "Verifying the tested-set is intact"

# Recompute rather than trust the digest line, so a truncated or edited record
# cannot be recorded as publishable.
if ! python3 "$HELPER" digest "$TESTED_SET" >/dev/null 2>&1; then
    fail "tested-set is not internally consistent: $TESTED_SET"
fi
DIGEST="$(python3 "$HELPER" digest "$TESTED_SET" --quiet 2>/dev/null || echo "")"
case "$DIGEST" in
    [0-9a-f]*) [ "${#DIGEST}" -eq 64 ] || fail "computed digest is not 64-hex: $DIGEST" ;;
    *) fail "could not compute a digest for $TESTED_SET" ;;
esac
info "digest        : $DIGEST"

step "Verifying the candidate commit"
git -C "$KERNEL_DIR" cat-file -e "${CANDIDATE_SHA}^{commit}" 2>/dev/null \
    || fail "candidate commit is not in $KERNEL_DIR: $CANDIDATE_SHA"
info "candidate     : ${CANDIDATE_SHA:0:12}"

# The tested-set must actually describe this commit, or the manifest would make
# an unrelated tree publishable under this digest.
if ! bash "$SELF_DIR/check_tested_tree_matches.sh" \
        --expected "$TESTED_SET" \
        --kernel-dir "$KERNEL_DIR" \
        --ref "$CANDIDATE_SHA" \
        --quiet; then
    fail "the candidate commit does not contain the tested set; refusing to record it"
fi
info "tested set is present in the candidate commit"

# --------------------------------------------------------------------------
step "Building the manifest"

RECORDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT

DIGEST="$DIGEST" CANDIDATE_REPO="$CANDIDATE_REPO" CANDIDATE_REF="$CANDIDATE_REF" \
CANDIDATE_SHA="$CANDIDATE_SHA" CONFIG_REPO="$CONFIG_REPO" CONFIG_SHA="$CONFIG_SHA" \
PR_NUMBER="$PR_NUMBER" RUN_URL="$RUN_URL" STATUSES="$STATUSES" \
RECORDED_AT="$RECORDED_AT" python3 - >"$MANIFEST" <<'PY'
import json, os

statuses = [s for s in (os.environ.get("STATUSES") or "").split(",") if s]
pr = os.environ.get("PR_NUMBER") or "0"
try:
    pr_val = int(pr)
except ValueError:
    pr_val = 0

print(json.dumps({
    "schema": 1,
    "digest": os.environ["DIGEST"],
    "candidate_repo": os.environ["CANDIDATE_REPO"],
    "candidate_ref": os.environ.get("CANDIDATE_REF") or "",
    "candidate_sha": os.environ["CANDIDATE_SHA"],
    "config_repo": os.environ.get("CONFIG_REPO") or "",
    "config_sha": os.environ.get("CONFIG_SHA") or "",
    "pr": pr_val,
    "run_url": os.environ.get("RUN_URL") or "",
    "proven_statuses": statuses,
    "recorded_at": os.environ["RECORDED_AT"],
}, indent=2, sort_keys=True))
PY

[ -s "$MANIFEST" ] || fail "manifest generation produced nothing"

# Build the commit with plumbing against a temporary index, so the caller's
# worktree and index are untouched.
TMP_INDEX="$(mktemp -u)"
blob_manifest="$(git -C "$KERNEL_DIR" hash-object -w --stdin < "$MANIFEST")" \
    || fail "could not write the manifest blob"
blob_tested="$(git -C "$KERNEL_DIR" hash-object -w --stdin < "$TESTED_SET")" \
    || fail "could not write the tested-set blob"

{
    printf '100644 blob %s\tmanifest.json\n' "$blob_manifest"
    printf '100644 blob %s\ttested-set.txt\n' "$blob_tested"
} > "${TMP_INDEX}.tree"

TREE="$(git -C "$KERNEL_DIR" mktree < "${TMP_INDEX}.tree")" \
    || fail "could not build the manifest tree"
rm -f "${TMP_INDEX}.tree"

# First parent is the candidate commit: that is what keeps the tested tree
# reachable after the candidate branch is pruned.
COMMIT_MSG="qcom-next: tested candidate for ${DIGEST:0:16}

digest        ${DIGEST}
candidate     ${CANDIDATE_SHA}
candidate ref ${CANDIDATE_REF:-<none>}
config        ${CONFIG_REPO:-<none>} @ ${CONFIG_SHA:-<none>}
pr            ${PR_NUMBER}
statuses      ${STATUSES:-<none>}
run           ${RUN_URL:-<none>}

Recorded by record_tested_candidate.sh. The first parent is the commit that
passed the gates and is therefore the commit publication must push."

MANIFEST_COMMIT="$(
    GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-qcom-next CI}" \
    GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-qcom-next-ci@qualcomm.com}" \
    GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-qcom-next CI}" \
    GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-qcom-next-ci@qualcomm.com}" \
    git -C "$KERNEL_DIR" commit-tree "$TREE" -p "$CANDIDATE_SHA" -m "$COMMIT_MSG"
)" || fail "could not create the manifest commit"

MANIFEST_REF="${REF_NS}/${DIGEST}"
git -C "$KERNEL_DIR" update-ref "$MANIFEST_REF" "$MANIFEST_COMMIT" \
    || fail "could not update $MANIFEST_REF locally"

info "manifest ref  : $MANIFEST_REF"
info "manifest commit: ${MANIFEST_COMMIT:0:12}"

# --------------------------------------------------------------------------
if [ "$PUSH" -eq 0 ]; then
    step "Not pushing (--no-push)"
    info "RESULT: PASS - manifest recorded locally at $MANIFEST_REF"
    exit 0
fi

step "Pushing the manifest"

[ -n "${GH_PUSH_TOKEN:-}" ] || fail "GH_PUSH_TOKEN is not set; cannot push to $CANDIDATE_REPO"

git -C "$KERNEL_DIR" remote remove manifest-target 2>/dev/null || true
git -C "$KERNEL_DIR" remote add manifest-target \
    "https://x-access-token:${GH_PUSH_TOKEN}@github.com/${CANDIDATE_REPO}.git" \
    || fail "could not add the manifest remote"

# --force is intended: a re-run of a green PR produces a content-identical tree
# under a new commit id, and the newest green candidate is the one to publish.
# The previous manifest commit is simply superseded.
push_rc=0
git -C "$KERNEL_DIR" push --force manifest-target \
    "${MANIFEST_COMMIT}:${MANIFEST_REF}" 2>&1 | sed 's/x-access-token:[^@]*@/x-access-token:***@/g' \
    || push_rc=1

git -C "$KERNEL_DIR" remote remove manifest-target 2>/dev/null || true

[ "$push_rc" -eq 0 ] || fail "could not push $MANIFEST_REF to $CANDIDATE_REPO"

info ""
info "RESULT: PASS - ${CANDIDATE_SHA:0:12} is publishable for digest ${DIGEST:0:16}"
info "  lookup with: git ls-remote https://github.com/${CANDIDATE_REPO} $MANIFEST_REF"

# The published tree carries qcom-next/topic_SHA1 and qcom-next/merge.log,
# added by generation. Recording therefore describes a commit that states its
# own provenance, which is what makes a published qcom-next auditable without
# access to the CI run that built it.
