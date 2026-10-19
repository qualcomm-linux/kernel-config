#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the qcom-next tree described by qcom-next.yaml.
#
#   qcom-next = base.sha + topics[].sha merged in order, conflicts replayed
#               from the rerere cache
#
# Steps, in order:
#
#   1. fetch every pinned commit into one local clone
#   2. move each topic branch and the baseline onto its pinned sha
#   3. generate the ci-merge conf from the yaml
#   4. run ci-merge
#   5. prove every pin ended up in the tree
#   6. commit qcom-next/topic_SHA1 and qcom-next/merge.log, as automerge.yml does
#
# Step 5 is the part worth keeping honest: if pinning had silently fallen back
# to a branch tip, the pinned commit would not be an ancestor of the result.
#
# Exit 0 tree built, 1 something failed, 2 usage error.
set -u
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_TOOL="$HERE/qcom_next_conf.py"

CONFIG=""
KERNEL_DIR=""
AUTOMERGE=""
OUT_DIR=""
INTEG="qcom-next"
BASE_BRANCH="qcom-next-base"
LOG_COMMIT=1

die()  { printf 'error: %s\n' "$*" >&2; exit 2; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

usage() {
    cat <<'EOF'
Build the qcom-next tree from qcom-next.yaml.

  --config PATH       qcom-next.yaml (default: ./qcom-next.yaml)
  --kernel-dir DIR    clone to build in; needs the topic branches (required)
  --automerge DIR     directory holding ci-merge (required)
  --out-dir DIR       where to write merge.log, conf, summary (required)
  --integ-branch NAME branch to build (default: qcom-next)
  --no-log-commit     skip the in-tree topic_SHA1 / merge.log commit
  -h, --help          this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --config)        CONFIG="${2:?}"; shift 2 ;;
        --kernel-dir)    KERNEL_DIR="${2:?}"; shift 2 ;;
        --automerge)     AUTOMERGE="${2:?}"; shift 2 ;;
        --out-dir)       OUT_DIR="${2:?}"; shift 2 ;;
        --integ-branch)  INTEG="${2:?}"; shift 2 ;;
        --no-log-commit) LOG_COMMIT=0; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$KERNEL_DIR" ] || die "--kernel-dir is required"
[ -n "$AUTOMERGE" ]  || die "--automerge is required"
[ -n "$OUT_DIR" ]    || die "--out-dir is required"
[ -n "$CONFIG" ]     || CONFIG="$(pwd)/qcom-next.yaml"
[ -f "$CONFIG" ]     || die "config not found: $CONFIG"
[ -x "$AUTOMERGE/ci-merge" ] || [ -f "$AUTOMERGE/ci-merge" ] || die "ci-merge not found in $AUTOMERGE"
git -C "$KERNEL_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $KERNEL_DIR"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
KERNEL_DIR="$(cd "$KERNEL_DIR" && pwd)"
AUTOMERGE="$(cd "$AUTOMERGE" && pwd)"

PINS="$OUT_DIR/pins.tsv"
CONF="$OUT_DIR/qcom-next.conf"
MERGE_LOG="$OUT_DIR/merge.log"
SUMMARY="$OUT_DIR/summary.md"

G() { git -C "$KERNEL_DIR" "$@"; }

python3 "$CONF_TOOL" --config "$CONFIG" pins > "$PINS" || fail "cannot read $CONFIG"

BASE_SHA="$(awk -F'\t' '$1=="base" {print $3; exit}' "$PINS")"
BASE_REPO="$(awk -F'\t' '$1=="base" {print $2; exit}' "$PINS")"
RERERE_REPO="$(awk -F'\t' '$1=="rerere" {print $2; exit}' "$PINS")"
RERERE_REF="$(awk -F'\t' '$1=="rerere" {print $3; exit}' "$PINS")"
TOPIC_COUNT="$(awk -F'\t' '$1=="topic"' "$PINS" | grep -c . || true)"

say "config    : $CONFIG"
say "kernel    : $KERNEL_DIR"
say "base      : ${BASE_SHA:0:12}"
say "topics    : $TOPIC_COUNT"
say "rerere    : ${RERERE_REPO:-none} @ ${RERERE_REF:-none}"

# --------------------------------------------------------------------------
step "Fetching the pinned commits"

