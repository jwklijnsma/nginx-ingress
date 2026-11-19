#!/usr/bin/env bash
# Fix and merge dependency PRs from Dependabot and Renovate.
#
# Run by .github/workflows/autofix-prs.yaml (schedule, PR events, manual).
# For every open bot PR, one action per run:
#
#   merge   all checks on the head commit passed, the PR is mergeable, and (if it
#           touches the shipped Go modules) it is up to date with main
#   fix     checks failed, or it is behind/conflicting: merge main into the
#           branch, resolve go.mod/go.sum conflicts, go mod tidy + vulnerability
#           fixes, push, and start verification CI on the branch
#   wait    checks still running
#   skip    fix already tried on this head and it failed (label "autofix-failed"
#           + one comment; a human looks at it, a new bot push resets it)
#
# Every head commit this script fixed or re-verified gets a commit status
# "autofix-prs". That status is how the script knows it already tried a commit:
# it never merges such a commit before its verification checks exist and pass,
# and never retries a commit whose verification failed.
#
# Needs: gh (GH_TOKEN), git with push rights, go, python3.
# Env:   DRY_RUN=1 to only print decisions.

set -o errexit
set -o nounset
set -o pipefail

REPO="${GITHUB_REPOSITORY:?}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DRY_RUN="${DRY_RUN:-0}"
BOTS='"dependabot[bot]", "renovate[bot]"'   # PR authors handled (jq list)
FAIL_LABEL="autofix-failed"
FIX_MARK="autofix-prs"              # commit messages and commit-status context
REDISPATCH_MIN="${REDISPATCH_MIN:-90}"   # re-start verification if no checks after this
# Go modules that end up in released images: PRs touching them must be up to
# date with main before merging, so main never gets an untested go.sum mix.
SHIPPED_GO='^(go\.(mod|sum)|images/kube-webhook-certgen/rootfs/go\.(mod|sum))$'
# PRs without any checks (e.g. docs-only) merge after this many minutes.
NO_CHECKS_GRACE_MIN="${NO_CHECKS_GRACE_MIN:-60}"

log()   { echo "[$(date -u +%H:%M:%S)] $*"; }
api()   { gh api "repos/${REPO}/$1" "${@:2}"; }
run()   { if [ "$DRY_RUN" = 1 ]; then log "DRY-RUN: $*"; else "$@"; fi; }

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
run gh label create "$FAIL_LABEL" -R "$REPO" --color B60205 \
  --description "autofix-prs could not fix this PR; needs a human" 2>/dev/null || true

# Summarise check runs on a commit, newest run per check name only (a re-run
# supersedes an older failure): prints "<pending> <failed> <passed> <total>"
check_summary() {
  api "commits/$1/check-runs?per_page=100" -q '
    [.check_runs[] | select(.name != "autofix")]
    | group_by(.name) | map(max_by(.started_at)) as $r |
    "\([$r[] | select(.status != "completed")] | length) " +
    "\([$r[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure")] | length) " +
    "\([$r[] | select(.conclusion == "success")] | length) " +
    "\($r | length)"'
}

# Mergeability is computed lazily by GitHub; poll a few times.
pr_json() {
  local n="$1" j
  for _ in 1 2 3 4 5; do
    j="$(api "pulls/$n")"
    [ "$(jq -r .mergeable <<<"$j")" != null ] && break
    sleep 3
  done
  echo "$j"
}

# minutes since this script marked the commit, or empty if never
attempt_age() {
  local t
  t="$(api "commits/$1/statuses?per_page=100" -q "[.[] | select(.context == \"$FIX_MARK\")][0].created_at // empty")"
  if [ -n "$t" ]; then echo $(( ( $(date +%s) - $(date -d "$t" +%s) ) / 60 )); fi
}

mark() {   # mark <sha> <state> <description>
  run api "statuses/$1" -X POST -f state="$2" -f context="$FIX_MARK" -f description="$3" \
    -f target_url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-}" >/dev/null
}

