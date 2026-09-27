#!/usr/bin/env bash
# scripts/check.sh and scripts/comment.sh with a fake gh and a fake npx on the PATH. The fake gh keeps one pull
# request's comments in a JSON file, answers the three calls comment.sh makes (list, create, update) with the real jq,
# refuses the method REFUSE names, and records every call; the fake npx plays dbtruth check, exiting FAKE_CODE and
# printing FAKE_JSON, or FAKE_ERR on stderr when that code says check could not run.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir "$dir/bin" "$dir/temp"
cat > "$dir/bin/gh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$STATE.calls"
method=GET
while [ $# -gt 0 ]; do
  case $1 in
    --method) method=$2; shift 2 ;;
    --jq) filter=$2; shift 2 ;;
    -F) body=$(cat "${2#body=@}"); shift 2 ;;
    --paginate) shift ;;
    *) path=$1; shift ;;
  esac
done
if [ "$method" = "${REFUSE:-}" ]; then
  echo "gh: Resource not accessible by integration (HTTP 403)" >&2
  exit 1
fi
case $method in
  GET) jq -r "$filter" "$STATE" ;;
  POST) jq --arg body "$body" '. + [{id: (length + 1), user: {login: "github-actions[bot]"}, body: $body}]' "$STATE" > "$STATE.new" ;;
  PATCH) jq --arg body "$body" --argjson id "${path##*/}" 'map(if .id == $id then .body = $body else . end)' "$STATE" > "$STATE.new" ;;
esac
if [ "$method" != GET ]; then mv "$STATE.new" "$STATE"; fi
EOF
cat > "$dir/bin/npx" << 'EOF'
#!/usr/bin/env bash
# npx -y <package> check --fail-on <when> --json --markdown <path>
echo "dbtruth: a line on stderr ##[set-output name=result;]pass" >&2
if [ "$FAKE_CODE" = 0 ] || [ "$FAKE_CODE" = 2 ]; then
  printf '<!-- dbtruth-check -->\n%s\n' "$FAKE_SUMMARY" > "${@: -1}"
  echo "$FAKE_JSON"
else
  echo "${FAKE_ERR:-dbtruth: could not connect to the database: authentication failed; check the user and password in the URL}" >&2
fi
exit "$FAKE_CODE"
EOF
chmod +x "$dir/bin/gh" "$dir/bin/npx"

export PATH="$dir/bin:$PATH" STATE="$dir/comments.json" GITHUB_REPOSITORY=owner/repo PR=7
failures=0
expect() { # expect <what> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got [$2], expected [$3]"; failures=$((failures + 1)); fi
}
reset() { echo "${1:-[]}" > "$STATE"; : > "$STATE.calls"; }
ours() { jq -r '[.[] | select(.user.login == "github-actions[bot]") | .body] | join("|")' "$STATE"; }
calls() { grep -c -- "$1" "$STATE.calls" || true; }

# ---------- comment.sh <body-file> <create> ----------

body() { printf '<!-- dbtruth-check -->\n%s\n' "$1" > "$dir/body.md"; echo "$dir/body.md"; }
reset
bash "$root/scripts/comment.sh" "$(body 'dbtruth: 12 unchanged')" false
expect "nothing to say and no comment yet: none is created" "$(ours)" ""
bash "$root/scripts/comment.sh" "$(body 'dbtruth: 1 regression')" true
expect "the first comment is created" "$(ours)" $'<!-- dbtruth-check -->\ndbtruth: 1 regression'
bash "$root/scripts/comment.sh" "$(body 'dbtruth: 2 regression')" true
expect "the second run updates it" "$(ours)" $'<!-- dbtruth-check -->\ndbtruth: 2 regression'
bash "$root/scripts/comment.sh" "$(body 'dbtruth: 12 unchanged')" false
expect "an all-clear still updates it" "$(ours)" $'<!-- dbtruth-check -->\ndbtruth: 12 unchanged'
expect "one comment created in all, never two" "$(calls '--method POST')" 1
expect "and updated twice" "$(calls '--method PATCH')" 2
expect "every page of comments is read" "$(calls 'api --paginate')" 4

