#!/usr/bin/env bash
# Render tests for the O'guide chart: no Model of its own, the per-phase model selection
# rules, the O'Reilly connection (endpoint, the Secret named and never a key), the
# Kubemoot image stamping placeholder, and that every Agent's PromptModules ship with it.
# Needs helm and yq.
# Run from anywhere: oguide-crew/tests/test-render.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
command -v helm >/dev/null || { echo "helm is required"; exit 1; }
command -v yq >/dev/null || { echo "yq is required"; exit 1; }

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi
}
render() { helm template t "$chart" -n crew-oguide "$@"; }
# render_err ARGS: the error a render fails with, empty when it succeeds.
render_err() { { render "$@" >/dev/null; } 2>&1 || true; }
# rule PHASE EXPR: evaluates yq EXPR against the scheduling rule for PHASE.
rule() {
  yq -N -o=json -I=0 "select(.kind == \"CrewSchedulingPolicy\") | .spec.rules[] | select(.phase == \"$1\") | $2" <<<"$out"
}
search() { yq -N -o=json -I=0 "select(.kind == \"MCPServer\" and .metadata.name == \"search-mcp\") | $1"; }

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

# The raw O'Reilly server stays on the gateway, which holds the key; the search server reaches it
# only through the gateway. The search server: stock Python image pinned by digest, code from a Secret.
oreilly() { yq -N -o=json -I=0 "select(.kind == \"MCPServer\" and .metadata.name == \"oreilly-mcp\") | $1"; }
check "the search server image is pinned by digest" 1 \
  "$(search '.spec.image' <<<"$out" | grep -cE '^"python@sha256:[0-9a-f]{64}"$' || true)"
check "the search server runs the mounted code" '["python","/app/server.py"]' "$(search '.spec.command' <<<"$out")"
check "the search server is stdio" '"stdio"' "$(search '.spec.transport' <<<"$out")"
check "the endpoint defaults to O'Reilly's" '"https://api.oreilly.com/api/content-discovery/v1/mcp/"' \
  "$(oreilly '.spec.externalEndpoint' <<<"$out")"
check "the endpoint is a value" '"https://mcp.example.test/mcp/"' \
  "$(render --set oreilly.endpoint=https://mcp.example.test/mcp/ | oreilly '.spec.externalEndpoint')"
check "the raw server is an external endpoint with no deployment" '"http"|null' \
  "$(oreilly '.spec.transport' <<<"$out")|$(oreilly '.spec.image' <<<"$out")"
check "the gateway holds the key: the Secret is referenced by name" '"oreilly-mcp-auth"' "$(oreilly '.spec.registry.authSecretRef' <<<"$out")"
check "the registry block holds the reference and no key value" 0 \
  "$(oreilly '.spec.registry | keys | .[] | select(. != "authSecretRef" and . != "authHeader" and . != "categories" and . != "enabled")' <<<"$out" | grep -c . || true)"
check "the Secret name is a value" '"my-key"' \
  "$(render --set oreilly.auth.secretName=my-key | oreilly '.spec.registry.authSecretRef')"
check "an api-key carries its header" '"Authorization"' \
  "$(render --set oreilly.auth.secretKey=api-key --set oreilly.auth.header=Authorization | oreilly '.spec.registry.authHeader')"
check "the search server holds no key and no secret reference in its environment" 0 \
  "$(search '.spec.env[] | select(.valueFrom != null or .name == "OREILLY_MCP_KEY" or .name == "OREILLY_MCP_HEADER") | .name' <<<"$out" | grep -c . || true)"
check "the search server calls this crew's gateway" '"http://oguide-gateway.crew-oguide.svc:8080"' \
  "$(search '.spec.env[] | select(.name == "OREILLY_GATEWAY_URL") | .value' <<<"$out")"
check "the gateway address follows the gateway values" '"http://gw.other.svc:9090"' \
  "$(render -n other --set mcpGateway.name=gw --set mcpGateway.port=9090 | search '.spec.env[] | select(.name == "OREILLY_GATEWAY_URL") | .value')"
check "the default time zone is UTC" '"UTC"' "$(search '.spec.env[] | select(.name == "OREILLY_DEFAULT_TIMEZONE") | .value' <<<"$out")"
check "the default time zone is a value" '"Europe/London"' \
  "$(render --set oreilly.defaultTimeZone=Europe/London | search '.spec.env[] | select(.name == "OREILLY_DEFAULT_TIMEZONE") | .value')"
