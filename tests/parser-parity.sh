#!/usr/bin/env bash
# tools/adopt.py and routing-guard/routing_guard.py each read the workflows
# with their own line-by-line YAML shapes — forced by `python3 -I` (isolated
# mode removes the script dir from sys.path), so the two cannot share a
# module. The duplication is deliberate; this suite pins the agreement: on
# workflows shaped to mislead a naive line scan — a runs-on line inside a
# block scalar, a comment naming the label, a quoted "runs-on" key — the
# scanner's classification and adopt's plan name the same jobs, and neither
# routes what the other cannot read.
#
# Run:  bash tests/parser-parity.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expr="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --print-expression)"

# scan <dir> <flag>: the scanner's stdout, with its exit status in rc. The
# scanner's own progress lines are quiet in --list modes.
scan() {
  out="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --workflows-dir "$1" "$2" 2>/dev/null)"
  rc=$?
}
# plan <dir>: setup's plan, as "ROUTED <key>" lines. rc 1 is the refusal.
plan() {
  rm -rf "$work/out"
  out="$(python3 -I "$ROOT/tools/adopt.py" setup "$1" "$work/out" --expression "$expr" 2>&1)"
  rc=$?
}
routed_keys() { printf '%s\n' "$1" | sed -n 's/^ROUTED\t//p' | sort; }

mkdir -p "$work/wf"
cat >"$work/wf/ci.yml" <<EOF
name: CI
on: [pull_request]
jobs:
  routed:
    runs-on: $expr
    steps:
      - uses: actions/checkout@v5
      - run: |
          echo "runs-on: ubuntu-latest"
  # runs-on: [self-hosted]
  hosted:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
EOF

scan "$work/wf" --list
record "a runs-on line inside a block scalar, and one in a comment: the scanner routes only the real job" "ci.yml:routed" "$out"
scan "$work/wf" --list-unroutable
record "...and sees no no-runs-on job there" "" "$out"
plan "$work/wf"
got="$(routed_keys "$out")"
record "adopt's plan routes the same two jobs" "ci.yml:hosted
ci.yml:routed" "$got"
# The general parity, as a check over the fixture: every job the scanner
# routes is one adopt's plan names.
missing="$(comm -23 <(printf '%s\n' "$(scan "$work/wf" --list; printf '%s' "$out")" | sort) <(printf '%s\n' "$got"))"
record "every scanner-routed job is in adopt's plan" "" "$missing"

cat >"$work/wf/b.yml" <<'EOF'
name: B
on: [pull_request]
jobs:
  texttrick:
    steps:
      - run: |
          echo "runs-on: ubuntu-latest"
  "quoted":
    "runs-on": ubuntu-latest
    steps:
      - uses: actions/checkout@v5
EOF

scan "$work/wf" --list-unroutable
record "a job whose runs-on is only block-scalar text, and one with a quoted key, have no readable runs-on" "b.yml:texttrick
b.yml:quoted" "$out"
scan "$work/wf" --list
record "a quoted \"runs-on\" key: --list still exits 0 — drift is an answer, a crash is the nonzero" \
  "0/1" "$rc/$(printf '%s' "$out" | grep -c . || true)"
# adopt's parser reads the quoted key: it routes the job and rewrites it to a
# plain runs-on line, so the file the plan produces is one the scanner reads.
plan "$work/wf"
record "...adopt's plan reads the quoted key and routes it (with ci.yml's two)" "b.yml:quoted
ci.yml:hosted
ci.yml:routed" "$(routed_keys "$out")"
scan "$work/out" --list
record "...and the rewritten workflows pass the scanner's --list" "b.yml:quoted
ci.yml:routed
ci.yml:hosted" "$out"

summary