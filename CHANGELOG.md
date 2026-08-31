# Changelog

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
and the versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - 2026-08-31

### Fixed
- The action's description is under the 125 characters the Marketplace requires,
  so the listing can be published. The long version is the README's first
  paragraph, which is where it belonged.

### Changed
- `tests/metadata.sh` is the metadata gate, and it runs on every pull request as
  well as at release. The first version checked three keys and a colour by grep
  and the publish UI still refused the listing — for a length a grep cannot
  measure. It now reads `action.yml` through a parser and checks the description
  length, the name, the colour against the nine allowed values, the icon against
  the thirteen unavailable ones, and that every input and output carries a
  description and every output a value expression.

## [1.0.0] - 2026-08-31

### Added
- Deploy a container image to a host over SSH, then verify from the runner that
  the host serves what was deployed. `verify-url` without `verify-contains` is
  refused, because the deployment being replaced answers `200` too.
- Host key pinning through `known-hosts`, required unless
  `insecure-accept-any-host-key` says otherwise out loud.
- The key is registered with the runner's log masking, written 600 under
  `RUNNER_TEMP`, never passed as an argument, and removed on `EXIT INT TERM` —
  a composite action can declare no post step, so that trap is the only cleanup
  there is.
- Wait on a container's own `HEALTHCHECK` before verifying.
- The digest that ended up running is recorded as an output and in the log, so a
  run names the bytes rather than a tag that can move.
- A connection probe on the compose path that names which failure it was: a
  changed host key, a refused key, nothing answering, a refused port, a name
  that does not resolve, or a user who got in and cannot talk to docker. Five
  of those six were previously one red run and a guess. Skipped when
  `remote-command` is set, because a `command="…"`-restricted key runs its
  script for whatever you ask — so on that setup a probe would be a deploy.
- `rollback`, off by default: a failed verification puts the previous digest back
  and checks the host answers again, and the workflow still fails — a rollback
  that turned a red run green would be the worst of both. It moves the local tag
  back rather than requiring a convention in your compose file, and it says
  plainly when it cannot help: an image given as a digest has no tag to move, and
  a first deploy has nothing to return to. CI drives it against a local registry
  with two different images behind one moving reference, and asserts the host
  serves the first one again.
- `examples/` — a cloud-init file, a compose file and a Caddyfile that bring a
  fresh box to the state the action expects, with the reasoning next to each
  decision, plus how to test that the restricted deploy key is actually
  restricted.
- An integration job that deploys to a real SSH host and then drives three
  refusals, failing if any of them passes.

[unreleased]: https://github.com/rubentalstra/hetzner-deploy-action/compare/v1.0.1...HEAD
[1.0.0]: https://github.com/rubentalstra/hetzner-deploy-action/releases/tag/v1.0.0
[1.0.1]: https://github.com/rubentalstra/hetzner-deploy-action/releases/tag/v1.0.1
