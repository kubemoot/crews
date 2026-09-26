# homelab-pilot-crew

Kubemoot agent crew for homelab infrastructure consultation.

A multi-specialist crew that answers questions spanning the four layers of a homelab — **physical/hypervisor** (Proxmox), **Kubernetes**, **observability** (Prometheus + DCGM), and **GPU/AI** (NVIDIA + Ollama). Discussions are coordinated through the Kubemoot consensus protocol: the coordinator generates an advisory, selects a relevant subcommittee of specialists via triage, and synthesizes their findings into a single answer.

## Before you install

This crew is the reference homelab's own. Its Proxmox specialists use a `proxmox-mcp`
tool image built from a private repository and pulled from that homelab's registry,
so a copy of this chart on another cluster needs its own Proxmox MCP server (or
the Proxmox agents removed). Everything else in the chart is public.

## Topology

- **1 coordinator** (`homelab-coordinator`) — declares `reasoning` capability; binds to a quality-tier model (e.g. qwen3:32b)
- **21 specialists** spanning Kubernetes (`k8s-*`), observability (`obs-*`), GPU monitoring (`nvidia-gpu-*`), Proxmox (`proxmox-*`), scheduling, and internet search — declare `tool-calling` plus their domain capability; bind to speed-tier models (e.g. qwen3:8b) via `CrewSchedulingPolicy.spec.qualityBias`

Model selection is loose-coupled — no agent CR names a specific model. See [`kubemoot/docs/scheduler.md`](https://github.com/kubemoot/kubemoot/blob/main/docs/scheduler.md) "Quality bias" for the mechanism.

## Layout

```
homelab-pilot-crew/
  Chart.yaml
  values.yaml
  templates/
    agent-*.yaml              # individual agent definitions
    promptmodule-*.yaml       # composable ADL behavior modules
    mcpserver-*.yaml          # tool servers (proxmox, kubernetes, observability, internet)
    crewschedulingpolicy.yaml # phase rules + qualityBias
    crew.yaml                 # top-level Crew CR
    models.yaml               # Model CRs labeled by family/params/latencyClass
    ...
  fitness/                    # CrewFitness scenarios (10 today) — measurable test cases
  mcp-smoke/                  # MCP tool smoke tests — verify each MCP server's tools respond
```

## Deployment

The chart publishes to `oci://ghcr.io/kubemoot/charts/homelab-pilot-crew` via the per-crew release workflow on commit to main (and to an in-cluster mirror when one is configured). Flux pulls the chart from an OCI source and applies it to the cluster.

## Fitness

Ten scenarios in `fitness/` cover:

- Kubernetes — pod status, helm releases, storage classes
- GPU — live utilization queries, concept-RAG retrieval
- Proxmox — VM listing, concept-RAG retrieval
- Observability — Prometheus queries
- Multi-tool troubleshooting

Run the suite via CrewForge's fitness runner (in development).
