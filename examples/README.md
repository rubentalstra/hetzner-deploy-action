# Examples

These are read, not run. This action deploys to a host; it does not build one,
and an action that tries to do both is one nobody should trust with a key. What
these files are is the shape of host the action expects, with the reasoning kept
next to each decision.

| File | What it is |
|---|---|
| `cloud-init.yaml` | A fresh server to serving state on first boot: the `deploy` user, key-only SSH, both firewalls, unattended upgrades, Docker, capped logs, and the one command the CI key may run |
| `docker-compose.yml` | One service behind Caddy, with the three things most often left out: a restart policy, a healthcheck the action can wait on, and a memory limit |
| `Caddyfile` | Automatic TLS, so no certificate is ever renewed by hand or by CI |

## The restricted key, and what it costs

The CI key's entry in `authorized_keys` is prefixed
`command="/opt/app/deploy.sh"`. SSH then runs that script whatever the client
asked for, so the key cannot open a shell, read a file, or start a container of
its own choosing.

**It only works with `remote-command`.** The action's compose path issues
several commands — pull, compose pull, compose up, an inspect for the digest and
the health — and a restricted key runs the script once for each of them. So pick
one shape:

| | Key | What you get |
|---|---|---|
| `remote-command: deploy` | restricted to one script | The tightest key. No digest output, no health wait — neither can run |
| `compose-file: …` | ordinary key, docker group, no sudo | The digest, the health wait, and the connection diagnosis |

Neither is wrong. The restricted key is the right default for a box you care
about; the compose path is the right default for one you are still setting up.

Test the restriction rather than trusting it:

```bash
ssh -i deploy-key deploy@app.example.com 'echo this should not run'
# → the deploy script runs; the echo never happens
```

If that command prints `this should not run`, the restriction is not in place.

## What is deliberately absent

**Backups.** These examples assume a host that holds nothing worth backing up:
the container is rebuilt from a published image, and anything durable lives
somewhere else. A host that does hold state needs a backup story, and this
action has no opinion about it.

**A second server.** One box, one service. Rolling updates across several hosts
behind a load balancer is a different problem with different failure modes, and
this action does not pretend to solve it.
