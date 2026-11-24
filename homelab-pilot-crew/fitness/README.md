# Fitness Suite, homelab-pilot-crew

Curated CrewFitness scenarios for the pilot crew, covering single-agent, multi-agent, RAG, and out-of-scope behavior. Run one with `kmctl fitness run`, or put its text in a `CrewFitness` resource's `spec.testContent`.

Each `.adl` file is plain ADL text. The parser is `kubemoot/fitness-runner/parser.go`.

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
| `smoke-cluster-namespaces.adl` | Smoke | Basic crew responsiveness; gateway + SSE + synthesis happy path |
| `smoke-out-of-scope.adl` | Smoke | Stand-aside behavior on irrelevant questions (no fabrication) |
| `k8s-pod-status.adl` | Single-agent | k8s-workloads; pod health for a namespace |
| `k8s-pod-errors-clusterwide.adl` | Single-agent | k8s-workloads; not-Running pods across all namespaces |
| `k8s-events-concerning.adl` | Single-agent | k8s-workloads; Warning-level events |
| `k8s-nodes-capacity.adl` | Single-agent | k8s-workloads; node capacity / allocatable |
| `k8s-metrics-top-consumers.adl` | Single-agent | k8s-workloads; top CPU/memory consumers |
| `k8s-scaling-quotas.adl` | Single-agent | k8s-workloads; ResourceQuota / scaling headroom |
| `k8s-services-endpoints.adl` | Single-agent | k8s-workloads; Services + endpoint readiness |
| `k8s-statefulset-purpose.adl` | Single-agent | k8s-workloads; enumerate StatefulSets + purpose |
| `k8s-storage.adl` | Single-agent | k8s-storage |
| `k8s-helm-releases.adl` | Single-agent | k8s-helm |
| `gpu-utilization-live.adl` | Single-agent | nvidia-gpu-now (live state via execute_query) |
| `gpu-utilization-all-rigs.adl` | Single-agent | nvidia-gpu-now; util/VRAM/temp per rig |
| `gpu-metrics-discovery.adl` | Single-agent | nvidia-gpu-meta; available DCGM metrics + scrape-target health |
| `gpu-trend-history.adl` | Single-agent | nvidia-gpu-history; utilization trend over a window |
| `gpu-concept-rag.adl` | Single-agent (RAG) | nvidia-gpu-advisor; RAG retrieval quality |
| `proxmox-vm-list.adl` | Single-agent | proxmox (requires `proxmox-secret` in crew namespace) |
| `proxmox-node-health.adl` | Single-agent | proxmox; hypervisor node health |
| `proxmox-concept-rag.adl` | Single-agent (RAG) | proxmox-advisor; RAG retrieval quality |
| `observability-prometheus.adl` | Single-agent | observability (Prometheus queries) |
| `obs-concept-rules.adl` | Single-agent (RAG) | observability; alerting/recording-rules concepts |
| `scheduler-list-pending.adl` | Single-agent | scheduler; pending agent assignments |
| `internet-search-cilium.adl` | Single-agent | internet-search researcher role |
| `k8s-concept-rag.adl` | Single-agent (RAG) | k8s-advisor; RAG retrieval quality |
| `multi-tool-troubleshooting.adl` | Multi-agent | Cross-agent coordination on a diagnostic question |

## Tiers

A scenario names the tiers it belongs to with one constant, placed before the question:

```
DEFINE CONST TIERS AS "smoke standard"
```

`kmctl fitness run --tier smoke|standard|full --crew homelab-pilot` (or a `CrewFitnessSuite` with `spec.tier`) runs the scenarios that name the tier; `full` runs every scenario, labelled or not. The label belongs to the scenario, so a change to a tier is reviewed in the diff of that scenario. A test in `.github/scripts/test-fitness-scenarios.sh` pins the standard tier to the list below and checks the smoke tier's shape.

