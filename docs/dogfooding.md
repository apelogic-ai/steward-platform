# Dogfooding: governed agents doing real work for the platform

The platform runs its own governed agents on real project work. The roadmap is
[#51](https://github.com/apelogic-ai/steward-platform/issues/51).

## How a dogfood task is built

The governed agent has no general network access. It sees only the input artifact
the workflow uploads, plus whatever read-only tools its task definition requests.
Every task therefore has three jobs:

1. **prepare**: a plain GitHub runner collects the data (for example with `gh`) and
   uploads it as the task input.
2. **governed**: steward-run's reusable workflow exchanges the job's GitHub identity
   for a Steward task token and runs the task. The agent writes its report under `out/`;
   from steward-run 0.7.6 the reusable workflow fails the job when the task writes
   nothing there.
3. **publish**: a plain job with the workflow token checks the report and publishes
   it. The agent itself never writes to GitHub.

Task packages live in this repository under `.steward/tasks/<name>/`. Steward reads
the reviewed definition and prompt from the exact commit that triggered the run:
through an invocation manifest with `"commit": "git:trigger"`, or, for a single-file
package submitted with `package-path`, from the trigger commit directly.

## Tasks

| Task | Workflow | Package | Issue |
|---|---|---|---|
| Release summary and BOM consistency check | `.github/workflows/dogfood-release-summary.yml` | `.steward/tasks/release-summary/` | [#46](https://github.com/apelogic-ai/steward-platform/issues/46) |
| repo-snapshot | `.github/workflows/repo-snapshot.yml` | `.steward/tasks/repo-snapshot/task-definition.json` | |

The release summary runs when a release is published, or on demand with
`gh workflow run dogfood-release-summary.yml -f tag=<tag>`. It attaches
`release-summary.md` to the release and shows it in the job summary. It never
edits the hand-written release notes. To preview its input locally:

```bash
scripts/dogfood/release-summary-inputs.sh 2026.10.0-alpha.7 /tmp/release-summary-input
```

### repo-snapshot

`repo-snapshot` (version 2) writes a short, read-only snapshot of one public GitHub
repository: its latest release, recent commits, open pull requests with the CI state of
up to three of them, open issues, and a green, yellow or red verdict. It is a
single-file package: `task-definition.json` carries the prompt inline in `promptText`,
and the workflow submits it with steward-run's `package-path` input (steward-run 0.8.0
or later, Steward 0.3.11 or later). The agent reads the repository through the
read-only GitHub MCP tools that the prompt names; it never writes to GitHub.

To run it, open **Actions → repo-snapshot → Run workflow**, or:

```bash
gh workflow run repo-snapshot.yml -f owner=apelogic-ai -f repo=steward-run -f days=14 -f maxItems=5
```

| Input | Default | Meaning |
|---|---|---|
| `owner` | `apelogic-ai` | Owner of the repository to snapshot |
| `repo` | `steward-run` | Repository name; it must be public |
| `days` | `14` | Days of commit history to list, 1 to 90 |
| `maxItems` | `5` | Items per listing (`perPage`), 1 to 20 |

The `prepare` job validates the inputs, refuses a repository that is not public, and
writes them with `jq` as `inputs.json` at the root of the input artifact. The
reusable workflow downloads that artifact into `in/` and steward-run archives `in/`,
which Steward unpacks in the agent's working directory, so the agent reads
`in/inputs.json`. The `summary` job adds `out/report.md` to the job summary. The run
uses `execution-log: full`, so the agent's transcript is replayed in the governed
job's log, which is public like the rest of this repository's Actions logs. To
preview the input locally:

```bash
SKIP_VISIBILITY_CHECK=1 scripts/dogfood/repo-snapshot-inputs.sh apelogic-ai steward-run 14 5 /tmp/repo-snapshot-input
```

## Enabling it on an installation

Every job is skipped until the repository variable `STEWARD_API_URL` is set.
Before setting it:

- **Steward:** version 0.3.x or later, with `taskIdentity.resource` set, so steward-run
  discovers Identity. Also needed:
  - the read-only GitHub source App installed on this repository;
  - a source binding whose caller and source are both this repository;
  - an execution binding for the `agentRef` in the task definition;
  - the model the task requests.
- **Identity:** a policy v6 entry for this repository (numeric owner and repository
  IDs), with events `release` and `workflow_dispatch`. Also an actor mapping for
  whoever publishes releases or dispatches the workflow.
- **Envelope:** exactly one active Envelope for that user that covers each task's
  `requires` (model, no tools, budget, TTL for the release summary). `repo-snapshot`
  has no `requires`, so the Envelope's approved authority applies; it must
  allow the model in its task definition and the read-only GitHub tools its prompt
  names.
- **Repository variables:** `STEWARD_API_URL` (the exact public API origin) and
  `STEWARD_RUNNER_LABEL`. Don't define `IDENTITY_EXCHANGE_URL`,
  `IDENTITY_EXCHANGE_AUDIENCE` or `STEWARD_CA_CERTIFICATE_FILE`, at repository or
  organization level; any of them switches discovery off.

This repository is public, so its Actions logs and artifacts are public too. Dogfood
tasks here must only read and produce public information.