# One fetch per distinct repository, then confirm each pin arrived. Fetching
# heads and tags covers the normal case; a pin that is behind a rebased branch
# is reachable only through a tag, which is why tags are included.
i=0
while read -r repo; do
    [ -n "$repo" ] || continue
    i=$((i + 1))
    remote="src$i"
    G remote remove "$remote" 2>/dev/null
    G remote add "$remote" "$repo"
    say "  $repo"
    G fetch --quiet --tags "$remote" "+refs/heads/*:refs/remotes/$remote/*" 2>/dev/null \
        || say "    (fetch reported errors; individual pins are checked next)"
done < <(awk -F'\t' '$1=="base" || $1=="topic" {print $2}' "$PINS" | sort -u)

missing=0
while IFS=$'\t' read -r kind repo sha name; do
    case "$kind" in base|topic) ;; *) continue ;; esac
    if ! G cat-file -e "${sha}^{commit}" 2>/dev/null; then
        # Last resort: ask the server for that one commit.
        G fetch --quiet "$repo" "$sha" 2>/dev/null || true
    fi
    if ! G cat-file -e "${sha}^{commit}" 2>/dev/null; then
        printf '  missing: %-28s %s\n' "${name:-base}" "${sha:0:12}" >&2
        missing=$((missing + 1))
    fi
done < "$PINS"
[ "$missing" -eq 0 ] || fail "$missing pinned commit(s) could not be fetched"
say "every pin is present locally"

# --------------------------------------------------------------------------
step "Moving the branches onto their pins"

# ci-merge merges override/<name> when that ref exists, so this is where topics
# get pinned. The baseline gets a local branch at base.sha, which the conf then
# points at.
G branch -f "$BASE_BRANCH" "$BASE_SHA" >/dev/null 2>&1 \
    || fail "cannot put $BASE_BRANCH on ${BASE_SHA:0:12}"

while IFS=$'\t' read -r kind repo sha name; do
    [ "$kind" = "topic" ] || continue
    G update-ref "refs/heads/$name" "$sha"       || fail "cannot set $name"
    G update-ref "refs/heads/override/$name" "$sha" || fail "cannot set override/$name"
done < "$PINS"
say "$TOPIC_COUNT topic branch(es) and the baseline are on their pins"

# Start from a clean worktree on the baseline; ci-merge creates the integration
# branch itself.
G checkout --quiet --force "$BASE_BRANCH" || fail "cannot check out $BASE_BRANCH"
G branch -D "$INTEG" >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
step "Generating the ci-merge conf"

python3 "$CONF_TOOL" --config "$CONFIG" conf \
    --local-repo "$KERNEL_DIR" \
    --baseline-branch "$BASE_BRANCH" \
    --output "$CONF" || fail "cannot write $CONF"

# --------------------------------------------------------------------------
step "Running ci-merge"

args=(-f "$CONF" -t head -i "$INTEG" -n)
[ -n "$RERERE_REPO" ] && args+=(-c "$RERERE_REPO")
# -p ("keep going past a conflict") only exists on some revisions.
grep -q '[-]p)' "$AUTOMERGE/ci-merge" 2>/dev/null && args+=(-p)

( cd "$KERNEL_DIR" && bash "$AUTOMERGE/ci-merge" "${args[@]}" ) 2>&1 | tee "$MERGE_LOG"

G show-ref --verify --quiet "refs/heads/$INTEG" \
    || { tail -30 "$MERGE_LOG" >&2; fail "ci-merge did not create $INTEG"; }

CONFLICTS="$(grep -c '^Merge conflict : ' "$MERGE_LOG" 2>/dev/null || true)"
[ "${CONFLICTS:-0}" -eq 0 ] \
    || fail "$CONFLICTS unresolved conflict(s); resolve them and push the rerere cache
$(grep '^Merge conflict : ' "$MERGE_LOG" | sed 's/^/  /')"

HEAD_SHA="$(G rev-parse "refs/heads/$INTEG")"
say "built $INTEG @ ${HEAD_SHA:0:12}"

# --------------------------------------------------------------------------
step "Checking every pin is in the tree"

# The real proof that pinning worked. A tip that leaked in instead of the pin
# shows up here as a commit that is not an ancestor.
G merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" 2>/dev/null \
    || fail "base ${BASE_SHA:0:12} is not in the tree"

