#!/usr/bin/env bash
# Render tests for the fitness crew's model selection: the chart ships no Model and
# names no model server (the cluster's model catalog supplies the judge's model), and
# its CrewSchedulingPolicy requires reasoning, ranks by size through qualityBias, and
# reads nothing that changes between runs. Needs helm and yq.
# Run from anywhere: kubemoot-fitness-crew/tests/test-render.sh
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
render() {
  helm template t "$chart" "$@"
}
# csp EXPR [helm args...]: evaluates yq EXPR against the rendered CrewSchedulingPolicy.
csp() {
  local expr="$1"; shift
  render "$@" | yq -N -o=json -I=0 "select(.kind == \"CrewSchedulingPolicy\") | $expr"
}
# agent_env NAME VAR: the value of env VAR on Agent NAME.
agent_env() {
  yq -N "select(.kind == \"Agent\" and .metadata.name == \"$1\") | .spec.deployment.env[] | select(.name == \"$2\") | .value" <<<"$out"
}

out="$(render)"

# No Model, no model server, no retired label: the judge selects from the catalog.
models="$(yq -N 'select(.kind == "Model") | .metadata.name' <<<"$out")"
[ -z "$models" ] || fail "the chart renders Model objects: $models"
# A stale models value from an older install must not bring one back.
legacy="$(render --set 'models[0].name=x' --set 'models[0].model=x' --set 'models[0].serverRef=s' | yq -N 'select(.kind == "Model") | .metadata.name')"
[ -z "$legacy" ] || fail "a models value still renders a Model: $legacy"
! grep -q 'serverRef' <<<"$out" || fail "serverRef appears in the rendered chart"
! grep -qiE 'providerRef|modelprovider' <<<"$out" || fail "the rendered chart names a ModelProvider or providerRef"
! grep -q 'latencyClass' <<<"$out" || fail "latencyClass appears in the rendered chart"
! grep -q '^models:' "$chart/values.yaml" || fail "values.yaml still has models"
echo "PASS: no Model, serverRef, or latencyClass rendered"

# One policy; qualityBias 0.9 ranks large over medium over small.
[ "$(yq -N 'select(.kind == "CrewSchedulingPolicy") | .metadata.name' <<<"$out" | grep -c .)" = "1" ] || fail "expected exactly one CrewSchedulingPolicy"
[ "$(csp '.spec.crewRef')" = '"kubemoot-fitness"' ] || fail "crewRef changed"
bias="$(csp '.spec.qualityBias')"
[ "$bias" = '{"reasoning":"0.9","default":"0.9"}' ] || fail "qualityBias changed: $bias"
echo "PASS: qualityBias leans to the largest model"

# Every phase requires only reasoning and states no explicit preference, so the size
# score applies and nothing measured at run time (preferFaster) moves the pick.
phases="$(csp '.spec.rules[].phase' | tr -d '"' | paste -sd, -)"
[ "$phases" = "triage,mulling,synthesis" ] || fail "phases changed: $phases"
for phase in triage mulling synthesis; do
  rule="$(csp ".spec.rules[] | select(.phase == \"$phase\")")"
  [ "$(yq -N -o=json -I=0 '.require' <<<"$rule")" = '{"matchLabels":{"capability/reasoning":"true"}}' ] \
    || fail "$phase must require only capability/reasoning: $rule"
  [ "$(yq -N 'keys | sort | join(",")' <<<"$rule")" = "phase,require" ] \
    || fail "$phase must hold only phase and require (no prefer, preferFaster, or requireExpressions): $rule"
done
! grep -q 'kubemoot.ai/size' <<<"$out" || fail "no rule may require or prefer a size: a cluster without a large model must still run the judge"
echo "PASS: every phase requires reasoning, with no explicit preference"

# scheduling.requireLabels narrows every phase to the labeled catalog entry.
for phase in triage mulling synthesis; do
  got="$(csp ".spec.rules[] | select(.phase == \"$phase\") | .require.matchLabels" --set 'scheduling.requireLabels.kubemoot\.ai/fitness-judge=true')"
  [ "$got" = '{"capability/reasoning":"true","kubemoot.ai/fitness-judge":"true"}' ] || fail "$phase did not take requireLabels: $got"
done
# A value cannot drop the reasoning requirement.
got="$(csp '.spec.rules[0].require.matchLabels' --set-string 'scheduling.requireLabels.capability/reasoning=false')"
[ "$got" = '{"capability/reasoning":"true"}' ] || fail "requireLabels overrode capability/reasoning: $got"
# A non-string value renders as a string, as a label selector needs.
got="$(csp '.spec.rules[0].require.matchLabels.tier' --set 'scheduling.requireLabels.tier=1')"
[ "$got" = '"1"' ] || fail "a numeric requireLabels value must render as a string: $got"
echo "PASS: scheduling.requireLabels"

# Both agents keep to the bound model's score: no lower-scoring warm stand-in.
for agent in fitness-judge fitness-coordinator; do
  [ "$(agent_env "$agent" KUBEMOOT_MODEL_CANDIDATE_TOLERANCE)" = "0" ] || fail "$agent must set KUBEMOOT_MODEL_CANDIDATE_TOLERANCE to 0"
  [ "$(yq -N "select(.kind == \"Agent\" and .metadata.name == \"$agent\") | .spec.capabilities | join(\",\")" <<<"$out")" = "reasoning" ] \
    || fail "$agent must declare reasoning"
done
echo "PASS: both agents hold the candidate tolerance at 0"

helm lint "$chart" >/dev/null || fail "helm lint"
echo "PASS: helm lint"
