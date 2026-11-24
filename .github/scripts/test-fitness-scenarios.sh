#!/usr/bin/env bash
# Tests that each crew chart deploys its fitness scenarios as one labeled ConfigMap by
# default, so CrewForge and the dashboard list them without running anything, and that
# it renders no CrewFitness or CrewFitnessSuite (either would start a run on install).
# Usage: bash .github/scripts/test-fitness-scenarios.sh   (exit 0 = all passed)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"
command -v helm >/dev/null || { echo "helm is required"; exit 1; }
command -v yq >/dev/null || { echo "yq is required"; exit 1; }

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi
}
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# render <chart dir> [helm args...]: the chart's manifests with default values.
render() {
  local chart="$1"; shift
  helm template t "$chart" -n crew-test --set vectorStore.host=db "$@"
}
# scenario_maps <manifests>: the ConfigMaps labeled as fitness scenarios.
scenario_maps() {
  yq 'select(.kind == "ConfigMap" and .metadata.labels."kubemoot.ai/fitness-kind" == "scenarios")' <<<"$1"
}
# scenario_files <chart dir>: the scenario files under fitness/, sorted.
scenario_files() {
  find "$1/fitness" -maxdepth 1 -type f \( -name '*.adl' -o -name '*.md' \) ! -name README.md -printf '%f\n' | sort
}

declare -A crew_names=([homelab-pilot-crew]=homelab-pilot [kubemoot-fitness-crew]=kubemoot-fitness [oguide-crew]=oguide)
for chart in homelab-pilot-crew kubemoot-fitness-crew oguide-crew; do
  crew="${crew_names[$chart]}"
  out="$(render "${repo}/${chart}")"
  maps="$(scenario_maps "$out")"
  check "${chart} renders one scenarios ConfigMap by default" 1 "$(yq -N '.metadata.name' <<<"$maps" | grep -c . || true)"
  check "${chart} names it <crew>-fitness" "${crew}-fitness" "$(yq -N '.metadata.name' <<<"$maps")"
  check "${chart} labels it with the crew" "$crew" "$(yq -N '.metadata.labels."kubemoot.ai/crew"' <<<"$maps")"
  check "${chart} puts it in the release namespace" crew-test "$(yq -N '.metadata.namespace' <<<"$maps")"
  check "${chart} holds one key per scenario file" "$(scenario_files "${repo}/${chart}" | tr '\n' ' ')" \
    "$(yq -N '.data | keys | .[]' <<<"$maps" | sort | tr '\n' ' ')"
  check "${chart} leaves fitness/README.md out" "false" "$(yq -N '.data | has("README.md")' <<<"$maps")"
  first="$(scenario_files "${repo}/${chart}" | head -1)"
  check "${chart} keeps ${first} byte for byte" "$(sha256sum < "${repo}/${chart}/fitness/${first}")" \
    "$(yq -N ".data.\"${first}\"" <<<"$maps" | head -c -1 | sha256sum)"
  check "${chart} renders no fitness run" 0 \
    "$(yq -N 'select(.kind == "CrewFitness" or .kind == "CrewFitnessSuite") | .metadata.name' <<<"$out" | grep -c . || true)"
  check "${chart} lints" 0 "$(helm lint "${repo}/${chart}" --set vectorStore.host=db >/dev/null 2>&1; echo $?)"
done

# A renamed crew renames and relabels the ConfigMap.
maps="$(scenario_maps "$(render "${repo}/homelab-pilot-crew" --set crew.name=other)")"
check "a renamed crew renames the ConfigMap" other-fitness "$(yq -N '.metadata.name' <<<"$maps")"
check "a renamed crew relabels the ConfigMap" other "$(yq -N '.metadata.labels."kubemoot.ai/crew"' <<<"$maps")"

# The removed toggle no longer turns scenarios into runs.
out="$(render "${repo}/homelab-pilot-crew" --set fitness.deployBaselineScenarios=true)"
check "the old toggle renders no fitness run" 0 \
  "$(yq -N 'select(.kind == "CrewFitness") | .metadata.name' <<<"$out" | grep -c . || true)"
check "the old toggle is gone from values" "" "$(grep -rn deployBaselineScenarios "${repo}"/*/values.yaml "${repo}"/*/templates || true)"

# A prose scenario (.md) is carried like an ADL one; other files are not.
cp -r "${repo}/homelab-pilot-crew" "${root}/chart"
printf 'DESCRIPTION A prose scenario.\n' > "${root}/chart/fitness/prose-check.md"
printf 'not a scenario\n' > "${root}/chart/fitness/notes.txt"
maps="$(scenario_maps "$(render "${root}/chart")")"
check "carries a .md scenario" "DESCRIPTION A prose scenario." "$(yq -N '.data."prose-check.md"' <<<"$maps")"
check "skips a file that is not a scenario" "false" "$(yq -N '.data | has("notes.txt")' <<<"$maps")"

