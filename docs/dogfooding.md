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
   for a Steward task token and runs the task. The agent writes its report under `out/`.
3. **publish**: a plain job with the workflow token checks the report and publishes
   it. The agent itself never writes to GitHub.

Task packages live in this repository under `.steward/tasks/<name>/`, with
`"commit": "git:trigger"`, so Steward reads the reviewed definition and prompt from
the exact commit that triggered the run.

## Tasks

| Task | Workflow | Package | Issue |
|---|---|---|---|
| Release summary and BOM consistency check | `.github/workflows/dogfood-release-summary.yml` | `.steward/tasks/release-summary/` | [#46](https://github.com/apelogic-ai/steward-platform/issues/46) |

The release summary runs when a release is published, or on demand with
`gh workflow run dogfood-release-summary.yml -f tag=<tag>`. It attaches
`release-summary.md` to the release and shows it in the job summary. It never
edits the hand-written release notes. To preview its input locally:

```bash
scripts/dogfood/release-summary-inputs.sh 2026.10.0-alpha.7 /tmp/release-summary-input
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
- **Envelope:** exactly one active Envelope for that user that covers the task's
  `requires` (model, no tools, budget, TTL).
- **Repository variables:** `STEWARD_API_URL` (the exact public API origin) and
  `STEWARD_RUNNER_LABEL`. Don't define `IDENTITY_EXCHANGE_URL`,
  `IDENTITY_EXCHANGE_AUDIENCE` or `STEWARD_CA_CERTIFICATE_FILE`, at repository or
  organization level; any of them switches discovery off.

This repository is public, so its Actions logs and artifacts are public too. Dogfood
tasks here must only read and produce public information.
