# homelab-pilot-crew

The Kubemoot reference crew: a coordinator and up to 22 specialists that answer operational questions about the cluster they run in, across four layers, **Kubernetes**, **observability** (Prometheus and DCGM), **GPU/AI** (NVIDIA accelerators and their model servers), and optionally **physical/hypervisor** (Proxmox VE). Discussions run on the Kubemoot consensus protocol: the coordinator writes an advisory, selects a subcommittee of relevant specialists, and synthesizes their findings into one answer. Each selected specialist gets its own task from the advisory (`memberTasks`). Every prompt is written in ADL.

- **Who it is for:** cluster operators who want to ask their cluster questions in plain language, and anyone learning how a Kubemoot crew is built, since this is the reference for the others.
- **What it answers:** what is running and whether it is healthy (pods, events, nodes, storage, Helm releases, network policies), resource use and capacity from Prometheus, GPU utilization and history from DCGM, Kubernetes, Prometheus, NVIDIA, and Proxmox concepts from their documentation (RAG), counting and arithmetic over gathered data in a sandbox, and current facts from a web search.
- **What it needs from the cluster:**
  - a chat model with `tool-calling` in the cluster's model catalog (a larger model with `reasoning` for the coordinator helps; the chart ships no Model), and a ModelServer that has the embedding model (`nomic-embed-text`) in its catalog, or a Model that asks for it on one;
  - a pgvector database and a Secret with its credentials in the crew namespace, for the RAG sources and the gateway tool index (or turn RAG off);
  - Prometheus (and DCGM for GPU questions) reachable from the crew; the chart deploys its own MCP servers for Kubernetes, Prometheus, k8sgpt, web search, the code sandbox, and artifact read-ops;
  - NATS JetStream for the discussions;
  - optionally a Proxmox MCP image ([akmalovaa/proxmox-mcp](https://github.com/akmalovaa/proxmox-mcp) is the recommended one) and a `proxmox-secret` with a read-only Proxmox API token.
- **What it does not do:** it does not change the cluster by default (its Kubernetes access is read-only until you enable `kubernetesAccess.writeAccess`), it does not read Secrets unless `kubernetesAccess.secretRead` is on, it ships no Proxmox image (it asks for yours), and its fitness reference answers describe the maintainer's homelab, not your cluster.

## Before you install

This crew was built for the maintainer's homelab: a Talos Kubernetes cluster on Proxmox VE, with two GPU nodes that each run a model server, kube-prometheus-stack, and a pgvector database. The chart defaults are generic; this is what you supply or change for your cluster:

| Value | Default | What to set |
|---|---|---|
| `vectorStore.host`, `.database`, `.existingSecret` | empty (required) | Your pgvector database and a Secret with its credentials. Or set `ragSources.enabled=false` and `mcpGateway.toolIndex=null` to run without RAG. |
| `mcpServers.prometheus.endpoint` | `http://kube-prometheus-stack-prometheus.monitoring:9090` | Your Prometheus. |
| `mcpServers.proxmox.*` | disabled | Proxmox needs a Proxmox MCP image and a credentials Secret; Kubemoot ships no image, so `image` is required. The recommended image is `ghcr.io/akmalovaa/proxmox-mcp` (MIT, multi-arch), pinned by digest; see [Proxmox](#proxmox). The `proxmox-pve` and `proxmox-qm` agents render only when this is enabled; `proxmox-advisor` answers from Proxmox documentation (RAG) and always renders. |
| `mcpServers.scheduling.enabled` | `false` | Reminders and follow-ups. The scheduling-mcp image is published to GHCR as `ghcr.io/kubemoot/scheduling-mcp`, and each chart release pins the latest Kubemoot release of it at build. The `scheduler-advisor` agent renders only when this is enabled. |
| `kubernetesAccess.secretRead`, `.writeAccess` | `false` | See [Cluster permissions](#cluster-permissions). |
| `nats.url`, `nats.namespace` | release `nats` in namespace `nats` | Your NATS JetStream. |

The prompts and fitness scenarios also carry the reference cluster's vocabulary (host aliases such as `rig0`, two GPUs, its namespaces). The crew discovers the real topology at run time, so they work elsewhere, but the fitness reference answers describe the maintainer's cluster and will not match yours.

See the [repository README](../README.md#install) for prerequisites and the install command.

## Proxmox

The `proxmox-pve` and `proxmox-qm` agents get their tools from a Proxmox MCP server that you enable with `mcpServers.proxmox.enabled=true`. The chart ships no image, so `mcpServers.proxmox.image` is required. The recommended one is [akmalovaa/proxmox-mcp](https://github.com/akmalovaa/proxmox-mcp) (MIT, multi-arch, Streamable HTTP, released as tags). Pin it by digest:

```yaml
mcpServers:
  proxmox:
    enabled: true
    image: ghcr.io/akmalovaa/proxmox-mcp@sha256:c14fe296fc49d40ae1ac72578f06939a9ea89baec77e21c9e3ead03b96b9323f   # 2.3.0
    secretRef: proxmox-secret
    verifySsl: true   # false for nodes with self-signed certificates
```

The chart starts the server over Streamable HTTP (no bridge sidecar) at `PROXMOX_RISK_LEVEL=read`, and `PROXMOX_TOOLS_ALLOW` narrows it to the 13 tools the two agents use, so nothing that starts, stops, clones, or migrates a guest is registered. The Secret in `secretRef` holds the server's environment variables:

| Key | Value |
|---|---|
| `PROXMOX_HOST` | The Proxmox host or IP, without a scheme or port |
| `PROXMOX_USER` | The API user, for example `mcp@pve` |
| `PROXMOX_TOKEN_NAME` | The token name, for example `mcp` |
| `PROXMOX_TOKEN_VALUE` | The token secret |

Give the token its own user and the `PVEAuditor` role (with privilege separation on, grant the role to the token too). Another server needs its own tool names in the two agents and their modules.

| Agent | Tools |
|---|---|
| `proxmox-pve` | `list_nodes`, `get_node_status`, `get_node_rrd_data`, `list_storage`, `get_storage_content`, `get_node_networks`, `get_node_tasks`, `get_task_status`, `get_cluster_resources` |
| `proxmox-qm` | `list_vms`, `get_vm_config`, `get_vm_rrd_data`, `list_vm_snapshots` |

Network bridges come from `get_node_networks`, whose entries with `type` `bridge` are the bridges. The server has no VM firewall tool, so `proxmox-qm` does not answer from firewall rules. Allow the pod to reach the Proxmox API with an egress entry such as `egress.mcpServers.proxmox-mcp` with `allowedCIDRs` for your Proxmox host and `ports: [8006]` (see [Egress](#egress)).

## Cluster permissions

The Kubernetes MCP servers (`kubernetes-mcp`, `kubernetes-legacy-mcp`) share one ServiceAccount, `<release>-kubernetes-mcp`, and k8sgpt has its own, `<release>-k8sgpt-mcp`. This chart binds neither account to any namespaced read. The Kubemoot operator does, **only in namespaces whose owner opts in**: a namespace labeled `kubemoot.ai/crew-read=true` gets a RoleBinding to the operator's read role for every MCPServer with the `kubernetes` capability. The role reads pods and their logs, services, endpoints, ConfigMaps, events, volume claims, workloads, jobs, ingresses, network policies, autoscalers, Flux releases and sources, Kubemoot resources, and ServiceAccounts, Roles and RoleBindings. It reads no Secrets. The operator also lets both accounts list namespaces. A namespace without the label is invisible to the crew, so label every namespace you want it to answer about:

```bash
kubectl label namespace kube-system monitoring kubemoot.ai/crew-read=true
```

This needs a Kubemoot operator that has the read-consent controller; see the operator's installation notes for the upgrade.

What this chart still binds cluster-wide is a small read-only ClusterRole per account, for kinds a RoleBinding cannot grant:

| Account | Kind | Needed by |
|---|---|---|
| `<release>-kubernetes-mcp` | `nodes` | `k8s-nodes`: node capacity, conditions, kubelet version |
| | `persistentvolumes` | `k8s-storage`: list and get PVs |
| | `storageclasses` | `k8s-storage`: list and get StorageClasses |
| | `customresourcedefinitions` | `k8s-nodes`: list and get CRDs |
| | `clusterroles`, `clusterrolebindings` | `k8s-config`: list and get cluster RBAC objects |
| `<release>-k8sgpt-mcp` | `nodes`, `persistentvolumes`, `storageclasses`, `ingressclasses`, `gatewayclasses`, `mutatingwebhookconfigurations`, `validatingwebhookconfigurations` | The k8sgpt Node, Storage, Ingress, GatewayClass and webhook analyzers |

Nothing else is cluster-wide. Node metrics and ingress classes are not granted to the Kubernetes servers because no agent reads them.

- `kubernetesAccess.secretRead: true` makes the Kubernetes servers ask the operator for Secret reads (annotation `kubemoot.ai/kubernetes-access: secrets`), and k8sgpt for `get` on one Secret (`secret-get`, which its Ingress analyzer uses to check a TLS Secret). The operator binds them only in namespaces that also carry `kubemoot.ai/crew-read-secrets=true`. `helm_list` needs it, because Helm stores release state in Secrets. The `k8s-helm` agent always has `helm_list` and `resources_list`. Without Secret reads `helm_list` fails as forbidden, and its description sends the agent to the Flux `HelmRelease` objects (`helm.toolkit.fluxcd.io/v2`) through `resources_list`, which cover only the releases Flux manages, and tells it never to request the `helm.sh` `Release` kind, which the API does not serve.
- `kubernetesAccess.writeAccess: true` adds the annotation word `write` and the `pods_exec`, `resources_scale`, `helm_install`, and `helm_uninstall` agent tools. The operator binds `pods/exec`, patch and scale on workloads only in namespaces that also carry `kubemoot.ai/crew-write=true`. That label also exposes the namespace's Secrets and ServiceAccount tokens, because exec and patch reach them.

With the setting on and the label absent, a tool is registered and fails as forbidden in that namespace.

Agents act on text they read from tools and the web, so treat either setting as giving that access to anyone who can put text in front of the crew.

## Topology

- **1 coordinator** (`homelab-coordinator`) declares the `reasoning` capability and leans to a large model.
- **Up to 22 specialists** (19 with the chart defaults, which leave Proxmox VE and scheduling off) cover Kubernetes (`k8s-*`, `k8sgpt`), observability (`obs-*`), GPU monitoring (`nvidia-gpu-*`), Proxmox (`proxmox-*`), computation (`compute`), scheduling, and internet search. They declare `tool-calling` plus their domain capability, and lean to medium models through `CrewSchedulingPolicy.spec.qualityBias`.

## Agent descriptions

The coordinator picks agents for a question from what each Agent says about itself. It reads each candidate's `description` and tool names. The resume search that narrows the candidates also embeds the `triageSummary`, the `discussKeywords`, and the agent's prompt.

Each description names the live data its agent fetches, in the words a question uses. Neighbors do not claim the same data:

- `k8s-nodes`: node CPU and memory capacity and allocatable, roles, conditions.
- `k8s-workloads`: pods and controllers, and each container's CPU and memory requests and limits.
- `k8s-metrics`: CPU and memory usage, now and over time.
- `obs-metrics`: the monitoring stack itself and its alerts.
- `proxmox-pve`: the hypervisor hosts. `proxmox-qm`: the virtual machines.

An agent that fetches live data opens its description with "Fetches". The compute agent fetches nothing: its sandbox has no cluster API, no kubectl, and no network, so its description says to pick it together with the agents that fetch the data. No description names a particular cluster. `tests/test-prompt-tools.sh` checks these rules.

## Models

The chart ships no Model objects and names no model server for its chat models. The cluster owner's model catalog supplies them: the Model objects in the operator namespace plus the models each ModelServer reports. The crew's CrewSchedulingPolicy says what each phase needs, by the labels the catalog carries:

- **Mulling** (the agents' tool work and answers) requires `capability/tool-calling`. Size follows each agent's declared capabilities through `qualityBias`: the coordinator, which declares `reasoning`, leans to `kubemoot.ai/size: large`, and the specialists to `medium`.
- **Triage** (subcommittee selection, the advisory, and relevance checks) requires `capability/tool-calling` and prefers the model measured fastest (`preferFaster: 50`), with no size or ability scoring. Speed is measured on each model server, so the cluster decides which model that is; a small model on a CPU is not assumed to be fast.

One chat model with tool-calling is enough to run the crew: every phase falls back to it. The policy's status condition `CatalogMode` reports `Cluster` once the crew selects from the catalog. After an upgrade from a release that shipped Models, the upgrade removes them; if `CatalogMode` still reads `CrewLocal`, Models remain in the crew namespace and the crew uses only those. See the Kubemoot scheduler documentation, sections "Quality bias", "Selecting from the model catalog", and "Preferring the faster model".

The embedding model names its model and vector size (`embeddingModel.modelId`, `embeddingModel.dimensions`) and no server. Stored vectors match only the model that made them, so the crew pins the model; the cluster supplies a ModelServer that has it, and the operator binds the EmbeddingModel to one (`status.boundServer`, condition `Bound`). Moving the embeddings to another server is a change to the cluster, never to the crew. If no server has the model the `Bound` condition says `NoServer` and names the model; the cluster owner pulls it onto an Ollama server or adds a Model for it (`kmctl model add`). Set `embeddingModel.serverRef` only to pin the model to one ModelServer. The gateway tool index names that EmbeddingModel resource in `mcpGateway.toolIndex.embeddingModelRef` (default: `embeddingModel.name`) and reads its server from it; `mcpGateway.toolIndex.embeddingModel.endpoint` is an optional override.

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

## Tools in the prompts

A module that lists an agent's tools writes `${agent.tools}`, and the Kubemoot agent runtime replaces it with the tools that agent registered from its gateway. Shared modules describe tool kinds ("your list tool") and never name a tool another agent has, because an agent that calls a tool outside its set gets "Unknown tool".

A runtime that predates the placeholder leaves the text `${agent.tools}` in the prompt: it sits at the end of a sentence that points to the agent's tool definitions, so the prompt still reads.

`tests/test-prompt-tools.sh` fails when a module names a tool its agent does not have, with the optional tools (`kubernetesAccess.secretRead`, `kubernetesAccess.writeAccess`, `compute.workspaceQuery`) on and off.

## Tool overrides

A tool result is as large as what the call asks for. The chart rewrites the descriptions agents see, through the `toolOverrides` on each `MCPServer`, so the narrow form of a call is the obvious one. The descriptions are ADL, like the prompts.

The Kubernetes MCP server (containers/kubernetes-mcp-server, pinned by digest in `mcpServers.kubernetes.image`) prints every list as a wide table with a `LABELS` column and has no option for fewer columns, so the size of a list is set by the rows a call asks for. The server reads its settings from a TOML file only; the chart renders one in a Secret (`<release>-kubernetes-mcp-config`) that loads the `core` and `helm` toolsets and sets `read_only` unless `kubernetesAccess.writeAccess` is true. Its overrides (`templates/mcpserver-kubernetes.yaml`):

| Tool | What the description says |
|---|---|
| `pods_list`, `pods_list_in_namespace`, `resources_list` | For a count, `limit=1` with no `labelSelector` and no `fieldSelector`: the reply's header lines carry `# remainingItemCount: N`, so the total is N+1, and a selector suppresses that count. `namespace` is an exact name; `all` and `*` are not wildcards and return an empty result. |
| `pods_list`, `pods_list_in_namespace` | The pod fields `fieldSelector` accepts (`spec.nodeName=<node>` lists one node's pods), that `status.phase=Running` matches nearly every pod and does not narrow, that container states such as `CrashLoopBackOff` cannot be selected (read `STATUS` and `RESTARTS`), and the `labelSelector` syntax. |
| `resources_list` | The few fields `fieldSelector` accepts per kind (Node: `metadata.name`, `spec.unschedulable`; Namespace: `metadata.name`, `status.phase`; Job: `status.successful`; most other kinds: `metadata.name`, `metadata.namespace`), so an agent stops sending selectors the API rejects, such as Node conditions. |
| `pods_top` | One row per container; `all_namespaces` defaults to true (a call with no `namespace` returns every container in the cluster); `namespace`, `name` (with `namespace`) and `label_selector` narrow it; the Metrics API ignores `limit`. |
| `events_list` | `fieldSelector` accepts `type`, `reason`, and the `involvedObject.*` fields; `type=Warning` leaves out the Normal events. |
| `helm_list` | `namespace` lists one namespace, `all_namespaces=true` lists every namespace, and with neither it lists only the server's own namespace; a forbidden error means the server's account has no Secret read, so the agent lists Flux `HelmRelease` objects instead (chart and version from `status.history[0]` or `spec.chart.spec`), and never the unserved `helm.sh` `Release` kind. |

The Prometheus server's overrides (`templates/mcpserver-prometheus.yaml`) make PromQL do the narrowing: `topk` or `bottomk` for the largest or smallest few, `sum by` or `count by` for totals, a range vector only inside `rate(...[5m])` or a `*_over_time` function (Prometheus rejects `sum(metric[5m])`), a range-query step of about 60 points, and `filter_pattern` with `limit` on `list_metrics` (whose `total_count` answers a count). No agent has `get_targets`: it takes no argument that narrows it and its result outgrows a tool call, so `nvidia-gpu-meta` reads scrape health from the `up` series (`count by (job) (up)`) with the instant query.

The Proxmox server's overrides (`templates/mcpserver-proxmox.yaml`) keep `verbose` off on `list_nodes`, `list_vms`, and `get_cluster_resources` (the compact row carries status, CPU, and memory), point questions about several VMs at one `list_vms` or `get_cluster_resources` call instead of one history call per VM, and give the RRD tools' exact `timeframe` values (`hour`, `day`, `week`, `month`, `year`) and `cf` values (`AVERAGE`, `MAX`), and that they take no `limit`.

Each description restates what the parameter does in the server's own source at the pinned version, and the Kubernetes API's field-selector support. A question that needs every object of a kind, such as a count per namespace, still gets the full table; the overrides only stop a call from asking for more than the question needs. `tests/test-prompt-tools.sh` pins the overrides. `tests/test-server-tools.sh` checks every tool an agent enables, and every tool an override names, against the tools each server lists at its pinned image (`tests/server-tools.yaml`).

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
`learned` (each call goes where it is predicted to finish soonest, from the model servers'
calibrated and observed speeds), or `shadow` (`algorithm` places; the learned choice is
logged beside it). Empty, the default, inherits the cluster's default. See the Kubemoot
scheduler documentation, section "Placement policy".

## Workspace query

`compute.workspaceQuery` (default `true`) adds the `workspace_query` tool to the compute agent's `enabledTools`: read-only SQL over the discussion's staged artifacts, the way to count, filter, sort and total a listing. The tool's own description carries its usage and SQL dialect. The artifact read-ops server offers the tool only when the Kubemoot operator's `artifacts.queryEngine` is set to `sqlite` or `duckdb`. With the operator's default `none` the agent does not register the tool (an agent registers only the tools its gateway offers), so the crew works either way and gains the tool when the operator turns an engine on. Set `false` to leave it out.

## Network policies

When the Kubemoot operator generates network policies (its `security.networkPolicies.enabled` setting, off by default), a crew's discussion gateway admits only its own namespace and the operator. `network.allowedIngress` lists the other namespaces whose pods may reach it, such as the namespace of the web server that fronts the crew. Each entry is a Kubernetes namespace label selector:

```yaml
network:
  allowedIngress:
    - matchLabels:
        kubernetes.io/metadata.name: my-web-namespace
```

Empty, the default, renders no `network` field on the Crew, so the chart still installs on a Kubemoot operator whose Crew resource has no such field. Set it only on an operator that supports Crew network policies; see the Kubemoot documentation page on network policies.

## RAG sources

`ragSources.sources` lists the documentation the crew indexes; each entry becomes a `RAGSource`. An entry's `agents` map names the agents that retrieve from it, keyed by the agent's rendered name, with an optional `topK` (chunks per question) and `priority`:

```yaml
ragSources:
  sources:
    - name: prometheus-reference
      gitUrl: https://github.com/prometheus/docs
      collection: prometheus_reference
      paths: ["docs"]
      agents:
        obs-advisor: {topK: 3}
```

The chart renders that as `spec.ragSources` on the agent, and the Kubemoot operator gives the agent the source's query endpoint. An agent that no source lists retrieves nothing. By default `k8s-advisor` binds the Kubernetes, kubectl, Helm, and Talos sources, `proxmox-advisor` the two Proxmox sources, `nvidia-gpu-advisor` the NVIDIA source, and `obs-advisor` the Prometheus source. `kubernetes-mcp-tools` is indexed but lists no agent. `ragSources.enabled=false` renders no source and no binding.

`topK` must be at least 1 and `priority` a number (higher retrieves first, default 0); either one wrong fails the render. Omitting `topK` takes the Agent CRD default of 5, which the default values never use. An entry set to `null` unbinds that agent and `{}` binds it with the defaults. A key that names no agent in the chart is a typo the chart does not catch at install; the render tests check the default values. Bindings live on the source, so a new agent is added to each source it should read. Overriding `ragSources.sources` replaces the whole list, bindings included.

## Egress

The `egress` value sets outbound network access for one tool server or agent at a time. Each entry is keyed by the rendered name of an MCPServer (`egress.mcpServers`) or an Agent (`egress.agents`), and its value is copied as written into that resource's `spec.egress`. A field the Kubemoot operator adds to `spec.egress` later needs no chart change. Names are the ones in `templates/`, for example `web-search-mcp`, `k8s-advisor`, or `<release>-kubernetes-mcp`. An entry whose name matches no resource in this chart renders nothing and does not fail the install.

```yaml
egress:
  mcpServers:
    web-search-mcp:
      allowedHosts: ["api.example.com"]
      ports: [443]
```

This lets `web-search-mcp` reach `api.example.com` on port 443, plus what the operator always allows (DNS, and for an agent the bus, gateway, and model servers). It needs a Kubemoot operator with egress policies, and the operator chart flag `security.networkPolicies.egress.mode: Declared`; without the flag `spec.egress` has no effect, and a workload without `spec.egress` is never restricted. Leave `egress` empty, the default, on a Kubemoot release that has no `spec.egress` field: the chart then renders the same manifests as before. See the Kubemoot documentation page on network policies for the fields and how host names are enforced on each network plugin.

### Default egress for every agent

`egress.agentsDefault` sets one `spec.egress` for all the chart's Agents at once. Unset (the default) it changes nothing. When set, every Agent the chart renders gets it as `spec.egress`, unless `egress.agents.<name>` names that Agent: the per-agent entry then wins entirely, with no merging of fields, and the other agents keep the default. MCP servers never take the default; set them under `egress.mcpServers`.

```yaml
egress:
  agentsDefault: {}
  agents:
    some-agent:
      allowedHosts: ["api.example.com"]
      ports: [443]
```

`agentsDefault: {}` renders `egress: {}` on every Agent, which limits each one to Kubemoot's automatic allows (DNS, the bus, the crew's gateway, its model servers, the query service, and the placement service) under `security.networkPolicies.egress.mode: Declared`. An agent that needs more has its own entry, as `some-agent` does above. A non-empty default, for example an `allowedHosts` list, is copied as written. An empty per-agent entry (`{}`) also counts as naming that Agent, so it beats a non-empty default.

## Code sandbox isolation

The code sandbox runs Python or bash that a model wrote, so it is the pod in this chart most worth isolating. `mcpServers.codeSandbox.runtimeClassName` runs that pod under a Kubernetes RuntimeClass, for example `gvisor`, which puts a user-space kernel between the model-written code and the node:

```yaml
mcpServers:
  codeSandbox:
    runtimeClassName: gvisor
```

Empty, the default, renders no `runtimeClassName` on the MCPServer, so the pod runs under the cluster's default runtime and the chart still installs on a Kubemoot operator whose MCPServer resource has no such field. Set it only on an operator that supports MCPServer runtime classes, and only when the runtime is installed on the nodes and a RuntimeClass of that name exists. Only the code sandbox pod is affected.

Under a sandboxed runtime, also set `mcpServers.codeSandbox.transport: http`:

```yaml
mcpServers:
  codeSandbox:
    runtimeClassName: gvisor
    transport: http
```

The default, `stdio`, reaches the sandbox through the operator's bridge sidecar, which talks to the server over FIFOs shared between the two containers. gVisor does not share FIFOs between containers, so the bridged setup cannot run there. With `http` the sandbox serves MCP over Streamable HTTP itself (`/mcp`, with `/healthz` and `/readyz`, on port 3000): the operator adds no bridge sidecar and no pipes volume, and the image entrypoint, which already runs the server under `tini`, starts it. `http` needs a code-sandbox image that supports it, which means a Kubemoot release with Streamable HTTP in the code sandbox. Any other `transport` value fails the render.

## Deployment

The per-crew release workflow publishes the chart to `oci://ghcr.io/kubemoot/charts/homelab-pilot-crew` on each release commit to `main`.
