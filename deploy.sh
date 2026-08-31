#!/usr/bin/env bash
# Deploy a container image to a host over SSH, then prove the host serves it.
#
# The order matters and is the whole point. Every step refuses rather than
# guesses: an unknown host key, an image the host cannot pull, a container that
# never reports healthy, and a public URL that does not serve what was
# deployed are four different failures, and each one says which it is.
set -euo pipefail

readonly SSH_DIR="${RUNNER_TEMP:-/tmp}/hetzner-deploy-$$"
readonly KEY_FILE="$SSH_DIR/id"
readonly KNOWN_HOSTS_FILE="$SSH_DIR/known_hosts"

cleanup() {
  # The key goes whatever happened, including on every failure path.
  if [[ -d "$SSH_DIR" ]]; then
    find "$SSH_DIR" -type f -exec shred -u {} + 2>/dev/null || true
    find "$SSH_DIR" -type f -delete 2>/dev/null || true
    rmdir "$SSH_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

fail() {
  echo "::error::$*" >&2
  exit 1
}

require() {
  local name="$1" value="${2:-}"
  [[ -n "$value" ]] || fail "$name is required"
}

# ── The credentials, on disk for the length of this step and no longer ───────
prepare_ssh() {
  # A secret is redacted only if the runner was told about it. The key usually
  # arrives from `secrets.*` and is masked already; it does not have to, so it
  # is registered here, line by line, because the runner masks exact strings.
  #
  # ONLY under a runner. `::add-mask::<value>` is the value in the clear until
  # something consumes the line, so emitting it with nothing listening — a local
  # run, or a step whose stdout is redirected — writes the key to wherever that
  # output goes. CI asserts both halves of this.
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "::add-mask::$line"
    done <<< "$INPUT_SSH_KEY"
  fi

  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  printf '%s\n' "$INPUT_SSH_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  # A key that lost its trailing newline fails with "invalid format", which
  # reads like a wrong key rather than a mangled one.
  ssh-keygen -y -f "$KEY_FILE" > /dev/null 2>&1 \
    || fail "the supplied ssh-key is not a private key OpenSSH can read (a key pasted without its trailing newline is the usual cause)"

  if [[ "${INPUT_INSECURE,,}" == "true" ]]; then
    echo "::warning::host key verification is off, so this deploy trusts whatever answers at ${INPUT_HOST}"
    HOST_KEY_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    return
  fi
  [[ -n "$INPUT_KNOWN_HOSTS" ]] \
    || fail "known-hosts is empty. Pin the host's key — 'ssh-keyscan -p ${INPUT_PORT} ${INPUT_HOST}' prints it — or set insecure-accept-any-host-key if you accept that anything answering that address will be trusted."
  printf '%s\n' "$INPUT_KNOWN_HOSTS" > "$KNOWN_HOSTS_FILE"
  chmod 600 "$KNOWN_HOSTS_FILE"
  HOST_KEY_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE")
}

remote() {
  ssh -i "$KEY_FILE" \
    "${HOST_KEY_OPTS[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -p "$INPUT_PORT" \
    "${INPUT_USER}@${INPUT_HOST}" \
    "$@"
}

# Four failures look nearly identical in a workflow log and have completely
# different fixes, and the person least able to tell them apart is the one
# setting this up for the first time. So the connection is probed once, before
# anything is deployed, and the answer names which of the four it was.
#
# ONLY on the compose path. A key restricted with command="…" runs its script
# for whatever you ask, so on that setup a probe IS a deploy — which is why the
# restriction belongs with `remote-command`, where the action issues exactly one
# command and that command is the deploy.
check_connection() {
  local out rc
  out="$(remote true 2>&1)" && rc=0 || rc=$?
  if (( rc == 0 )); then
    echo "→ ${INPUT_USER}@${INPUT_HOST}:${INPUT_PORT} accepts the key"
  else
    case "$out" in
      *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
        fail "the host key at ${INPUT_HOST}:${INPUT_PORT} is not the one pinned in known-hosts. Either the host was rebuilt — re-pin it with 'ssh-keyscan -p ${INPUT_PORT} ${INPUT_HOST}' — or something else is answering for that address, which is worth looking into before you deploy anything." ;;
      *"Permission denied"*|*"Too many authentication failures"*)
        fail "${INPUT_HOST} refused the key for user '${INPUT_USER}'. The public half has to be in that user's authorized_keys, and the user has to exist. If you restricted the key with command=\"…\", check the script path in that entry." ;;
      *"Connection timed out"*|*"Operation timed out"*|*"No route to host"*|*"Network is unreachable"*)
        fail "nothing answered at ${INPUT_HOST}:${INPUT_PORT} within 15s. Check the address, the port, and both firewalls — the cloud one and the host's own." ;;
      *"Connection refused"*)
        fail "${INPUT_HOST} refused the connection on port ${INPUT_PORT}: something is reachable there and sshd is not listening on that port." ;;
      *"Name or service not known"*|*"nodename nor servname"*|*"could not resolve"*|*"Could not resolve"*)
        fail "${INPUT_HOST} does not resolve. If the DNS record is new, it may not have propagated yet." ;;
      *)
        fail "could not reach ${INPUT_USER}@${INPUT_HOST}:${INPUT_PORT} (ssh exit ${rc}): ${out}" ;;
    esac
  fi

  # Reached the host and cannot use docker is its own failure, and it is the one
  # people hit after following a setup guide that forgot the docker group.
  if ! remote "docker version --format '{{.Server.Version}}'" > /dev/null 2>&1; then
    fail "'${INPUT_USER}' logged into ${INPUT_HOST} and cannot talk to docker. Add the user to the docker group ('usermod -aG docker ${INPUT_USER}'); the group takes effect on the next login."
  fi
}

