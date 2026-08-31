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
trap cleanup EXIT

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

# What is actually running, by digest, so the log records the bytes rather than
# a tag that can move under it.
record_digest() {
  local digest=""
  if [[ -n "$INPUT_IMAGE" ]]; then
    digest="$(remote "docker image inspect --format '{{index .RepoDigests 0}}' $(printf '%q' "$INPUT_IMAGE")" 2>/dev/null || true)"
  fi
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
      unhealthy) fail "${INPUT_WAIT_HEALTHY} reports unhealthy: the deploy landed and the container refuses to serve" ;;
    esac
    sleep "$INPUT_VERIFY_INTERVAL"
  done
  fail "${INPUT_WAIT_HEALTHY} never reported healthy within ${INPUT_HEALTH_TIMEOUT}s (last state: ${state})"
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
  fail "${INPUT_VERIFY_URL} did not serve what was deployed within ${INPUT_VERIFY_TIMEOUT}s (last status: ${status:-no answer}). The deploy reached the host, so what failed is the host serving it: read the container's logs."
}

main() {
  require host "$INPUT_HOST"
  require ssh-key "$INPUT_SSH_KEY"
  if [[ -z "$INPUT_REMOTE_COMMAND" && -z "$INPUT_COMPOSE_FILE" ]]; then
    fail "give either compose-file (with image) or remote-command; there is nothing to deploy otherwise"
  fi
  if [[ -n "$INPUT_REMOTE_COMMAND" && -n "$INPUT_COMPOSE_FILE" ]]; then
    fail "compose-file and remote-command are mutually exclusive: two deploy paths in one run is one too many"
  fi

  prepare_ssh
  deploy
  record_digest
  wait_healthy
  verify
  echo "→ deployed and verified"
}

main "$@"
