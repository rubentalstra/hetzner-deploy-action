#!/usr/bin/env bash
# What the Marketplace requires of action.yml, checked here rather than at the
# publish click.
#
# Every rule below was learned the way rules get learned: the publish UI refused
# the listing and named one. A check that lives in CI turns that into a red pull
# request instead of a surprise at release time.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "::error::$*" >&2; exit 1; }

# The three keys the metadata reference marks required.
for key in name description runs; do
  grep -qE "^${key}:" action.yml || fail "action.yml has no top-level '${key}'"
done

# Read through a YAML parser rather than by grep: the description may be a
# folded block, and its LENGTH is what the Marketplace measures.
python3 - <<'PY'
import sys, yaml

meta = yaml.safe_load(open("action.yml"))
errors = []

description = meta.get("description", "")
if len(description) >= 125:
    errors.append(
        f"description is {len(description)} characters; the Marketplace requires "
        "fewer than 125. The long version belongs in the README."
    )
if not description.strip():
    errors.append("description is empty")

name = meta.get("name", "")
if not name.strip():
    errors.append("name is empty")
if len(name) > 60:
    errors.append(f"name is {len(name)} characters, which is longer than any listing shows")

branding = meta.get("branding") or {}
allowed = {
    "white", "black", "yellow", "blue", "green", "orange", "red", "purple",
    "gray-dark",
}
if branding.get("color") not in allowed:
    errors.append(
        f"branding.color is {branding.get('color')!r}; the metadata reference "
        f"allows only {sorted(allowed)}"
    )
# The thirteen Feather icons the reference says are unavailable.
omitted = {
    "coffee", "columns", "divide-circle", "divide-square", "divide", "frown",
    "hexagon", "key", "meh", "mouse-pointer", "smile", "tool", "x-octagon",
}
icon = branding.get("icon")
if not icon:
    errors.append("branding.icon is missing")
elif icon in omitted:
    errors.append(f"branding.icon {icon!r} is one of the icons the reference says is unavailable")

runs = meta.get("runs") or {}
if runs.get("using") != "composite":
    errors.append(f"runs.using is {runs.get('using')!r}, and this action is composite")
for name_, spec in (meta.get("inputs") or {}).items():
    if not (spec or {}).get("description", "").strip():
        errors.append(f"input {name_!r} has no description")
for name_, spec in (meta.get("outputs") or {}).items():
    if not (spec or {}).get("description", "").strip():
        errors.append(f"output {name_!r} has no description")
    # A composite action's outputs need an explicit value expression.
    if "value" not in (spec or {}):
        errors.append(f"output {name_!r} has no value; a composite action's outputs need one")

for e in errors:
    print(f"::error::{e}", file=sys.stderr)
sys.exit(1 if errors else 0)
PY

echo "action.yml is what the Marketplace requires — OK."