dispatch_verify() {   # dispatch_verify <branch>
  run gh workflow run docker.yaml -R "$REPO" --ref "$1" -f verify_only=true
  if git diff --name-only origin/main..."origin/$1" 2>/dev/null | grep -q '^charts/'; then
    run gh workflow run helm.yaml -R "$REPO" --ref "$1"
  fi
}

fix_pr() {
  local n="$1" branch="$2"
  log "#$n: fixing on $branch"
  git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" "+refs/heads/${branch}:refs/remotes/origin/${branch}"
  git checkout -q -B "$branch" "origin/$branch"

  # 1. bring the branch up to date with main
  if ! git merge -q --no-edit -m "Merge main into ${branch} (${FIX_MARK})" origin/main; then
    local conflicted others
    conflicted="$(git diff --name-only --diff-filter=U)"
    others="$(grep -vE '(^|/)go\.(mod|sum)$' <<<"$conflicted" || true)"
    # files the PR edits but main deleted: keep the deletion
    for f in $others; do
      if ! git cat-file -e "origin/main:$f" 2>/dev/null; then git rm -q "$f"; fi
    done
    others="$(git diff --name-only --diff-filter=U | grep -vE '(^|/)go\.(mod|sum)$' || true)"
    if [ -n "$others" ]; then
      git merge --abort
      log "#$n: conflicts outside go.mod/go.sum: $others"
      return 1
    fi
    mapfile -t gofiles < <(git diff --name-only --diff-filter=U)
    python3 hack/fork/gomod_resolve.py "${gofiles[@]}"
    git add -A
    git commit -q --no-edit -m "Merge main into ${branch} (${FIX_MARK})"
  fi

  # 2. tidy every Go module the PR touches, plus vulnerability fixes for the shipped ones
  local mods
  mods="$(git diff --name-only origin/main...HEAD | grep -E '(^|/)go\.(mod|sum)$' | xargs -r -n1 dirname | sort -u)"
  for d in $mods; do
    log "#$n: go mod tidy in $d"
    (cd "$d" && go mod tidy)
  done
  local rc=0
  hack/fork/fix-go-vulns.sh . >/tmp/fix-root.log 2>&1 || rc=$?
  tail -n 15 /tmp/fix-root.log
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || { log "#$n: fix-go-vulns (root) failed rc=$rc"; return 1; }
  hack/fork/fix-go-vulns.sh images/kube-webhook-certgen/rootfs >/tmp/fix-cert.log 2>&1 || {
    tail -n 15 /tmp/fix-cert.log; log "#$n: fix-go-vulns (certgen) failed"; return 1; }

  if ! git diff --quiet; then
    git add -A
    git commit -q -m "go: tidy and fix vulnerable dependencies (${FIX_MARK})"
  fi

  if [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$branch")" ]; then
    log "#$n: nothing to change; re-verifying the current head"
  else
    run git push -q origin "HEAD:refs/heads/${branch}"
    run git fetch -q origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"
  fi

  # 3. mark the head as attempted, then verify. Pushes with GITHUB_TOKEN start
  #    no workflows, so start them explicitly; their check runs land on the
  #    head commit, which the next run of this script reads.
  mark "$(git rev-parse HEAD)" pending "fixed by autofix-prs; verifying"
  dispatch_verify "$branch"
  return 0
}

