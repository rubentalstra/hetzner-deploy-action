# hetzner-deploy-action

Deploy a container image to a host you already own, over SSH, and refuse to go
green until that host actually serves what you deployed.

Written for a Hetzner box, and it works on any host with SSH and Docker.

```yaml
- uses: rubentalstra/hetzner-deploy-action@v1
  with:
    host: console.example.com
    user: deploy
    ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
    known-hosts: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
    image: ghcr.io/example/console:1.2.3
    compose-file: /opt/console/docker-compose.yml
    service: console
    wait-healthy: console
    verify-url: https://console.example.com/
    verify-contains: "1.2.3"
```

## Why another deploy action

Three things this one refuses to do, because each of them is how a deploy
silently lies to you.

**It will not tell you a deploy worked because a command exited zero.** Most
deploy actions end at `docker compose up -d`. That says the daemon accepted the
request, and nothing more. This one fetches a URL **from the runner**, outside
the host, and requires the answer to contain something only the new version
serves. Give it the version string.

**It will not accept a bare 200 as proof.** The deployment you just replaced
answers 200 too. `verify-url` without `verify-contains` is refused with that
sentence, rather than passing and leaving you to find out at the next release
that nothing has moved for three of them.

**It will not trust whatever answers on port 22.** `known-hosts` is required.
Every "just add `StrictHostKeyChecking=no`" deploy hands your deploy key to
anything that can answer for that address, and it does it silently. Pin the key
with `ssh-keyscan`, or set `insecure-accept-any-host-key: true` and see the
warning in your log.

It also never asks for a cloud API token. It talks to your host and to nothing
else, so a leaked deploy key cannot destroy servers, resize volumes or read
your account. The actions that combine both are solving a different problem.

## What it does, in order

1. Writes the key to a file only this step can read, and removes it when the
   step ends — including on every failure path.
2. Verifies the host key against `known-hosts`, unless you turned that off.
3. Pulls the image on the host, then `docker compose pull` and `up -d`. Or runs
   `remote-command` instead, if your deploy is not compose-shaped.
4. Records the digest that is now running, so the log names the bytes rather
   than a tag that can move under it.
5. Waits for the container's own `HEALTHCHECK`, if you named one.
6. Fetches `verify-url` until it serves `verify-contains`, or fails with which
   of those five steps failed and what to read next.

## Inputs

| Input | Required | Default | What it is |
|---|---|---|---|
| `host` | yes | | The host to deploy to |
| `user` | | `deploy` | The SSH user. Give it the narrowest account that can run the deploy |
| `port` | | `22` | The SSH port |
| `ssh-key` | yes | | The private key, from a secret. Never printed |
| `known-hosts` | yes* | | The host's public key, as `ssh-keyscan` prints it |
| `insecure-accept-any-host-key` | | `false` | Skip host key verification, loudly |
| `image` | | | The image to deploy, by tag or digest |
| `compose-file` | one of | | A compose file **on the host** |
| `service` | | | The compose service to restart; empty means all of them |
| `remote-command` | one of | | A command to run instead of the compose path |
| `verify-url` | | | Fetched from the runner after the deploy |
| `verify-contains` | with url | | Text the answer must contain — the version |
| `verify-timeout` | | `300` | Seconds to wait for it |
| `verify-interval` | | `5` | Seconds between attempts |
| `wait-healthy` | | | A container to wait on until Docker reports it healthy |
| `health-timeout` | | `120` | Seconds to wait for that |

\* unless `insecure-accept-any-host-key` is true.

## Outputs

| Output | What it is |
|---|---|
| `digest` | The image digest running on the host after the deploy |
| `verified` | Whether the verification ran and passed |

## Setting up the host

The action assumes a host that already has Docker and a compose file. What it
needs from you, once:

```bash
# On the host, a user that can run docker and nothing else interesting.
adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh

# The deploy key's public half. Restrict it to one command and it can do
# exactly one thing, even if the key leaks.
echo 'command="/opt/console/deploy.sh",no-agent-forwarding,no-port-forwarding,no-pty ssh-ed25519 AAAA... deploy@ci' \
  > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
```

Then, in the workflow's repository:

```bash
ssh-keygen -t ed25519 -f deploy-key -C deploy@ci -N ""
gh secret set DEPLOY_SSH_KEY < deploy-key
ssh-keyscan -p 22 console.example.com | gh secret set DEPLOY_KNOWN_HOSTS
```

Put the public half in `authorized_keys` above, and delete your local copy of
the private half.

## Runners

Linux and macOS. The action is bash, `ssh` and `curl`; on a Windows runner it
refuses at the first step with that sentence rather than failing somewhere deep.

Composite actions cannot declare a post step
([metadata syntax](https://docs.github.com/en/actions/reference/metadata-syntax-for-github-actions)),
so the key is removed by a `trap` on `EXIT INT TERM` inside the step. A
cancelled job still cleans up; a runner destroyed mid-step takes the temporary
directory with it.

## What it does not do

- It does not create servers, resize them, or touch your cloud account.
- It does not do rolling updates across several hosts behind a load balancer.
  If that is your shape, you want something else.
- It does not manage TLS. Put a reverse proxy on the host — Caddy gets a
  certificate on its own — and point this at the public URL.

## Security

`SECURITY.md` states what the action is trusted with and what it does with the
key. The short version: an SSH key and no cloud API token, the key masked with
the runner's own redaction and removed on every exit path, and host key pinning
required rather than suggested.

CI asserts both properties rather than claiming them — one job greps the
action's own output for key material and fails if it finds any, and checks that
no key directory survives a failed run.

## Versioning

`@v1` follows the latest v1.x and is what the examples above use. It is a trust
relationship with this repository: nothing inside a major will break you on
purpose, and the integration job is the contract that keeps it true.

Pin a full commit SHA instead if you want bytes rather than a promise:

```yaml
- uses: rubentalstra/hetzner-deploy-action@<full 40-character sha> # v1.0.0
```

The release lane verifies the tagged commit, publishes the release, and moves
`v1` **last**, so that pointer never names a commit whose release did not
finish.

## Licence

MIT.