# The id of the image the service's container is actually running.
#
# Read from the CONTAINER, never from the tag. A tag is what a deploy moves, so
# `docker image inspect <reference>` answers "what would start next", which is
# the new bytes even before anything restarts — and taking that as "what is
# running now" gave a rollback that rolled forward.
running_image_id() {
  [[ -n "$INPUT_COMPOSE_FILE" ]] || return 0
  local compose service=""
  compose="docker compose -f $(printf '%q' "$INPUT_COMPOSE_FILE")"
  [[ -n "$INPUT_SERVICE" ]] && service="$(printf '%q' "$INPUT_SERVICE")"
  local container
  container="$(remote "${compose} ps -q ${service} 2>/dev/null | head -1" 2>/dev/null || true)"
  [[ -n "$container" ]] || return 0
  remote "docker inspect --format '{{.Image}}' $(printf '%q' "$container")" 2>/dev/null || true
}

# ── The deploy itself ────────────────────────────────────────────────────────
deploy() {
  if [[ -n "$INPUT_REMOTE_COMMAND" ]]; then
    echo "→ running the supplied command on ${INPUT_HOST}"
    remote "$INPUT_REMOTE_COMMAND"
    return
  fi

  if [[ -n "$INPUT_IMAGE" ]]; then
    echo "→ pulling ${INPUT_IMAGE} on ${INPUT_HOST}"
    remote "docker pull -q $(printf '%q' "$INPUT_IMAGE")"
  fi

  local compose service=""
  compose="docker compose -f $(printf '%q' "$INPUT_COMPOSE_FILE")"
  [[ -n "$INPUT_SERVICE" ]] && service="$(printf '%q' "$INPUT_SERVICE")"
  echo "→ compose pull and up on ${INPUT_HOST}"
  remote "${compose} pull -q ${service} && ${compose} up -d --remove-orphans ${service}"
}

