# dbtruth check

[![test](https://github.com/FilipKalcic1/dbtruth-action/actions/workflows/test.yml/badge.svg)](https://github.com/FilipKalcic1/dbtruth-action/actions/workflows/test.yml)

Runs `dbtruth check` on every pull request. It measures again, on your
database, what the `context/` that [dbtruth](https://github.com/FilipKalcic1/dbtruth)
wrote claims about it, keeps one comment on the pull request that says what
moved, and fails the job when the database now contradicts the context: a
relationship that broke, a suspicion that came true, a table or column a claim
names that is gone, or a relation added or dropped since.

It needs `context/` committed with its `snapshot.json`, which every full run
of `npx dbtruth` writes, and a database the runner can reach that holds the
data the context describes. It needs no model and no API key.

## Usage

Add a workflow such as `.github/workflows/dbtruth.yml`:

```yaml
name: dbtruth
on: pull_request
permissions:
  contents: read
  pull-requests: write
concurrency:
  group: dbtruth-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: FilipKalcic1/dbtruth-action@v1
        with:
          database-url: ${{ secrets.DBTRUTH_DATABASE_URL }}
```

Then add the database URL, `postgres://user:password@host:5432/dbname`, as the
repository secret `DBTRUTH_DATABASE_URL` (Settings, Secrets and variables,
Actions). `pull-requests: write` lets the Action write its comment.
`concurrency` cancels a run still going when the next push starts one, so two
runs never race to create two comments.

## Inputs

| Input | Default | What it does |
|---|---|---|
| `database-url` | none: required | The database to check, from a secret. Empty, as it is on a pull request from a fork, skips the check. |
| `working-directory` | `.` | The directory that holds `context/`, relative to the root of the checkout; `check` runs there. In a monorepo, the directory `npx dbtruth` ran in. |
| `fail-on` | `regression` | When the job fails, as `check --fail-on` takes it: `regression` on a regression or a stale item, `change` on any change, `never` not at all. |
| `comment` | `on-change` | `on-change` creates the comment on the first run that finds an item that is not unchanged, or cannot run; `always` on the first run. Both update it on every run after that. `never` leaves the pull request alone. |
| `dbtruth-version` | `0.4.0` | The dbtruth to run: a version, or anything else npm takes after `dbtruth@`, such as a range. 0.4.0 is the first with the `--json` and `--markdown` of `check`, which the Action needs. |

dbtruth's tunables are `DBTRUTH_*` variables
([Tuning](https://github.com/FilipKalcic1/dbtruth#tuning)). Set them in the
job's `env:`, and `check` reads them from there:

```yaml
jobs:
  check:
    runs-on: ubuntu-latest
    env:
      DBTRUTH_STATEMENT_TIMEOUT_SECONDS: 30
```

`check` measures each claim with the settings the snapshot was measured with;
the time budget (`DBTRUTH_BUDGET_SECONDS`), the statement timeout
(`DBTRUTH_STATEMENT_TIMEOUT_SECONDS`) and the hit-rate tolerance
(`DBTRUTH_CHECK_HIT_RATE_TOLERANCE`) are the run's own.

## Outputs

| Output | Value |
|---|---|
| `result` | `pass` or `fail`, by the exit code of `check` under `fail-on`; `error` when it could not run or an input is wrong; `skipped` when `database-url` is empty. Empty when the Action's step did not start: on a `working-directory` that does not exist, or when setup-node failed before it. |
| `regressions` | How many regressions `check` found. Empty unless the result is `pass` or `fail`. |
| `stale` | How many stale items it found: claims that name a table or column that is gone, and relations added or dropped. Empty unless the result is `pass` or `fail`. |

The step fails the job on `fail` and on `error`, so a later step that reads
the outputs then needs `if: always()`.

## Permissions

The job needs `pull-requests: write` to comment on the pull request, and
`contents: read` for the checkout; the `permissions:` block in the usage
grants both and nothing else. Without `pull-requests: write`, GitHub refuses
the comment with HTTP 403: gh prints its line, the Action prints this warning
after it, and the job's result is still the check's.

```
could not comment on the pull request; gh's line above says why, and HTTP 403 means the workflow needs permissions: pull-requests: write
```

## The comment

Its first line is the marker `<!-- dbtruth-check -->`, which GitHub does not
show, and by which the Action finds the comment again. There is one per pull
request: the Action takes the first comment that github-actions[bot] wrote and
that starts with the marker, and updates it in place; only when there is none
does it create one. It always comments with the workflow's own token, so its
comments are github-actions[bot]'s, and a person's comment that quotes the
marker is never touched.

With `comment: on-change`, the default, the comment is created by the first
run that finds an item that is not unchanged, or that could not run; notes
alone create none. From then on every run updates it, so once everything is
unchanged again it becomes the all-clear: the marker, the counts, such as
`dbtruth: 12 unchanged`, and any notes.

The body is what `dbtruth check --markdown` writes: the counts, a table of
what fails the default build, the rest folded, at most 50 rows in all, the
notes, then the fix. Names are written as code, and it holds no query and no
reason. After the foreign key from `order_items` to `orders` was dropped and
every fifth line item was pointed at an order that does not exist, as this
repository's tests do, it reads:

```markdown
<!-- dbtruth-check -->
dbtruth: 1 regression, 11 unchanged

| Class | Claim | Before | After |
|---|---|---|---|
| regression | ` relationship:order_items.order_id->orders.id ` | confirmed 100.0% | broken 80.0% |

- note: the schema changed since the snapshot

run npx dbtruth and commit context/
```

When `check` could not run, the Action writes the comment itself, with what
dbtruth printed as a code block:

```markdown
<!-- dbtruth-check -->
dbtruth check could not run (exit 1). What it printed, also in the [job log](https://github.com/<owner>/<repo>/actions/runs/<id>):

    dbtruth: could not connect to the database: authentication failed; check the user and password in the URL
```

GitHub refuses a comment over 65,536 characters. Fifty rows keep a comment of
the longest names Postgres allows well under that. A body over 65,536 bytes,
from a snapshot edited by hand or a long could-not-run message, is cut to its
first two lines and this one:

```
The report is too long for a comment; the job log has every line.
```

The Action comments only on `pull_request` events. On `push`,
`pull_request_target` or any other event it runs the check and sets its
outputs, and comments nowhere.

## Security

The secret lets the job into your database, so:

- Connect as a role that can only read, on a replica or a staging copy, never
  as an owner role on production. dbtruth opens a read-only session and sends
  only `SELECT`; a role that cannot write makes that hold on the server's side
  too.
- Keep the URL in a secret. GitHub masks a secret in the log, and prints any
  other value a step is given in `with:` or `env:`. dbtruth never prints the
  URL, and the Action writes it nowhere.
- Run it on `pull_request`, never on `pull_request_target` with a checkout of
  the pull request's code, which hands your secrets to the code of whoever
  opened the pull request.
- A pull request from a fork gets no secrets, so the Action skips it with a
  notice and does not fail the job.
- The database must hold the data the context describes: the one
  `npx dbtruth` ran on, or a copy of it. On a database with other data, claims
  move that the pull request never touched.
- Review a change to `context/snapshot.json` as you would a change to the
  code. It is part of the pull request, so the pull request decides what is
  checked: it can mark a broken join confirmed, drop a claim, or change the
  settings until nothing can be measured.

**What it sends.** The Action sends data to one place, the GitHub API: the
comment, and the requests that find it. The only other traffic is installing:
setup-node fetches Node when the runner does not have it, and npx fetches
dbtruth from the npm registry. `dbtruth check` connects to the database and to
nothing else; it calls no model.

## Side effects

setup-node leaves Node 22 on the `PATH` for the rest of the job, and its
problem matchers registered, which turn lines in later steps' output that look
like `tsc` or ESLint errors into annotations. A later step that needs another
Node sets it up again after this Action.

## Runners and versions

Tested on `ubuntu-latest`. The Action needs bash, and gh when it comments;
GitHub's hosted runners have both, and a self-hosted runner needs them
installed. It is not tested on Windows or macOS runners, or on GitHub
Enterprise Server.

`v1` runs dbtruth 0.4.0 unless `dbtruth-version` says otherwise. The `v1` tag
moves to each 1.x release of this Action; to fix one, use its commit SHA, as
the usage does for checkout.

## Troubleshooting

The first column holds every message the Action prints, word for word, and
the line npm prints when it cannot install dbtruth, with `<...>` where a value
goes. Every other line in the step's log is dbtruth's own, and is in
[dbtruth's troubleshooting](https://github.com/FilipKalcic1/dbtruth#troubleshooting).

| Message | Cause, and what to do |
|---|---|
| `dbtruth check skipped: database-url is empty, as it is on a pull request from a fork, which gets no secrets` | A notice: the job passes, and `result` is `skipped`. A pull request from a fork gets no secrets, and that is the usual cause. A pull request Dependabot opens gets the Dependabot secrets, not the Actions ones: to check it, add `DBTRUTH_DATABASE_URL` under Dependabot secrets too. Otherwise the secret is not set, or its name in the workflow is misspelled: a secret that does not exist is empty, not an error. |
| `comment must be on-change, always or never` | The `comment` input has another value. Nothing ran, `result` is `error`, and the job fails. Set one of the three, or leave it out for `on-change`. |
| `this dbtruth-version prints a report this action cannot read; leave dbtruth-version at its default` | `check` ran, but what it printed on stdout is not a report in the format this Action reads: `dbtruth-version` names a dbtruth newer than this Action. `result` is `error`, and the job fails. Leave `dbtruth-version` out, or use the release of this Action made for that dbtruth. |
| `gh, the GitHub CLI, is not on this runner's PATH: install it, or set comment: never` | A self-hosted runner without gh, on a pull request, where the Action looks for its comment. The check ran, its lines are above this one and `result` is set, but the job fails. Install gh, or set `comment: never`. |
| `could not comment on the pull request; gh's line above says why, and HTTP 403 means the workflow needs permissions: pull-requests: write` | A warning: GitHub refused to list, create or update the comment, and the job's result is still the check's. gh's line above gives GitHub's reason. `HTTP 403` with `Resource not accessible by integration`: add `pull-requests: write` under the workflow's `permissions:`. On a locked conversation GitHub can refuse the comment too; unlock it, or read the job log. `HTTP 422`: GitHub refused the body, such as one too long; the Action cuts a body over 65,536 bytes before it sends it, and the job log has every line. |
| `npm error notarget No matching version found for dbtruth@<version>.`<br>`npm error 404  'dbtruth@<version>' is not in this registry.` | npm could not install dbtruth, so `check` did not run: `result` is `error`, and the comment says it could not run, with npm's lines. `notarget`: npm has no dbtruth of that version, because `dbtruth-version` is misspelled or names a version that is not on npm, such as 0.3.0, which was never published; `npm view dbtruth versions` lists them. `404`: the registry npm asks has no dbtruth at all, because an `.npmrc` in the working directory or on the runner points npm at a registry of its own; add dbtruth to it, or point npm at `https://registry.npmjs.org/`. A dbtruth older than 0.4.0 installs, then stops with `error: unknown option '--fail-on'`: it has no `check`. |
