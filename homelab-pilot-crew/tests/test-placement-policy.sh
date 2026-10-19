#!/usr/bin/env bash
# Render tests for the crew's CrewSchedulingPolicy: the placement policy value, the
# per-phase model selection rules, and that the chart ships no Model of its own (the
# cluster's model catalog supplies them). Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-placement-policy.sh
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
render() {
  helm template t "$chart" --set ragSources.enabled=false --set vectorStore.host=db.test "$@"
}
policy() {
  render "$@" | yq -N 'select(.kind == "CrewSchedulingPolicy") | .spec.placementPolicy'
}
# rule PHASE EXPR: evaluates yq EXPR against the rule for PHASE.
rule() {
  render | yq -N -o=json "select(.kind == \"CrewSchedulingPolicy\") | .spec.rules[] | select(.phase == \"$1\") | $2"
}

# Placement policy.
[ "$(policy)" = "null" ] || fail "an empty value should leave placementPolicy unset, so the crew inherits the default"
for mode in algorithm learned shadow; do
  [ "$(policy --set "crew.placementPolicy=$mode")" = "$mode" ] || fail "placementPolicy $mode not rendered"
done
echo "PASS: placement policy render tests"

# The chart ships no Model, so the crew selects from the cluster's catalog.
out="$(render)"
models="$(yq -N 'select(.kind == "Model") | .metadata.name' <<<"$out")"
[ -z "$models" ] || fail "the chart renders Model objects: $models"
# A stale models value from an older install must not bring one back.
legacy="$(render --set 'models[0].name=x' --set 'models[0].model=x' --set 'models[0].providerRef=p' | yq -N 'select(.kind == "Model") | .metadata.name')"
[ -z "$legacy" ] || fail "a models value still renders a Model: $legacy"
! grep -q 'latencyClass' <<<"$out" || fail "latencyClass appears in the rendered chart"
[ "$(yq -N 'select(.kind == "CrewSchedulingPolicy") | .metadata.name' <<<"$out" | grep -c .)" = "1" ] || fail "expected exactly one CrewSchedulingPolicy"
echo "PASS: no Model and no latencyClass rendered"

# Mulling: tool-calling is a hard need; size follows qualityBias, so no prefer and no speed term.
[ "$(rule mulling '.require.matchLabels["capability/tool-calling"]')" = '"true"' ] || fail "mulling must require capability/tool-calling"
[ "$(rule mulling '.require.matchLabels | length')" = "1" ] || fail "mulling must require only capability/tool-calling"
[ "$(rule mulling '.prefer')" = "null" ] || fail "mulling must have no prefer block, so qualityBias applies"
[ "$(rule mulling '.preferFaster')" = "null" ] || fail "mulling must not set preferFaster"
bias="$(render | yq -N -o=json -I=0 'select(.kind == "CrewSchedulingPolicy") | .spec.qualityBias')"
[ "$bias" = '{"reasoning":"0.7","tool-calling":"0.5","observability":"0.4","kubernetes":"0.4","default":"0.4"}' ] || fail "qualityBias changed: $bias"
echo "PASS: mulling rule"

# Triage: tool-calling is a hard need, speed is the wish, and size plays no part.
[ "$(rule triage '.require.matchLabels["capability/tool-calling"]')" = '"true"' ] || fail "triage must require capability/tool-calling"
[ "$(rule triage '.require.matchLabels | length')" = "1" ] || fail "triage must require only capability/tool-calling"
[ "$(rule triage '.preferFaster')" = "50" ] || fail "triage must set preferFaster 50"
# The one prefer term matches every model the rule admits (it repeats the require), so it
# ranks nothing and only turns off the qualityBias and ability scores for triage.
[ "$(rule triage '.prefer | length')" = "1" ] || fail "triage must have exactly one prefer term"
[ "$(rule triage '(.prefer[0].selector.matchLabels | to_json(0)) == (.require.matchLabels | to_json(0))')" = "true" ] || fail "the triage prefer term must match exactly what require admits"
triage="$(rule triage '.')"
! grep -q 'kubemoot.ai/size' <<<"$triage" || fail "triage must not select on size"
echo "PASS: triage rule"
