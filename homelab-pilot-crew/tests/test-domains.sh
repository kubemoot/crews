#!/usr/bin/env bash
# Render tests for the pilot crew's declared domains. The coordinator convenes the analysts that
# review a discussion by the domains they declare (Agent spec.domains) against the question's
# domains and the domains of the toolers that gathered the data, so every tooler and analyst
# declares them, and each analyst shares a domain with the toolers whose data it reviews. Needs
# helm and yq.
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
shares() { if [ -n "$(comm -12 <(tr ',' '\n' <<<"$(domains_of "$1")") <(tr ',' '\n' <<<"$(domains_of "$2")") | grep .)" ]; then echo yes; else echo no; fi; }

# Cross-cutting agents have no subject area: compute works on any data, the scheduler on reminders.
no_domain="compute scheduler-advisor"
for agent in $(agents_of tooler) $(agents_of analyst); do
  case " $no_domain " in *" $agent "*) continue ;; esac
  declared="$(domains_of "$agent")"
  check "$agent declares domains" yes "$([ -n "$declared" ] && echo yes || echo no)"
done
for agent in $no_domain; do
  check "$agent declares no domain, so it reviews only when the coordinator selects it" "" "$(domains_of "$agent")"
done

# Every analyst can be matched by some tooler's data.
for analyst in $(agents_of analyst); do
  case " $no_domain " in *" $analyst "*) continue ;; esac
  matched=no
  for tooler in $(agents_of tooler); do
    [ "$(shares "$analyst" "$tooler")" = yes ] && matched=yes
  done
  check "$analyst shares a domain with a tooler" yes "$matched"
done

# The review of a Proxmox answer is the Proxmox analyst's alone.
check "proxmox-pve data reaches the Proxmox analyst" yes "$(shares proxmox-advisor proxmox-pve)"
for other in nvidia-gpu-advisor k8s-advisor obs-advisor; do
  check "proxmox-pve data does not reach $other" no "$(shares "$other" proxmox-pve)"
done
# A Kubernetes node answer reaches the Kubernetes analyst and no other.
check "k8s-nodes data reaches the Kubernetes analyst" yes "$(shares k8s-advisor k8s-nodes)"
for other in nvidia-gpu-advisor proxmox-advisor obs-advisor; do
  check "k8s-nodes data does not reach $other" no "$(shares "$other" k8s-nodes)"
done

if [ "$failures" -ne 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all domain checks passed"