check "the code is mounted from its Secret" '[{"name":"oguide-search-server","mountPath":"/app/server.py","subPath":"server.py"}]' \
  "$(search '.spec.secretVolumes' <<<"$out")"
check "the only Secret is the search server code" "oguide-search-server" "$(yq -N 'select(.kind == "Secret") | .metadata.name' <<<"$out")"
check "the code Secret holds the server file" "$(sha256sum "${chart}/search-server/server.py" | cut -d' ' -f1)" \
  "$(yq -N 'select(.kind == "Secret" and .metadata.name == "oguide-search-server") | .data."server.py"' <<<"$out" | base64 -d | sha256sum | cut -d' ' -f1)"
check "the search server is contained" '{"readOnlyRootFilesystem":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}' \
  "$(search '.spec.securityContext' <<<"$out")"
pkg="$(mktemp -d)"
helm package "$chart" -d "$pkg" >/dev/null 2>&1
check "the package holds the server and not its tests" "1,0" \
  "$(tar -tzf "$pkg"/*.tgz | grep -c 'search-server/server.py' || true),$(tar -tzf "$pkg"/*.tgz | grep -c 'test_server' || true)"
rm -rf "$pkg"
check "an empty Secret name fails the render" 1 \
  "$(render_err --set oreilly.auth.secretName= | grep -c 'oreilly.auth.secretName is required' || true)"
check "an unknown Secret key fails the render" 1 \
  "$(render_err --set oreilly.auth.secretKey=token | grep -c 'must be bearer-token or api-key' || true)"
check "a header with a bearer-token fails the render" 1 \
  "$(render_err --set oreilly.auth.header=X-Key | grep -c 'applies only with oreilly.auth.secretKey api-key' || true)"

# No key or token value in any rendered object, even when one is passed by mistake.
planted="$(render --set oreilly.auth.key=PLANTED-KEY-0001 --set oreilly.key=PLANTED-KEY-0001 --set oreilly.auth.token=PLANTED-KEY-0001)"
check "a key passed as a value is never rendered" 0 "$(grep -c PLANTED-KEY-0001 <<<"$planted" || true)"
check "renders no stringData" 0 "$(grep -c stringData <<<"$out" || true)"
check "renders no bearer value" 0 "$(grep -ciE 'bearer [A-Za-z0-9]' <<<"$out" || true)"
check "values.yaml holds no key value" "" \
  "$(grep -nE '^\s*(key|token|apiKey|api-key|bearer-token|password):\s*\S' "${chart}/values.yaml" || true)"

# The MCP gateway registers this release's MCPServers.
check "the gateway selects this release" '{"app.kubernetes.io/instance":"t"}' \
  "$(yq -N -o=json -I=0 'select(.kind == "MCPGateway") | .spec.mcpServerSelector.matchLabels' <<<"$out")"
check "all three MCPServers carry the release label" "t t t" \
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
check "renders four Agents" "curator,events-scout,library-search,oguide-coordinator" \
  "$(yq -N 'select(.kind == "Agent") | .metadata.name' <<<"$out" | sort | paste -sd,)"
check "every Agent carries the crew label" "oguide" \
  "$(yq -N 'select(.kind == "Agent") | .metadata.labels."kubemoot.ai/crew"' <<<"$out" | sort -u)"
check "a renamed crew relabels its Agents" "other" \
  "$(render --set crew.name=other | yq -N 'select(.kind == "Agent") | .metadata.labels."kubemoot.ai/crew"' | sort -u)"
modules="$(yq -N 'select(.kind == "PromptModule") | .metadata.name' <<<"$out" | sort)"
check "renders eleven PromptModules" 11 "$(grep -c . <<<"$modules")"
check "every promptRef names a shipped PromptModule" "" \
  "$(yq -N 'select(.kind == "Agent") | .spec.promptRefs[]' <<<"$out" | sort -u | comm -23 - <(printf '%s\n' "$modules"))"

module() { yq -N "select(.kind == \"PromptModule\" and .metadata.name == \"$1\") | .spec.content" <<<"$out"; }
has() { grep -cF -- "$2" <<<"$(module "$1")" || true; }