give_up() {
  local n="$1" why="$2"
  log "#$n: giving up: $why"
  run gh pr edit "$n" -R "$REPO" --add-label "$FAIL_LABEL"
  run gh pr comment "$n" -R "$REPO" --body "**autofix-prs** could not fix this PR automatically: ${why}

Labelled \`${FAIL_LABEL}\`; it will be skipped until the bot pushes a new version or the label is removed.
Run log: ${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-}"
}

merged=0
for n in $(api "pulls?state=open&per_page=100" -q ".[] | select(.user.login | IN(${BOTS})) | select(.draft | not) | .number" | sort -n); do
  pr="$(pr_json "$n")"
  branch="$(jq -r .head.ref <<<"$pr")"
  sha="$(jq -r .head.sha <<<"$pr")"
  mergeable="$(jq -r .mergeable <<<"$pr")"          # true/false/null
  state="$(jq -r .mergeable_state <<<"$pr")"        # clean/unstable/behind/dirty/blocked/unknown
  created="$(jq -r .created_at <<<"$pr")"
  labels="$(jq -r '[.labels[].name] | join(",")' <<<"$pr")"
  title="$(jq -r .title <<<"$pr")"
  read -r pending failed passed total <<<"$(check_summary "$sha")"
  log "#$n [$state, mergeable=$mergeable, checks: ${passed} ok / ${failed} failed / ${pending} running / ${total}] $title"

  attempted="$(attempt_age "$sha")"     # empty = this head was never fixed/verified by us

  if [[ ",$labels," == *",$FAIL_LABEL,"* ]]; then
    if [ -n "$attempted" ]; then log "#$n: skip ($FAIL_LABEL)"; continue; fi
    run gh pr edit "$n" -R "$REPO" --remove-label "$FAIL_LABEL"   # bot pushed a new version
  fi

  if [ "$pending" -gt 0 ]; then log "#$n: wait (checks running)"; continue; fi

  if [ -n "$attempted" ] && [ "$failed" -eq 0 ] && [ "$passed" -eq 0 ]; then
    # we fixed/re-verified this head but its checks have not started yet
    if [ "$attempted" -ge "$REDISPATCH_MIN" ]; then
      log "#$n: no verification checks after ${attempted}m; dispatching again"
      git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" "+refs/heads/${branch}:refs/remotes/origin/${branch}"
      mark "$sha" pending "re-dispatched verification"
      dispatch_verify "$branch"
    else
      log "#$n: wait (verification dispatched ${attempted}m ago)"
    fi
    continue
  fi

  touches_shipped=false
  if api "pulls/$n/files?per_page=100" -q '.[].filename' | grep -qE "$SHIPPED_GO"; then touches_shipped=true; fi

  needs_fix=false
  [ "$failed" -gt 0 ] && needs_fix=true
  [ "$state" = dirty ] && needs_fix=true
  [ "$state" = behind ] && $touches_shipped && needs_fix=true

  if $needs_fix; then
    if [ -n "$attempted" ] && [ "$failed" -gt 0 ]; then
      mark "$sha" failure "checks fail after automatic fix"
      give_up "$n" "checks still fail after the automatic fix (head ${sha:0:7})"
      continue
    fi
    if [ "$DRY_RUN" = 1 ]; then log "DRY-RUN: would fix #$n (failed=$failed, state=$state)"; continue; fi
    if ! fix_pr "$n" "$branch"; then
      git checkout -q -f --detach origin/main 2>/dev/null || true
      give_up "$n" "the automatic fix failed (see run log)"
    fi
    git checkout -q -f --detach origin/main 2>/dev/null || true
    continue
  fi

  if [ "$total" -eq 0 ]; then
    age_min=$(( ( $(date +%s) - $(date -d "$created" +%s) ) / 60 ))
    if [ "$age_min" -lt "$NO_CHECKS_GRACE_MIN" ]; then log "#$n: wait (no checks yet, ${age_min}m old)"; continue; fi
  elif [ "$passed" -eq 0 ]; then
    log "#$n: wait (no successful checks yet)"; continue
  fi

  if [ "$mergeable" != true ]; then log "#$n: wait (mergeable=$mergeable)"; continue; fi

  log "#$n: merge"
  [ -n "$attempted" ] && mark "$sha" success "verified; merging"
  run gh pr merge "$n" -R "$REPO" --squash --delete-branch \
    --subject "${title} (#${n})" --body "Merged automatically by autofix-prs after all checks passed."
  merged=$((merged + 1))
  # main moved: GitHub recomputes mergeability of the others; handle them next run
  if $touches_shipped; then log "main changed (Go modules); remaining Go PRs continue next run"; break; fi
done

log "done: merged ${merged} PR(s)"
echo "merged ${merged} PR(s)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