**Standard** is the 16 gate scenarios, as they were before tiers existed, so earlier results stay comparable: `constraint-exclude-system-ns`, `constraint-format-scoped-list`, `constraint-topn-table`, `constraint-units-and-rounding`, `gotcha-false-attribution-restart`, `k8s-configmap-secret-inventory`, `k8s-daemonset-coverage`, `k8s-helm-releases`, `k8s-jobs-cronjobs`, `k8s-metrics-top-consumers`, `k8s-networkpolicy-coverage`, `k8s-nodes-capacity`, `k8s-pod-errors-clusterwide`, `k8s-pod-status`, `proxmox-vm-list`, `smoke-cluster-namespaces`.

**Smoke** is 8 scenarios chosen so that together they take every call path. It checks plumbing in minutes after a change to a client library, an engine adapter, the operator or a chart; it says nothing about answer quality. Each scenario earns its place by a path only it, or few others, take:

| Scenario | Tiers | Path it adds (from the scenario and the agents it engages) |
|----------|-------|---------------------------------------------------------------|
| `smoke-cluster-namespaces` | smoke, standard | The base path: gateway, SSE, triage by the toolers, one tool loop on `k8s-config` (thinking off), coordinator synthesis. The cheapest end-to-end check. |
| `smoke-greeting` | smoke | A question no specialist answers: every agent triages and stands aside, and the coordinator answers with simple calls (advisory, synthesis) and no tool loop. The path where nothing contributes and the discussion must still settle. |
| `k8s-pod-status` | smoke, standard | A health scan by `k8s-workloads` (thinking off) that the analyst `k8s-advisor` (thinking on, reads the workspace) reviews: the two thinking settings in one discussion, and the analyst's own calls. |
| `constraint-units-and-rounding` | smoke, standard | Arithmetic over fetched data: the `compute` agent (thinking on) runs code in the sandbox beside the node and metrics toolers. A different MCP server and a reasoning-biased call. |
| `k8s-concept-rag` | smoke | A conceptual question answered from documentation: RAG retrieval and simple calls with no live tool, the analyst's reasoning path. |
| `proxmox-vm-list` | smoke, standard | A second tool domain: the Proxmox MCP server (thinking off) with its own credentials and gateway route, across a hypervisor API. |
| `obs-target-health` | smoke | A third tool domain: Prometheus through the observability agent (thinking off), a query tool rather than a list tool. |
| `gotcha-false-attribution-restart` | smoke, standard | The question with a trap: the premise names a cause the crew must check, not confirm. The one gotcha, because it takes the same paths as the others and adds the evidence check. |

The crew names no model and no model server: the scheduler places each call by its phase and the agent's capabilities (triage leans to the fastest model, tool turns to a medium one, reasoning and synthesis to a large one), so which models and providers a smoke run reaches depends on the cluster's catalog, not on this list. The run's `status.pathCoverage` says which call kinds, phases, models, providers and thinking settings it did exercise, and names the ones the crew has that it missed. A gap there is a reason to add a scenario, or to check why the scheduler never placed a call there; do not assume the smoke run covered it.

## How to run

**One scenario:** `kmctl fitness run`, or apply a `CrewFitness` resource with the scenario text in `spec.testContent`.

**Suite runs for measurement:** a `CrewFitnessSuite` runs a set of scenarios N times each against one crew and exports per-run results as XLSX. See the Kubemoot fitness documentation (`docs/user-guides/define-fitness-functions.md` in the kubemoot repository).

## When to add a scenario

- New agent or capability lands → add a single-agent scenario exercising it
- A regression escapes → add a scenario that would have caught it
- A new cross-agent flow → add a multi-tool scenario

Don't add scenarios that only one specific deployment can pass (cluster-specific data). Keep questions answerable against any healthy pilot crew.

## References follow the live cluster

A scenario about the state of the cluster (node health, pod status, rollouts, events, capacity) never assumes the state: not "all nodes Ready", not "no Pending pods", not a fixed node count or name list. Its `DEFER synthesis REFLECTS` reference says that the correct answer is what the live Kubernetes API shows at the time of the question, that a node that is NotReady or cordoned (and the pods Pending on it) is a correct thing to report, and that a name, count or state the live cluster does not show is fabrication. Deterministic `does NOT CONTAIN` guards are limited to wording that no truthful answer can use (a planted false cause, an invented name), never a word such as `0/` or `DiskPressure` that a truthful report of a degraded cluster contains. See `k8s-nodes-health-grounded` for the pattern.
