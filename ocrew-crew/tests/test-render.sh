#!/usr/bin/env bash
# Render tests for the O'crew chart: no Model of its own, the per-phase model selection
# rules, the O'Reilly connection (endpoint, the Secret named and never a key), the
# Kubemoot image stamping placeholder, and that every Agent's PromptModules ship with it.
# Needs helm and yq.
# Run from anywhere: ocrew-crew/tests/test-render.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
command -v helm >/dev/null || { echo "helm is required"; exit 1; }
command -v yq >/dev/null || { echo "yq is required"; exit 1; }

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi
}
render() { helm template t "$chart" -n crew-ocrew "$@"; }
# render_err ARGS: the error a render fails with, empty when it succeeds.
render_err() { { render "$@" >/dev/null; } 2>&1 || true; }
# rule PHASE EXPR: evaluates yq EXPR against the scheduling rule for PHASE.
rule() {
  yq -N -o=json -I=0 "select(.kind == \"CrewSchedulingPolicy\") | .spec.rules[] | select(.phase == \"$1\") | $2" <<<"$out"
}
oreilly() { yq -N -o=json -I=0 "select(.kind == \"MCPServer\" and .metadata.name == \"oreilly-mcp\") | $1"; }

check "the chart lints" 0 "$(helm lint "$chart" >/dev/null 2>&1; echo $?)"
out="$(render)"

# Portable crew: no Model, no latencyClass; the cluster's model catalog supplies the models.
check "renders no Model" "" "$(yq -N 'select(.kind == "Model") | .metadata.name' <<<"$out")"
check "a stray models value renders no Model" "" \
  "$(render --set 'models[0].name=x' --set 'models[0].model=x' | yq -N 'select(.kind == "Model") | .metadata.name')"
check "renders no latencyClass" 0 "$(grep -c latencyClass <<<"$out" || true)"
check "renders one CrewSchedulingPolicy" 1 "$(yq -N 'select(.kind == "CrewSchedulingPolicy") | .metadata.name' <<<"$out" | grep -c .)"

# Mulling: tool-calling is the hard need; size follows qualityBias.
check "mulling requires only tool-calling" '{"capability/tool-calling":"true"}' "$(rule mulling '.require.matchLabels')"
check "mulling has no prefer list" null "$(rule mulling '.prefer')"
check "mulling has no preferFaster" null "$(rule mulling '.preferFaster')"
check "qualityBias" '{"reasoning":"0.7","tool-calling":"0.5","default":"0.5"}' \
  "$(yq -N -o=json -I=0 'select(.kind == "CrewSchedulingPolicy") | .spec.qualityBias' <<<"$out")"

# Triage: tool-calling is the hard need and measured speed ranks the candidates.
check "triage requires only tool-calling" '{"capability/tool-calling":"true"}' "$(rule triage '.require.matchLabels')"
check "triage sets preferFaster 50" 50 "$(rule triage '.preferFaster')"
check "triage holds only phase, require, and preferFaster" '"phase,preferFaster,require"' "$(rule triage 'keys | sort | join(",")')"

check "the placement policy is unset by default" null \
  "$(yq -N 'select(.kind == "CrewSchedulingPolicy") | .spec.placementPolicy' <<<"$out")"
check "the placement policy value renders" shadow \
  "$(render --set crew.placementPolicy=shadow | yq -N 'select(.kind == "CrewSchedulingPolicy") | .spec.placementPolicy')"

# The O'Reilly MCP server: an external endpoint, the Secret named, never a key.
check "the endpoint defaults to O'Reilly's" '"https://api.oreilly.com/api/content-discovery/v1/mcp/"' \
  "$(oreilly '.spec.externalEndpoint' <<<"$out")"
check "the endpoint is a value" '"https://mcp.example.test/mcp/"' \
  "$(render --set oreilly.endpoint=https://mcp.example.test/mcp/ | oreilly '.spec.externalEndpoint')"
check "the transport is http with no deployment" '"http"|null' \
  "$(oreilly '.spec.transport' <<<"$out")|$(oreilly '.spec.image' <<<"$out")"
