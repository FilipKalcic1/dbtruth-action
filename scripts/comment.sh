#!/usr/bin/env bash
# comment.sh <body-file> <create>: keeps one dbtruth comment on pull request PR of GITHUB_REPOSITORY, the one this
# workflow's token wrote whose body starts with the marker. It is updated to the body; with none, one is created when
# <create> is true. A comment that cannot be read or written is a warning: the job's result is the check's.
set -euo pipefail
body=$1 create=$2

if ! command -v gh > /dev/null; then
  echo "::error::gh, the GitHub CLI, is not on this runner's PATH: install it, or set comment: never"
  exit 1
fi
warn() {
  echo "::warning::could not comment on the pull request; gh's line above says why, and HTTP 403 means the workflow needs permissions: pull-requests: write"
}
# GitHub refuses a body over 65,536 characters, and bytes are never fewer. The first two lines are the marker and the counts.
if [ "$(wc -c < "$body")" -gt 65536 ]; then
  { head -n 2 "$body"; echo; echo "The report is too long for a comment; the job log has every line."; } > "$body.short"
  body=$body.short
fi

comments="repos/$GITHUB_REPOSITORY/issues/$PR/comments"
# The action always comments with the workflow's token, so its comments are github-actions[bot]'s; a person's comment
# that quotes the marker is never taken for it.
mine='.[] | select(.user.login == "github-actions[bot]" and (.body | startswith("<!-- dbtruth-check -->"))) | .id'
if ! ids=$(gh api --paginate "$comments?per_page=100" --jq "$mine"); then
  warn
  exit 0
fi
id=${ids%%$'\n'*}
if [ -n "$id" ]; then
  gh api --method PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$id" -F "body=@$body" > /dev/null || warn
elif [ "$create" = true ]; then
  gh api --method POST "$comments" -F "body=@$body" > /dev/null || warn
fi
