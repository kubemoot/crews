# homelab-pilot-crew

The Kubemoot reference crew: a coordinator and up to 22 specialists that answer operational questions about a cluster across four layers, **Kubernetes**, **observability** (Prometheus and DCGM), **GPU/AI** (NVIDIA and Ollama), and optionally **physical/hypervisor** (Proxmox VE). Discussions run on the Kubemoot consensus protocol: the coordinator writes an advisory, selects a subcommittee of relevant specialists, and synthesizes their findings into one answer. Every prompt is written in ADL.

## Before you install

This crew was built for the maintainer's homelab: a Talos Kubernetes cluster on Proxmox VE, with two GPU nodes that each run a model server, kube-prometheus-stack, and a pgvector database. The chart defaults are generic; this is what you supply or change for your cluster:

| Value | Default | What to set |
|---|---|---|
| `embeddingModel.providerRef` | `ollama-local` | The ModelProvider that serves `nomic-embed-text`. |
| `vectorStore.host`, `.database`, `.existingSecret` | empty (required) | Your pgvector database and a Secret with its credentials. Or set `ragSources.enabled=false` and `mcpGateway.toolIndex=null` to run without RAG. |
| `mcpGateway.toolIndex.embeddingModel.endpoint` | `http://ollama.ollama:11434` | An Ollama URL that serves the embedding model. |
| `mcpServers.prometheus.endpoint` | `http://kube-prometheus-stack-prometheus.monitoring:9090` | Your Prometheus. |
| `mcpServers.proxmox.*` | disabled | Proxmox needs your own Proxmox MCP image and an API-credentials Secret. No public image ships with Kubemoot. The `proxmox-pve` and `proxmox-qm` agents render only when this is enabled; `proxmox-advisor` answers from Proxmox documentation (RAG) and always renders. |
| `mcpServers.scheduling.enabled` | `false` | Reminders and follow-ups. The scheduling-mcp image is published to GHCR as `ghcr.io/kubemoot/scheduling-mcp`, and each chart release pins the latest Kubemoot release of it at build. The `scheduler-advisor` agent renders only when this is enabled. |
| `kubernetesAccess.secretRead`, `.writeAccess` | `false` | See [Cluster permissions](#cluster-permissions). |
| `nats.url`, `nats.namespace` | release `nats` in namespace `nats` | Your NATS JetStream. |

The prompts and fitness scenarios also carry the reference cluster's vocabulary (host aliases such as `rig0`, two GPUs, its namespaces). The crew discovers the real topology at run time, so they work elsewhere, but the fitness reference answers describe the maintainer's cluster and will not match yours.

See the [repository README](../README.md#install) for prerequisites and the install command.

## Cluster permissions

The Kubernetes MCP servers (`kubernetes-mcp`, `kubernetes-legacy-mcp`, and k8sgpt) share one ServiceAccount. By default it is read-only: the built-in `view` ClusterRole plus get/list/watch on Flux, storage, networking, metrics, and Kubemoot resources, and the servers run in their read-only modes.

- `kubernetesAccess.secretRead: true` adds cluster-wide Secret reads. `helm_list` needs it, because Helm stores release state in Secrets; without it the `k8s-helm` agent has no Helm tools and falls back to the read-only resource tools.
- `kubernetesAccess.writeAccess: true` adds `pods/exec`, patch and scale on workloads, and the `pods_exec`, `resources_scale`, `helm_install`, and `helm_uninstall` agent tools.

Agents act on text they read from tools and the web, so treat either setting as giving that access to anyone who can put text in front of the crew.

## Topology

- **1 coordinator** (`homelab-coordinator`) declares the `reasoning` capability and leans to a large model.
- **Up to 22 specialists** (19 with the chart defaults, which leave Proxmox VE and scheduling off) cover Kubernetes (`k8s-*`, `k8sgpt`), observability (`obs-*`), GPU monitoring (`nvidia-gpu-*`), Proxmox (`proxmox-*`), computation (`compute`), scheduling, and internet search. They declare `tool-calling` plus their domain capability, and lean to medium models through `CrewSchedulingPolicy.spec.qualityBias`.

## Models

The chart ships no Model objects and names no provider for its chat models. The cluster owner's model catalog supplies them: the Model objects in the operator namespace plus the models each ModelProvider reports. The crew's CrewSchedulingPolicy says what each phase needs, by the labels the catalog carries:

- **Mulling** (the agents' tool work and answers) requires `capability/tool-calling`. Size follows each agent's declared capabilities through `qualityBias`: the coordinator, which declares `reasoning`, leans to `kubemoot.ai/size: large`, and the specialists to `medium`.
- **Triage** (subcommittee selection, the advisory, and relevance checks) requires `capability/tool-calling` and prefers the model measured fastest (`preferFaster: 50`). Speed is measured on each provider, so the cluster decides which model that is; a small model on a CPU is not assumed to be fast.

One chat model with tool-calling is enough to run the crew: every phase falls back to it. The policy's status condition `CatalogMode` reports `Cluster` once the crew selects from the catalog. After an upgrade from a release that shipped Models, the upgrade removes them; if `CatalogMode` still reads `CrewLocal`, Models remain in the crew namespace and the crew uses only those. See the Kubemoot scheduler documentation, sections "Quality bias", "Selecting from the model catalog", and "Preferring the faster model".

The embedding model still names its provider, in `embeddingModel.providerRef`.

## Layout

```
homelab-pilot-crew/
  Chart.yaml
  values.yaml
  templates/
    agent-*.yaml              # agent definitions
    promptmodule-*.yaml       # composable ADL behavior modules
    mcpserver-*.yaml          # tool servers (kubernetes, prometheus, proxmox, web search, ...)
    crewschedulingpolicy.yaml # phase rules and qualityBias
    crew.yaml                 # top-level Crew resource
  fitness/                    # CrewFitness scenarios in ADL
  mcp-smoke/                  # MCP tool smoke-test definitions
```

## Fitness

`fitness/` holds 76 scenarios in ADL (`*.adl`), grouped by prefix: smoke, single-domain Kubernetes, GPU, observability, and Proxmox questions, cross-domain (`xdomain-*`, `multi-tool-*`), judgment, constraint-following, and trap questions (`gotcha-*`, `partial-answerable-*`). Scenarios that use `DEFER synthesis REFLECTS` need the [kubemoot-fitness-crew](../kubemoot-fitness-crew/) judge installed.

The chart deploys the scenarios with the crew as one ConfigMap, `homelab-pilot-fitness`, labeled `kubemoot.ai/crew` and `kubemoot.ai/fitness-kind: scenarios`. CrewForge and the dashboard list them from it; nothing runs until someone starts a run.

Run a scenario with `kmctl fitness run`, or apply a `CrewFitness` resource with `kubectl`. To run all of them as one `CrewFitnessSuite`, assemble it with [`scripts/build-suite.py`](../scripts/build-suite.py):

```bash
python3 scripts/build-suite.py homelab-pilot-crew/fitness \
  --namespace crew-homelab-pilot --crew-ref homelab-pilot --name baseline-n10 --iterations 10
```

## Placement policy

`crew.placementPolicy` chooses how Kubemoot places this crew's model calls: `algorithm`,
`learned` (each call goes where it is predicted to finish soonest, from the providers'
calibrated and observed speeds), or `shadow` (`algorithm` places; the learned choice is
logged beside it). Empty, the default, inherits the cluster's default. See the Kubemoot
scheduler documentation, section "Placement policy".

## Deployment

The per-crew release workflow publishes the chart to `oci://ghcr.io/kubemoot/charts/homelab-pilot-crew` on each release commit to `main`.
