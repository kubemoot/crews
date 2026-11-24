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
check "the pilot crews pin Kubemoot images as placeholders" "code-sandbox scheduling-mcp workspace-access" \
  "$(rl_image_placeholders "${repo}/homelab-pilot-crew/values.yaml" | tr '\n' ' ' | sed 's/ $//')"
check "O'guide pins the code sandbox and its own search image (its workspace server selects the operator's image)" "code-sandbox oguide-search" \
  "$(rl_image_placeholders "${repo}/oguide-crew/values.yaml" | tr '\n' ' ' | sed 's/ $//')"

# A throwaway Kubemoot with final and candidate tags.
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git init -q -b main "${root}/kubemoot"
git -C "${root}/kubemoot" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
for t in code-sandbox-v0.14.4 code-sandbox-v0.17.0 code-sandbox-v0.18.0-rc.126 \
  workspace-access-v0.342.1 workspace-access-v0.343.0 workspace-access-v0.344.0-rc.126 \
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
check "renders the newest candidate workspace-access" 1 "$(grep -cx 'ghcr.io/kubemoot/workspace-access:0.344.0-rc.126' <<<"$images")"
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
git -C "${root}/kubemoot" tag workspace-access-v0.345.0-rc.1
git -C "${root}/kubemoot" push -q "${root}/kubemoot.git" workspace-access-v0.345.0-rc.1
copy_crew homelab-pilot-crew
KUBEMOOT_PINS=final stamp "${root}/homelab-pilot-crew" 0.47.2-rc.1 && status=0 || status=$?
images="$(rendered_images homelab-pilot-crew)"
check "KUBEMOOT_PINS=final takes the latest final" "0|1|1|1" \
  "${status}|$(grep -cx 'ghcr.io/kubemoot/workspace-access:0.343.0' <<<"$images")|$(grep -cx 'ghcr.io/kubemoot/code-sandbox:0.20.0' <<<"$images")|$(grep -cx 'ghcr.io/kubemoot/scheduling-mcp:0.1.0' <<<"$images")"
copy_crew homelab-pilot-crew
stamp "${root}/homelab-pilot-crew" 0.47.2-rc.2 && status=0 || status=$?
check "the default build takes the newer workspace-access candidate" 1 "$(rendered_images homelab-pilot-crew | grep -cx 'ghcr.io/kubemoot/workspace-access:0.345.0-rc.1')"
copy_crew homelab-pilot-crew
KUBEMOOT_PINS=newest stamp "${root}/homelab-pilot-crew" 0.47.2-rc.3 && status=0 || status=$?
check "refuses an unknown KUBEMOOT_PINS" 1 "$((status != 0))"

# O'guide pins one Kubemoot image, the code sandbox; its workspace server selects the
# operator's with kubemootImage. The stamp reads Kubemoot's tags for the sandbox only.
# It also pins the image of its own Go search server, which the release builds into Harbor as
# crews/oguide-search:<chart version>: git holds oguide-search:0.0.0 and the stamp writes the digest.
digest_a="sha256:$(printf 'a%.0s' {1..64})"
digest_b="sha256:$(printf 'b%.0s' {1..64})"
cat > "${root}/digest.sh" <<DIGEST
#!/usr/bin/env bash
case "\$1" in
  harbor.test/crews/oguide-search:0.1.0-rc.0) echo ${digest_a} ;;
  harbor.test/crews/oguide-search:0.1.0) echo ${digest_b} ;;
  *) exit 1 ;;
esac
DIGEST
export RL_DIGEST_CMD="bash ${root}/digest.sh"
copy_crew oguide-crew
stamp "${root}/oguide-crew" 0.1.0-rc.0 && status=0 || status=$?
check "O'guide refuses to stamp its own image without OWN_IMAGE_REGISTRY" "1|1|1" \
  "$((status != 0))|$(grep -c 'OWN_IMAGE_REGISTRY is required to stamp oguide-search' "${root}/stamp.log")|$(rl_image_placeholders "${root}/oguide-crew/values.yaml" | grep -cx oguide-search)"
export OWN_IMAGE_REGISTRY=harbor.test/crews
copy_crew oguide-crew
stamp "${root}/oguide-crew" 0.1.0-rc.0 && status=0 || status=$?
check "O'guide candidate stamp succeeds" 0 "$status"
check "O'guide renders Kubemoot's newest code-sandbox, and no other Kubemoot image" "1|1" \
  "$(rendered_images oguide-crew | grep -cx 'ghcr.io/kubemoot/code-sandbox:0.20.0')|$(rendered_images oguide-crew | grep -c '^ghcr.io/kubemoot/' || true)"
check "O'guide renders no 0.0.0 Kubemoot image" 0 "$(rendered_images oguide-crew | grep -cE 'kubemoot/[a-z-]+:0\.0\.0' || true)"
check "O'guide workspace server selects kubemootImage workspaceAccess" 1 \
  "$(helm template t "${root}/oguide-crew" | grep -cx '  kubemootImage: workspaceAccess')"
check "O'guide keeps the search server's Python image pinned by digest, unstamped" 1 \
  "$(rendered_images oguide-crew | grep -cE '^python@sha256:[0-9a-f]{64}$')"
