#!/usr/bin/env bash
# For one rendering of a crew chart: no agent's PromptModules name a tool the agent does not
# have. A module names a tool when it contains a tool name used by any agent under the
# "vocabulary" rendering (the chart with every optional tool switched on). Needs helm and yq.
#
# Usage: scripts/check-module-tools.sh CHART_DIR [helm args for the rendering to check...]
# Environment: VOCAB_ARGS (helm args for the vocabulary rendering, default: the same args),
#              IGNORE_WORDS (space separated tool names that are also ordinary words).
# Exit 0 = every agent names only its own tools; 1 = a module names a tool its agent lacks.
set -euo pipefail
chart="$1"
shift
ignore=" ${IGNORE_WORDS:-analyze search} "
# shellcheck disable=SC2206
vocab_args=(${VOCAB_ARGS:-"$@"})

render() { helm template t "$chart" --set ragSources.enabled=false --set vectorStore.host=db.test "$@"; }

vocab="$(render "${vocab_args[@]}" | yq -N 'select(.kind == "Agent") | .spec.enabledTools // [] | .[]' | sort -u)"
out="$(render "$@")"
failures=0
while IFS= read -r agent; do
  own="$(yq -N "select(.kind == \"Agent\" and .metadata.name == \"$agent\") | .spec.enabledTools // [] | .[]" <<<"$out")"
  for module in $(yq -N "select(.kind == \"Agent\" and .metadata.name == \"$agent\") | .spec.promptRefs // [] | .[]" <<<"$out"); do
    content="$(yq -N "select(.kind == \"PromptModule\" and .metadata.name == \"$module\") | .spec.content" <<<"$out")"
    while IFS= read -r tool; do
      [ -n "$tool" ] || continue
      case "$ignore" in *" $tool "*) continue ;; esac
      grep -qxF "$tool" <<<"$own" && continue
      # a whole name: hyphens and underscores belong to the name, so proxmox-list-vms is not found in proxmox-list-vms-all
      escaped="$(sed 's/[][\.*^$+?(){}|/-]/\\&/g' <<<"$tool")"
      if grep -qE "(^|[^A-Za-z0-9_-])${escaped}($|[^A-Za-z0-9_-])" <<<"$content"; then
        echo "FAIL agent $agent: module $module names the tool $tool, which the agent does not have" >&2
        failures=$((failures + 1))
      fi
    done <<<"$vocab"
  done
done < <(yq -N 'select(.kind == "Agent") | .metadata.name' <<<"$out")
[ "$failures" -eq 0 ]
