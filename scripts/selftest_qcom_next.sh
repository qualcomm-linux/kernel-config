#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Offline tests for the qcom-next flow.
#
# Builds small local repositories, runs the real scripts against them over
# file://, and checks the things that would otherwise only break in CI:
# the conf is generated from the yaml, the pins are honoured rather than the
# branch tips, a bad config is rejected, and the in-tree log files are correct.
#
# Needs git, python3 with PyYAML, and a ci-merge checkout (AUTOMERGE_DIR, or a
# sibling automerge/ directory).
set -u
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CONF_TOOL="$HERE/qcom_next_conf.py"
TREE="$HERE/qcom_next_tree.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$*"; }
no()   { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
chk()  { if [ "$2" -eq 0 ]; then ok "$1"; else no "$1"; [ -n "${3:-}" ] && [ -f "$3" ] && sed 's/^/        /' "$3" | tail -20; fi; }

command -v git >/dev/null || { echo "SKIP: no git"; exit 0; }
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: no PyYAML"; exit 0; }

if [ -z "${AUTOMERGE_DIR:-}" ]; then
    for c in "$REPO/../automerge" "$REPO/../../automerge"; do
        [ -f "$c/ci-merge" ] && AUTOMERGE_DIR="$(cd "$c" && pwd)" && break
    done
fi
[ -n "${AUTOMERGE_DIR:-}" ] && [ -f "$AUTOMERGE_DIR/ci-merge" ] \
    || { echo "SKIP: ci-merge not found; set AUTOMERGE_DIR"; exit 0; }
# An explicitly supplied relative path stops resolving once the scripts cd
# elsewhere, so make it absolute here.
AUTOMERGE_DIR="$(cd "$AUTOMERGE_DIR" && pwd)"

W="$(mktemp -d "${TMPDIR:-/tmp}/qcom-next-test.XXXXXX")"
cleanup() { [ "${KEEP:-0}" = 1 ] || rm -rf "$W"; }
trap cleanup EXIT

echo "qcom-next offline tests"
echo "  work     : $W"
echo "  ci-merge : $AUTOMERGE_DIR/ci-merge"
echo ""

G() { git -C "$1" "${@:2}"; }

# --------------------------------------------------------------------------
# Fixture: one repo with a baseline branch and two topics, plus an empty
# rerere cache. Each topic gets a second commit so "pinned, not tip" is
# actually testable.
# --------------------------------------------------------------------------
SRC="$W/src"
git init -q -b main "$SRC"
G "$SRC" config user.email t@example.com
G "$SRC" config user.name T
printf 'VERSION = 7\nPATCHLEVEL = 3\nEXTRAVERSION = -rc4\n' > "$SRC/Makefile"
G "$SRC" add Makefile && G "$SRC" commit -qm base
BASE="$(G "$SRC" rev-parse HEAD)"

mk_topic() {   # mk_topic <name> <file>
    G "$SRC" checkout -q -b "$1" main
    echo one > "$SRC/$2"; G "$SRC" add "$2"; G "$SRC" commit -qm "$1: one"
    local pinned; pinned="$(G "$SRC" rev-parse HEAD)"
    echo two >> "$SRC/$2"; G "$SRC" add "$2"; G "$SRC" commit -qm "$1: two (past the pin)"
    echo "$pinned"
}
CLK_PIN="$(mk_topic tech/bsp/clk clk.c)"
NET_PIN="$(mk_topic tech/net/eth eth.c)"
CLK_TIP="$(G "$SRC" rev-parse tech/bsp/clk)"
G "$SRC" checkout -q main

RR="$W/rerere"
git init -q -b master "$RR"
G "$RR" config user.email t@example.com
G "$RR" config user.name T
echo cache > "$RR/README"; G "$RR" add README; G "$RR" commit -qm "empty cache"

write_cfg() {   # write_cfg <path> <clk-sha>
    cat > "$1" <<EOF
schema_version: 1
base:
  repo: "file://$SRC"
  branch: main
  tag: null
  sha: $BASE
promotion_state: open
rerere_cache:
  repo: "file://$RR"
  ref: master
topics:
  - name: tech/bsp/clk
    repo: "file://$SRC"
    branch: tech/bsp/clk
    sha: $2
    tag: null
  - name: tech/net/eth
    repo: "file://$SRC"
    branch: tech/net/eth
    sha: $NET_PIN
    tag: null
EOF
}

CFG="$W/qcom-next.yaml"
write_cfg "$CFG" "$CLK_PIN"

# --------------------------------------------------------------------------
echo "[1] config -> conf and pins"

python3 "$CONF_TOOL" --config "$CFG" pins > "$W/pins.tsv" 2>"$W/pins.err"
chk "pins are produced" $? "$W/pins.err"

[ "$(awk -F'\t' '$1=="topic"' "$W/pins.tsv" | grep -c .)" = 2 ]
chk "both topics are listed" $?

grep -q "^base	file://$SRC	$BASE" "$W/pins.tsv"
chk "the baseline pin is recorded" $?

grep -q "^rerere" "$W/pins.tsv"
chk "the rerere cache is recorded" $?

python3 "$CONF_TOOL" --config "$CFG" conf --local-repo "$SRC" --output "$W/test.conf" 2>/dev/null
chk "the conf is written" $?

[ "$(grep -vc '^#' "$W/test.conf")" = 3 ]
chk "the conf has one baseline row and two topic rows" $?

# Every row must point at the local clone, which is what pins the baseline.
[ "$(grep -c "file://$SRC" "$W/test.conf")" = 3 ]
chk "every conf row points at the local clone" $?

# A config that cannot be built must be refused before ci-merge runs.
sed 's/^    sha: .*/    sha: notasha/' "$CFG" > "$W/bad.yaml"
python3 "$CONF_TOOL" --config "$W/bad.yaml" pins >/dev/null 2>"$W/bad.err"
[ $? -ne 0 ]
chk "a short sha is rejected" $?
grep -qi "40-hex" "$W/bad.err"
chk "and the error names the problem" $?

python3 - "$CFG" "$W/dup.yaml" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
blk = text[text.index("  - name: tech/net/eth"):]
open(dst, "w").write(text + blk)
PY
python3 "$CONF_TOOL" --config "$W/dup.yaml" pins >/dev/null 2>"$W/dup.err"
[ $? -ne 0 ]
chk "a duplicate topic is rejected" $?

# --------------------------------------------------------------------------
echo ""
echo "[2] building the tree"

KD="$W/kernel"
git clone -q "$SRC" "$KD"
G "$KD" config user.email t@example.com
G "$KD" config user.name T

bash "$TREE" --config "$CFG" --kernel-dir "$KD" \
    --automerge "$AUTOMERGE_DIR" --out-dir "$W/out" > "$W/build.log" 2>&1
chk "the tree is built" $? "$W/build.log"

HEAD_SHA="$(cat "$W/out/head.txt" 2>/dev/null || echo none)"
G "$KD" rev-parse --verify -q refs/heads/qcom-next >/dev/null
chk "the qcom-next branch exists" $?

[ -n "$HEAD_SHA" ] && [ "$HEAD_SHA" != "none" ]
chk "the built head is recorded in head.txt" $?

inside=0
for p in "$BASE" "$CLK_PIN" "$NET_PIN"; do
    G "$KD" merge-base --is-ancestor "$p" "$HEAD_SHA" 2>/dev/null || {
        printf '        missing from the tree: %s\n' "${p:0:12}"
        inside=$((inside + 1))
    }
done
[ "$inside" -eq 0 ]
chk "the baseline and both pins are in the tree" $?

# The point of pinning: the commit past the pin must NOT be there.
if G "$KD" merge-base --is-ancestor "$CLK_TIP" "$HEAD_SHA" 2>/dev/null; then
    no "the branch tip leaked in instead of the pin"
else
    ok "the commit past the pin stayed out"
fi

[ -s "$W/out/merge.log" ]
chk "merge.log is kept" $?
[ -s "$W/out/qcom-next.conf" ]
chk "the generated conf is kept" $?
grep -q "Pins verified | 2 / 2" "$W/out/summary.md" 2>/dev/null
chk "the summary reports the verified pins" $?

# --------------------------------------------------------------------------
echo ""
echo "[3] in-tree topic_SHA1 and merge.log"

G "$KD" cat-file -e "refs/heads/qcom-next:qcom-next/topic_SHA1" 2>/dev/null
chk "qcom-next/topic_SHA1 is committed" $?
G "$KD" cat-file -e "refs/heads/qcom-next:qcom-next/merge.log" 2>/dev/null
chk "qcom-next/merge.log is committed" $?

G "$KD" show "refs/heads/qcom-next:qcom-next/topic_SHA1" > "$W/table" 2>/dev/null
[ "$(awk 'NR>2' "$W/table" | grep -c .)" = 2 ]
chk "the table has a row per topic" $?
grep -q "$CLK_PIN" "$W/table"
chk "the table records the pinned sha" $?

# The migration script is the real consumer of this table.
SD="$HERE" python3 - "$W/table" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SD"])
from bootstrap_qcom_next_yaml import load_topic_sha1
t = load_topic_sha1(sys.argv[1])
assert len(t) == 2, t
assert "tech/bsp/clk" in t, t
PY
chk "the bootstrap parser reads the table" $?

G "$KD" show "refs/heads/qcom-next:qcom-next/merge.log" > "$W/log" 2>/dev/null
! grep -q 'x-access-token:[^*]' "$W/log"
chk "no credential is committed" $?
! grep -q $'\r' "$W/log"
chk "no CR characters are committed" $?

G "$KD" log -1 --format=%s refs/heads/qcom-next | grep -q "^Add qcom-next log files for"
chk "the log commit keeps automerge's subject" $?
G "$KD" log -1 --format=%ae refs/heads/qcom-next | grep -q 'qti\.qualcomm\.com$'
chk "the author passes the repo ruleset" $?

# --------------------------------------------------------------------------
echo ""
echo "[4] a moved pin changes the tree"

write_cfg "$W/moved.yaml" "$CLK_TIP"
KD2="$W/kernel2"
git clone -q "$SRC" "$KD2"
G "$KD2" config user.email t@example.com
G "$KD2" config user.name T
bash "$TREE" --config "$W/moved.yaml" --kernel-dir "$KD2" \
    --automerge "$AUTOMERGE_DIR" --out-dir "$W/out2" > "$W/build2.log" 2>&1
chk "the tree is built from the moved pin" $? "$W/build2.log"

H2="$(cat "$W/out2/head.txt" 2>/dev/null || echo none)"
G "$KD2" merge-base --is-ancestor "$CLK_TIP" "$H2" 2>/dev/null
chk "the newly pinned commit is in the tree" $?
[ "$H2" != "$HEAD_SHA" ]
chk "the tree differs from the previous one" $?

# --------------------------------------------------------------------------
echo ""
echo "============================================================"
printf 'ran %d checks: %d passed, %d failed\n' "$((PASS+FAIL))" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"
echo "(re-run with KEEP=1 to inspect $W)"
exit 1