check "library search leaves scheduled releases to the events agent" 1 "$(has library-search-system 'the events agent searches those and you do not')"
check "the search agents get the fixed tools only" "events-scout=find_live_events,find_scheduled library-search=find_by_author,find_released,find_title" \
  "$(yq -N 'select(.kind == "Agent" and (.metadata.name == "library-search" or .metadata.name == "events-scout")) | .metadata.name + "=" + (.spec.enabledTools | sort | join(","))' <<<"$out" | sort | paste -sd' ')"
check "the curator reads artifacts only" 0 \
  "$(yq -N 'select(.kind == "Agent" and .metadata.name == "curator") | .spec.enabledTools[]' <<<"$out" | grep -vc '^artifact_' || true)"
check "no agent lists the raw search tool" 0 \
  "$(yq -N 'select(.kind == "Agent") | .spec.enabledTools[]' <<<"$out" | grep -c '^search_oreilly_content$' || true)"
check "no prompt names the raw search tool or builds search arguments" 0 \
  "$(yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$out" | grep -cE 'search_oreilly_content|date_range|content_types|n_items|order_by|author_filter|get_current_time' || true)"
check "the tools take one text argument and build the search" 1 "$(has tooler-discipline 'ASSERT each search tool takes one text argument and builds the search itself')"
check "the tooler passes the status label on" 1 "$(has tooler-discipline 'pass it on exactly as returned')"
check "library search has the two released tools" 1 "$(has library-search-system 'ASSERT find_by_author(name) returns one author')"
check "the events agent has the scheduled and live tools" 1 "$(has events-scout-system 'ASSERT find_scheduled(topic) returns books, videos, and courses')"
check "an author is searched by name" 1 "$(has library-search-system 'THEN call find_by_author with the author'"'"'s full name')"
check "the status label is used as given" 1 "$(has response-style 'ASSERT every item carries a status, Released or Scheduled')"
check "the curator opens with Released and Scheduled groups" 1 "$(has analyst-review-protocol 'ALWAYS open your contribution with two groups, Released and Scheduled')"
check "the coordinator compares no dates" 1 "$(has synthesis-prompt 'you have no clock and compare no dates')"
check "an explicit order sets the sequence in the curator" 1 "$(has curator-system 'sets the sequence of the released items, over relevance_score')"
check "an explicit order sets the sequence in the coordinator" 1 "$(has synthesis-prompt 'the released items follow that order by publication_date')"
check "a search is never sent twice" 1 "$(has tooler-discipline 'NEVER send a search call identical to one you already sent in this turn')"
check "the curator never concludes from the head of an artifact" 1 "$(has analyst-review-protocol 'artifact_head shows only the start of an artifact')"
all_modules="$(yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$out")"
check "no prompt text says advisory (the word the coordinator repeated to users)" 0 \
  "$(grep -ci 'advisory' <<<"$all_modules" || true)"
check "an author's list holds only items that name the author" 1 \
  "$(has response-style "WHEN the question asks for an author's own work")"
check "an empty author list says the catalog lists nothing by that author" 1 \
  "$(has response-style 'WHEN none remain THEN say the catalog lists nothing by that author')"
check "the author rule is scoped to a request for the author's work" 1 \
  "$(has response-style 'applies to a request for an author')"
check "the author rule leaves live events listed" 1 "$(has response-style 'a live event stays listed with its start dates')"
check "the retired date-filter vocabulary is gone" 0 \
  "$(grep -cE 'Scheduled or Upcoming|upcoming or an early release|Today is <|release filter|artifact author|argument-types' <<<"$all_modules" || true)"
words=(zero one two three four five six seven eight nine ten)
count="$(find "${chart}/fitness" -maxdepth 1 -name '*.adl' | wc -l | tr -d ' ')"
check "the README states the scenario count" 1 "$(grep -cF "holds ${words[$count]} scenarios" "${chart}/README.md" || true)"
all_modules="$(yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$out")"

# Grounding: no answer comes from model memory. Every agent reads the provenance rule, the
# search agents fail on a missing, failing, or empty tool, and the answer lists nothing
# without catalog results.
check "every Agent reads catalog-grounding" "curator,events-scout,library-search,oguide-coordinator" \
  "$(yq -N 'select(.kind == "Agent" and (.spec.promptRefs | contains(["catalog-grounding"]))) | .metadata.name' <<<"$out" | sort | paste -sd,)"