# What is actually running, so the log records the bytes rather than a tag that
# can move under it. The registry digest is the readable form and is preferred;
# the local image id is the fallback, and is what the rollback moves back to.
record_digest() {
  local digest="" id
  id="$(running_image_id)"
  if [[ -n "$INPUT_IMAGE" ]]; then
    digest="$(remote "docker image inspect --format '{{index .RepoDigests 0}}' $(printf '%q' "$INPUT_IMAGE")" 2>/dev/null || true)"
  fi
  [[ -z "$digest" ]] && digest="$id"
  echo "digest=${digest}" >> "${GITHUB_OUTPUT:-/dev/null}"
  [[ -n "$digest" ]] && echo "→ running ${digest}"
  return 0
}

wait_healthy() {
  [[ -n "$INPUT_WAIT_HEALTHY" ]] || return 0
  local deadline=$(( SECONDS + INPUT_HEALTH_TIMEOUT ))
  local state="unknown"
  echo "→ waiting for ${INPUT_WAIT_HEALTHY} to report healthy"
  while (( SECONDS < deadline )); do
    state="$(remote "docker inspect --format '{{.State.Health.Status}}' $(printf '%q' "$INPUT_WAIT_HEALTHY")" 2>/dev/null || echo unknown)"
    case "$state" in
      healthy) echo "→ ${INPUT_WAIT_HEALTHY} is healthy"; return 0 ;;
      unhealthy)
        echo "::error::${INPUT_WAIT_HEALTHY} reports unhealthy: the deploy landed and the container refuses to serve" >&2
        return 1 ;;
    esac
    sleep "$INPUT_VERIFY_INTERVAL"
  done
  echo "::error::${INPUT_WAIT_HEALTHY} never reported healthy within ${INPUT_HEALTH_TIMEOUT}s (last state: ${state})" >&2
  return 1
}

# ── The verification, from HERE rather than from the host ────────────────────
# A deploy is not done because a platform said so. It is done when the public
# address serves what was deployed, which is a question only something outside
# the host can answer.
verify() {
  if [[ -z "$INPUT_VERIFY_URL" ]]; then
    echo "verified=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "::warning::no verify-url was given, so nothing checked that ${INPUT_HOST} serves what was deployed"
    return 0
  fi
  [[ -n "$INPUT_VERIFY_CONTAINS" ]] \
    || fail "verify-url was given without verify-contains. A bare 200 is not proof: the deployment you just replaced answers 200 too. Name something only the new one serves, normally its version."

  local deadline=$(( SECONDS + INPUT_VERIFY_TIMEOUT ))
  local answer="" status=""
  echo "→ waiting for ${INPUT_VERIFY_URL} to serve what was deployed"
  while (( SECONDS < deadline )); do
    answer="$(curl -sS -m 30 -w $'\n%{http_code}' "$INPUT_VERIFY_URL" 2>/dev/null || true)"
    status="${answer##*$'\n'}"
    if [[ "$answer" == *"$INPUT_VERIFY_CONTAINS"* ]]; then
      echo "verified=true" >> "${GITHUB_OUTPUT:-/dev/null}"
      echo "→ ${INPUT_VERIFY_URL} serves it (HTTP ${status})"
      return 0
    fi
    sleep "$INPUT_VERIFY_INTERVAL"
  done
  echo "::error::${INPUT_VERIFY_URL} did not serve what was deployed within ${INPUT_VERIFY_TIMEOUT}s (last status: ${status:-no answer}). The deploy reached the host, so what failed is the host serving it: read the container's logs." >&2
  return 1
}

