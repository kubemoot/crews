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
check "only the search agents have the catalog tool" "events-scout,library-search" \
  "$(yq -N 'select(.kind == "Agent" and (.spec.enabledTools // [] | contains(["search_oreilly_content"]))) | .metadata.name' <<<"$out" | sort | paste -sd,)"

module() { yq -N "select(.kind == \"PromptModule\" and .metadata.name == \"$1\") | .spec.content" <<<"$out"; }
has() { grep -cF -- "$2" <<<"$(module "$1")" || true; }

# The clock: the MCP reference Time server, pinned by digest, read by the curator.
timesrv() { yq -N 'select(.kind == "MCPServer" and .metadata.name == "time-mcp") | '"$1" <<<"${2:-$out}"; }
check "the Time server image is pinned by digest" 1 "$(timesrv .spec.image | grep -cE '^docker\.io/mcp/time@sha256:[0-9a-f]{64}$' || true)"
check "the Time server runs stdio through its own command" "mcp-server-time,--local-timezone,UTC" \
  "$(timesrv '.spec.command[]' | paste -sd,)"
check "the Time server zone is a value" "Europe/London" \
  "$(timesrv '.spec.command[2]' "$(render --set mcpServers.time.localTimezone=Europe/London)")"
check "the Time server is contained" "false,[ALL]" \
  "$(timesrv '.spec.securityContext.allowPrivilegeEscalation' ),$(timesrv '.spec.securityContext.capabilities.drop' | yq -o=json -I=0 '.' 2>/dev/null | tr -d '"' )"

check "the curator reads artifacts only" 0 \
  "$(yq -N 'select(.kind == "Agent" and .metadata.name == "curator") | .spec.enabledTools[]' <<<"$out" | grep -vc '^artifact_' || true)"
check "the search agents read the clock" "events-scout,library-search" \
  "$(yq -N 'select(.kind == "Agent" and (.spec.enabledTools // [] | contains(["get_current_time"]))) | .metadata.name' <<<"$out" | sort | paste -sd,)"
check "library search calls get_current_time first" 1 "$(has library-search-system 'ALWAYS call get_current_time with the timezone "UTC" first')"
check "library search returns released items only" 1 "$(has library-search-system 'ASSERT every search for recorded content carries date_range')"
check "events agent searches scheduled releases from today" 1 "$(has events-scout-system 'start_date": "<today>"')"
check "release status comes from the search, not from a date comparison" 1 "$(has response-style 'Whether an item is released comes from the search that returned it')"
check "the coordinator takes status from the source" 1 "$(has synthesis-prompt 'you have no clock, you compare no dates')"
check "the coordinator selects the events agent for what is coming" 1 "$(has advisory-prompt 'an author'"'"'s next work THEN select the events agent as well')"
check "search-discipline names the release-filter exception in its ASSERT" 1 "$(has tooler-discipline 'ASSERT date_range is set in only two cases')"
check "the scheduled search is outside the four-search budget" 1 "$(has tooler-discipline "the events agent's scheduled-releases search, which is extra")"
check "the events agent calls the clock only for the scheduled search" 1 "$(has events-scout-system 'WHEN you run the scheduled-releases search THEN call get_current_time')"
check "the events agent's live searches keep content_types, the scheduled one has none" 1 "$(has events-scout-system 'for every event search, except the scheduled-releases search below')"
check "a missing clock is NO_DATA for the search agents" 1 "$(has tooler-discipline 'WHEN get_current_time is not among your tools THEN respond NO_DATA')"
check "the curator names the artifact author as the source of status" 1 "$(has analyst-review-protocol 'the <agent> segment names who gathered it')"
check "an item in both artifacts is released" 1 "$(has analyst-review-protocol 'WHEN the same url appears in both artifacts THEN list the item once, as released')"
check "library search leaves scheduled releases to the events agent" 1 "$(has library-search-system 'the events agent searches those and you do not')"
words=(zero one two three four five six seven eight nine ten)
count="$(find "${chart}/fitness" -maxdepth 1 -name '*.adl' | wc -l | tr -d ' ')"
check "the README states the scenario count" 1 "$(grep -cF "holds ${words[$count]} scenarios" "${chart}/README.md" || true)"
check "author and recency searches use 25 items and no content_types" 1 "$(has library-search-system 'n_items 25, and NO content_types filter')"
check "the clock's server exists with the time capability" "time" \
  "$(timesrv '.spec.capabilities[]')"
check "the Time server filesystem is read-only" "true,RuntimeDefault" \
  "$(timesrv '.spec.securityContext.readOnlyRootFilesystem'),$(timesrv '.spec.securityContext.seccompProfile.type')"
all_modules="$(yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$out")"
check "the retired upcoming-label vocabulary is gone" 0 \
  "$(grep -cE 'Scheduled or Upcoming|upcoming or an early release|the curator states today|Today is <' <<<"$all_modules" || true)"

