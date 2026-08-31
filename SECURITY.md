# Security

## What this action is trusted with

An SSH private key that can log into a host, and nothing else. It asks for no
cloud API token, so a key that leaks cannot destroy a server, resize a volume
or read an account. That is a deliberate boundary: the actions that combine
deploy access with cloud-account access are solving a different problem, and the
blast radius is not the same.

## What it does with the key

- Registers it with the runner's log masking, line by line, so it is redacted
  even when it did not arrive from `secrets.*`.
- Writes it to a file under `RUNNER_TEMP` with mode 600, in a directory with
  mode 700.
- Removes it on every exit path, including a cancelled job. Composite actions
  cannot declare a post step
  (<https://docs.github.com/en/actions/reference/metadata-syntax-for-github-actions>),
  so the cleanup is a `trap` on `EXIT INT TERM` rather than something the runner
  guarantees.
- Never prints it, and never passes it as a command-line argument, where it
  would be visible in a process listing.

## Host key pinning is not optional

`known-hosts` is required. Without it the first connection trusts whatever
answers for that address, which hands the key to anything that can win that
race. `insecure-accept-any-host-key` exists, is named for what it gives up, and
logs a warning when used.

## What you should do

- Keep the deploy user as narrow as it can be, and restrict its key to one
  command with `command="…"` in `authorized_keys`. Then a leaked key can run
  one script instead of a shell.
- Pin this action to a full commit SHA if you want bytes rather than a promise.
  `@v1` follows the latest v1.x, which is a trust relationship with this
  repository.
- Rotate the deploy key on a schedule, and after anyone with access leaves.

## Reporting something

Open a private security advisory on this repository. Please do not open a public
issue for a vulnerability.