check "O'guide stamped chart lints" 0 "$(helm lint "${root}/oguide-crew" >/dev/null 2>&1; echo $?)"
check "O'guide pins its own search image by the digest of the build, with no tag" "1" \
  "$(grep -c "\"oguide-search@${digest_a}\"" "${root}/oguide-crew/values.yaml")"
check "O'guide has no placeholder left" "" \
  "$(rl_image_placeholders "${root}/oguide-crew/values.yaml" | tr '\n' ' ' | sed 's/ $//')"
check "the Go engine renders from the stamped chart with no value set" "ghcr.io/kubemoot/oguide-search@${digest_a}" \
  "$(helm template t "${root}/oguide-crew" --set mcpServers.search.engine=go | yq -N 'select(.kind == "MCPServer" and .metadata.name == "search-mcp") | .spec.image')"
check "the Python engine renders the same stamped chart" 1 "$(rendered_images oguide-crew | grep -cE '^python@sha256:[0-9a-f]{64}$')"
check "the stamped chart holds no 0.0.0 own image" 0 "$(grep -c 'oguide-search:0.0.0' "${root}/oguide-crew/values.yaml" || true)"
cp "${root}/oguide-crew/values.yaml" "${root}/oguide-candidate-values.yaml"
copy_crew oguide-crew
stamp "${root}/oguide-crew" 0.1.0 "${root}/oguide-candidate-values.yaml" && status=0 || status=$?
check "a final takes the digest the tested candidate pinned, not a rebuild" "0|1" \
  "${status}|$(grep -c "\"oguide-search@${digest_a}\"" "${root}/oguide-crew/values.yaml")"
copy_crew oguide-crew
printf 'global:\n  imageRegistry: ghcr.io/kubemoot\n' > "${root}/oguide-nopin.yaml"
stamp "${root}/oguide-crew" 0.1.0 "${root}/oguide-nopin.yaml" && status=0 || status=$?
check "a final refuses a candidate that pinned no digest for the image" "1|1" \
  "$((status != 0))|$(grep -c 'must pin oguide-search by one digest' "${root}/stamp.log")"
copy_crew oguide-crew
printf 'a: "oguide-search@%s"\nb: "oguide-search@%s"\n' "${digest_a}" "${digest_b}" > "${root}/oguide-twopins.yaml"
stamp "${root}/oguide-crew" 0.1.0 "${root}/oguide-twopins.yaml" && status=0 || status=$?
check "a final refuses a candidate that pinned two digests" 1 "$((status != 0))"
copy_crew oguide-crew
stamp "${root}/oguide-crew" 0.2.0-rc.0 && status=0 || status=$?
check "a build whose image is not in Harbor is refused and leaves the placeholder" "1|1" \
  "$((status != 0))|$(rl_image_placeholders "${root}/oguide-crew/values.yaml" | grep -cx oguide-search)"
check "and says which image" 1 "$(grep -c 'cannot read the digest of harbor.test/crews/oguide-search:0.2.0-rc.0' "${root}/stamp.log")"
copy_crew oguide-crew
sed -i 's/"oguide-search:0.0.0"/"oguide-search:1.2.3"/' "${root}/oguide-crew/values.yaml"
stamp "${root}/oguide-crew" 0.1.0-rc.0 && status=0 || status=$?
check "a typed own image tag is not stamped over" 1 "$(grep -c '"oguide-search:1.2.3"' "${root}/oguide-crew/values.yaml")"

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
git -C "${root}/empty" tag workspace-access-v0.343.0
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
git -C "${root}/nocand" tag workspace-access-v0.343.0
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

# The workspace-access series is seeded in Kubemoot when the component is renamed. The stamp reads
# tags only and never checks that an image exists, so what a seed makes it pick matters: a FINAL seed
# is the base the next candidate continues from (candidates of the next minor outrank it), and is
# picked only until the first candidate is built; a candidate-only seed is no base, the series
# restarts below it, and the stamp keeps picking the seed's candidate.
seed_pick() {
  local name="$1"; shift
  local repo_dir="${root}/seed-${name}"
  git init -q -b main "$repo_dir"
  git -C "$repo_dir" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
  for t in code-sandbox-v0.17.0 scheduling-mcp-v0.1.0 "$@"; do git -C "$repo_dir" tag "$t"; done
  git clone -q --bare "$repo_dir" "${root}/seed-${name}.git"
  copy_crew homelab-pilot-crew
  KUBEMOOT_REMOTE="${root}/seed-${name}.git" stamp "${root}/homelab-pilot-crew" 0.47.9-rc.0 || return 1
  rendered_images homelab-pilot-crew | grep -E '^ghcr.io/kubemoot/workspace-access:' | sed 's#.*:##'
}
check "a final seed is what the stamp picks until the first candidate exists" "0.348.0" \
  "$(seed_pick final-seed workspace-access-v0.348.0)"
check "the first candidate of the next minor outranks the final seed" "0.349.0-rc.2" \
  "$(seed_pick final-seed-rc workspace-access-v0.348.0 workspace-access-v0.349.0-rc.2)"
check "with a candidate-only seed the stamp stays on the seed after the series restarts below it" "0.349.0-rc.0" \
  "$(seed_pick rc-seed workspace-access-v0.349.0-rc.0 workspace-access-v0.1.0-rc.2)"

if [ "$failures" -ne 0 ]; then echo "${failures} test(s) failed"; exit 1; fi
echo "all stamp-crew tests passed"
