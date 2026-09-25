#!/usr/bin/env bash
# check.sh: the action's step. Runs dbtruth check in the working directory, sets the outputs, keeps the comment on the
# pull request, and exits with check's own code: 0 passes, 2 fails under fail-on, anything else could not run.
# Every input arrives as a variable that action.yml sets, never as text pasted into this script.
set -euo pipefail

case $COMMENT in
  on-change | always | never) ;;
  *)
    echo "::error::comment must be on-change, always or never"
    echo "result=error" >> "$GITHUB_OUTPUT"
    exit 1
    ;;
esac
if [ -z "$DATABASE_URL" ]; then
  echo "::notice::dbtruth check skipped: database-url is empty, as it is on a pull request from a fork, which gets no secrets"
  echo "result=skipped" >> "$GITHUB_OUTPUT"
  exit 0
fi

report=$RUNNER_TEMP/dbtruth
code=0
npx -y "$PACKAGE" check --fail-on "$FAIL_ON" --json --markdown "$report.md" > "$report.json" 2> "$report.err" || code=$?
# What dbtruth printed holds names from the snapshot, and the runner reads a workflow command anywhere in a line. All
# three go to stdout, so the runner reads them in order.
token=$(node -p 'crypto.randomUUID()')
echo "::stop-commands::$token"
cat "$report.err"
echo "::$token::"

result=error regressions='' stale='' moved=1
if [ "$code" = 0 ] || [ "$code" = 2 ]; then
  # The report's format, its regressions, its stale items (a relation added or dropped is one), and what is not
  # unchanged. JSON that cannot be parsed prints nothing, and so reads as a format this action does not know; node's
  # error is dropped, since it quotes that JSON, and commands are no longer stopped here.
  read -r format regressions stale moved <<< "$(node -e '
    const { report, claims, relations } = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    const count = (cls) => claims.filter((claim) => claim.class === cls).length;
    console.log(report, count("regression"), count("stale") + relations.length, claims.length - count("unchanged") + relations.length);
  ' "$report.json" 2> /dev/null)"
  if [ "$format" != 1 ]; then
    echo "::error::this dbtruth-version prints a report this action cannot read; leave dbtruth-version at its default"
    echo "result=error" >> "$GITHUB_OUTPUT"
    exit 1
  fi
  result=fail
  if [ "$code" = 0 ]; then result=pass; fi
else
  # dbtruth wrote no comment, so this one says it could not run, in dbtruth's own words, which never hold the URL. Each
  # line is indented four spaces: an indented code block, which no line in it can end. Markdown also ends a line at a
  # carriage return, and a name from the snapshot can hold one, so each carriage return is made a line break first.
  {
    echo "<!-- dbtruth-check -->"
    echo "dbtruth check could not run (exit $code). What it printed, also in the [job log]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID):"
    echo
    tr '\r' '\n' < "$report.err" | sed 's/^/    /'
  } > "$report.md"
fi
printf 'result=%s\nregressions=%s\nstale=%s\n' "$result" "$regressions" "$stale" >> "$GITHUB_OUTPUT"

# Created only when something is not unchanged, or check could not run, unless comment is always; one that is there is
# always updated, so an all-clear replaces an old failure.
if [ "$GITHUB_EVENT_NAME" = pull_request ] && [ "$COMMENT" != never ]; then
  create=false
  if [ "$COMMENT" = always ] || [ "$moved" != 0 ]; then create=true; fi
  bash "$GITHUB_ACTION_PATH/scripts/comment.sh" "$report.md" "$create"
fi
exit "$code"