check "the Secret is referenced by name" '"oreilly-mcp-auth"' "$(oreilly '.spec.registry.authSecretRef' <<<"$out")"
check "the registry block holds only the reference" '"authSecretRef,categories,enabled"' \
  "$(oreilly '.spec.registry | keys | sort | join(",")' <<<"$out")"
check "the Secret name is a value" '"my-key"' \
  "$(render --set oreilly.auth.secretName=my-key | oreilly '.spec.registry.authSecretRef')"
check "an api-key carries its header" '"Authorization"' \
  "$(render --set oreilly.auth.secretKey=api-key --set oreilly.auth.header=Authorization | oreilly '.spec.registry.authHeader')"
check "an empty Secret name fails the render" 1 \
  "$(render_err --set oreilly.auth.secretName= | grep -c 'oreilly.auth.secretName is required' || true)"
check "an unknown Secret key fails the render" 1 \
  "$(render_err --set oreilly.auth.secretKey=token | grep -c 'must be bearer-token or api-key' || true)"
check "a header with a bearer-token fails the render" 1 \
  "$(render_err --set oreilly.auth.header=X-Key | grep -c 'applies only with oreilly.auth.secretKey api-key' || true)"

# No key or token value in any rendered object, even when one is passed by mistake.
planted="$(render --set oreilly.auth.key=PLANTED-KEY-0001 --set oreilly.key=PLANTED-KEY-0001 --set oreilly.auth.token=PLANTED-KEY-0001)"
check "a key passed as a value is never rendered" 0 "$(grep -c PLANTED-KEY-0001 <<<"$planted" || true)"
check "renders no Secret" "" "$(yq -N 'select(.kind == "Secret") | .metadata.name' <<<"$out")"
check "renders no stringData" 0 "$(grep -c stringData <<<"$out" || true)"
check "renders no bearer value" 0 "$(grep -ciE 'bearer [A-Za-z0-9]' <<<"$out" || true)"
check "values.yaml holds no key value" "" \
  "$(grep -nE '^\s*(key|token|apiKey|api-key|bearer-token|password):\s*\S' "${chart}/values.yaml" || true)"

# The MCP gateway registers this release's MCPServers.
check "the gateway selects this release" '{"app.kubernetes.io/instance":"t"}' \
  "$(yq -N -o=json -I=0 'select(.kind == "MCPGateway") | .spec.mcpServerSelector.matchLabels' <<<"$out")"
check "both MCPServers carry the release label" "t t" \
  "$(yq -N 'select(.kind == "MCPServer") | .metadata.labels."app.kubernetes.io/instance"' <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
check "no pull secret by default" null "$(yq -N 'select(.kind == "MCPGateway") | .spec.imagePullSecrets' <<<"$out")"
check "a pull secret is a value" '[{"name":"p"}]' \
  "$(render --set 'imagePullSecrets[0].name=p' | yq -N -o=json -I=0 'select(.kind == "MCPGateway") | .spec.imagePullSecrets')"

# The Kubemoot-built image: 0.0.0 in git (stamped at build), never :latest.
readops() { yq -N 'select(.kind == "MCPServer" and .metadata.name == "artifact-readops-mcp") | .spec.image'; }
check "the read-ops image is the stamping placeholder" ghcr.io/kubemoot/artifact-access:0.0.0 "$(readops <<<"$out")"
check "global.imageRegistry prefixes it" harbor.test/kubemoot/artifact-access:0.0.0 \
  "$(render --set global.imageRegistry=harbor.test/kubemoot | readops)"
check "a full reference passes through" reg.test/x/artifact-access:1.2.3 \
  "$(render --set mcpServers.artifactAccess.image=reg.test/x/artifact-access:1.2.3 | readops)"
check "no :latest anywhere" 0 "$(grep -rc ':latest' "${chart}/values.yaml" "${chart}/templates" | awk -F: '{s += $NF} END {print s}')"
check "the NATS URL is a value" nats://n.test:4222 \
  "$(render --set nats.url=nats://n.test:4222 | yq -N 'select(.metadata.name == "artifact-readops-mcp") | .spec.env[] | select(.name == "NATS_URL") | .value')"

