#!/usr/bin/env bash
# Render tests for the pilot crew's declared domains. The coordinator convenes the analysts that
# review a discussion by the domains they declare (Agent spec.domains) against the question's
# domains and the domains of the toolers that gathered the data. In domain mode an analyst that
# declares none is a generalist and reviews every discussion. So every tooler that gathers data
# and every specialist analyst declares domains, and each tooler's data reaches exactly the
# analysts that should review it. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-domains.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"

out="$(render "${all_on[@]}")"
# The domains an agent declares, sorted and comma-joined.
domains_of() { yq -N "select(.kind == \"Agent\" and .metadata.name == \"$1\") | .spec.domains // [] | .[]" <<<"$out" | sort -u | paste -sd, -; }
# The agents of a role (spec.discussRole), one per line.
agents_of() { yq -N "select(.kind == \"Agent\" and .spec.discussRole == \"$1\") | .metadata.name" <<<"$out" | sort; }
# 1 when the two agents share a domain.
shares() { if comm -12 <(tr ',' '\n' <<<"$(domains_of "$1")") <(tr ',' '\n' <<<"$(domains_of "$2")") | grep -q .; then echo yes; else echo no; fi; }
count() { grep -c . || true; }

# The crew's shape, so an agent added without a decision here fails this test.
check "toolers in the all-on rendering" 16 "$(agents_of tooler | count)"
check "analysts in the all-on rendering" 5 "$(agents_of analyst | count)"
check "researchers in the all-on rendering" 1 "$(agents_of researcher | count)"
check "coordinators in the all-on rendering" 1 "$(agents_of coordinator | count)"

# The agents that declare no domain, derived from the rendering. Only compute (an analyst, a generalist
# that reviews every discussion) and scheduler-advisor (a tooler, never convened for
# review) may.
undeclared="$(for a in $(agents_of tooler) $(agents_of analyst); do if [ -z "$(domains_of "$a")" ]; then echo "$a"; fi; done | sort | paste -sd' ' -)"
check "only compute and scheduler-advisor declare no domain" "compute scheduler-advisor" "$undeclared"
check "compute is an analyst, so it reviews as a generalist" yes "$(agents_of analyst | grep -qx compute && echo yes || echo no)"
check "scheduler-advisor is a tooler, so it never reviews" yes "$(agents_of tooler | grep -qx scheduler-advisor && echo yes || echo no)"

# Which analysts each tooler's data reaches. An analyst with a domain of its own is convened only
# when a domain matches; the expected reach is written out per tooler family.
expected() {
  case "$1:$2" in
    k8s-metrics:k8s-advisor | k8s-metrics:obs-advisor) echo yes ;;
    k8s-*:k8s-advisor | k8sgpt:k8s-advisor) echo yes ;;
    obs-metrics:obs-advisor) echo yes ;;
    nvidia-gpu-*:nvidia-gpu-advisor) echo yes ;;
    proxmox-*:proxmox-advisor) echo yes ;;
    *) echo no ;;
  esac
}
for tooler in $(agents_of tooler); do
  [ -n "$(domains_of "$tooler")" ] || continue
  for analyst in $(agents_of analyst); do
    [ -n "$(domains_of "$analyst")" ] || continue
    check "$tooler data reaching $analyst" "$(expected "$tooler" "$analyst")" "$(shares "$analyst" "$tooler")"
  done
done

if [ "$failures" -ne 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all domain checks passed"
