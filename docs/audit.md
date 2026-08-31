# What this repository was audited against, and when

An audit nobody recorded is an audit that gets repeated from scratch. This file
names the reference pages, the date, and what each one actually changed — so the
next pass is a diff rather than a re-read.

## 2026-08-31 — first pass, before v1.0.0

### [Metadata syntax for GitHub Actions](https://docs.github.com/en/actions/reference/metadata-syntax-for-github-actions)

- **Composite actions support neither `pre` nor `post`.** So the key's cleanup
  is the step's own `trap`, and it catches `INT` and `TERM` as well as `EXIT` —
  a cancelled job is the case where a temporary key would otherwise survive.
  This is the single most consequential thing the page says about this action.
- `branding.color` is one of nine values and `branding.icon` is a Feather
  v4.28.0 name, thirteen of which are unavailable. The release lane checks the
  colour against that list, because the failure otherwise arrives at publish
  time.
- `action.yml` and `action.yaml` are both read, and renaming between releases
  affects earlier releases on the Marketplace. The name stays `action.yml`.
- Composite outputs need an explicit `value` with an expression, unlike
  JavaScript and Docker actions.

### [Security hardening / secure use](https://docs.github.com/en/actions/reference/security/secure-use)

- **"Register all generated secrets."** Redaction covers only what the runner was
  told about, so the key is masked line by line. Which surfaced its own problem:
  `::add-mask::<value>` is the value in the clear until something consumes that
  line, so the registration happens only under `GITHUB_ACTIONS`, and CI asserts
  both halves.
- **Set untrusted values into environment variables** rather than interpolating
  them into `run:`. Every input reaches `deploy.sh` through `env:`.
- **Pin third-party actions to a full commit SHA**, which is "the only way to use
  an action as an immutable release" — and which also means Dependabot alerts
  cannot fire for them, since those key off semantic versions. Hence
  `dependabot.yml` beside the pins.
- **Audit by running with valid and invalid input and reading the output.** That
  is a CI job now, not a habit.
- **CODEOWNERS in front of workflow changes.**
- Least-privilege `GITHUB_TOKEN`: `permissions: {}` at workflow level, with the
  minimum granted per job.

### [Publishing actions in GitHub Marketplace](https://docs.github.com/en/actions/sharing-automations/creating-actions/publishing-actions-in-github-marketplace)

- The listing is a **checkbox on a release**, disabled until the owning account
  accepts the Marketplace Developer Agreement. **No API exists for either**, so
  publishing is an owner action and this repository cannot automate it.
- The action's `name` must be unique across the Marketplace and must not collide
  with a user, an organization, or a category.
- A public repository with exactly one root metadata file, and no review by
  GitHub.

## 2026-08-31 — second pass, from the publish UI's own refusal

The Marketplace publish form refused the listing and named one rule the audit
had missed: **a description must be under 125 characters.** Neither reference
page states it; the form does. Two things changed.

The description is now 107 characters, and the long version lives in the README
where it belonged. And the metadata gate stopped being a grep: `tests/metadata.sh`
reads `action.yml` through a parser and checks the description length, the name,
the colour, the icon against the thirteen unavailable ones, and that every input
and output carries a description and every output a value expression. It runs on
every pull request as well as at release, and it has a seeded-violation proof.

The lesson worth keeping: a gate written from documentation catches what the
documentation says. The publish form is the authority on what it accepts, and the
only way to learn its rules is to be refused by it — so each refusal becomes a
check rather than a memory.

## What is still unread

The reusable-workflows and JavaScript-action references, which do not apply to a
composite action, and the self-hosted runner pages, which do not apply to a
consumer-run action. Named here so their absence is a decision.