# Agents: four, each labeled with the crew, each PromptModule it names shipped with it.
check "renders four Agents" "curator,events-scout,library-search,ocrew-coordinator" \
  "$(yq -N 'select(.kind == "Agent") | .metadata.name' <<<"$out" | sort | paste -sd,)"
check "every Agent carries the crew label" "ocrew" \
  "$(yq -N 'select(.kind == "Agent") | .metadata.labels."kubemoot.ai/crew"' <<<"$out" | sort -u)"
check "a renamed crew relabels its Agents" "other" \
  "$(render --set crew.name=other | yq -N 'select(.kind == "Agent") | .metadata.labels."kubemoot.ai/crew"' | sort -u)"
modules="$(yq -N 'select(.kind == "PromptModule") | .metadata.name' <<<"$out" | sort)"
check "renders eleven PromptModules" 11 "$(grep -c . <<<"$modules")"
check "every promptRef names a shipped PromptModule" "" \
  "$(yq -N 'select(.kind == "Agent") | .spec.promptRefs[]' <<<"$out" | sort -u | comm -23 - <(printf '%s\n' "$modules"))"
check "only the search agents have the catalog tool" "events-scout,library-search" \
  "$(yq -N 'select(.kind == "Agent" and (.spec.enabledTools // [] | contains(["search_oreilly_content"]))) | .metadata.name' <<<"$out" | sort | paste -sd,)"
check "the curator reads artifacts only" 0 \
  "$(yq -N 'select(.kind == "Agent" and .metadata.name == "curator") | .spec.enabledTools[]' <<<"$out" | grep -vc '^artifact_' || true)"

# Grounding: no answer comes from model memory. Every agent reads the provenance rule, the
# search agents fail on a missing, failing, or empty tool, and the answer lists nothing
# without catalog results.
module() { yq -N "select(.kind == \"PromptModule\" and .metadata.name == \"$1\") | .spec.content" <<<"$out"; }
has() { grep -cF -- "$2" <<<"$(module "$1")" || true; }
check "every Agent reads catalog-grounding" "curator,events-scout,library-search,ocrew-coordinator" \
  "$(yq -N 'select(.kind == "Agent" and (.spec.promptRefs | contains(["catalog-grounding"]))) | .metadata.name' <<<"$out" | sort | paste -sd,)"
check "the search agents read tooler-discipline" "events-scout,library-search" \
  "$(yq -N 'select(.kind == "Agent" and (.spec.promptRefs | contains(["tooler-discipline"]))) | .metadata.name' <<<"$out" | sort | paste -sd,)"
check "catalog-grounding names this turn's search results as the only source" 1 \
  "$(has catalog-grounding 'ASSERT the ONLY source of items is the output of search_oreilly_content calls made in this turn')"
check "catalog-grounding drops a link outside the reader" 1 \
  "$(has catalog-grounding "WHEN an item's url does not start with https://learning.oreilly.com/ THEN drop the item")"
check "catalog-grounding stops with no items when there are no results" 1 \
  "$(has catalog-grounding 'list no title and no link, and stop')"
check "a missing search tool is NO_DATA" 1 \
  "$(has tooler-discipline 'WHEN search_oreilly_content is not among your tools THEN respond NO_DATA')"
check "an empty search is NO_DATA" 1 \
  "$(has tooler-discipline 'WHEN every search returned nothing THEN respond NO_DATA')"
check "a failing search is NO_DATA" 1 \
  "$(has tooler-discipline 'WHEN a search call fails with an error twice THEN respond NO_DATA: the O'"'"'Reilly catalog could not be searched')"
check "both search agents defer to those rules" 2 \
  "$(yq -N 'select(.kind == "PromptModule" and (.metadata.name == "library-search-system" or .metadata.name == "events-scout-system")) | .spec.content' <<<"$out" | grep -cF 'handled by the tool-unavailable and drill-on-empty-or-error rules')"
