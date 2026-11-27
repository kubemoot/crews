#!/usr/bin/env bash
# For one rendering of a crew chart: no prompt text carries tool knowledge. A prompt is a
# PromptModule's content, a Skill's content or an Agent's discussRelevance.promptHint. A line
# fails when it names a tool one of the crew's MCP servers lists (the tool's description is where
# that belongs) or when it says "defer to" (an agent cannot hand a question to another; the
# coordinator chooses who answers from the declarations). Needs helm and yq.
#
# Usage: scripts/check-prompt-rules.sh CHART_DIR SERVER_TOOLS_YAML [helm args...]
# SERVER_TOOLS_YAML lists each server's tools as servers.<name>.tools and .write.
# Environment: IGNORE_WORDS (space separated tool names that are also ordinary words),
#              ALLOW_LINES (a file of prompt lines, one per line, allowed as written).
# Exit 0 = no prompt line names a tool or defers; 1 = at least one does (each is printed as a
# FAIL line on stderr); 2 = the check could not run (the render failed or the fixture lists no tool).
set -euo pipefail
chart="$1"
fixture="$2"
shift 2
ignore=" ${IGNORE_WORDS:-analyze search config} "

out="$(helm template t "$chart" --set ragSources.enabled=false --set vectorStore.host=db.test "$@")" \
  || { echo "the chart did not render" >&2; exit 2; }
tools="$(yq -N '.servers[] | (.tools // []) + (.write // []) | .[]' "$fixture" | sort -u)" \
  || { echo "cannot read $fixture" >&2; exit 2; }
allowed=""
if [ -n "${ALLOW_LINES:-}" ]; then allowed="$(sed 's/^[[:space:]]*//' "$ALLOW_LINES")"; fi

# Every prompt line, as "<where>\t<line>".
prompts() {
  yq -N 'select(.kind == "PromptModule" or .kind == "Skill") | .kind as $k | .metadata.name as $n | .spec.content | split("\n") | .[] | $k + " " + $n + "\t" + .' <<<"$out"
  yq -N 'select(.kind == "Agent" and .spec.discussRelevance.promptHint != null) | .metadata.name as $n | .spec.discussRelevance.promptHint | split("\n") | .[] | "Agent " + $n + " promptHint\t" + .' <<<"$out"
}

# One pattern of every tool name, matched as a whole name: hyphens and underscores belong to it.
names="$(while IFS= read -r tool; do
  [ -n "$tool" ] || continue
  case "$ignore" in *" $tool "*) continue ;; esac
  sed 's/[][\.*^$+?(){}|/-]/\\&/g' <<<"$tool"
done <<<"$tools" | paste -sd'|' -)"
[ -n "$names" ] || { echo "$fixture lists no tool to check for" >&2; exit 2; }
toolword="(^|[^A-Za-z0-9_-])(${names})($|[^A-Za-z0-9_-])"

lines="$(prompts | awk -F'\t' '{ t = $2; sub(/^[[:space:]]+/, "", t); if (t != "") print $1 "\t" t }')" \
  || { echo "cannot read the prompts of the rendering" >&2; exit 2; }
if [ -n "$allowed" ]; then
  lines="$(awk -F'\t' 'NR == FNR { ok[$0] = 1; next } !($2 in ok)' <(printf '%s\n' "$allowed") <(printf '%s\n' "$lines"))"
fi
deferring="$(grep -iE $'\t.*defer to' <<<"$lines" | sed 's/^/defers to another agent: /' || true)"
naming="$(grep -E $'\t'".*${toolword}" <<<"$lines" | sed 's/^/names a tool: /' || true)"
report="$(printf '%s\n%s\n' "$deferring" "$naming" | grep . || true)"
[ -z "$report" ] || { sed 's/^/FAIL /' <<<"$report" >&2; exit 1; }