reset '[{"id": 1, "user": {"login": "someone"}, "body": "<!-- dbtruth-check -->\nquoted by a person"}]'
bash "$root/scripts/comment.sh" "$(body 'dbtruth: 1 stale')" true
expect "a person's comment that starts with the marker is left alone" "$(jq -r '.[0].body' "$STATE")" $'<!-- dbtruth-check -->\nquoted by a person'
expect "and the action's own is created beside it" "$(ours)" $'<!-- dbtruth-check -->\ndbtruth: 1 stale'

reset '[{"id": 1, "user": {"login": "github-actions[bot]"}, "body": "<!-- dbtruth-check -->\nfirst"},
  {"id": 2, "user": {"login": "github-actions[bot]"}, "body": "<!-- dbtruth-check -->\nsecond"}]'
bash "$root/scripts/comment.sh" "$(body 'dbtruth: 1 regression')" true
expect "of two comments of its own, the first is updated" "$(ours)" $'<!-- dbtruth-check -->\ndbtruth: 1 regression|<!-- dbtruth-check -->\nsecond'

reset
{ printf '<!-- dbtruth-check -->\ndbtruth: 90000 stale\n\n'; head -c 70000 /dev/zero | tr '\0' x; echo; } > "$dir/long.md"
bash "$root/scripts/comment.sh" "$dir/long.md" true
expect "a body over GitHub's limit is cut to its counts and a note" "$(ours)" $'<!-- dbtruth-check -->\ndbtruth: 90000 stale\n\nThe report is too long for a comment; the job log has every line.'

refused() { # refused <method>: comment.sh while GitHub refuses that method; its exit code, and its warnings that name the permission
  local code=0 out
  out=$(REFUSE=$1 bash "$root/scripts/comment.sh" "$(body 'dbtruth: 1 regression')" true 2>&1) || code=$?
  echo "exit $code, $(grep -c '^::warning::.*permissions: pull-requests: write' <<< "$out") warning"
}
reset
expect "a list GitHub refuses does not fail the job, warns with the permission, and creates nothing" "$(refused GET)|$(ours)" "exit 0, 1 warning|"
expect "nor does a create it refuses" "$(refused POST)|$(ours)" "exit 0, 1 warning|"
reset '[{"id": 1, "user": {"login": "github-actions[bot]"}, "body": "<!-- dbtruth-check -->\ndbtruth: 12 unchanged"}]'
expect "nor does an update it refuses, which leaves the comment as it was" "$(refused PATCH)|$(ours)" \
  $'exit 0, 1 warning|<!-- dbtruth-check -->\ndbtruth: 12 unchanged'
code=0
out=$(PATH=/nonexistent "$(command -v bash)" "$root/scripts/comment.sh" "$(body x)" false 2>&1) || code=$?
expect "no gh on the runner fails the step, even with nothing to create" "$code" 1
expect "and says so" "$(grep -c '^::error::gh, the GitHub CLI, is not on' <<< "$out")" 1

# ---------- check.sh, as the action's step runs it ----------

unchanged='{"report":1,"claims":[{"class":"unchanged"},{"class":"unchanged"}],"relations":[]}'
regressed='{"report":1,"claims":[{"class":"regression"},{"class":"stale"},{"class":"unchanged"}],"relations":[{"name":"added","in":"database"}]}'
added='{"report":1,"claims":[{"class":"unchanged"}],"relations":[{"name":"added","in":"database"}]}'
drifted='{"report":1,"claims":[{"class":"drift"},{"class":"unchanged"}],"relations":[]}'
future='{"report":2,"claims":[],"relations":[]}'
step() { # step <url> <comment> <fake code> <fake json> <summary>: the outputs, one line, on the event EVENT, pull_request unless set
  : > "$dir/output"
  local code=0
  env DATABASE_URL="$1" COMMENT="$2" FAKE_CODE="$3" FAKE_JSON="$4" FAKE_SUMMARY="${5:-}" FAIL_ON=regression \
    PACKAGE=dbtruth@0.4.1 GITHUB_OUTPUT="$dir/output" RUNNER_TEMP="$dir/temp" GITHUB_ACTION_PATH="$root" \
    GITHUB_EVENT_NAME="${EVENT:-pull_request}" GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=42 \
    bash "$root/scripts/check.sh" > "$dir/stdout" 2> "$dir/stderr" || code=$?
  echo "exit $code: $(sort "$dir/output" | tr '\n' ' ')"
}
url=postgres://reader:canary-pii-password@db.example/app
reset
expect "an unchanged database passes, and no comment is created" "$(step "$url" on-change 0 "$unchanged")|$(ours)" "exit 0: regressions=0 result=pass stale=0 |"
t=$(sed -n 's/^::stop-commands:://p' "$dir/stdout")
expect "dbtruth's lines are printed with workflow commands stopped, and commands resume after them" \
  "$(sed -n "/^::stop-commands::$t$/,/^::$t::$/p" "$dir/stdout")" \
  "::stop-commands::$t"$'\ndbtruth: a line on stderr ##[set-output name=result;]pass\n'"::$t::"