check "the search agents read tooler-discipline" "events-scout,library-search" \
  "$(yq -N 'select(.kind == "Agent" and (.spec.promptRefs | contains(["tooler-discipline"]))) | .metadata.name' <<<"$out" | sort | paste -sd,)"
check "catalog-grounding names this turn's search results as the only source" 1 \
  "$(has catalog-grounding 'ASSERT the ONLY source of items is the output of your search tool calls made in this turn')"
check "a missing search tool is NO_DATA" 1 \
  "$(has tooler-discipline 'WHEN your search tools are not among your tools THEN respond NO_DATA')"
check "NO_DATA means could not be searched, and only that" 1 \
  "$(has tooler-discipline 'ASSERT NO_DATA means the catalog could not be searched, and only that')"
check "a search that found nothing is not a failure" 1 \
  "$(has tooler-discipline 'ASSERT a search that ran and found nothing is not a failure')"
check "no rule makes an empty search NO_DATA" 0 \
  "$(grep -cE 'every search returned nothing THEN respond NO_DATA|NO_DATA: the O.Reilly catalog returned nothing' <<<"$(yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$out")" || true)"
check "library search looks a named item up by title" 1 "$(has library-search-system 'THEN call find_title with the title')"
check "a failing search tool is NO_DATA" 1 \
  "$(has tooler-discipline 'WHEN a search tool answers with an error THEN respond NO_DATA')"
check "both search agents defer to those rules" 2 \
  "$(yq -N 'select(.kind == "PromptModule" and (.metadata.name == "library-search-system" or .metadata.name == "events-scout-system")) | .spec.content' <<<"$out" | grep -cF 'handled by the tool-unavailable rules of the tooler-discipline module' || true)"
check "catalog-grounding drops a link outside the reader" 1 \
  "$(has catalog-grounding "WHEN an item's url does not start with https://learning.oreilly.com/ THEN drop the item")"
check "catalog-grounding stops with no items when there are no results" 1 \
  "$(has catalog-grounding 'list no title and no link, and stop')"
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

# Argument types and artifact reading: the search agents send typed parameters, and the curator
# reads past error lines at the head of an artifact before it concludes anything.
check "an explicit order sets the sequence in the curator" 1 \
  "$(has curator-system 'sets the sequence of the released items, over relevance_score')"
check "an explicit order sets the sequence in the coordinator" 1 \
  "$(has synthesis-prompt 'the released items follow that order by publication_date')"
# These checks guard the rendered rules; whether the models follow them shows in the fitness scenarios.
check "a reader link is written exactly as returned" 1 "$(has response-style 'ASSERT a reader link is written exactly as the catalog returned it')"
check "the empty-catalog scenario forbids a plan from general knowledge" 1 "$(grep -cF '"common knowledge" AND "general knowledge")' "${chart}/fitness/catalog-empty-no-titles.adl")"
check "the coordinator writes nothing of its own without results" 1 "$(has coordinator-decision-logic 'Write nothing else: no learning path, plan, reading list')"
check "a learning-path request is a library question" 1 "$(has coordinator-decision-logic 'is a question about the O'"'"'Reilly library whether or not it names O'"'"'Reilly')"
check "session dates are written in full" 1 "$(has response-style 'ASSERT every session date is written in full as the catalog returns it')"
check "the curator reports a failed search only as could not be searched" 1 "$(has analyst-review-protocol "WHEN every search agent failed or reported NO_DATA (could not search) THEN respond only: NO_DATA")"
check "a failed search is never reported as nothing found" 1 "$(has analyst-review-protocol 'when the search did not run; say only that the catalog could not be searched')"
check "the coordinator never turns a failure into nothing found" 1 "$(has coordinator-decision-logic 'and never say that nothing was found or that no items exist')"
check "the coordinator separates could not search from found nothing" 1 "$(has coordinator-decision-logic 'WHEN the searches ran and the agents say nothing was found')"
check "the coordinator names no tool and gives no advice after a failure" 1 "$(has coordinator-decision-logic 'Name no tool and no internal term, and give no advice')"
check "the typed-argument learning-path scenario ships" 1 "$(yq -N 'has("learning-path-uses-found-results.adl")' <<<"$scenarios" | grep -c true)"
check "the typed-argument learning-path scenario forbids the give-up wording" 1 \
  "$(grep -cF 'ASSERT(synthesis does NOT CONTAIN "no usable data" AND "tooling error"' "${chart}/fitness/learning-path-uses-found-results.adl")"

