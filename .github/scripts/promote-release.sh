#!/usr/bin/env bash
# Promote the tested crew chart release candidates to public releases.
#
# main builds release candidates only: each crew chart X.Y.Z-rc.N goes to Harbor, and
# the homelab runs it. For every crew chart, this script takes the highest
# <crew>-vX.Y.Z-rc.N tag reachable from the starting point (RC_TAG, or the tip of main
# for "latest") that is not yet released, packages the chart from that tag's commit
# with the final version X.Y.Z and the Kubemoot image tags its tested candidate chart
# in Harbor ran (stamp-crew.sh, in a scratch worktree, never committed), pushes it to
# Harbor and the release registry, and tags the candidate's commit <crew>-vX.Y.Z.
# Every chart is packaged and checked before anything is pushed; all the tags are
# pushed together (atomic). Each promoted crew gets its own release
# notes (${OUT_DIR}/<crew>.md) and a line in ${OUT_DIR}/releases.tsv.
#
# A crew chart that pins a Kubemoot release candidate image is refused: promote
# Kubemoot first, then build a new crew candidate, which resolves Kubemoot's finals.
#
# Env:
#   RC_TAG            "latest" (default) or a release-candidate tag on main
#   DRY_RUN           "true" (default) plans and packages; pushes nothing, tags nothing
#   REGISTRY          Harbor host (charts at oci://${REGISTRY}/crews)
#   RELEASE_REGISTRY  registry plus namespace, e.g. ghcr.io/kubemoot (charts at .../charts)
#   GHCR_USERNAME, GHCR_TOKEN  (the caller logs helm in to Harbor)
#   CREWS             crew chart directories (default below)
#   OUT_DIR           where packaged charts and notes land (default: promotion)
#   RELEASE_LIB       release-lib.sh of kubemoot/release-actions (its actions set it)
set -euo pipefail

# shellcheck source=/dev/null
source "${RELEASE_LIB:?RELEASE_LIB must point to release-lib.sh from kubemoot/release-actions}"

RC_TAG="${RC_TAG:-latest}"
CREWS="${CREWS:-homelab-pilot-crew kubemoot-fitness-crew}"
OUT_DIR="$(mkdir -p "${OUT_DIR:-promotion}" && cd "${OUT_DIR:-promotion}" && pwd)"
: "${REGISTRY:?REGISTRY required}"
: "${RELEASE_REGISTRY:?RELEASE_REGISTRY required}"

here="$(cd "$(dirname "$0")" && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
trap rl_remove_worktrees EXIT

# candidate_values CREW RC_TAG: the path of the values.yaml the candidate chart in
# Harbor was packaged with, which holds the Kubemoot image tags the candidate ran.
candidate_values() {
  local crew="$1" rc_tag="$2" file
  file="$(mktemp)"
  helm show values --insecure-skip-tls-verify "oci://${REGISTRY}/crews/${crew}" \
    --version "${rc_tag#"${crew}-v"}" > "$file" \
    || die "cannot read the candidate chart ${crew} ${rc_tag#"${crew}-v"} from Harbor"
  printf '%s\n' "$file"
}

# package_crew CREW RC_TAG FINAL: the chart from the candidate's commit, stamped with the
# final version and the Kubemoot image tags of the tested candidate chart.
package_crew() {
  local crew="$1" rc_tag="$2" final="$3" wt candidate pins=()
  rl_checkout_at "$(git rev-list -n 1 "$rc_tag")"
  wt="$RL_CHECKOUT"
  if [ -n "$(rl_image_placeholders "${wt}/${crew}/values.yaml")" ]; then
    candidate="$(candidate_values "$crew" "$rc_tag")"
    pins=("$candidate")
  fi
  bash "${here}/stamp-crew.sh" "${wt}/${crew}" "${final}" "${pins[@]}"
  [ -z "${candidate:-}" ] || rm -f "$candidate"
  if grep -nE -- ':[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+' "${wt}/${crew}/values.yaml"; then
    die "${crew} at ${rc_tag} pins a release candidate image; promote Kubemoot first, then promote a crew candidate built after it"
  fi
  helm package "${wt}/${crew}" --destination "${OUT_DIR}"
}

push_chart() {
  local tgz="$1"
  echo "chart $(basename "$tgz")"
  rl_is_dry && return 0
  helm push --insecure-skip-tls-verify "$tgz" "oci://${REGISTRY}/crews"
  echo "${GHCR_TOKEN:?GHCR_TOKEN required}" | helm registry login "${RELEASE_REGISTRY%%/*}" -u "${GHCR_USERNAME:?GHCR_USERNAME required}" --password-stdin
  helm push "$tgz" "oci://${RELEASE_REGISTRY}/charts"
}

write_notes() {
  local crew="$1" final="$2" src="$3" prev="$4"
  {
    echo "Kubemoot crew chart ${crew} ${final}."
    echo
    echo '```bash'
    echo "helm install ${crew} oci://${RELEASE_REGISTRY}/charts/${crew} --version ${final}"
    echo '```'
    echo
    rl_notes_document "$prev" "$src" "${crew}-v${final}" "$crew"
  } > "${OUT_DIR}/${crew}.md"
}

# promote_crew CREW POINT: package the crew's latest unreleased candidate, if any, and
# record its final tag and release. Nothing is pushed here.
promote_crew() {
  local crew="$1" point="$2" prefix rc_tag final src prev
  prefix="${crew}-v"
  rc_tag=$(rl_latest_rc "$prefix" "$point")
  if [ -z "$rc_tag" ]; then echo "${crew}: no release candidate"; return 0; fi
  final=$(rl_final_of "${rc_tag#"$prefix"}")
  if rl_tag_exists "${prefix}${final}"; then echo "${crew}: ${prefix}${final} already released"; return 0; fi
  src=$(git rev-list -n 1 "$rc_tag")
  prev=$(rl_latest_final "$prefix" "$src")
  echo "${crew}: ${rc_tag} -> ${prefix}${final}"
  package_crew "$crew" "$rc_tag" "$final"
  rl_make_tag "${prefix}${final}" "$rc_tag"
  write_notes "$crew" "$final" "$src" "$prev"
  rl_add_release "${OUT_DIR}" "${prefix}${final}" "${crew} ${final}" "${crew}.md"
}

main() {
  local point crew tgz
  point=$(rl_resolve_point "$RC_TAG")
  echo "Promoting crew charts from ${RC_TAG} (commit ${point}); dry run: ${DRY_RUN:-true}"
  : > "${OUT_DIR}/releases.tsv"
  for crew in ${CREWS}; do
    promote_crew "$crew" "$point"
  done
  [ "${#RL_NEW_TAGS[@]}" -gt 0 ] || die "nothing to promote: every crew's latest candidate is already released"
  # Every chart is packaged and checked before the first push.
  for tgz in "${OUT_DIR}"/*.tgz; do
    push_chart "$tgz"
  done
  rl_push_new_tags
}

main "$@"
