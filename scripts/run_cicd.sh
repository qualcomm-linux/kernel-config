#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Dispatch one of the existing CI/CD workflows against a ref and wait for it.
#
# pre_merge.yml and pre-merge-yocto.yml are workflow_dispatch only, so they
# cannot be called with `uses:`. This starts one and waits for its verdict.
#
#   run_cicd.sh --workflow pre_merge.yml --repo qualcomm-linux/kernel \
#               --ref qcom-next-candidate-42 --sha <sha> --pr 42
#
# Needs GH_TOKEN. Exit 0 if the run succeeded, 1 otherwise.
set -u
set -o pipefail

WORKFLOW=""
WF_REPO="qualcomm-linux/kernel-config"
WF_REF="main"
TARGET_REPO=""
REF=""
SHA=""
PR="0"
TIMEOUT_MIN="240"
EXTRA=()

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --workflow)      WORKFLOW="${2:?}"; shift 2 ;;
        --workflow-repo) WF_REPO="${2:?}"; shift 2 ;;
        --workflow-ref)  WF_REF="${2:?}"; shift 2 ;;
        --repo)          TARGET_REPO="${2:?}"; shift 2 ;;
        --ref)           REF="${2:?}"; shift 2 ;;
        --sha)           SHA="${2:?}"; shift 2 ;;
        --pr)            PR="${2:?}"; shift 2 ;;
        --timeout-min)   TIMEOUT_MIN="${2:?}"; shift 2 ;;
        --extra)         EXTRA+=("-f" "${2:?}"); shift 2 ;;
        -h|--help)       sed -n '3,14p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$WORKFLOW" ]    || die "--workflow is required"
[ -n "$TARGET_REPO" ] || die "--repo is required"
[ -n "$REF" ]         || die "--ref is required"
[ -n "$SHA" ]         || die "--sha is required"
command -v gh >/dev/null 2>&1 || die "gh is required"
[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is not set"

say "dispatching $WORKFLOW"
say "  target : $TARGET_REPO @ $REF (${SHA:0:12})"

# Record the time first: the run has to be newer than this, so an older run of
# the same workflow is never mistaken for ours.
since="$(date -u -d '-2 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
         || date -u +%Y-%m-%dT%H:%M:%SZ)"

gh workflow run "$WORKFLOW" --repo "$WF_REPO" --ref "$WF_REF" \
    -f pr="$PR" -f sha="$SHA" -f ref="$REF" -f repo="$TARGET_REPO" \
    "${EXTRA[@]}" >/dev/null || die "could not dispatch $WORKFLOW"

# GitHub does not return the run id from a dispatch, so find it by workflow and
# creation time.
RUN=""
for _ in $(seq 1 30); do
    sleep 10
    RUN="$(gh api "repos/$WF_REPO/actions/workflows/$WORKFLOW/runs?event=workflow_dispatch&per_page=20" \
            --jq "[.workflow_runs[] | select(.created_at >= \"$since\")] | first | .id" 2>/dev/null)"
    [ -n "$RUN" ] && [ "$RUN" != "null" ] && break
    RUN=""
done
[ -n "$RUN" ] || die "could not find the dispatched run for $WORKFLOW"

URL="https://github.com/$WF_REPO/actions/runs/$RUN"
say "  run    : $URL"

deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    status="$(gh api "repos/$WF_REPO/actions/runs/$RUN" --jq '(.conclusion // .status)' 2>/dev/null)"
    case "$status" in
        success|failure|cancelled|timed_out|startup_failure|skipped|action_required|neutral|stale)
            break ;;
    esac
    sleep 60
done

say "  result : ${status:-unknown}"
[ "$status" = "success" ] && exit 0

printf 'error: %s did not succeed (%s)\n  %s\n' "$WORKFLOW" "${status:-timed out}" "$URL" >&2
exit 1
