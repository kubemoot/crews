# Kubemoot Crews

Each subdirectory is an independently versioned Helm chart for a Kubemoot agent crew. Crews are the deployable unit of agent collaboration on the [Kubemoot](https://github.com/kubemoot/kubemoot) operator.

## Layout

```
crews/
  <crew-name>/
    Chart.yaml          # versioned independently per crew
    values.yaml
    templates/          # Agents, PromptModules, MCPServers, CrewSchedulingPolicy, Crew CR
    fitness/            # CrewFitness scenarios for measuring this crew
    README.md           # what this crew does
```

A crew chart deploys:

- **Agents** — the participants in the discussion
- **PromptModules** — composable ADL behavior modules referenced by agents
- **MCPServers** — tool servers the agents call
- **CrewSchedulingPolicy** — phase rules + `qualityBias` for model selection
- **Crew** — the top-level CR binding everything together
- **CrewFitness** scenarios (under `fitness/`) — measurable test cases

## Versioning

Each crew chart is **independently versioned**. Path-filtered CI per crew:

- `.github/workflows/<crew-name>-release.yaml` triggers on `<crew-name>/**`
- Semver computed from conventional commits scoped to the changed crew's path
- Per-crew tag stream (e.g. `homelab-pilot-crew-v1.2.3`)
- Per-crew chart push to the release registry, `oci://ghcr.io/kubemoot/charts/<crew-name>` (and to an in-cluster mirror when one is configured)

Crews could split into separate repos later; one repo for now keeps ergonomics for cross-crew refactors.

## Current crews

| Crew | Purpose | Chart path |
|---|---|---|
| [homelab-pilot-crew](./homelab-pilot-crew/) | Homelab infrastructure conversations: multi-layer Kubernetes + Proxmox + GPU + observability | `oci://ghcr.io/kubemoot/charts/homelab-pilot-crew` |

## Consumers

- **[CrewForge](https://github.com/kubemoot/crew-forge)** — Tauri desktop IDE reads/edits chart files here, runs fitness suites, exports results
- **[Homelab Pilot](https://github.com/kubemoot/homelab-pilot)** — pilot web app discovers deployed crews via the `kubemoot.ai/crew-type: pilot` label
- **[Kubemoot operator](https://github.com/kubemoot/kubemoot)** — reconciles the Crew CR + child resources once Flux applies the chart

## Contributing a new crew

1. Create a new subdirectory `crews/<your-crew>/` with the layout above.
2. Add a per-crew workflow `.github/workflows/<your-crew>-release.yaml` modeled on the existing ones.
3. Commit. CI will publish the chart on the first conventional-commit version bump.
