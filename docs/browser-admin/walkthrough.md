# Evaluator walkthrough: template, request, approval, audit

The human side of core mode on a browser-admin install: an administrator
authors an Envelope template, a user requests an Envelope from it, the
administrator approves the request, and both read the audit record. Nothing
runs: core mode admits no Task execution, so the Envelope is authority on
record, not a running agent.

Before you start: the install and HTTPS path from [local access](local-access.md),
and an administrator from the [first-admin runbook](first-admin.md). One
Workspace account can play both roles; a second account in the same
Workspace, as the requesting user, shows the separation more clearly. Steward
owns the model; its
[User Envelope and RBAC administration](https://github.com/apelogic-ai/steward/blob/v0.3.5/docs/operator-envelope-administration.md)
and [administrator browser contract](https://github.com/apelogic-ai/steward/blob/v0.3.5/docs/admin-ui-contract-v1.md)
at v0.3.5 are the authority for what each step means.

## 1. Give the user a member role

A user may request an Envelope from a template only while holding one of the
template's member roles. Role names are yours; this walkthrough uses
`evaluator`. The requesting user signs in once (to exist), then:

```sh
kubectl --context <context> -n steward exec deploy/steward-apiserver -- \
  /usr/local/bin/steward bootstrap-rbac \
  --user-id usr_<requesting user> --grant evaluator --actor <your name>
```

The requesting user signs out and in again, so that the session carries the
role. (`steward rbac grant member-role` is the operator CLI form, once it has
a credential; see [first admin](first-admin.md#4-the-operator-cli).)

## 2. Author a template (administrator)

Open `/admin/envelopes/templates/new`:

- **ID** `evaluation` and a display name.
- **Member roles**: `evaluator`.
- **Ceiling**, the most a request may ask for: the catalog model
  (`evaluation` / `evaluation-model` in the kind values; Steward refuses a
  template without a model from the deployment's capability catalog), a
  monthly budget such as 10.00 USD, and a TTL.
- **Automatic provisioning threshold**: lower than the ceiling, for example a
  budget of 1.00 USD. Requests at or below it are provisioned automatically;
  requests above it and within the ceiling wait for an administrator;
  requests above the ceiling are refused with `422`.

Templates are append-only: a change is a new revision, and a request pins the
exact template ID and revision it was made against.

## 3. Request an Envelope (user)

As the requesting user, open `/envelopes/new`, choose the `evaluation`
template, and ask for more than the threshold but within the ceiling, for
example a 5.00 USD budget. The request is created **pending**, with the user
as owner and actor.

A request at or below the threshold would instead be provisioned at once,
recorded with the actor `system:auto`: try both.

## 4. Approve it (administrator)

Open `/admin/approvals`. The queue lists the pending Envelope request with the
requested change against the template. Open it, give a rationale, and
approve. Steward re-checks the request against the current template revision
and ceiling at approval, then provisions the Envelope. Rejecting is the same
page.

## 5. Read the audit record

- **The request**, from the approvals page: its append-only status history,
  pending then approved, with the administrator's canonical user ID as the
  approving actor, the rationale, and the time. The same record is
  `GET /admin/api/v1/requests/<request id>` for an administrator session.
- **The Envelope**, as the user, at `/envelopes`: active, pinned to template
  `evaluation` at its revision, with its content digest
  (`steward:sha256:...`), the integrity identity a Task can select with
  `envelopeDigest`.
- **RBAC**: the grants from the first-admin runbook and step 1 are
  append-only events with their audited actors.

Nothing in this record depends on email addresses: owners and actors are
canonical user IDs, and email is display-only.

## Optional: link a Task identity to the user (manual)

The [task-auth profile](../profiles/task-auth.md) stops at
`403 task_identity_unassociated`: Steward authenticates the GitHub Actions
job's task token, records its federated subject
(`github-actions:actor:<GitHub actor ID>`) as an unassociated observation,
and grants it nothing. On a browser-admin install an administrator can
associate that subject with a canonical user, and the same submission then
gets past identity to Steward's core-mode answer:
`503`, "Task submission is disabled during the staged orchestration rollout"
([`submit`, v0.3.5](https://github.com/apelogic-ai/steward/blob/v0.3.5/crates/steward-apiserver/src/tasks.rs#L1924-L1967)).
That proves the whole authorization chain by hand: GitHub OIDC, the exchange,
Steward's token verification, the association, and the canonical user.

This is a manual demonstration, not part of CI: the CI clusters are
ephemeral and no one can sign in to them, and there is no non-browser way to
create a canonical user or associate a subject
([apelogic-ai/steward#179](https://github.com/apelogic-ai/steward/issues/179)).
It needs an install whose edge a GitHub Actions job can reach (a reachable
hostname, or a self-hosted runner next to the cluster):

1. Enrol the exchange policy for your repository and workflow, and run the
   steward-run action (or the direct exchange and `POST /v1/tasks` of the
   [task-auth test](../../tests/e2e/task-auth/run.sh)) against the install.
   Expect `403 task_identity_unassociated` naming the issuer and subject.
2. As an administrator, list the observations and note the subject's `id`
   and `revision`: `GET /admin/api/v1/federated-subjects`. Steward 0.3.5 has
   no page for this yet, so call the browser API with your session. Browser
   mutations need the session cookie, the exact origin, same-origin fetch
   metadata and the session's CSRF value:

   ```sh
   origin=https://<steward host>
   cookie='__Host-steward-session=<value from the browser developer tools>'
   csrf="$(curl -s --cacert steward-platform-edge-ca.crt -H "Cookie: ${cookie}" \
     "${origin}/admin/api/v1/session" | jq -r .csrf)"
   curl -s --cacert steward-platform-edge-ca.crt -H "Cookie: ${cookie}" \
     "${origin}/admin/api/v1/federated-subjects" | jq .
   curl -s --cacert steward-platform-edge-ca.crt -X POST \
     -H "Cookie: ${cookie}" -H "Origin: ${origin}" -H 'Sec-Fetch-Site: same-origin' \
     -H 'Content-Type: application/json' -H "X-Steward-CSRF: ${csrf}" \
     -d '{"expectedRevision": <revision>, "canonicalUserId": "usr_<user>"}' \
     "${origin}/admin/api/v1/federated-subjects/<id>/associate" | jq .
   ```

   The session cookie is a bearer credential for an hour: do not paste it
   anywhere else, and sign out afterwards. This is a known security
   limitation, repeated for every new caller identity; read the risk and
   mitigations in
   [prerequisites](../prerequisites.md#federated-subject-association-needs-a-pasted-session-cookie)
   first. A `409` means the observation changed; read it again before
   retrying.
3. Run the same submission again. Steward now resolves the subject to the
   user and answers `503` with the staged-orchestration message instead of
   `403`. The association and its actor are in
   `GET /admin/api/v1/federated-subjects/<id>/audit`.

Disabling the association (`.../disable`) returns the subject to refusal
immediately.