check "the empty-catalog scenario ships" 1 "$(yq -N 'has("catalog-empty-no-titles.adl")' <<<"$scenarios" | grep -c true)"
check "the empty-catalog scenario forbids every link" 1 \
  "$(grep -cF 'ASSERT(synthesis does NOT CONTAIN "http" AND "](" AND "oreilly.com/book/"' "${chart}/fitness/catalog-empty-no-titles.adl")"
check "the empty-catalog scenario asserts no specialist agreement" 0 \
  "$(grep -c 'specialist contributes' "${chart}/fitness/catalog-empty-no-titles.adl" || true)"

# The search server's own tests: date labelling, sorting, argument construction, the failure path.
check "the search server tests pass" 0 \
  "$(python3 -I -m unittest discover -s "${chart}/search-server" -p 'test_*.py' >/dev/null 2>&1; echo $?)"

# The goose seat: off by default, one extra Agent run by goose when on.
goose="$(render --set gooseSeat.enabled=true)"
gagent() { yq -N -o=json -I=0 "select(.kind == \"Agent\" and .metadata.name == \"goose-curator\") | $1" <<<"$goose"; }
check "the goose seat is off by default" 0 "$(grep -c 'goose' <<<"$out" || true)"
check "the goose seat adds one Agent" "curator,events-scout,goose-curator,library-search,oguide-coordinator" \
  "$(yq -N 'select(.kind == "Agent") | .metadata.name' <<<"$goose" | sort | paste -sd,)"
check "the goose seat adds one PromptModule" 12 "$(yq -N 'select(.kind == "PromptModule") | .metadata.name' <<<"$goose" | grep -c .)"
check "the goose seat declares the sidecar harness" '{"name":"goose","mode":"sidecar","nativeTools":"none"}' "$(gagent '.spec.harness')"
check "the goose seat names no image and no model" "null,null" "$(gagent ".spec.harness.image"),$(gagent ".spec.model")"
check "the goose seat is a tooler with the fixed search tools" '"tooler",["find_by_author","find_released","find_title"]' \
  "$(gagent '.spec.discussRole'),$(gagent '.spec.enabledTools | sort')"
check "the goose seat carries the crew label" '"oguide"' "$(gagent '.metadata.labels."kubemoot.ai/crew"')"
check "the goose seat name is a value" '"goose-two"' "$(render --set gooseSeat.enabled=true --set gooseSeat.name=goose-two | yq -N -o=json -I=0 'select(.kind == "Agent" and .spec.harness.name == "goose") | .metadata.name')"
check "every goose promptRef names a shipped PromptModule" "" \
  "$(yq -N 'select(.kind == "Agent") | .spec.promptRefs[]' <<<"$goose" | sort -u | comm -23 - <(yq -N 'select(.kind == "PromptModule") | .metadata.name' <<<"$goose" | sort))"
check "only the goose seat has a harness" "goose-curator" \
  "$(yq -N 'select(.kind == "Agent" and .spec.harness != null) | .metadata.name' <<<"$goose")"
check "the other Agents render the same with the goose seat on" "$(yq -N 'select(.kind == "Agent" and .metadata.name != "goose-curator")' <<<"$goose" | md5sum)" \
  "$(yq -N 'select(.kind == "Agent")' <<<"$out" | md5sum)"
check "the goose prompt names no raw search tool" 0 \
  "$(yq -N 'select(.kind == "PromptModule" and .metadata.name == "goose-curator-system") | .spec.content' <<<"$goose" | grep -cE 'search_oreilly_content|date_range|content_types|n_items|order_by|author_filter|get_current_time|advisory' || true)"

# network.allowedIngress renders spec.network only when set, so a Crew still applies to a
# Kubemoot whose CRD has no network field.
crew_spec() { render "$@" | yq -N -o=json -I=0 'select(.kind == "Crew") | .spec'; }
check "the default renders no network key" "false" "$(crew_spec | yq -p=json 'has("network")')"
check "an empty allowedIngress renders no network key" "false" "$(crew_spec --set-json 'network.allowedIngress=[]' | yq -p=json 'has("network")')"
check "one allowedIngress selector renders exactly" \
  '{"allowedIngress":[{"matchLabels":{"kubernetes.io/metadata.name":"homelab-pilot"}}]}' \
  "$(crew_spec --set 'network.allowedIngress[0].matchLabels.kubernetes\.io/metadata\.name=homelab-pilot' | yq -p=json -o=json -I=0 '.network')"
two="$(crew_spec -f - <<'VALUES' | yq -p=json -o=json -I=0 '.network'
network:
  allowedIngress:
    - matchLabels:
        kubernetes.io/metadata.name: homelab-pilot
    - matchExpressions:
        - key: team
          operator: In
          values: [web, edge]
VALUES
)"
check "two allowedIngress selectors render exactly, in order" \
  '{"allowedIngress":[{"matchLabels":{"kubernetes.io/metadata.name":"homelab-pilot"}},{"matchExpressions":[{"key":"team","operator":"In","values":["web","edge"]}]}]}' "$two"

