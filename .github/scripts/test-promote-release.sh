#!/usr/bin/env bash
# Tests for promote-release.sh (crews): a throwaway repository with crew charts as git
# holds them (0.0.0 versions and image tags), release-candidate tags on the built
# commits, and a bare origin; `helm push` and `helm registry` are stubbed, `helm show
# values` reads the candidate charts' values from a stub Harbor, `helm package` is real.
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
  show)
    echo "helm \$*" >> "\$LOG"
    ref=""; ver=""; prev=""
    for a in "\$@"; do
      case "\$a" in oci://*) ref="\${a##*/}" ;; esac
      [ "\$prev" = "--version" ] && ver="\$a"
      prev="\$a"
    done
    exec cat "${root}/harbor/\${ref}-\${ver}.values.yaml" 2>/dev/null ;;
esac
exec "${real_helm}" "\$@"
EOF
chmod +x "${root}/bin/helm"
export PATH="${root}/bin:${PATH}"
mkdir -p "${root}/harbor"
# harbor_candidate CREW VERSION IMAGE_TAG: the values.yaml the candidate chart was
# packaged with (its stamped Kubemoot image tag).
harbor_candidate() {
  printf 'global:\n  imageRegistry: ghcr.io/kubemoot\ntools:\n  sandbox:\n    image: "code-sandbox:%s"\n' "$3" \
    > "${root}/harbor/$1-$2.values.yaml"
}

git init -q --bare "${root}/origin.git"
git clone -q "${root}/origin.git" "${root}/repo" 2>/dev/null
cd "${root}/repo"
git config user.email test@example.com
git config user.name test
git checkout -q -b main
# crew_chart NAME [IMAGE_TAG]: a crew chart as git holds it (default image tag 0.0.0).
crew_chart() {
  mkdir -p "$1"
  printf 'apiVersion: v2\nname: %s\nversion: 0.0.0\nappVersion: 0.0.0\n' "$1" > "$1/Chart.yaml"
  printf 'global:\n  imageRegistry: ghcr.io/kubemoot\ntools:\n  sandbox:\n    image: "code-sandbox:%s"\n' "${2:-0.0.0}" > "$1/values.yaml"
}
crew_chart alpha
crew_chart beta
crew_chart gamma
git add -A; git commit -q -m "chore: init"
git tag -a alpha-v0.4.6 -m f; git tag -a beta-v0.30.0 -m f; git tag -a gamma-v0.2.0 -m f

# Each candidate tag marks the commit its release workflow built; no version commit follows.
echo "# alpha" > alpha/README.md; git add alpha; git commit -q -m "feat(alpha): new scenario"
git tag -a alpha-v0.5.0-rc.0 -m rc
harbor_candidate alpha 0.5.0-rc.0 0.17.0
alpha_rc=$(git rev-parse HEAD)
echo "# beta" > beta/README.md; git add beta; git commit -q -m "fix(beta): prompt wording"
git tag -a beta-v0.30.1-rc.0 -m rc
harbor_candidate beta 0.30.1-rc.0 0.16.31
echo "# alpha later" >> alpha/README.md; git commit -q -am "fix(alpha): later, not built"
git push -q origin main --tags 2>/dev/null
git fetch -q origin
main_before=$(git rev-parse origin/main)

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
check "stamps the final appVersion" 1 "$(tar -xzOf "${root}/out-dry/alpha-0.5.0.tgz" alpha/Chart.yaml | grep -c '^appVersion: 0.5.0$')"
check "pins the Kubemoot image the candidate ran" 1 "$(tar -xzOf "${root}/out-dry/alpha-0.5.0.tgz" alpha/values.yaml | grep -c '"code-sandbox:0.17.0"')"
check "beta pins its own candidate's image" 1 "$(tar -xzOf "${root}/out-dry/beta-0.30.1.tgz" beta/values.yaml | grep -c '"code-sandbox:0.16.31"')"
check "no 0.0.0 left in the final chart" 0 "$(tar -xzOf "${root}/out-dry/alpha-0.5.0.tgz" | grep -c '0\.0\.0' || true)"
check "reads the candidate charts from Harbor" 2 "$(grep -c '^helm show values .*oci://harbor.test/crews/' "$LOG")"
check "git keeps 0.0.0" "0.0.0|0.0.0" "$(sed -n 's/^version: //p' alpha/Chart.yaml)|$(grep -o 'code-sandbox:[0-9.]*' alpha/values.yaml | cut -d: -f2)"
check "leaves out later work" 0 "$(tar -xzOf "${root}/out-dry/alpha-0.5.0.tgz" alpha/README.md | grep -c 'alpha later' || true)"
check "alpha notes are alpha only" 0 "$(grep -c 'beta' "${root}/out-dry/alpha.md" || true)"
check "alpha notes list its feature" 1 "$(grep -c '^- New scenario (' "${root}/out-dry/alpha.md")"
check "dry run pushes nothing" 0 "$(grep -c '^helm push' "$LOG" || true)"
check "dry run tags nothing" "" "$(git tag -l alpha-v0.5.0)"