# Grounding: no answer comes from model memory. Every agent reads the provenance rule, the
# search agents fail on a missing, failing, or empty tool, and the answer lists nothing
# without catalog results.
check "every Agent reads catalog-grounding" "curator,events-scout,library-search,oguide-coordinator" \
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
  "$(has tooler-discipline 'WHEN a search call fails again after you changed it THEN respond NO_DATA: the O'"'"'Reilly catalog could not be searched')"
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

# Argument types and artifact reading: the search agents send typed parameters, and the curator
# reads past error lines at the head of an artifact before it concludes anything.
check "the tooler states n_items is a bare integer" 1 \
  "$(has tooler-discipline 'ASSERT n_items is a bare integer')"
check "the tooler states list parameters are JSON arrays" 1 \
  "$(has tooler-discipline 'ASSERT content_types, languages, and every other list parameter is a JSON array of strings')"
check "the tooler shows a correctly typed call" 1 \
  "$(has tooler-discipline '"content_types": ["books", "videos"], "n_items": 8')"
check "the tooler corrects a type error instead of resending" 1 \
  "$(has tooler-discipline 'NEVER resend the call unchanged')"
check "the curator never concludes from the head of an artifact" 1 \
  "$(has analyst-review-protocol 'NEVER conclude that the search agents found no data, or that the data is unusable, from the head of an artifact')"
check "the curator reads past error lines" 1 \
  "$(has analyst-review-protocol 'THEN read past them before you answer, with artifact_grep')"
check "an explicit order sets the sequence in the curator" 1 \
  "$(has curator-system 'sets the sequence of the released items, over relevance_score')"
check "an explicit order sets the sequence in the coordinator" 1 \
  "$(has synthesis-prompt 'the released items follow that order by publication_date')"
check "the curator reads artifact_tail and artifact_count past error lines" 1 \
  "$(has analyst-review-protocol 'with artifact_tail, or with artifact_count')"
# These checks guard the rendered rules; whether the models follow them shows in the fitness scenarios.
check "a date_range comes only from the question" 1 "$(has tooler-discipline 'ASSERT date_range is set in only two cases')"
check "no rule demands more than four searches" 0 "$(grep -cF 'run at least three searches' <<<"$all_modules" || true)"
check "the search budget counts the drill steps" 1 "$(has tooler-discipline 'a drill step after an empty result counts toward the four')"
check "a date range is never invented" 1 "$(has tooler-discipline 'NEVER invent a date_range')"
check "a reader link is written exactly as returned" 1 "$(has response-style 'ASSERT a reader link is written exactly as the catalog returned it')"
check "the empty-catalog scenario forbids a plan from general knowledge" 1 "$(grep -cF '"common knowledge" AND "general knowledge")' "${chart}/fitness/catalog-empty-no-titles.adl")"
check "a search is never sent twice" 1 "$(has tooler-discipline 'NEVER send a search call identical to one you already sent in this turn')"
check "the survey search budget is stated" 1 "$(has tooler-discipline 'ASSERT a gather is three to four distinct searches in all')"
check "the coordinator writes nothing of its own without results" 1 "$(has coordinator-decision-logic 'Write nothing else: no learning path, plan, reading list')"
check "a learning-path request is a library question" 1 "$(has coordinator-decision-logic 'is a question about the O'"'"'Reilly library whether or not it names O'"'"'Reilly')"
check "session dates are written in full" 1 "$(has response-style 'ASSERT every session date is written in full as the catalog returns it')"
check "the curator reports a failed search only as could not be searched" 1 "$(has analyst-review-protocol "WHEN every search agent failed, reported NO_DATA, or posted no findings THEN respond only: NO_DATA")"
check "a failed search is never reported as nothing found" 1 "$(has analyst-review-protocol 'when the search did not run; say only that the catalog could not be searched')"
check "the coordinator never turns a failure into nothing found" 1 "$(has coordinator-decision-logic 'A search that could not run is not a search that found nothing')"
check "the coordinator names no tool and gives no advice after a failure" 1 "$(has coordinator-decision-logic 'Name no tool and no internal term, and give no advice')"
check "the typed-argument learning-path scenario ships" 1 "$(yq -N 'has("learning-path-uses-found-results.adl")' <<<"$scenarios" | grep -c true)"
check "the typed-argument learning-path scenario forbids the give-up wording" 1 \
  "$(grep -cF 'ASSERT(synthesis does NOT CONTAIN "no usable data" AND "tooling error"' "${chart}/fitness/learning-path-uses-found-results.adl")"

check "the empty-catalog scenario ships" 1 "$(yq -N 'has("catalog-empty-no-titles.adl")' <<<"$scenarios" | grep -c true)"
check "the empty-catalog scenario forbids every link" 1 \
  "$(grep -cF 'ASSERT(synthesis does NOT CONTAIN "http" AND "](" AND "oreilly.com/book/"' "${chart}/fitness/catalog-empty-no-titles.adl")"
check "the empty-catalog scenario asserts no specialist agreement" 0 \
  "$(grep -c 'specialist contributes' "${chart}/fitness/catalog-empty-no-titles.adl" || true)"

if [ "$failures" -ne 0 ]; then echo "${failures} test(s) failed"; exit 1; fi
echo "all O'guide render tests passed"