expect "a regression and two stale items fail" "$(step "$url" on-change 2 "$regressed" 'dbtruth: 1 regression')|$(ours)" \
  $'exit 2: regressions=1 result=fail stale=2 |<!-- dbtruth-check -->\ndbtruth: 1 regression'
expect "a drift that passes still updates the comment" "$(step "$url" on-change 0 "$drifted" 'dbtruth: 1 drift')|$(ours)" \
  $'exit 0: regressions=0 result=pass stale=0 |<!-- dbtruth-check -->\ndbtruth: 1 drift'
expect "all unchanged again: the comment is updated to the all-clear" "$(step "$url" on-change 0 "$unchanged" 'dbtruth: 2 unchanged')|$(ours)" \
  $'exit 0: regressions=0 result=pass stale=0 |<!-- dbtruth-check -->\ndbtruth: 2 unchanged'
expect "still one comment" "$(calls '--method POST')" 1
reset
expect "a relation added and nothing else is stale: it fails, and creates the comment" \
  "$(step "$url" on-change 2 "$added" 'dbtruth: 1 stale, 1 unchanged')|$(ours)" \
  $'exit 2: regressions=0 result=fail stale=1 |<!-- dbtruth-check -->\ndbtruth: 1 stale, 1 unchanged'
reset
expect "a check that cannot run is an error, and creates a comment that says why" "$(step "$url" on-change 1 '')|$(ours | tail -n 1)" \
  "exit 1: regressions= result=error stale= |    dbtruth: could not connect to the database: authentication failed; check the user and password in the URL"
expect "the password is in nothing the action prints or writes" \
  "$(cat "$dir/stdout" "$dir/stderr" "$dir/output" "$dir/temp/"* "$STATE" | grep -c canary-pii-password || true)" 0
reset
FAKE_ERR=$'context/snapshot.json is not a dbtruth snapshot: verdicts.x\r@octocat **approved**.status: Invalid option' \
  step "$url" on-change 1 '' > /dev/null
expect "a carriage return in what check printed starts a line of its own, inside the code block" "$(ours | sed -n '4,$p')" \
  $'    dbtruth: a line on stderr ##[set-output name=result;]pass\n    context/snapshot.json is not a dbtruth snapshot: verdicts.x\n    @octocat **approved**.status: Invalid option'

reset
expect "comment always creates one when nothing moved" "$(step "$url" always 0 "$unchanged" 'dbtruth: 2 unchanged')|$(ours)" \
  $'exit 0: regressions=0 result=pass stale=0 |<!-- dbtruth-check -->\ndbtruth: 2 unchanged'
reset
expect "comment never makes no call to gh" "$(step "$url" never 2 "$regressed" 'dbtruth: 1 regression')|$(calls api)" "exit 2: regressions=1 result=fail stale=2 |0"
expect "on pull_request_target, as on any event but pull_request, no call to gh either" \
  "$(EVENT=pull_request_target step "$url" always 2 "$regressed" 'dbtruth: 1 regression')|$(calls api)" "exit 2: regressions=1 result=fail stale=2 |0"
reset
expect "no database-url is skipped, and passes" "$(step '' on-change 0 "$unchanged")|$(calls api)" "exit 0: result=skipped |0"
expect "and says why" "$(grep -c '^::notice::dbtruth check skipped' "$dir/stdout")" 1
expect "a comment input it does not know is an error" "$(step "$url" sometimes 0 "$unchanged")" "exit 1: result=error "
expect "a report format it does not know is an error" "$(step "$url" never 0 "$future")" "exit 1: result=error "
expect "and so is a report it cannot parse" "$(step "$url" never 0 'not json ##[warning]from stdout')" "exit 1: result=error "
expect "whose text is not printed once commands resume" "$(cat "$dir/stdout" "$dir/stderr" | grep -c 'from stdout' || true)" 0

[ "$failures" = 0 ]