# A chart with no scenarios still renders the ConfigMap, empty.
rm -f "${root}/chart/fitness/"*
maps="$(scenario_maps "$(render "${root}/chart")")"
check "an empty fitness/ renders the ConfigMap" "${crew_names[homelab-pilot-crew]}-fitness" "$(yq -N '.metadata.name' <<<"$maps")"
check "an empty fitness/ holds no scenario" 0 "$(yq -N '.data // {} | length' <<<"$maps")"

# Tiers: a scenario names the tiers it belongs to in DEFINE CONST TIERS AS "smoke standard". The
# operator reads the label from the ConfigMap's scenarios, so a typo would shrink a tier or stop a
# suite, and a changed tier would make runs of that tier incomparable. Checked on the rendered ConfigMap.
# tier_members <manifests> <tier>: the scenarios (file names without extension) that name the tier, sorted.
tier_members() {
  local key
  while read -r key; do
    if yq -N ".data.\"${key}\"" <<<"$(scenario_maps "$1")" | grep -E '^DEFINE CONST TIERS AS ' | grep -qwF -- "$2"; then
      echo "${key%.*}"
    fi
  done < <(yq -N '.data | keys | .[]' <<<"$(scenario_maps "$1")") | sort
}
# tier_words <manifests>: every word of every TIERS label, sorted and unique.
tier_words() {
  local key
  while read -r key; do
    yq -N ".data.\"${key}\"" <<<"$(scenario_maps "$1")" | sed -n 's/^DEFINE CONST TIERS AS "\(.*\)"$/\1/p' | tr ', ' '\n'
  done < <(yq -N '.data | keys | .[]' <<<"$(scenario_maps "$1")") | sed '/^$/d' | sort -u
}

pilot="$(render "${repo}/homelab-pilot-crew")"
check "the pilot's TIERS labels use only smoke and standard" "smoke standard" "$(tier_words "$pilot" | tr '\n' ' ' | sed 's/ $//')"
# The standard tier is the 16 gate scenarios, as it was before tiers existed, so past results stay comparable.
check "the pilot's standard tier is the 16 gate scenarios" \
  "constraint-exclude-system-ns constraint-format-scoped-list constraint-topn-table constraint-units-and-rounding gotcha-false-attribution-restart k8s-configmap-secret-inventory k8s-daemonset-coverage k8s-helm-releases k8s-jobs-cronjobs k8s-metrics-top-consumers k8s-networkpolicy-coverage k8s-nodes-capacity k8s-pod-errors-clusterwide k8s-pod-status proxmox-vm-list smoke-cluster-namespaces" \
  "$(tier_members "$pilot" standard | tr '\n' ' ' | sed 's/ $//')"
smoke="$(tier_members "$pilot" smoke)"
smoke_count="$(grep -c . <<<"$smoke" || true)"
check "the pilot's smoke tier has 6 to 10 scenarios" yes "$([ "$smoke_count" -ge 6 ] && [ "$smoke_count" -le 10 ] && echo yes || echo no)"
# Each path a smoke run exists to take has a scenario that takes it.
check "pilot smoke: a gotcha question" yes "$(grep -q '^gotcha-' <<<"$smoke" && echo yes || echo no)"
check "pilot smoke: a concept question answered with no live tool" yes "$(grep -q -- '-concept-' <<<"$smoke" && echo yes || echo no)"
check "pilot smoke: a question that engages the compute agent" yes "$(grep -q '^constraint-' <<<"$smoke" && echo yes || echo no)"
check "pilot smoke: a second tool domain (Proxmox)" yes "$(grep -q '^proxmox-' <<<"$smoke" && echo yes || echo no)"
check "pilot smoke: a Prometheus question" yes "$(grep -q '^obs-' <<<"$smoke" && echo yes || echo no)"
check "pilot smoke: a question no specialist answers" yes "$(grep -q '^smoke-greeting$' <<<"$smoke" && echo yes || echo no)"
for chart in kubemoot-fitness-crew oguide-crew; do
  words="$(tier_words "$(render "${repo}/${chart}")" | grep -vxE 'smoke|standard' || true)"
  check "${chart} TIERS labels use only smoke and standard" "" "$words"
done

if [ "$failures" -ne 0 ]; then echo "${failures} test(s) failed"; exit 1; fi
echo "all fitness-scenario tests passed"
