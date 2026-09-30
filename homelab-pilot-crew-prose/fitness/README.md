# Fitness Suite, homelab-pilot-crew-prose

Curated CrewFitness scenarios for the prose crew, covering single-agent, multi-agent, RAG, and out-of-scope behavior. Run one with `kmctl fitness run`, or put its text in a `CrewFitness` resource's `spec.testContent`.

Each `.md` file is the prose Markdown form of the matching ADL scenario in `homelab-pilot-crew/fitness/`: the same question, assertions, and reference answer. The ADL form is shown below. The parser is `kubemoot/fitness-runner/parser.go`.

## Scenario shape

```
DESCRIPTION <one-line summary>

DEFINE CONST QUESTION AS "<the question to ask the crew>"
DEFINE CONST MAX_DURATION AS <N> seconds

ASSERT(<assertion 1>)
ASSERT(<assertion 2>)
...
```

Supported assertion kinds (parser-recognized; anything else degrades to manual review):

- `POST to discussion endpoint returns 200 with conversationId`
- `SSE stream emits "<event>" event`
- `SSE stream emits "<event>" event within N seconds`
- `discussion completes with "done" event within MAX_DURATION`
- `at least N specialist(s) contribute with signal=agree`
- `coordinator produces synthesis`
- `synthesis is non-empty`
- `synthesis CONTAINS "<term>" AND "<term>"...` (case-insensitive)
- `synthesis does NOT CONTAIN "<term>"...` (case-insensitive)

## Suite organization

| File | Layer | What it tests |
|---|---|---|
| `smoke-cluster-namespaces.md` | Smoke | Basic crew responsiveness; gateway + SSE + synthesis happy path |
| `smoke-out-of-scope.md` | Smoke | Stand-aside behavior on irrelevant questions (no fabrication) |
| `k8s-pod-status.md` | Single-agent | k8s-workloads; pod health for a namespace |
| `k8s-pod-errors-clusterwide.md` | Single-agent | k8s-workloads; not-Running pods across all namespaces |
| `k8s-events-concerning.md` | Single-agent | k8s-workloads; Warning-level events |
| `k8s-nodes-capacity.md` | Single-agent | k8s-workloads; node capacity / allocatable |
| `k8s-metrics-top-consumers.md` | Single-agent | k8s-workloads; top CPU/memory consumers |
| `k8s-scaling-quotas.md` | Single-agent | k8s-workloads; ResourceQuota / scaling headroom |
| `k8s-services-endpoints.md` | Single-agent | k8s-workloads; Services + endpoint readiness |
| `k8s-statefulset-purpose.md` | Single-agent | k8s-workloads; enumerate StatefulSets + purpose |
| `k8s-storage.md` | Single-agent | k8s-storage |
| `k8s-helm-releases.md` | Single-agent | k8s-helm |
| `gpu-utilization-live.md` | Single-agent | nvidia-gpu-now (live state via execute_query) |
| `gpu-utilization-all-rigs.md` | Single-agent | nvidia-gpu-now; util/VRAM/temp per rig |
| `gpu-metrics-discovery.md` | Single-agent | nvidia-gpu-meta; available DCGM metrics + scrape-target health |
| `gpu-trend-history.md` | Single-agent | nvidia-gpu-history; utilization trend over a window |
| `gpu-concept-rag.md` | Single-agent (RAG) | nvidia-gpu-advisor; RAG retrieval quality |
| `proxmox-vm-list.md` | Single-agent | proxmox (requires `proxmox-secret` in crew namespace) |
| `proxmox-node-health.md` | Single-agent | proxmox; hypervisor node health |
| `proxmox-concept-rag.md` | Single-agent (RAG) | proxmox-advisor; RAG retrieval quality |
| `observability-prometheus.md` | Single-agent | observability (Prometheus queries) |
| `obs-concept-rules.md` | Single-agent (RAG) | observability; alerting/recording-rules concepts |
| `scheduler-list-pending.md` | Single-agent | scheduler; pending agent assignments |
| `internet-search-cilium.md` | Single-agent | internet-search researcher role |
| `k8s-concept-rag.md` | Single-agent (RAG) | k8s-advisor; RAG retrieval quality |
| `multi-tool-troubleshooting.md` | Multi-agent | Cross-agent coordination on a diagnostic question |

## How to run

**One scenario:** `kmctl fitness run`, or apply a `CrewFitness` resource with the scenario text in `spec.testContent`.

**Suite runs for measurement:** a `CrewFitnessSuite` runs a set of scenarios N times each against one crew and exports per-run results as XLSX. See the Kubemoot fitness documentation (`docs/user-guides/define-fitness-functions.md` in the kubemoot repository).

## When to add a scenario

- New agent or capability lands → add a single-agent scenario exercising it
- A regression escapes → add a scenario that would have caught it
- A new cross-agent flow → add a multi-tool scenario

Don't add scenarios that only one specific deployment can pass (cluster-specific data). Keep questions answerable against any healthy pilot crew.
