# Fitness Suite, homelab-pilot-crew

Curated CrewFitness scenarios for the pilot crew, covering single-agent, multi-agent, RAG, and out-of-scope behavior. Used by:

- CrewForge's verify page (reads `.yaml` files here, creates CrewFitness CRs with `testContent`)
- Cluster-side application via Helm-generated ConfigMap (future) + ad-hoc `kubectl apply -f` of CrewFitness CRs

Each file is plain ADL text (the file extension is `.yaml` for tooling compatibility; the content is not nested YAML). The parser is in `crew-forge/src-tauri/src/fitness.rs` and `kubemoot/fitness-runner/parser.go`.

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
| `smoke-cluster-namespaces.yaml` | Smoke | Basic crew responsiveness; gateway + SSE + synthesis happy path |
| `smoke-cluster-namespaces.yaml` | Smoke | Basic crew responsiveness; gateway + SSE + synthesis happy path |
| `smoke-out-of-scope.yaml` | Smoke | Stand-aside behavior on irrelevant questions (no fabrication) |
| `k8s-pod-status.yaml` | Single-agent | k8s-workloads; pod health for a namespace |
| `k8s-pod-errors-clusterwide.yaml` | Single-agent | k8s-workloads; not-Running pods across all namespaces |
| `k8s-events-concerning.yaml` | Single-agent | k8s-workloads; Warning-level events |
| `k8s-nodes-capacity.yaml` | Single-agent | k8s-workloads; node capacity / allocatable |
| `k8s-metrics-top-consumers.yaml` | Single-agent | k8s-workloads; top CPU/memory consumers |
| `k8s-scaling-quotas.yaml` | Single-agent | k8s-workloads; ResourceQuota / scaling headroom |
| `k8s-services-endpoints.yaml` | Single-agent | k8s-workloads; Services + endpoint readiness |
| `k8s-statefulset-purpose.yaml` | Single-agent | k8s-workloads; enumerate StatefulSets + purpose |
| `k8s-storage.yaml` | Single-agent | k8s-storage |
| `k8s-helm-releases.yaml` | Single-agent | k8s-helm |
| `gpu-utilization-live.yaml` | Single-agent | nvidia-gpu-now (live state via execute_query) |
| `gpu-utilization-all-rigs.yaml` | Single-agent | nvidia-gpu-now; util/VRAM/temp per rig |
| `gpu-metrics-discovery.yaml` | Single-agent | nvidia-gpu-meta; available DCGM metrics + scrape-target health |
| `gpu-trend-history.yaml` | Single-agent | nvidia-gpu-history; utilization trend over a window |
| `gpu-concept-rag.yaml` | Single-agent (RAG) | nvidia-gpu-advisor; RAG retrieval quality |
| `proxmox-vm-list.yaml` | Single-agent | proxmox (requires `proxmox-secret` in crew namespace) |
| `proxmox-node-health.yaml` | Single-agent | proxmox; hypervisor node health |
| `proxmox-concept-rag.yaml` | Single-agent (RAG) | proxmox-advisor; RAG retrieval quality |
| `observability-prometheus.yaml` | Single-agent | observability (Prometheus queries) |
| `obs-concept-rules.yaml` | Single-agent (RAG) | observability; alerting/recording-rules concepts |
| `scheduler-list-pending.yaml` | Single-agent | scheduler; pending agent assignments |
| `internet-search-cilium.yaml` | Single-agent | internet-search researcher role |
| `k8s-concept-rag.yaml` | Single-agent (RAG) | k8s-advisor; RAG retrieval quality |
| `multi-tool-troubleshooting.yaml` | Multi-agent | Cross-agent coordination on a diagnostic question |

## How to run

**Via CrewForge** (desktop): open the crew, click "Verify", pick a test or "Run All". Results land in CrewFitness CR status.

**Via kubectl** (manual): apply a CrewFitness CR pointing at one of these scenarios via `spec.testContent` (paste the file content) or `spec.configMapRef` (after the chart renders these into a ConfigMap).

**Suite runs for measurement** (the ADL-POC use case): see [[CrewForge Fitness Runner with XLSX Export]] in the homelab-ecosystem tasks repo, the runner iterates N times per scenario and exports per-run telemetry.

## When to add a scenario

- New agent or capability lands → add a single-agent scenario exercising it
- A regression escapes → add a scenario that would have caught it
- A new cross-agent flow → add a multi-tool scenario

Don't add scenarios that only one specific deployment can pass (cluster-specific data). Keep questions answerable against any healthy pilot crew.
