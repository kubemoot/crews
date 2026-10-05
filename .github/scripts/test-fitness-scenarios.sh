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

declare -A crew_names=([homelab-pilot-crew]=homelab-pilot [kubemoot-fitness-crew]=kubemoot-fitness)
for chart in homelab-pilot-crew kubemoot-fitness-crew; do
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

if [ "$failures" -ne 0 ]; then echo "${failures} test(s) failed"; exit 1; fi
echo "all fitness-scenario tests passed"
