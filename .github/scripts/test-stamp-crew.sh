#!/usr/bin/env bash
# Tests for stamp-crew.sh and for the version rule in this repository: every crew chart
# in git holds 0.0.0, its Kubemoot images carry no typed version, and no release
# workflow commits a version back. Stamps copies of the real crew charts against a
# throwaway Kubemoot remote and checks what `helm template` renders.
# Usage: RELEASE_LIB=<release-actions>/release-lib.sh bash .github/scripts/test-stamp-crew.sh
#        (exit 0 = all passed; in CI the release-actions setup action sets RELEASE_LIB)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"
command -v helm >/dev/null || { echo "helm is required"; exit 1; }
[ -f "${RELEASE_LIB:-}" ] || { echo "RELEASE_LIB must point to release-lib.sh from kubemoot/release-actions"; exit 1; }
# shellcheck source=/dev/null
source "${RELEASE_LIB}"

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi
}
crews=(homelab-pilot-crew kubemoot-fitness-crew oguide-crew)

# The rule as git holds it.
for crew in "${crews[@]}"; do
  check "${crew} Chart.yaml holds 0.0.0" "0.0.0|0.0.0" \
    "$(sed -n 's/^version: //p' "${repo}/${crew}/Chart.yaml")|$(sed -n 's/^appVersion: //p' "${repo}/${crew}/Chart.yaml")"
  # A bare image name is a Kubemoot-built image (global.imageRegistry is prefixed); its
  # tag in git is 0.0.0, never a typed X.Y.Z.
  check "${crew} types no Kubemoot image version" "" \
    "$(grep -nE '^\s*image:\s*"?[a-z0-9][a-z0-9._-]*:[0-9]+\.[0-9]+\.[0-9]+' "${repo}/${crew}/values.yaml" | grep -v ':0\.0\.0' || true)"
  check "${crew} pins no Kubemoot image by commit" "" \
    "$(grep -nE '^\s*image:\s*"?[a-z0-9][a-z0-9._-]*:[0-9a-f]{40}"?\s*$' "${repo}/${crew}/values.yaml" || true)"
  check "${crew} release workflow commits nothing" "" \
    "$(grep -nE 'git (commit|add|reset|pull)|HEAD:main|\[skip ci\]' "${repo}/.github/workflows/${crew}-release.yaml" || true)"
  # shellcheck disable=SC2016 # the workflow text itself, not an expansion
  check "${crew} release workflow stamps at build" "1" \
    "$(grep -c 'stamp-crew.sh "\${CHART_PATH}" "\${VERSION}"' "${repo}/.github/workflows/${crew}-release.yaml")"
  # shellcheck disable=SC2016 # the workflow text itself, not an expansion
  check "${crew} release workflow tags the built commit" "1" \
    "$(grep -c 'git tag -a "\$TAG" -m "Release candidate \$TAG" "\${GITHUB_SHA}"' "${repo}/.github/workflows/${crew}-release.yaml")"
  # Kubemoot's Publish Release sends exactly this event; a dispatch with no listener
  # succeeds and builds nothing, so the name must match on both sides.
  check "${crew} release workflow listens for kubemoot-published" "1" \
    "$(grep -cE '^[[:space:]]+types: \[kubemoot-published\]$' "${repo}/.github/workflows/${crew}-release.yaml")"
  # shellcheck disable=SC2016 # the workflow text itself, not an expansion
  check "${crew} release workflow forces the candidate on that event" "1" \
    "$(grep -cF "force: \${{ inputs.force_release || github.event_name == 'repository_dispatch' }}" "${repo}/.github/workflows/${crew}-release.yaml")"
done
check "the pilot crews pin Kubemoot images as placeholders" "artifact-access code-sandbox scheduling-mcp" \
  "$(rl_image_placeholders "${repo}/homelab-pilot-crew/values.yaml" | tr '\n' ' ' | sed 's/ $//')"
check "O'guide pins no Kubemoot image (its read-ops server selects the operator's)" "" \
  "$(rl_image_placeholders "${repo}/oguide-crew/values.yaml" | tr '\n' ' ' | sed 's/ $//')"