: > "$OUT_DIR/topics.tsv"
bad=0
while IFS=$'\t' read -r kind repo sha name; do
    [ "$kind" = "topic" ] || continue
    if G merge-base --is-ancestor "$sha" "$HEAD_SHA" 2>/dev/null; then
        n="$(G rev-list --no-merges --count "$BASE_SHA..$sha" 2>/dev/null || echo 0)"
        printf '%s\t%s\t%s\n' "$name" "$sha" "$n" >> "$OUT_DIR/topics.tsv"
    else
        printf '  not in the tree: %-28s %s\n' "$name" "${sha:0:12}" >&2
        bad=$((bad + 1))
    fi
done < "$PINS"
[ "$bad" -eq 0 ] || fail "$bad pinned commit(s) are missing from the tree"
say "all $TOPIC_COUNT pins verified"

# --------------------------------------------------------------------------
if [ "$LOG_COMMIT" -eq 1 ]; then
    step "Adding topic_SHA1 and merge.log to the tree"

    # Same two files automerge.yml has always committed, so a published
    # qcom-next states what it is made of. The table is built from the verified
    # pins rather than parsed out of merge.log, because the "Merge successful"
    # lines it would need are not emitted by every ci-merge revision.
    mkdir -p "$KERNEL_DIR/$INTEG"
    {
        printf "%-20s %*s %*s\n" "Name" 20 "SHA" 40 "Commits"
        printf "%s\n" "------------------------------------------------------------------------------------"
        while IFS=$'\t' read -r name sha n; do
            printf "%-20s %*s %10s\n" "$name" 45 "$sha" "$n"
        done < "$OUT_DIR/topics.tsv"
    } > "$KERNEL_DIR/$INTEG/topic_SHA1"

    # Strip CR and redact credentials: this log gets published and a leaked
    # token cannot be withdrawn.
    sed -e 's/\r$//' \
        -e 's#https://x-access-token:[^/@[:space:]]\{1,\}@github\.com/#https://x-access-token:***@github.com/#g' \
        -e 's#https://[^/@[:space:]]\{1,\}@github\.com/#https://***@github.com/#g' \
        "$MERGE_LOG" > "$KERNEL_DIR/$INTEG/merge.log"
    grep -q 'x-access-token:[^*]' "$KERNEL_DIR/$INTEG/merge.log" \
        && fail "the merge log still holds a credential; refusing to commit it"

    # The kernel repositories reject author/committer emails matching
    # .*@qualcomm\.com (GH013), which is why automerge.yml uses qti.qualcomm.com.
    name="${GIT_AUTHOR_NAME:-qcom-next CI}"
    email="${GIT_AUTHOR_EMAIL:-qcom-next-ci@qti.qualcomm.com}"
    case "$email" in
        *@qualcomm.com) fail "author email $email is rejected by the repo ruleset; use qti.qualcomm.com" ;;
    esac

    G add "$INTEG/topic_SHA1" "$INTEG/merge.log" || fail "cannot stage the log files"

    # rerere is disabled for this one commit on purpose. ci-merge leaves
    # .git/rr-cache as a symlink into its own working directory, and once that
    # target is gone git fails the commit with
    #   fatal: could not create directory '.git/rr-cache'
    # There are no conflict resolutions to record for a commit that only adds
    # two files, so turning it off here is both safe and sufficient.
    GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" \
    GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
        G -c rerere.enabled=false commit --quiet \
            -m "Add qcom-next log files for $(date '+%Y%m%d')" \
            -m "Adding merge log file and topic_SHA1 file" \
            -m "Signed-off-by: $name <$email>" \
        || fail "cannot commit the log files"

    HEAD_SHA="$(G rev-parse "refs/heads/$INTEG")"
    say "log commit: ${HEAD_SHA:0:12}"
fi

# --------------------------------------------------------------------------
{
    echo "### qcom-next candidate"
    echo ""
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Head | \`$HEAD_SHA\` |"
    echo "| Base | \`$BASE_SHA\` |"
    echo "| Topics merged | $TOPIC_COUNT |"
    echo "| Pins verified | $TOPIC_COUNT / $TOPIC_COUNT |"
    echo "| Rerere cache | \`${RERERE_REPO:-none}\` @ \`${RERERE_REF:-none}\` |"
    if [ "$LOG_COMMIT" -eq 1 ]; then
        echo "| In-tree logs | \`$INTEG/topic_SHA1\`, \`$INTEG/merge.log\` |"
    fi
} > "$SUMMARY"

echo "$HEAD_SHA" > "$OUT_DIR/head.txt"

step "Done"
say "$INTEG @ ${HEAD_SHA:0:12}, $TOPIC_COUNT topics, all pins verified"
say "artifacts in $OUT_DIR"
exit 0