check "the curator ranks nothing without catalog results" 1 \
  "$(has analyst-review-protocol 'NEVER rank, plan, or list titles from memory')"
check "the coordinator lists nothing without catalog results" 1 \
  "$(has coordinator-decision-logic 'without catalog results there are no items')"
check "the answer links only reader links" 1 \
  "$(has synthesis-prompt 'starts with https://learning.oreilly.com/')"

# Fitness: every scenario checks that each link is a reader link, and one scenario fails
# an answer made from memory when the catalog has nothing.
scenarios="$(yq -N 'select(.kind == "ConfigMap" and .metadata.labels."kubemoot.ai/fitness-kind" == "scenarios") | .data' <<<"$out")"
total="$(find "${chart}/fitness" -maxdepth 1 -name '*.adl' | wc -l | tr -d ' ')"
check "every scenario except the empty-catalog one checks the reader links" "$((total - 1))" \
  "$(grep -c 'synthesis matches "\\A(?:\[^h\]|h(?:h|th|tth)\*(?:\[^ht\]|t\[^ht\]|tt\[^hp\]|ttps://learning\\.oreilly\\.com/))\*' "${chart}"/fitness/*.adl | grep -c ':1$')"
# Run each scenario's link pattern against sample answers. The operator evaluates it with
# Go's RE2, case-insensitive, and passes at one match; PCRE (grep -P) reads this pattern
# the same way. -z makes the whole answer one record, so \A and \z are its two ends; the
# trailing newline keeps an empty answer a record and changes no verdict.
links_ok() { printf '%s\n' "$2" | grep -Pzq -- "(?i)$1"; }
good_answers=(
  ""
  "The O'Reilly catalog found nothing for that author."
  "see https://learning.oreilly.com/library/view/x/1/"
  $'- [A](https://learning.oreilly.com/library/view/a/1/)\n- [B](https://learning.oreilly.com/videos/b/2/)'
  "hh, ht, htt, hth, htth, ends with htt"
)
bad_answers=(
  "http://x"
  "https://www.oreilly.com/book/1"
  "https://evil.com"
  "[A](http://learning.oreilly.com/library/view/a/1/)"
  "good https://learning.oreilly.com/x then bad https://evil.example/"
  "hhttps://evil.example and HTTPS://EVIL.EXAMPLE"
  "https://learning.oreilly.com.evil/x"
  "https://learning-oreilly.com/x"
  "hthttps://evil.example"
  "htthttps://evil.example"
)
for f in "${chart}"/fitness/*.adl; do
  pattern="$(sed -n 's/^ASSERT(synthesis matches "\(.*\)" at least 1 times)$/\1/p' "$f")"
  [ -n "$pattern" ] || continue
  passed=0; caught=0
  for a in "${good_answers[@]}"; do links_ok "$pattern" "$a" && passed=$((passed + 1)); done
  for a in "${bad_answers[@]}"; do links_ok "$pattern" "$a" || caught=$((caught + 1)); done
  check "$(basename "$f") link pattern passes reader links" "${#good_answers[@]}" "$passed"
  check "$(basename "$f") link pattern fails other links" "${#bad_answers[@]}" "$caught"
done

check "the empty-catalog scenario ships" 1 "$(yq -N 'has("catalog-empty-no-titles.adl")' <<<"$scenarios" | grep -c true)"
check "the empty-catalog scenario forbids every link" 1 \
  "$(grep -cF 'ASSERT(synthesis does NOT CONTAIN "http" AND "](" AND "oreilly.com/book/"' "${chart}/fitness/catalog-empty-no-titles.adl")"
check "the empty-catalog scenario asserts no specialist agreement" 0 \
  "$(grep -c 'specialist contributes' "${chart}/fitness/catalog-empty-no-titles.adl" || true)"

if [ "$failures" -ne 0 ]; then echo "${failures} test(s) failed"; exit 1; fi
echo "all O'crew render tests passed"
