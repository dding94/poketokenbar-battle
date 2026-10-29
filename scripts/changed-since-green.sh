#!/bin/bash
# Writes changed=true|false to $GITHUB_OUTPUT: whether the given paths differ from what CI last
# verified. A pull request compares with the commit it branched from. A push compares with the newest
# green push run of this workflow that it builds on, not with the previous push: a run that a newer
# push cancelled (cancel-in-progress) or that failed never verified its changes, and comparing with it
# would let them through unchecked. With no such run (first push, rewritten history, API error) the
# answer is true.
# Usage: changed-since-green.sh <pathspec>...  (needs a full-history checkout and GH_TOKEN)
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: $0 <pathspec>..." >&2; exit 2; }

answer() {
    echo "::notice::$2"
    echo "changed=$1" >> "$GITHUB_OUTPUT"
    exit 0
}

if [ "$GITHUB_EVENT_NAME" = pull_request ]; then
    head="$PR_HEAD_SHA"
    base="$(git merge-base "$PR_BASE_SHA" "$head")"
else
    head="$GITHUB_SHA"
    workflow="$(basename "${GITHUB_WORKFLOW_REF%%@*}")"
    green="$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs?event=push&status=success&per_page=100" \
        --jq '.workflow_runs[].head_sha')" || { echo "::warning::could not list green push runs"; green=""; }
    base=""
    for sha in $green; do
        if git merge-base --is-ancestor "$sha" "$head" 2>/dev/null; then base="$sha"; break; fi
    done
    [ -n "$base" ] || answer true "no green push run that ${head:0:7} builds on, so $* count as changed"
fi

changed="$(git diff --name-only "$base" "$head" -- "$@")"
[ -n "$changed" ] || answer false "$* unchanged in ${base:0:7}..${head:0:7}"
echo "$changed"
answer true "$(grep -c . <<< "$changed") file(s) under $* changed in ${base:0:7}..${head:0:7}"
