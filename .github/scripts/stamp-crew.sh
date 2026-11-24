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
#                      release candidate build) each image gets Kubemoot's newest
#                      candidate: the highest <image>-vX.Y.Z-rc.N tag, or the final
#                      <image>-vX.Y.Z once it exists. A candidate chart lives in Harbor
#                      only, so it may run candidates; Publish Release maps them to finals.
# Images the crews repository builds itself (CREW_OWN_IMAGES, default oguide-search) are stamped
# first, as NAME@sha256:<digest>: a candidate build reads the digest of OWN_IMAGE_REGISTRY/NAME:VERSION
# (the image the release built and tagged with the chart's version); a final release takes the
# digest its tested candidate chart pinned. A chart whose values hold NAME:0.0.0 for such an image
# and a build with neither is refused, so an unstamped image never ships. A candidate build also
# writes OWN_IMAGE_REGISTRY into global.crewImageRegistry, so the chart pulls the image from where it
# was built (not from global.imageRegistry, which names Kubemoot's images); a final keeps git's value,
# the release registry Publish Release copies the image to.
# Env:
#   OWN_IMAGE_REGISTRY registry path of the images this repository builds, e.g. harbor/crews
#   CREW_OWN_IMAGES    names of those images (default "oguide-search")
#   RL_DIGEST_CMD      reads a digest from an image reference (default "crane digest --insecure")
#   KUBEMOOT_PINS      "final" makes a candidate build take only final Kubemoot tags
#                      (default "candidate")
#   KUBEMOOT_REMOTE    Kubemoot's repository (default https://github.com/kubemoot/kubemoot.git)
#   RELEASE_LIB        release-lib.sh of kubemoot/release-actions (its actions set it)
set -euo pipefail

# shellcheck source=/dev/null
source "${RELEASE_LIB:?RELEASE_LIB must point to release-lib.sh from kubemoot/release-actions}"

chart_dir="${1:?usage: stamp-crew.sh CHART_DIR VERSION [CANDIDATE_VALUES]}"
version="${2:?usage: stamp-crew.sh CHART_DIR VERSION [CANDIDATE_VALUES]}"
candidate_values="${3:-}"
kubemoot_remote="${KUBEMOOT_REMOTE:-https://github.com/kubemoot/kubemoot.git}"
kubemoot_pins="${KUBEMOOT_PINS:-candidate}"
case "${kubemoot_pins}" in
  candidate | final) ;;
  *) echo "ERROR: KUBEMOOT_PINS is candidate or final, not [${kubemoot_pins}]" >&2; exit 1 ;;
esac

die() { echo "ERROR: $*" >&2; exit 1; }

# own_digest_ref NAME: NAME@sha256:<digest> for an image this repository built: the one the
# tested candidate chart pinned, or the digest of OWN_IMAGE_REGISTRY/NAME:VERSION.
own_digest_ref() {
  local name="$1" refs digest
  if [ -n "${candidate_values}" ]; then
    refs="$({ grep -oE "(^|[\"' /])${name}@sha256:[0-9a-f]{64}" "${candidate_values}" || true; } \
      | sed -E "s/^[\"' \/]//" | sort -u)"
    [ -n "${refs}" ] && [ "$(wc -l <<<"${refs}")" -eq 1 ] \
      || die "the candidate chart must pin ${name} by one digest, has [${refs//$'\n'/ }]"
    printf '%s\n' "${refs}"
    return 0
  fi
  [ -n "${OWN_IMAGE_REGISTRY:-}" ] || die "OWN_IMAGE_REGISTRY is required to stamp ${name}"
  # shellcheck disable=SC2086 # the command is a word list on purpose
  digest="$(${RL_DIGEST_CMD:-crane digest --insecure} "${OWN_IMAGE_REGISTRY}/${name}:${version}")" \
    || die "cannot read the digest of ${OWN_IMAGE_REGISTRY}/${name}:${version}; the release builds it before the chart"
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "not a digest: [${digest}]"
  printf '%s@%s\n' "${name}" "${digest}"
}

# stamp_own_images VALUES: writes the digest reference over each NAME:0.0.0 of an own image.
stamp_own_images() {
  local values="$1" name ref stamped_own=""
  for name in ${CREW_OWN_IMAGES:-oguide-search}; do
    rl_image_placeholders "${values}" | grep -qxF -- "${name}" || continue
    ref="$(own_digest_ref "${name}")" || exit 1
    sed -E -i "s#${RL_IMAGE_BEFORE}${name}:0\.0\.0${RL_IMAGE_AFTER}#\1${ref}\2#g" "${values}"
    echo "Stamped ${values}: ${ref}" >&2
    stamped_own=1
  done
  if [ -n "${stamped_own:-}" ] && [ -z "${candidate_values}" ]; then
    grep -qE '^  crewImageRegistry: ' "${values}" || die "${values} has no global.crewImageRegistry to stamp"
    sed -E -i "s#^(  crewImageRegistry:) .*#\\1 ${OWN_IMAGE_REGISTRY}#" "${values}"
    echo "Stamped ${values}: crewImageRegistry ${OWN_IMAGE_REGISTRY}" >&2
  fi
}

rl_stamp_chart "${chart_dir}" "${version}"
stamp_own_images "${chart_dir}/values.yaml"
if [ -n "${candidate_values}" ]; then
  rl_stamp_images_like "${chart_dir}/values.yaml" "${candidate_values}"
elif [ "${kubemoot_pins}" = final ]; then
  rl_stamp_remote_images "${chart_dir}/values.yaml" "${kubemoot_remote}"
else
  rl_stamp_remote_candidate_images "${chart_dir}/values.yaml" "${kubemoot_remote}"
fi
grep -E '^(version|appVersion):' "${chart_dir}/Chart.yaml"