# A throwaway Kubemoot with final and candidate tags.
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git init -q -b main "${root}/kubemoot"
git -C "${root}/kubemoot" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
for t in code-sandbox-v0.14.4 code-sandbox-v0.17.0 code-sandbox-v0.18.0-rc.126 \
  artifact-access-v0.342.1 artifact-access-v0.343.0 artifact-access-v0.344.0-rc.126 \
  scheduling-mcp-v0.1.0 scheduling-mcp-v0.2.0-rc.3 v0.99.0; do
  git -C "${root}/kubemoot" tag "$t"
done
git clone -q --bare "${root}/kubemoot" "${root}/kubemoot.git"
export KUBEMOOT_REMOTE="${root}/kubemoot.git"

stamp() { bash "${here}/stamp-crew.sh" "$@" > "${root}/stamp.log" 2>&1; }
copy_crew() { rm -rf "${root:?}/${1:?}"; cp -r "${repo}/$1" "${root}/$1"; }
# rendered_images CREW: the images the stamped copy renders. The pilot needs its database
# host, and its scheduling server enabled so all three Kubemoot images render.
rendered_images() {
  local args=()
  if [ "$1" = homelab-pilot-crew ]; then
    args=(--set vectorStore.host=db --set mcpServers.scheduling.enabled=true)
  fi
  helm template t "${root}/$1" "${args[@]}" | sed -n 's/^ *image: //p' | tr -d '"' | sort -u
}

# A release candidate build: chart version and Kubemoot's newest candidate images (an rc
# newer than the last final; the final once it exists).
copy_crew homelab-pilot-crew
stamp "${root}/homelab-pilot-crew" 0.47.0-rc.4 && status=0 || status=$?
check "candidate stamp succeeds" 0 "$status"
[ "$status" -eq 0 ] || sed 's/^/    /' "${root}/stamp.log"
check "candidate chart version" "0.47.0-rc.4|0.47.0-rc.4" \
  "$(sed -n 's/^version: //p' "${root}/homelab-pilot-crew/Chart.yaml")|$(sed -n 's/^appVersion: //p' "${root}/homelab-pilot-crew/Chart.yaml")"
images="$(rendered_images homelab-pilot-crew)"
check "renders the newest candidate code-sandbox" 1 "$(grep -cx 'ghcr.io/kubemoot/code-sandbox:0.18.0-rc.126' <<<"$images")"
check "renders the newest candidate artifact-access" 1 "$(grep -cx 'ghcr.io/kubemoot/artifact-access:0.344.0-rc.126' <<<"$images")"
check "renders the newest candidate scheduling-mcp" 1 "$(grep -cx 'ghcr.io/kubemoot/scheduling-mcp:0.2.0-rc.3' <<<"$images")"
check "renders no 0.0.0 Kubemoot image" 0 "$(grep -cE 'kubemoot/[a-z-]+:0\.0\.0' <<<"$images" || true)"
check "the stamped chart lints" 0 "$(helm lint "${root}/homelab-pilot-crew" >/dev/null 2>&1; echo $?)"
check "the repository copy is untouched" "0.0.0" "$(sed -n 's/^version: //p' "${repo}/homelab-pilot-crew/Chart.yaml")"

