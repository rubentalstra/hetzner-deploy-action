# Changelog

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
and the versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `examples/` — a cloud-init file, a compose file and a Caddyfile that bring a
  fresh box to the state the action expects, with the reasoning next to each
  decision, plus how to test that the restricted deploy key is actually
  restricted.

## [1.0.0] - 2026-08-31

### Added
- Deploy a container image to a host over SSH, then verify from the runner that
  the host serves what was deployed. `verify-url` without `verify-contains` is
  refused, because the deployment being replaced answers `200` too.
- Host key pinning through `known-hosts`, required unless
  `insecure-accept-any-host-key` says otherwise out loud.
- Wait on a container's own `HEALTHCHECK` before verifying.
- The digest that ended up running is recorded as an output and in the log, so a
  run names the bytes rather than a tag that can move.
- An integration job that deploys to a real SSH host and then drives three
  refusals, failing if any of them passes.
- The key is registered with the runner's log masking only when a runner is
  there to consume the registration: `::add-mask::<value>` is the value in the
  clear until something reads that line, so emitting it with nothing listening
  would write the key to wherever the output went. CI asserts both halves — no
  key material at all without a runner, and none outside the registration with
  one.

[unreleased]: https://github.com/rubentalstra/hetzner-deploy-action/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/rubentalstra/hetzner-deploy-action/releases/tag/v1.0.0
