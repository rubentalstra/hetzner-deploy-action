# Contributing

## The one rule that matters

A change to what the action refuses needs a test that proves the refusal. CI's
integration job deploys to a real SSH host — the runner itself — and then drives
the failure paths, asserting each one fails. A gate is proven by refusing, never
by staying quiet: an assertion that the action "did not complain" passes just as
happily over an action that did nothing at all.

## Running the gates

```bash
shellcheck deploy.sh
actionlint            # or the digest-pinned container CI uses
```

The integration job needs a Linux host with Docker and sshd, which is what
`ubuntu-latest` is. Running it locally means pointing the action at a box you
own; there is no way to prove a deploy without something to deploy to.

## Shape

- `action.yml` is the contract. Every input carries a description that says what
  it is for, not what type it is.
- `deploy.sh` is the whole implementation. It is bash on purpose: anyone
  trusting this with a key can read all of it in one sitting.
- Every failure names which of the steps failed and what to read next. "Deploy
  failed" is not an error message.

## Commits

Conventional commit types (`feat`, `fix`, `docs`, `ci`, `refactor`, `test`,
`chore`). One subject line that says what changed.