# A final release: the final version and the image tags the candidate chart ran, even when
# Kubemoot has released newer finals since.
cp "${root}/homelab-pilot-crew/values.yaml" "${root}/candidate-values.yaml"
git -C "${root}/kubemoot" tag code-sandbox-v0.19.0
git -C "${root}/kubemoot" push -q "${root}/kubemoot.git" code-sandbox-v0.19.0
copy_crew homelab-pilot-crew
stamp "${root}/homelab-pilot-crew" 0.47.0 "${root}/candidate-values.yaml" && status=0 || status=$?
check "final stamp succeeds" 0 "$status"
images="$(rendered_images homelab-pilot-crew)"
check "final keeps the candidate's code-sandbox" 1 "$(grep -cx 'ghcr.io/kubemoot/code-sandbox:0.18.0-rc.126' <<<"$images")"
check "final chart version" "0.47.0" "$(sed -n 's/^appVersion: //p' "${root}/homelab-pilot-crew/Chart.yaml")"
copy_crew homelab-pilot-crew
stamp "${root}/homelab-pilot-crew" 0.47.1-rc.0 && status=0 || status=$?
check "a final newer than the rc supersedes it" 1 "$(rendered_images homelab-pilot-crew | grep -cx 'ghcr.io/kubemoot/code-sandbox:0.19.0')"
# The final of the same base outranks that base's candidates (0.21.0 above 0.21.0-rc.N).
git -C "${root}/kubemoot" tag code-sandbox-v0.20.0-rc.9
git -C "${root}/kubemoot" tag code-sandbox-v0.20.0
git -C "${root}/kubemoot" push -q "${root}/kubemoot.git" code-sandbox-v0.20.0-rc.9 code-sandbox-v0.20.0
copy_crew homelab-pilot-crew
stamp "${root}/homelab-pilot-crew" 0.47.2-rc.0 && status=0 || status=$?
check "the final outranks its own rcs" 1 "$(rendered_images homelab-pilot-crew | grep -cx 'ghcr.io/kubemoot/code-sandbox:0.20.0')"
# A deliberate finals-only build skips candidates.
git -C "${root}/kubemoot" tag artifact-access-v0.345.0-rc.1
git -C "${root}/kubemoot" push -q "${root}/kubemoot.git" artifact-access-v0.345.0-rc.1
copy_crew homelab-pilot-crew
KUBEMOOT_PINS=final stamp "${root}/homelab-pilot-crew" 0.47.2-rc.1 && status=0 || status=$?
images="$(rendered_images homelab-pilot-crew)"
check "KUBEMOOT_PINS=final takes the latest final" "0|1|1|1" \
  "${status}|$(grep -cx 'ghcr.io/kubemoot/artifact-access:0.343.0' <<<"$images")|$(grep -cx 'ghcr.io/kubemoot/code-sandbox:0.20.0' <<<"$images")|$(grep -cx 'ghcr.io/kubemoot/scheduling-mcp:0.1.0' <<<"$images")"
copy_crew homelab-pilot-crew
stamp "${root}/homelab-pilot-crew" 0.47.2-rc.2 && status=0 || status=$?
check "the default build takes the newer artifact-access candidate" 1 "$(rendered_images homelab-pilot-crew | grep -cx 'ghcr.io/kubemoot/artifact-access:0.345.0-rc.1')"
copy_crew homelab-pilot-crew
KUBEMOOT_PINS=newest stamp "${root}/homelab-pilot-crew" 0.47.2-rc.3 && status=0 || status=$?
check "refuses an unknown KUBEMOOT_PINS" 1 "$((status != 0))"

# O'guide pins no Kubemoot image: its read-ops server selects the operator's with
# kubemootImage, so it stamps without a Kubemoot remote.
copy_crew oguide-crew
KUBEMOOT_REMOTE="${root}/missing.git" stamp "${root}/oguide-crew" 0.1.0-rc.0 && status=0 || status=$?
check "O'guide candidate stamp succeeds" 0 "$status"
check "O'guide renders no Kubemoot-built image" 0 "$(rendered_images oguide-crew | grep -c '^ghcr.io/kubemoot/' || true)"
check "O'guide read-ops selects kubemootImage artifactAccess" 1 \
  "$(helm template t "${root}/oguide-crew" | grep -cx '  kubemootImage: artifactAccess')"
check "O'guide keeps the search server's Python image pinned by digest, unstamped" 1 \
  "$(rendered_images oguide-crew | grep -cE '^python@sha256:[0-9a-f]{64}$')"
check "O'guide stamped chart lints" 0 "$(helm lint "${root}/oguide-crew" >/dev/null 2>&1; echo $?)"

# The fitness crew (no Kubemoot images) stamps the same way.
copy_crew kubemoot-fitness-crew
KUBEMOOT_REMOTE="${root}/missing.git" stamp "${root}/kubemoot-fitness-crew" 0.5.0-rc.1 && status=0 || status=$?
check "a crew without Kubemoot images needs no Kubemoot remote" 0 "$status"
check "fitness crew chart version" "0.5.0-rc.1" "$(sed -n 's/^version: //p' "${root}/kubemoot-fitness-crew/Chart.yaml")"
check "fitness crew lints" 0 "$(helm lint "${root}/kubemoot-fitness-crew" >/dev/null 2>&1; echo $?)"