# Unexpected input: a crew pinning a release-candidate image is refused before any push.
git checkout -q -b pin main
echo "# gamma" > gamma/README.md; git add gamma; git commit -q -m "fix(gamma): wording"
git tag -a gamma-v0.2.1-rc.0 -m rc
harbor_candidate gamma 0.2.1-rc.0 0.16.32-rc.1
git push -q origin pin:main --tags 2>/dev/null; git fetch -q origin
DRY_RUN=false run_promote rcpin && status=0 || status=$?
check "refuses a crew that pins a candidate image" 1 "$status"
check "says why" 1 "$(grep -c 'pins a release candidate image' "${root}/run-rcpin.log")"
check "pushes no chart when one crew is refused" 0 "$(grep -c '^helm push' "$LOG" || true)"
git push -q -f origin main:main 2>/dev/null; git push -q origin --delete gamma-v0.2.1-rc.0 2>/dev/null
git tag -d gamma-v0.2.1-rc.0 >/dev/null; git checkout -q main; git fetch -q --prune origin

# Unexpected input: a candidate chart missing from Harbor is refused before any push.
git checkout -q -b missing main
echo "# gamma" > gamma/README.md; git add gamma; git commit -q -m "fix(gamma): wording"
git tag -a gamma-v0.2.1-rc.1 -m rc
git push -q origin missing:main --tags 2>/dev/null; git fetch -q origin
DRY_RUN=true run_promote nochart && status=0 || status=$?
check "refuses a candidate missing from Harbor" 1 "$status"
check "names the missing chart" 1 "$(grep -c 'cannot read the candidate chart gamma 0.2.1-rc.1' "${root}/run-nochart.log")"
git push -q -f origin main:main 2>/dev/null; git push -q origin --delete gamma-v0.2.1-rc.1 2>/dev/null
git tag -d gamma-v0.2.1-rc.1 >/dev/null; git checkout -q main; git fetch -q --prune origin

# Unexpected input: a candidate's Harbor values without the Kubemoot image are refused.
git checkout -q -b noimage main
echo "# gamma" > gamma/README.md; git add gamma; git commit -q -m "fix(gamma): wording"
git tag -a gamma-v0.2.1-rc.2 -m rc
printf 'global:\n  imageRegistry: ghcr.io/kubemoot\n' > "${root}/harbor/gamma-0.2.1-rc.2.values.yaml"
git push -q origin noimage:main --tags 2>/dev/null; git fetch -q origin
DRY_RUN=true run_promote noimage && status=0 || status=$?
check "refuses a candidate chart without the image" 1 "$status"
git push -q -f origin main:main 2>/dev/null; git push -q origin --delete gamma-v0.2.1-rc.2 2>/dev/null
git tag -d gamma-v0.2.1-rc.2 >/dev/null; git checkout -q main; git fetch -q --prune origin

# A candidate whose values carry a typed final pin is packaged as it is, without a
# Harbor read.
git checkout -q -b legacy main
crew_chart gamma 0.14.4; git commit -q -am "fix(gamma): typed pin"
git tag -a gamma-v0.2.1-rc.3 -m rc
git push -q origin legacy:main --tags 2>/dev/null; git fetch -q origin
: > "$LOG"
DRY_RUN=true run_promote legacy && status=0 || status=$?
check "promotes a candidate with a typed final pin" 0 "$status"
check "keeps the typed pin" 1 "$(tar -xzOf "${root}/out-legacy/gamma-0.2.1.tgz" gamma/values.yaml | grep -c '"code-sandbox:0.14.4"')"
check "reads no Harbor values for it" 0 "$(grep -c 'crews/gamma' "$LOG" || true)"
git push -q -f origin main:main 2>/dev/null; git push -q origin --delete gamma-v0.2.1-rc.3 2>/dev/null
git tag -d gamma-v0.2.1-rc.3 >/dev/null; git checkout -q main; git fetch -q --prune origin
: > "$LOG"

# Real promotion.
DRY_RUN=false run_promote real && status=0 || status=$?
check "promotion succeeds" 0 "$status"
[ "$status" -eq 0 ] || sed 's/^/    /' "${root}/run-real.log"
git fetch -q origin --tags
check "final tag on the candidate commit" "$alpha_rc" "$(git rev-list -n 1 alpha-v0.5.0 2>/dev/null)"
check "pushes two charts to both registries" 4 "$(grep -c '^helm push' "$LOG")"
check "writes two releases" 2 "$(wc -l < "${root}/out-real/releases.tsv" | tr -d ' ')"
check "pushes the final chart to Harbor" 1 "$(grep -c '^helm push .*alpha-0.5.0.tgz oci://harbor.test/crews$' "$LOG")"
check "commits nothing to main" "$main_before" "$(git rev-parse origin/main)"

# Nothing left to promote.
DRY_RUN=false run_promote again && status=0 || status=$?
check "refuses when nothing is new" 1 "$status"

if [ "$failures" -ne 0 ]; then echo "${failures} test(s) failed"; exit 1; fi
echo "all promote-release tests passed"
