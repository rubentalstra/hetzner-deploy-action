## What changed

## Why

## If this changes what the action refuses

A change to a refusal needs a test that drives it and asserts it fails. The
integration job is where those live: a gate is proven by refusing, never by
staying quiet.

- [ ] `shellcheck deploy.sh` clean
- [ ] `actionlint` clean
- [ ] The integration job passes, including the refusals
- [ ] `CHANGELOG.md` has an entry under Unreleased
- [ ] The README says the same thing the code does
