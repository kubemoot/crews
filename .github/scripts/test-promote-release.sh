#!/usr/bin/env bash
# Tests for promote-release.sh (crews): a throwaway repository with crew charts,
# release-candidate tags, and a bare origin; `helm push` and `helm registry` are
# stubbed, `helm package` is the real one.
# Usage: RELEASE_LIB=<release-actions>/release-lib.sh bash .github/scripts/test-promote-release.sh
#        (exit 0 = all passed; in CI the release-actions setup action sets RELEASE_LIB)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
command -v helm >/dev/null || { echo "helm is required"; exit 1; }
[ -f "${RELEASE_LIB:-}" ] || { echo "RELEASE_LIB must point to release-lib.sh from kubemoot/release-actions"; exit 1; }
real_helm="$(command -v helm)"

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi
}

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export LOG="${root}/calls.log"
mkdir -p "${root}/bin"
touch "$LOG"
cat > "${root}/bin/helm" <<EOF
#!/usr/bin/env bash
case "\$1" in
  push|registry) echo "helm \$*" >> "\$LOG"; exit 0 ;;
esac
exec "${real_helm}" "\$@"
EOF
chmod +x "${root}/bin/helm"
export PATH="${root}/bin:${PATH}"

git init -q --bare "${root}/origin.git"
git clone -q "${root}/origin.git" "${root}/repo" 2>/dev/null
cd "${root}/repo"
git config user.email test@example.com
git config user.name test
git checkout -q -b main
crew_chart() {
  mkdir -p "$1"
  printf 'apiVersion: v2\nname: %s\nversion: %s\nappVersion: %s\n' "$1" "$2" "$2" > "$1/Chart.yaml"
  printf 'global:\n  imageRegistry: ghcr.io/kubemoot\ntools:\n  sandbox:\n    image: "code-sandbox:%s"\n' "$3" > "$1/values.yaml"
}
crew_chart alpha 0.4.6 0.14.4
crew_chart beta 0.30.0 0.14.4
crew_chart gamma 0.2.0 0.14.4
git add -A; git commit -q -m "chore: init"
git tag -a alpha-v0.4.6 -m f; git tag -a beta-v0.30.0 -m f; git tag -a gamma-v0.2.0 -m f

echo "# alpha" > alpha/README.md; git add alpha; git commit -q -m "feat(alpha): new scenario"
crew_chart alpha 0.5.0-rc.0 0.14.4; git commit -q -am "chore(alpha): update chart to v0.5.0-rc.0 [skip ci]"
git tag -a alpha-v0.5.0-rc.0 -m rc
alpha_rc=$(git rev-parse HEAD)
echo "# beta" > beta/README.md; git add beta; git commit -q -m "fix(beta): prompt wording"
crew_chart beta 0.30.1-rc.0 0.14.4; git commit -q -am "chore(beta): update chart to v0.30.1-rc.0 [skip ci]"
git tag -a beta-v0.30.1-rc.0 -m rc
echo "# alpha later" >> alpha/README.md; git commit -q -am "fix(alpha): later, not built"
git push -q origin main --tags 2>/dev/null
git fetch -q origin

export REGISTRY=harbor.test RELEASE_REGISTRY=ghcr.test/kubemoot GHCR_USERNAME=u GHCR_TOKEN=t
export CREWS="alpha beta gamma"
run_promote() { OUT_DIR="${root}/out-$1" bash "${here}/promote-release.sh" > "${root}/run-$1.log" 2>&1; }

# Dry run.
DRY_RUN=true run_promote dry && status=0 || status=$?
check "dry run succeeds" 0 "$status"
out="$(cat "${root}/run-dry.log")"
check "plans alpha" 1 "$(grep -c 'alpha: alpha-v0.5.0-rc.0 -> alpha-v0.5.0' <<<"$out")"
check "plans beta" 1 "$(grep -c 'beta: beta-v0.30.1-rc.0 -> beta-v0.30.1' <<<"$out")"
check "skips a crew with no candidate" 1 "$(grep -c 'gamma: no release candidate' <<<"$out")"
check "packages alpha from its candidate commit" 1 "$(tar -xzOf "${root}/out-dry/alpha-0.5.0.tgz" alpha/Chart.yaml | grep -c '^version: 0.5.0$')"
check "leaves out later work" 0 "$(tar -xzOf "${root}/out-dry/alpha-0.5.0.tgz" alpha/README.md | grep -c 'alpha later' || true)"
check "alpha notes are alpha only" 0 "$(grep -c 'beta' "${root}/out-dry/alpha.md" || true)"
check "alpha notes list its feature" 1 "$(grep -c '^- New scenario (' "${root}/out-dry/alpha.md")"
check "dry run pushes nothing" 0 "$(grep -c '^helm push' "$LOG" || true)"
check "dry run tags nothing" "" "$(git tag -l alpha-v0.5.0)"

# Unexpected input: a crew pinning a release-candidate image is refused before any push.
git checkout -q -b pin main
crew_chart gamma 0.2.1-rc.0 0.16.32-rc.1; git commit -q -am "chore(gamma): update chart to v0.2.1-rc.0 [skip ci]"
git tag -a gamma-v0.2.1-rc.0 -m rc
git push -q origin pin:main --tags 2>/dev/null; git fetch -q origin
DRY_RUN=false run_promote rcpin && status=0 || status=$?
check "refuses a crew that pins a candidate image" 1 "$status"
check "says why" 1 "$(grep -c 'pins a release candidate image' "${root}/run-rcpin.log")"
check "pushes no chart when one crew is refused" 0 "$(grep -c '^helm push' "$LOG" || true)"
git push -q -f origin main:main 2>/dev/null; git push -q origin --delete gamma-v0.2.1-rc.0 2>/dev/null
git tag -d gamma-v0.2.1-rc.0 >/dev/null; git checkout -q main; git fetch -q --prune origin

# Real promotion.
DRY_RUN=false run_promote real && status=0 || status=$?
check "promotion succeeds" 0 "$status"
[ "$status" -eq 0 ] || sed 's/^/    /' "${root}/run-real.log"
git fetch -q origin --tags
check "final tag on the candidate commit" "$alpha_rc" "$(git rev-list -n 1 alpha-v0.5.0 2>/dev/null)"
check "pushes two charts to both registries" 4 "$(grep -c '^helm push' "$LOG")"
check "writes two releases" 2 "$(wc -l < "${root}/out-real/releases.tsv" | tr -d ' ')"

# Nothing left to promote.
DRY_RUN=false run_promote again && status=0 || status=$?
check "refuses when nothing is new" 1 "$status"

if [ "$failures" -ne 0 ]; then echo "${failures} test(s) failed"; exit 1; fi
echo "all promote-release tests passed"