# Put back what was running, and prove THAT serves. A rollback nobody verified
# is a second unverified deploy on top of a failed one.
roll_back() {
  local previous="$1"
  if [[ -z "$previous" ]]; then
    echo "::warning::nothing to roll back to: no digest was running before this deploy"
    return 1
  fi
  case "$INPUT_IMAGE" in
    "")
      echo "::warning::rollback needs an image reference to move back, and none was given"
      return 1 ;;
    *@sha256:*)
      echo "::warning::image was given as a digest, so there is no tag to move back; pin the previous digest in your compose file instead"
      return 1 ;;
  esac
  echo "→ rolling back to ${previous}"
  # Nothing is pulled. The previous image is local by definition — a container
  # was running it, and a running container's image is never pruned — and a
  # local image id is not something a registry can be asked for anyway.
  # The compose file names a REFERENCE, and what a deploy changed is which bytes
  # that reference resolves to. So the rollback moves the local tag back to the
  # previous digest and recreates, which needs no convention in the compose file
  # and no file on the host edited by CI.
  if ! remote "docker tag $(printf '%q' "$previous") $(printf '%q' "$INPUT_IMAGE")"; then
    echo "::error::the rollback could not point ${INPUT_IMAGE} back at ${previous}; the host is still serving the failed deploy"
    return 1
  fi
  local compose service=""
  compose="docker compose -f $(printf '%q' "$INPUT_COMPOSE_FILE")"
  [[ -n "$INPUT_SERVICE" ]] && service="$(printf '%q' "$INPUT_SERVICE")"
  if ! remote "${compose} up -d --force-recreate --remove-orphans ${service}"; then
    echo "::error::the rollback could not start ${previous}; the host is still serving the failed deploy"
    return 1
  fi
  return 0
}

main() {
  case "${RUNNER_OS:-Linux}" in
    Windows) fail "this action needs bash, ssh and curl, so it runs on the Linux and macOS runners. On a Windows runner, deploy from a container step or use a Linux job." ;;
  esac
  require host "$INPUT_HOST"
  require ssh-key "$INPUT_SSH_KEY"
  if [[ -z "$INPUT_REMOTE_COMMAND" && -z "$INPUT_COMPOSE_FILE" ]]; then
    fail "give either compose-file (with image) or remote-command; there is nothing to deploy otherwise"
  fi
  if [[ -n "$INPUT_REMOTE_COMMAND" && -n "$INPUT_COMPOSE_FILE" ]]; then
    fail "compose-file and remote-command are mutually exclusive: two deploy paths in one run is one too many"
  fi

  prepare_ssh
  [[ -z "$INPUT_REMOTE_COMMAND" ]] && check_connection

  local before=""
  if [[ "${INPUT_ROLLBACK,,}" == "true" ]]; then
    before="$(running_image_id)"
    [[ -n "$before" ]] && echo "→ ${before} is running now, and is what a failed verification returns to"
  fi

  deploy
  record_digest
  local rolled=false

  # A failure from here on is a deploy that landed and does not serve, which is
  # exactly the case rollback exists for. The original failure is reported
  # first, and reported whatever the rollback does — a rollback must never turn
  # a red run green.
  if wait_healthy && verify; then
    echo "rolled-back=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "→ deployed and verified"
    return 0
  fi

  if [[ "${INPUT_ROLLBACK,,}" != "true" ]]; then
    fail "the deploy landed and ${INPUT_HOST} does not serve it. The host is still running it, so its logs are there to read; set rollback: true to have the previous digest put back instead."
  fi

  if roll_back "$before"; then
    rolled=true
    if [[ -n "$INPUT_VERIFY_URL" ]]; then
      local deadline=$(( SECONDS + 60 ))
      while (( SECONDS < deadline )); do
        if curl -sS -m 15 "$INPUT_VERIFY_URL" > /dev/null 2>&1; then
          echo "→ rolled back to ${before}, and ${INPUT_VERIFY_URL} answers again"
          break
        fi
        sleep "$INPUT_VERIFY_INTERVAL"
      done
    fi
  fi
  echo "rolled-back=${rolled}" >> "${GITHUB_OUTPUT:-/dev/null}"
  fail "the deploy landed and ${INPUT_HOST} does not serve it. See the errors above for what the rollback did."
}

main "$@"
