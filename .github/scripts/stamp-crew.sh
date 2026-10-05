#!/usr/bin/env bash
# Stamp the versions a crew chart is packaged with. Git holds 0.0.0 for the chart's
# version and appVersion and for the tag of every Kubemoot image in values.yaml; this
# writes the real versions into the working copy before `helm package` and never
# commits them.
#
# Usage: stamp-crew.sh CHART_DIR VERSION [CANDIDATE_VALUES]
#   VERSION            the chart version (X.Y.Z-rc.N for a candidate, X.Y.Z for a final)
#   CANDIDATE_VALUES   final release: the values.yaml of the tested candidate chart; each
#                      Kubemoot image gets the tag the candidate ran. Without it (a
#                      release candidate build) each image gets the latest final
#                      <image>-vX.Y.Z tag of Kubemoot.
# Env:
#   KUBEMOOT_REMOTE    Kubemoot's repository (default https://github.com/kubemoot/kubemoot.git)
#   RELEASE_LIB        release-lib.sh of kubemoot/release-actions (its actions set it)
set -euo pipefail

# shellcheck source=/dev/null
source "${RELEASE_LIB:?RELEASE_LIB must point to release-lib.sh from kubemoot/release-actions}"

chart_dir="${1:?usage: stamp-crew.sh CHART_DIR VERSION [CANDIDATE_VALUES]}"
version="${2:?usage: stamp-crew.sh CHART_DIR VERSION [CANDIDATE_VALUES]}"
candidate_values="${3:-}"
kubemoot_remote="${KUBEMOOT_REMOTE:-https://github.com/kubemoot/kubemoot.git}"

rl_stamp_chart "${chart_dir}" "${version}"
if [ -n "${candidate_values}" ]; then
  rl_stamp_images_like "${chart_dir}/values.yaml" "${candidate_values}"
else
  rl_stamp_remote_images "${chart_dir}/values.yaml" "${kubemoot_remote}"
fi
grep -E '^(version|appVersion):' "${chart_dir}/Chart.yaml"