egress_fail() { echo "FAIL $*"; failures=$((failures + 1)); }
# egress.mcpServers.<name> and egress.agents.<name> copy a map verbatim into that resource's
# spec.egress. Nothing renders by default, so a Kubemoot without egress policies still
# applies the chart, and a field the operator adds later needs no chart change.
egress_extra=(--set gooseSeat.enabled=true)
egress_render() { render "${egress_extra[@]}" "$@"; }
# egress_holders RENDERED: Kind/name of every MCPServer and Agent that has spec.egress.
egress_holders() {
  yq -N 'select(.kind == "MCPServer" or .kind == "Agent") | select(.spec | has("egress")) | .kind + "/" + .metadata.name' <<<"$1" | paste -sd, -
}
egress_out="$(egress_render)"
[ -z "$(egress_holders "$egress_out")" ] || egress_fail "the default renders spec.egress: $(egress_holders "$egress_out")"
want_egress='{"allowedHosts":["api.example.com"],"ports":[443]}'
egress_count=0
for kind in MCPServer Agent; do
  key=mcpServers; other=agents
  if [ "$kind" = Agent ]; then key=agents; other=mcpServers; fi
  for name in $(yq -N "select(.kind == \"$kind\") | .metadata.name" <<<"$egress_out"); do
    # An entry renders on that resource only.
    got="$(egress_render --set-json "egress={\"$key\":{\"$name\":$want_egress}}")"
    [ "$(egress_holders "$got")" = "$kind/$name" ] || egress_fail "egress.$key.$name must render on $kind/$name only, got: $(egress_holders "$got")"
    [ "$(yq -N -o=json -I=0 "select(.kind == \"$kind\" and .metadata.name == \"$name\") | .spec.egress" <<<"$got")" = "$want_egress" ] \
      || egress_fail "egress for $name did not render verbatim"
    # The same name under the other kind renders nothing.
    got="$(egress_render --set-json "egress={\"$other\":{\"$name\":$want_egress}}")"
    [ -z "$(egress_holders "$got")" ] || egress_fail "egress.$other.$name must not reach $kind/$name"
    egress_count=$((egress_count + 1))
  done
done
[ "$egress_count" -gt 0 ] || egress_fail "no MCPServer or Agent found to test"
# An unknown name renders nothing, leaves the output unchanged, and does not fail.
got="$(egress_render --set-json 'egress={"mcpServers":{"no-such-server":{"allowedHosts":["x.example.com"]}},"agents":{"no-such-agent":{"apiServer":true}}}')"
[ "$got" = "$egress_out" ] || egress_fail "an unknown name changed the output"
egress_render --set-json 'egress=null' >/dev/null || egress_fail "egress=null does not render"
# A field the chart does not know copies through unchanged.
first="$(yq -N 'select(.kind == "Agent") | .metadata.name' <<<"$egress_out" | sed -n 1p)"
got="$(egress_render --set-json "egress={\"agents\":{\"$first\":{\"apiServer\":true,\"future\":{\"a\":[1,2]}}}}")"
[ "$(yq -N -o=json -I=0 "select(.kind == \"Agent\" and .metadata.name == \"$first\") | .spec.egress" <<<"$got")" = '{"apiServer":true,"future":{"a":[1,2]}}' ] \
  || egress_fail "an unlisted egress field was not copied verbatim"
echo "PASS: egress values (${egress_count} resources)"

if [ "$failures" -ne 0 ]; then echo "${failures} test(s) failed"; exit 1; fi
echo "all O'guide render tests passed"