# Unexpected inputs fail the build instead of packaging a wrong chart.
for bad in "" v0.47.0 0.47 0.47.0-beta.1 latest; do
  copy_crew homelab-pilot-crew
  stamp "${root}/homelab-pilot-crew" "$bad" && status=0 || status=$?
  check "refuses chart version [${bad}]" 1 "$((status != 0))"
done
copy_crew homelab-pilot-crew
KUBEMOOT_REMOTE="${root}/missing.git" stamp "${root}/homelab-pilot-crew" 0.47.0-rc.4 && status=0 || status=$?
check "refuses when Kubemoot's tags cannot be read" 1 "$((status != 0))"
check "leaves the images unstamped then" 3 "$(rl_image_placeholders "${root}/homelab-pilot-crew/values.yaml" | wc -l | tr -d ' ')"
git init -q -b main "${root}/empty"
git -C "${root}/empty" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
git -C "${root}/empty" tag artifact-access-v0.343.0
git -C "${root}/empty" tag scheduling-mcp-v0.1.0
git -C "${root}/empty" tag code-sandbox-v0.18.0-rc.1
KUBEMOOT_PINS=final KUBEMOOT_REMOTE="${root}/empty" stamp "${root}/homelab-pilot-crew" 0.47.0-rc.4 && status=0 || status=$?
check "a finals-only build refuses a Kubemoot image with no final release" 1 "$((status != 0))"
check "says which image" 1 "$(grep -c 'no final code-sandbox-vX.Y.Z tag' "${root}/stamp.log")"
KUBEMOOT_REMOTE="${root}/empty" stamp "${root}/homelab-pilot-crew" 0.47.0-rc.4 && status=0 || status=$?
check "a candidate build takes the rc when there is no final" 0 "$status"
check "and stamps it" 1 "$(grep -c 'code-sandbox:0.18.0-rc.1"' "${root}/homelab-pilot-crew/values.yaml")"
copy_crew homelab-pilot-crew
git init -q -b main "${root}/nocand"
git -C "${root}/nocand" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
git -C "${root}/nocand" tag artifact-access-v0.343.0
git -C "${root}/nocand" tag scheduling-mcp-v0.1.0
KUBEMOOT_REMOTE="${root}/nocand" stamp "${root}/homelab-pilot-crew" 0.47.0-rc.4 && status=0 || status=$?
check "a candidate build refuses an image with no candidate at all" 1 "$((status != 0))"
check "and says which image" 1 "$(grep -c 'no code-sandbox-vX.Y.Z or code-sandbox-vX.Y.Z-rc.N tag' "${root}/stamp.log")"
check "and leaves the images unstamped" 3 "$(rl_image_placeholders "${root}/homelab-pilot-crew/values.yaml" | wc -l | tr -d ' ')"
copy_crew homelab-pilot-crew
sed -i 's/"code-sandbox:0.0.0"/"code-sandbox:0.16.0"/' "${root}/homelab-pilot-crew/values.yaml"
stamp "${root}/homelab-pilot-crew" 0.47.0-rc.4 && status=0 || status=$?
check "a typed pin is not stamped over" 1 "$(grep -c '"code-sandbox:0.16.0"' "${root}/homelab-pilot-crew/values.yaml")"
copy_crew homelab-pilot-crew
printf 'image: "code-sandbox:0.17.0"\n' > "${root}/partial-values.yaml"
stamp "${root}/homelab-pilot-crew" 0.47.0 "${root}/partial-values.yaml" && status=0 || status=$?
check "refuses candidate values without an image" 1 "$((status != 0))"
stamp "${root}/homelab-pilot-crew" 0.47.0 "${root}/none.yaml" && status=0 || status=$?
check "refuses missing candidate values" 1 "$((status != 0))"
stamp "${root}/none" 0.47.0-rc.4 && status=0 || status=$?
check "refuses a missing chart directory" 1 "$((status != 0))"
check "refuses without arguments" 1 "$(bash "${here}/stamp-crew.sh" >/dev/null 2>&1 && echo 0 || echo 1)"

if [ "$failures" -ne 0 ]; then echo "${failures} test(s) failed"; exit 1; fi
echo "all stamp-crew tests passed"
