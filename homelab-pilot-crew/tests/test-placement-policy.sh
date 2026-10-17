#!/usr/bin/env bash
# Render test for the crew's placement policy value. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-placement-policy.sh
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
policy() {
  helm template t "$chart" --set ragSources.enabled=false --set vectorStore.host=db.test "$@" | yq -N 'select(.kind == "CrewSchedulingPolicy") | .spec.placementPolicy'
}

[ "$(policy)" = "null" ] || fail "an empty value should leave placementPolicy unset, so the crew inherits the default"
for mode in algorithm learned shadow; do
  [ "$(policy --set "crew.placementPolicy=$mode")" = "$mode" ] || fail "placementPolicy $mode not rendered"
done
echo "PASS: placement policy render tests"
