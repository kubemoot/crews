# homelab-pilot-crew

The Kubemoot reference crew: a coordinator and up to 22 specialists that answer operational questions about the cluster they run in, across four layers, **Kubernetes**, **observability** (Prometheus and DCGM), **GPU/AI** (NVIDIA accelerators and their model servers), and optionally **physical/hypervisor** (Proxmox VE). Discussions run on the Kubemoot consensus protocol: the coordinator writes an advisory, selects a subcommittee of relevant specialists, and synthesizes their findings into one answer. Each selected specialist gets its own task from the advisory (`memberTasks`). Every prompt is written in ADL.

- **Who it is for:** cluster operators who want to ask their cluster questions in plain language, and anyone learning how a Kubemoot crew is built, since this is the reference for the others.
- **What it answers:** what is running and whether it is healthy (pods, events, nodes, storage, Helm releases, network policies), resource use and capacity from Prometheus, GPU utilization and history from DCGM, counting and arithmetic over gathered data in a sandbox, and current facts from a web search. Four domain advisors check the findings against the stored results, the live source and their documentation (RAG), and ask the agent behind a doubtful finding to recheck it.
- **What it needs from the cluster:**
  - a chat model with `tool-calling` in the cluster's model catalog (a larger model with `reasoning` for the coordinator helps; the chart ships no Model), and a ModelServer that has the embedding model (`nomic-embed-text`) in its catalog, or a Model that asks for it on one;
  - a pgvector database and a Secret with its credentials in the crew namespace, for the RAG sources and the gateway tool index (or turn RAG off);
  - Prometheus (and DCGM for GPU questions) reachable from the crew; the chart deploys its own MCP servers for Kubernetes, Prometheus, k8sgpt, web search, the code sandbox, and workspace read-ops;
  - NATS JetStream for the discussions;
  - optionally a Proxmox MCP image ([akmalovaa/proxmox-mcp](https://github.com/akmalovaa/proxmox-mcp) is the recommended one) and a `proxmox-secret` with a read-only Proxmox API token.
- **What it does not do:** it does not change the cluster by default (its Kubernetes access is read-only until you list namespaces under `kubernetesAccess.write.namespaces`), it does not read Secrets unless you list namespaces under `kubernetesAccess.secretRead.namespaces`, it ships no Proxmox image (it asks for yours), and its fitness reference answers describe the maintainer's homelab, not your cluster.

## Before you install

This crew was built for the maintainer's homelab: a Talos Kubernetes cluster on Proxmox VE, with two GPU nodes that each run a model server, kube-prometheus-stack, and a pgvector database. The chart defaults are generic; this is what you supply or change for your cluster:

| Value | Default | What to set |
|---|---|---|
| `vectorStore.host`, `.database`, `.existingSecret` | empty (required) | Your pgvector database and a Secret with its credentials. Or set `ragSources.enabled=false` and `mcpGateway.toolIndex=null` to run without RAG. |
| `mcpServers.prometheus.endpoint` | `http://kube-prometheus-stack-prometheus.monitoring:9090` | Your Prometheus. |
| `mcpServers.proxmox.*` | disabled | Proxmox needs a Proxmox MCP image and a credentials Secret; Kubemoot ships no image, so `image` is required. The recommended image is `ghcr.io/akmalovaa/proxmox-mcp` (MIT, multi-arch), pinned by digest; see [Proxmox](#proxmox). The `proxmox-pve` and `proxmox-qm` agents render only when this is enabled; `proxmox-advisor` answers from Proxmox documentation (RAG) and always renders. |
| `mcpServers.scheduling.enabled` | `false` | Reminders and follow-ups. The scheduling-mcp image is published to GHCR as `ghcr.io/kubemoot/scheduling-mcp`, and each chart release pins the latest Kubemoot release of it at build. The `scheduler-advisor` agent renders only when this is enabled. |
| `kubernetesAccess.namespaces`, `.clusterWide` | `[]`, `false` | Where the Kubernetes servers and k8sgpt read. With neither set they read no namespace. See [Cluster permissions](#cluster-permissions). |
| `kubernetesAccess.secretRead.namespaces`, `.write.namespaces` | `[]` | Where they also read Secrets, and where they may exec and patch. See [Cluster permissions](#cluster-permissions). |
| `rbac.render`, `rbac.namePrefix` | `all`, empty | Install the chart as two releases when the applier holds only its own namespace: an admin renders the RBAC objects (`cluster`), the tenant renders the rest (`namespaced`). See [Applying with a tenant account](#applying-with-a-tenant-account). |
| `nats.url`, `nats.namespace` | release `nats` in namespace `nats` | Your NATS JetStream. |

The prompts and fitness scenarios also carry the reference cluster's vocabulary (host aliases such as `rig0`, two GPUs, its namespaces). The crew discovers the real topology at run time, so they work elsewhere, but the fitness reference answers describe the maintainer's cluster and will not match yours.

See the [repository README](../README.md#install) for prerequisites and the install command.

## Applying with a tenant account

A Flux or Argo CD identity that holds only its crew namespace cannot create ClusterRoles, ClusterRoleBindings or RoleBindings, which this chart renders for the Kubernetes tool servers. Install the chart twice from the same values and let each release render its part:

| Release | Applied by | Sets | Renders |
|---|---|---|---|
| tenant | the crew's own account (for Flux, `serviceAccountName` on the HelmRelease) | `rbac.render: namespaced` | everything except the RBAC objects, including both ServiceAccounts |
| rbac | an admin | `rbac.render: cluster`, `rbac.namePrefix: <tenant release name>` | the ClusterRoles, ClusterRoleBindings and RoleBindings |

Use the same `kubernetesAccess` values in both, and install the rbac release into the same namespace as the tenant release: the bindings name the ServiceAccounts in the namespace they are rendered for. The admin release creates every binding, so the access the tool servers get stays a decision of whoever may create bindings, and the tenant account needs no RBAC rights at all.

- **Which objects the rbac release renders.** The four ClusterRoles and, for each account, the cluster-wide binding of its small read role. With `kubernetesAccess.clusterWide: true` it also renders the two read-role ClusterRoleBindings, which is all 8 objects the Homelab Pilot runs; without it, it renders a RoleBinding per namespace listed in `kubernetesAccess.namespaces` (and for the Secret and write tiers) instead.
- **Instance label.** Objects the rbac release takes over from a single-release install carry `app.kubernetes.io/instance: <rbac release name>` afterwards; that label is the only difference from the single-release rendering when `rbac.namePrefix` is the tenant release name.
- **Tests.** `tests/test-rbac.sh` pins that the two renderings together equal the default one object for object, that a prefix different from the release name renames the roles and the binding subjects, that the subjects are in the render namespace, that `rbac.render` accepts only `all`, `cluster` and `namespaced` (an empty or wrongly cased value fails; only an absent key means `all`), and the Homelab Pilot's own values (`tests/fixtures/homelab-pilot-values.yaml`).
- **Install notes.** The access warning prints in the release that binds; a `namespaced` release says where the binding comes from.

A tenant account also needs the `use` verb on the Secrets and ServiceAccounts the MCPServers name when the Kubemoot use-grant check is on: `<release>-kubernetes-mcp`, `<release>-k8sgpt-mcp`, `<release>-kubernetes-mcp-config`, and the Proxmox Secret if `mcpServers.proxmox.secretRef` is set.

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

The Kubernetes MCP server (`kubernetes-mcp`) runs as the ServiceAccount `<release>-kubernetes-mcp`, and k8sgpt has its own, `<release>-k8sgpt-mcp`. This chart ships both accounts, their roles, and the bindings, so the grant is in the chart's own manifests and Kubernetes RBAC records who agreed to it: whoever can create a RoleBinding in a namespace consents for that namespace. Nothing is labeled and no operator setting is involved.

```yaml
kubernetesAccess:
  namespaces: [kube-system, monitoring]   # a RoleBinding to the read role in each
  clusterWide: false                      # true: one ClusterRoleBinding instead
  secretRead:
    namespaces: []                        # Secret reads, per namespace
  write:
    namespaces: []                        # exec, patch and scale, per namespace
```

- **Read.** `kubernetesAccess.namespaces` binds `<release>-kubernetes-mcp-read` (and `<release>-k8sgpt-mcp-read` for k8sgpt) in each listed namespace. The role reads pods and their logs, services, endpoints, ConfigMaps, events, volume claims, workloads, jobs, ingresses, network policies, autoscalers, Flux releases and sources, Kubemoot resources, and ServiceAccounts, Roles and RoleBindings. It reads no Secrets. `kubernetesAccess.clusterWide: true` renders one ClusterRoleBinding for each read role instead and ignores `namespaces` for reads. A listed namespace must exist when the chart installs, and the installer needs the right to create RoleBindings in it.
- **Nothing listed.** With no namespace listed and `clusterWide` false the chart renders no read binding. The tool servers then read nothing inside a namespace, and every question about pods, workloads, events or logs fails as forbidden. `helm install` prints a warning in the notes, and `tests/test-rbac.sh` pins the behavior.
- **Secret reads.** `kubernetesAccess.secretRead.namespaces` binds `<release>-kubernetes-mcp-secrets` (get, list, watch on Secrets) for the Kubernetes servers, and `<release>-k8sgpt-mcp-secret-get` (get on one Secret, which its Ingress analyzer uses to check a TLS Secret) for k8sgpt, in the listed namespaces only. `helm_list` needs it, because Helm stores release state in Secrets. The `k8s-helm` agent always has `helm_list` and `resources_list`. Without Secret reads `helm_list` fails as forbidden, and its description sends the agent to the Flux `HelmRelease` objects (`helm.toolkit.fluxcd.io/v2`) through `resources_list`, which cover only the releases Flux manages, and tells it never to request the `helm.sh` `Release` kind, which the API does not serve. Secret reads are never cluster-wide. Together with a write namespace they let an agent exec into a pod and read its mounted tokens, so give a namespace both tiers only when you accept that.
- **Write.** `kubernetesAccess.write.namespaces` binds `<release>-kubernetes-mcp-write` (`pods/exec`, patch and scale on workloads) for the Kubernetes servers in the listed namespaces only, registers the `pods_exec`, `resources_scale`, `helm_install`, and `helm_uninstall` agent tools, and takes the servers out of their read-only modes. k8sgpt never writes. exec and patch reach the namespace's Secrets and ServiceAccount tokens. List a Secret or write namespace under `namespaces` too, or the servers can use the extra tier there but read nothing else.

What this chart still binds cluster-wide is a small read-only ClusterRole per account, for kinds a RoleBinding cannot grant:

| Account | Kind | Needed by |
|---|---|---|
| `<release>-kubernetes-mcp` | `namespaces` | The namespace list, and finding which namespace holds a workload |
| | `nodes` | `k8s-nodes`: node capacity, conditions, kubelet version |
| | `persistentvolumes` | `k8s-storage`: list and get PVs |
| | `storageclasses` | `k8s-storage`: list and get StorageClasses |
| | `customresourcedefinitions` | `k8s-nodes`: list and get CRDs |
| | `clusterroles`, `clusterrolebindings` | `k8s-config`: list and get cluster RBAC objects |
| `<release>-k8sgpt-mcp` | `namespaces`, `nodes`, `persistentvolumes`, `storageclasses`, `ingressclasses`, `gatewayclasses`, `mutatingwebhookconfigurations`, `validatingwebhookconfigurations` | The k8sgpt Node, Storage, Ingress, GatewayClass and webhook analyzers, and the findings' context |

Nothing else is cluster-wide. Node metrics and ingress classes are not granted to the Kubernetes servers because no agent reads them.

Upgrading from a release that relied on the Kubemoot operator's namespace labels (`kubemoot.ai/crew-read`, `crew-read-secrets`, `crew-write`): list the same namespaces under the values above and upgrade the chart first. The operator removes the RoleBindings it made from those labels when it starts, so upgrade this chart before the operator, or the crew reads nothing until the next chart upgrade. The labels do nothing after that and can be removed from the namespaces. Values written for the old shape render with both tiers off when they say `false`; a `true` fails the render and names the new shape.

Agents act on text they read from tools and the web, so treat each namespace you list as giving that access to anyone who can put text in front of the crew.

## Topology

- **1 coordinator** (`homelab-coordinator`) declares the `reasoning` capability and leans to a large model.
- **Up to 22 specialists** (19 with the chart defaults, which leave Proxmox VE and scheduling off) cover Kubernetes (`k8s-*`, `k8sgpt`), observability (`obs-*`), GPU monitoring (`nvidia-gpu-*`), Proxmox (`proxmox-*`), computation (`compute`), scheduling, and internet search. They declare `tool-calling` plus their domain capability, and lean to medium models through `CrewSchedulingPolicy.spec.qualityBias`.

## Agent domains

Every tooler that gathers data and every specialist analyst declares `spec.domains`, the subject areas it works in (`proxmox`, `kubernetes`, `gpu`, `observability`). The coordinator convenes the analysts that review a discussion by them: an analyst reviews when one of its domains is a domain of the question, or of a tooler that gathered data, so a Proxmox answer is reviewed by the Proxmox advisor alone among the specialists. `k8s-metrics` also declares `observability` and `prometheus`, because it runs Prometheus tools, so its data reaches `obs-advisor` too. `compute` is an analyst that declares none: an analyst without domains is a generalist and reviews every discussion, which is right for arithmetic over any data. `scheduler-advisor` is a tooler that declares none and is never convened for review. `tests/test-domains.sh` checks the agent counts per role, that only those two declare none, and which analysts each tooler's data reaches. The `review` block of the crew's `MootArchetype` sets the rule (`convene: all` brings every analyst back).

## Agent descriptions

The coordinator picks agents for a question from what each Agent says about itself. Its selection step reads each candidate's `description` and tool names; the resume search that narrows the candidates also embeds the `triageSummary` and the `discussKeywords`. So the description says what the agent answers, in the words a question uses, and the summary says the same at more length and never contradicts it.

- A worker's description opens with what it reads: "Reads", "Measures" or "Finds" (k8s-config: "Reads namespaces and configuration objects: ConfigMap contents (keys and values, such as a setting, a schedule or a policy) ..."). Neighbors do not claim the same data: `k8s-nodes` node capacity and allocatable, `k8s-workloads` each container's requests and limits, `k8s-metrics` usage now and over a window, `obs-metrics` the monitoring stack and its alerts, `proxmox-pve` the hosts and `proxmox-qm` the VMs, `k8s-helm` Helm releases only.
- An advisor's description opens with "Reviews and fact-checks".
- `compute` computes with code and fetches nothing, so its description says to select it with the agents that fetch the data.
- Keywords hold the words unique to an agent: no shared words such as `kubernetes`, `status` or `error` on `k8s-workloads`, no weekdays on `scheduler-advisor`, no `*` on `internet-search`.

No description or prompt names a particular cluster. `tests/test-prompt-tools.sh` checks these rules.

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

## Roles and prompts

Each agent's prompt is its role and its purpose, in ADL, and nothing else: about 2,000 characters per agent. What a tool does and how to call it is in the tool's description (see [Tool overrides](#tool-overrides)); recipes a model may lack are in opt-in [Skills](#skills); what a model already knows is in no prompt at all; who reviews and in what order belongs to the crew's consensus archetype.

| Module | Loaded by | Says |
|---|---|---|
| `crew-invariants` | every agent but the coordinator | One agent at a table; the crew reads only (or, with `kubernetesAccess.write.namespaces`, changes a system only when asked and only with a write tool); no Secret contents; no agent creates information; a value that is not a raw tool value says how it was made, `(calculated with code)` or `(inferred from <what>)`; one reply per phase. |
| `worker` | the 15 Kubernetes, GPU, observability and Proxmox agents and `internet-search` | Gather with your tools and report what they returned; read only what the question needs; an empty result from a call that ran is a finding; never count, total or order a result yourself; with the signal tool, answer a recheck request by reading again. |
| `advisor` | `k8s-advisor`, `nvidia-gpu-advisor`, `obs-advisor`, `proxmox-advisor` | The domain's fact-checker (see [Advisors, the fact-checkers](#advisors-the-fact-checkers)). |
| `<agent>-system` | that agent | Its purpose in one `DESCRIPTION`, and the few behaviors only it has (k8s-config reports a Secret by name and count only). `scheduler-advisor` has its role in its own module: it keeps the person's reminders and follow-ups, the one thing the crew writes, confirms before it cancels, and never shows a schedule id. |
| `compute-system` | `compute` | The table's calculator: every number is the output of code it ran, marked `(calculated with code)`; it fetches nothing. |
| `coordinator-convene`, `coordinator-answer` | `homelab-coordinator` | Select the agents whose description fits; answer only from the findings, a questioned value only after its agent rechecked it, a failed read as unknown, never as zero. |
| `ratify-prompt` | nobody while ratification is off | Kept as the crew's ratification text. |

### Verdicts: reply words or the signal tool

`discussion.signalTool.enabled` (default `true`) sets how an agent records its verdict. On, the shared modules say to record each verdict with the `signal` tool, which a Kubemoot with the signal tool offers whenever the crew's consensus archetype declares signals (consent-3 declares agree, concern, question, stand_aside, tool_gap, no_data and block); no module teaches a reply word. An advisor that doubts a finding asks the agent that made it a clarifying question, that agent rechecks and answers, and the coordinator counts the value only after the recheck. Off is for a crew on an older Kubemoot without the signal tool: the modules teach the reply words its runtime parses, in the exact forms it matches (a worker starts its reply with `NO_DATA: <what, why>` or `TOOL_GAP: <capability>`, compute replies exactly `NO_DATA`, an advisor starts with `CONCERN:`, `NOTHING_TO_ADD` stands aside), and since there is no recheck round a questioned value is reported as unverified. The flag and the archetype must agree: `crew.archetype` (default `consent-3`) names the archetype, `discussion.signalTool.archetypes` lists the ones known to declare signals, and the render fails when the flag is on and the archetype is not in that list. Only the PromptModules differ between the two settings.

### The prompt lint

[`scripts/check-prompt-rules.sh`](../scripts/check-prompt-rules.sh) fails a rendering in which a PromptModule line or a relevance hint names a tool one of the crew's MCP servers lists (`tests/server-tools.yaml`) or says "defer to": tool knowledge belongs in the tool's description, and an agent cannot hand a question to another. `tests/test-prompt-lint.sh` runs it with the optional tools and switches on and off, and checks that it catches a planted rule. `tests/test-prompt-tools.sh` also fails when a module names a tool its agent does not have.

The workspace server (`workspace-mcp`, which runs `workspace_query`) takes its memory from `mcpServers.workspace.resources` (request 256Mi, limit 512Mi by default) and caps what one query may add to the process with `mcpServers.workspace.queryMemory` (`WORKSPACE_QUERY_MEMORY`, 128MB). Two queries run at once, so the limit must hold both plus the process; a query over the cap stops with an error and the container stays up. The same two values exist in the O'guide crew chart.

## Tool overrides

A tool result is as large as what the call asks for. The chart rewrites the descriptions agents see, through the `toolOverrides` on each `MCPServer`: what the tool returns, how large the result gets, and what each argument does, so the narrow form of a call is the obvious one. This is where the tool knowledge that used to sit in the prompts lives now. A description states facts (`DESCRIPTION` and `ASSERT` lines) and never a rule (no `WHEN`, `THEN`, `ALWAYS` or `NEVER`); a model chooses a call from what the tool does. `tests/test-prompt-tools.sh` checks that.

The crew runs one Kubernetes MCP server: Red Hat's containers/kubernetes-mcp-server v0.1.3, pinned by digest in `mcpServers.kubernetes.image`, with the in-cluster ServiceAccount and stdio through the operator's bridge. The server reads its settings from a TOML file only; the chart renders one in a Secret (`<release>-kubernetes-mcp-config`) that loads the `core` and `helm` toolsets, sets `read_only` unless `kubernetesAccess.write.namespaces` is set, registers through `enabled_tools` only the tools the agents use (`resources_list`, `resources_get`, `pods_list`, `pods_list_in_namespace`, `pods_get`, `pods_log`, `pods_top`, `events_list`, `helm_list`, `api_resources_list`, and with write access `pods_exec`, `resources_scale`, `helm_install`, `helm_uninstall`), and, unless `kubernetesAccess.secretRead.namespaces` asks for Secret reads, refuses the Secret kind on the server's own client (`denied_resources`), beside the RBAC that grants no Secret read. The Flux159 server (`kubernetesLegacy`) that served `list_api_resources` and `explain_resource` is removed. What that loses: `explain_resource`, the field documentation of any kind (a custom kind's schema is still read from its CustomResourceDefinition with `resources_get`; a built-in kind's has no tool), and a listing of every API kind at once (`api_resources_list` looks up one kind; `resources_list` on CustomResourceDefinition lists the custom kinds).

The server prints every list as a wide table with a `LABELS` column and has no option for fewer columns, so the size of a list is set by the rows a call asks for. Its overrides (`templates/mcpserver-kubernetes.yaml`):

| Tool | What the description says |
|---|---|
| `pods_list`, `pods_list_in_namespace`, `resources_list`, `events_list`, `pods_top` | With no `limit` one reply holds every matching row, so its rows are the count, but a response over 4 MiB (the server's `max_backend_response_bytes`) fails with no rows; then `limit` with `continue` pages the list: a partial reply starts with `# continue: <token>` (and `# remainingItemCount: <n>` when the API reports it), and the token sent unchanged with the same limit, namespace and selectors returns the next page. `namespace` is an exact name; `all` and `*` are not wildcards and return an empty result. |
| `pods_list`, `pods_list_in_namespace` | The pod fields `fieldSelector` accepts (`spec.nodeName=<node>` lists one node's pods), that `status.phase=Running` matches nearly every pod and does not narrow, that container states such as `CrashLoopBackOff` cannot be selected (read `STATUS` and `RESTARTS`), and the `labelSelector` syntax. |
| `resources_list` | The few fields `fieldSelector` accepts per kind (Node: `metadata.name`, `spec.unschedulable`; Namespace: `metadata.name`, `status.phase`; Job: `status.successful`; most other kinds: `metadata.name`, `metadata.namespace`), that each term is `field=value` and that memory, CPU, capacity and allocatable cannot be selected and the Node table has no column for them (read a Node's `status.capacity` and `status.allocatable` with `resources_get`, or use a metrics tool for usage), so an agent stops sending selectors the API rejects, such as Node conditions. |
| `resources_list` `fieldSelector` rules | Four argument rules the Kubemoot gateway checks before the call, because the descriptions alone did not stop the model: a selector with a memory, CPU, capacity or allocatable field (read the Node with `resources_get` for capacity, or use a metrics tool for usage), with `=~` or `!~`, with `<` or `>`, or with a term that is a field name alone is answered with a corrective message and never reaches the server. The first matching rule answers, in that order. |
| `pods_top` | One row per container; `all_namespaces` defaults to true (a call with no `namespace` returns every container in the cluster); `namespace`, `name` (with `namespace`) and `label_selector` narrow it. |
| `events_list` | `fieldSelector` accepts `type`, `reason`, and the `involvedObject.*` fields; `type=Warning` leaves out the Normal events. |
| `helm_list` | `namespace` lists one namespace, `all_namespaces=true` lists every namespace, and with neither it lists only the server's own namespace; a forbidden error means the server's account has no Secret read, so the agent lists Flux `HelmRelease` objects instead (chart and version from `status.history[0]` or `spec.chart.spec`), and never the unserved `helm.sh` `Release` kind. |
| `pods_get`, `resources_get` | `pods_get` holds each container's restart count, image, requests and limits; `resources_get` returns one object in full, a ConfigMap's keys and values, a Node's capacity and allocatable, and a CustomResourceDefinition's schema of its kind. |
| `api_resources_list` | Looks up the apiVersion, plural name and scope of one kind; there is no listing of every kind at once. |

The Prometheus server's overrides (`templates/mcpserver-prometheus.yaml`) make PromQL do the narrowing: `topk` or `bottomk` for the largest or smallest few, `sum by` or `count by` for totals, a range vector only inside `rate(...[5m])` or a `*_over_time` function (Prometheus rejects `sum(metric[5m])`), a range-query step of about 60 points, and `filter_pattern` with `limit` on `list_metrics` (whose `total_count` answers a count). No agent has `get_targets`: it takes no argument that narrows it and its result outgrows a tool call, so `nvidia-gpu-meta` reads scrape health from the `up` series (`count by (job) (up)`) with the instant query.

The Proxmox server's overrides (`templates/mcpserver-proxmox.yaml`) keep `verbose` off on `list_nodes`, `list_vms`, and `get_cluster_resources` (the compact row carries status, CPU, and memory), point questions about several VMs at one `list_vms` or `get_cluster_resources` call instead of one history call per VM, and give the RRD tools' exact `timeframe` values (`hour`, `day`, `week`, `month`, `year`) and `cf` values (`AVERAGE`, `MAX`), and that they take no `limit`.

The other servers' overrides carry what the prompts used to: `analyze` on k8sgpt lists its filters, and gateway rules refuse `explain` and `backend`, which the server (no language model) cannot use; `execute_code` on the code sandbox says the sandbox has the Python standard library only and no network; `workspace_head`, `workspace_tail` and `workspace_grep` say what a `[CALL key=...]` line in a finding is, that it carries no data, and what an `[EMPTY RESULT]` block and a cut `args=` text mean (`workspace_query`, `workspace_list` and `workspace_describe` keep the server's own descriptions, which name the query engine).

The crew needs the Kubemoot release that carries `rules` on a parameter override (the MCPServer CRD field and the gateway that enforces it). Deploy that release before this chart: on an older CRD the field is dropped and only the descriptions apply, so nothing is enforced. The rules are RE2 patterns, searched anywhere in the argument and checked in order; The patterns walk whole `field=value` terms, so an escaped comma inside a value (`involvedObject.name=a\,b`) is not taken for a term separator. `tests/fixtures/field-selector-rules.json` holds the four patterns and the selectors each must reject or let through; `tests/test-prompt-tools.sh` checks the rendered chart against it, and the Kubemoot gateway runs a copy with its RE2 engine.

Each description restates what the parameter does in the server's own source at the pinned version, and the Kubernetes API's field-selector support. A question that needs every object of a kind, such as a count per namespace, still gets the full table; the overrides only stop a call from asking for more than the question needs. `tests/test-prompt-tools.sh` pins the overrides. `tests/test-server-tools.sh` checks every tool an agent enables, and every tool an override names, against the tools each server lists at its pinned image (`tests/server-tools.yaml`).

## Fitness

`fitness/` holds 77 scenarios in ADL (`*.adl`), grouped by prefix: smoke, single-domain Kubernetes, GPU, observability, and Proxmox questions, cross-domain (`xdomain-*`, `multi-tool-*`), judgment, constraint-following, and trap questions (`gotcha-*`, `partial-answerable-*`), and grounding questions whose every name and number is checked against the live cluster (`k8s-nodes-health-grounded`: it asks "Are all the cluster nodes healthy right now?" and fails on a node name the cluster does not have or a wrong count). Scenarios that use `DEFER synthesis REFLECTS` need the [kubemoot-fitness-crew](../kubemoot-fitness-crew/) judge installed.

The chart deploys the scenarios with the crew as one ConfigMap, `homelab-pilot-fitness`, labeled `kubemoot.ai/crew` and `kubemoot.ai/fitness-kind: scenarios`. CrewForge and the dashboard list them from it; nothing runs until someone starts a run.

An opt-in tier, `fitness-peer-errors/`, holds seven scenarios built to make one agent mislead the others (a planted wrong fact, conflicting sources, an oversized result, a plausible wrong answer, arithmetic), so a measurement of the crew's checking has something to catch. It is off by default: `--set fitness.peerErrors.enabled=true` renders its scenarios as the ConfigMap `homelab-pilot-fitness-peer-errors` and the deliberately wrong test fixtures (`peer-errors-fixture-*`) they read. The standard and full tiers never include it. See [fitness-peer-errors/README.md](fitness-peer-errors/README.md).

Run a scenario with `kmctl fitness run`, or apply a `CrewFitness` resource with `kubectl`. To run all of them as one `CrewFitnessSuite`, assemble it with [`scripts/build-suite.py`](../scripts/build-suite.py):

```bash
python3 scripts/build-suite.py homelab-pilot-crew/fitness \
  --namespace crew-homelab-pilot --crew-ref homelab-pilot --name baseline-n10 --iterations 10
```

To run only the node-health grounding scenario (before and after a Kubemoot release that ratifies the answer, on the same crew), build a suite from that one file and run it with the same iteration count each time:

```bash
mkdir -p /tmp/one && cp homelab-pilot-crew/fitness/k8s-nodes-health-grounded.adl /tmp/one/
python3 scripts/build-suite.py /tmp/one --namespace crew-homelab-pilot --crew-ref homelab-pilot \
  --name nodes-grounded --iterations 10 > /tmp/nodes-grounded.yaml
kubectl apply -f /tmp/nodes-grounded.yaml && kmctl fitness run nodes-grounded -n crew-homelab-pilot
```

The inline guards fail an iteration that names `crew-node` or counts `15 nodes`; the deferred judge fails any node name the cluster does not have and any count other than the live one. Compare the fail rate of the two runs, and read the failing iterations' syntheses, not only the score.

## Advisors, the fact-checkers

The four advisors (`k8s-advisor`, `nvidia-gpu-advisor`, `obs-advisor`, `proxmox-advisor`) review their domain's findings before the coordinator answers: trust, and verify. Each checks every number, name, count and state of a finding against the stored result it came from, the live source where its tools read it, and the documentation its RAG sources give it. A number it checks is computed with code from the stored values. It may reword or clarify a finding; it never changes the data or adds data of its own. With the signal tool (the default), when it doubts a finding it asks the agent that made it a clarifying question to recheck ("@k8s-nodes, can you recheck the node count? 100 seems high for this cluster"); that agent reads again and answers, the advisor checks the answer, and the coordinator counts a questioned value only after that recheck. With the reply words (an older Kubemoot), the doubt is a `CONCERN:` and the coordinator reports the value as unverified.

Their tools are read and compute only: `workspace_head`, `workspace_tail`, `workspace_grep`, `execute_code` (the crew's code sandbox), `workspace_query` and `workspace_describe` with `advisors.workspaceQuery` (default `true`), and with `advisors.liveRead` (default `true`) the read tools of their domain's live source: the Kubernetes server's `resources_list`, `resources_get`, `pods_list`, `pods_list_in_namespace` and `events_list` for `k8s-advisor`, Prometheus's `execute_query` for the GPU and observability advisors, and Proxmox's `list_nodes`, `list_vms` and `get_cluster_resources` for `proxmox-advisor` when Proxmox is on. `liveRead` adds no MCPServer, no RBAC and no write tool. The runtime's own analyst triage decides when an advisor takes part; the chart sets no triage prompt. `tests/test-advisors.sh` checks the roles, the tools in each setting, and the modules.

The separate fact-checker agent is folded into this role. `discussion.factChecker` and `discussion.peerVerification` no longer do anything: a release that still sets them renders the same and prints a `REMOVED:` note in the install notes.

## Skills

Two crew [Skills](https://github.com/kubemoot/kubemoot/blob/main/docs/reference/skill.md) hold recipes a model may lack, so they leave the prompts without being lost. The coordinator selects a skill for a question its description fits, and only then do the agents of that discussion read it. Both are off by default; they are the second arm of the prompt refactor's measurement.

| Value | Skill | Holds |
|---|---|---|
| `skills.promqlResourceUsage.enabled` | `promql-resource-usage` | PromQL for CPU, memory, disk and network use of pods, namespaces and nodes, and for naming a host whose series carry only an address. |
| `skills.dcgmGpuMetrics.enabled` | `dcgm-gpu-metrics` | The DCGM exporter's GPU metric names and units, queries over a window, and scrape health. |

## Placement policy

`crew.placementPolicy` chooses how Kubemoot places this crew's model calls: `algorithm`,
`learned` (each call goes where it is predicted to finish soonest, from the model servers'
calibrated and observed speeds), or `shadow` (`algorithm` places; the learned choice is
logged beside it). Empty, the default, inherits the cluster's default. See the Kubemoot
scheduler documentation, section "Placement policy".

## Workspace query

`compute.workspaceQuery` (default `true`) adds the workspace tools to the compute agent's `enabledTools`: `workspace_query` (read-only SQL over the discussion's stored results, the way to count, filter, sort and total a listing), `workspace_list` (what the discussion has stored, from which tool, with its type, rows and errors) and `workspace_describe` (each stored table's columns, types and example values, read before writing a query). The tool's own description carries its usage and SQL dialect. The workspace read-ops server offers the query tools only when the Kubemoot operator's `workspace.queryEngine` is set to `sqlite` or `duckdb`. With the operator's default `none` the agents do not register them (an agent registers only the tools its gateway offers).

Without `workspace_query`, whether the switch is off or the operator's engine is `none`, compute cannot count, filter or select stored results: it has `workspace_head`, `workspace_tail` and `workspace_grep` and the code sandbox only.

`advisors.workspaceQuery` (default `true`) adds `workspace_query` and `workspace_describe` for the four advisors (k8s, nvidia-gpu, obs, proxmox), beside `workspace_head`, `workspace_tail`, `workspace_grep` and `execute_code`; compute has the same three read tools. The chart names no `artifact_*` tool: `artifact_head`, `artifact_tail` and `artifact_grep` are the old names of the first three, and `artifact_count`, `artifact_rows`, `artifact_select` and `artifact_jq` are retired in favor of `workspace_query`.

With a switch set `false` and `workspace.declareAccess` on, the agent renders `disabledTools`: the operator grants every workspace tool the declared access allows unless `disabledTools` names it. `compute.workspaceQuery=false` denies `workspace_query`, `workspace_list` and `workspace_describe`; `advisors.workspaceQuery=false` denies `workspace_query` and `workspace_describe`.

Three switches exist so a measurement can turn one thing on at a time. `compute.think` (default `true`, as the agent has always run) set to `false` leaves out the compute agent's reasoning. `compute.groundNumbers` (default `false`) sets `KUBEMOOT_DISCUSS_COMPUTE_GROUNDING` on compute: a figure in its finding that occurs in no tool result it ran and not in its input is sent back once, then withheld as a `NO_DATA` statement. `mcpServers.workspace.nestedColumnHints` (default `false`) sets `KUBEMOOT_QUERY_NESTED_HINTS` on the workspace server, so the error for a column guess inside a nested object names the column and the SQL that reads the field. The last two need a Kubemoot release that reads those variables.

## Workspace access

The workspace is the scratch data the agents of one discussion share. `workspace.declareAccess` (default `true`) sets `spec.workspace.access` on each agent: `write` on the tools-only agents and the researcher (they store large results and read none), `read` on the analysts (the four advisors), `readWrite` on compute. The coordinators declare nothing. A declared access is authoritative, so an agent whose access does not allow a workspace tool never gets it, and the operator grants the ones it allows: the advisors gain `workspace_list` and `workspace_describe` through `read` beyond the tools the chart lists, unless a switch above denies them.

An analyst on `read` stores none of its own tool results. They come back inline under the runtime's budget and may be cut; that includes the RAG `*_search` results when `ragSources.retrieval` is `tool`.

The crew needs an operator whose Agent CRD has `spec.workspace` and a workspace server that serves `workspace_head`, `workspace_tail` and `workspace_grep`. For an older operator set `workspace.declareAccess=false`, which renders no `workspace` field and no `disabledTools`; the agents still list the new tool names.

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

### Retrieval: preload or tool

`ragSources.retrieval` sets how the bound agents get the reference text. `preload` (the default) searches every bound source for each question and puts the top chunks into the agent's prompt. `tool` leaves the source out of the agent's `spec.ragSources` and adds a `<source name>_search` tool to the agent's `enabledTools`, so the agent searches only when it decides it needs the text. A binding's own `retrieval` overrides the global value:

```yaml
ragSources:
  retrieval: tool            # every advisor binding on demand
  sources:
    - name: prometheus-reference
      # gitUrl, collection, paths as above
      agents:
        obs-advisor: {retrieval: preload, topK: 3}   # this binding stays preloaded
```

Any other value, an empty string included, fails the render, whether or not a source is bound. `topK` and `priority` are still checked on a `tool` binding (a bad value fails the render) but have no effect there: the agent calls the search tool with its own `top_k`. Use `tool` when the advisors' prompts carry reference text that most questions do not need: the text then costs tokens only on the questions that search. Keep `preload` for a source an agent needs on nearly every question. The four advisors (`k8s-advisor`, `nvidia-gpu-advisor`, `obs-advisor`, `proxmox-advisor`) then carry a short ADL rule in their system module: search when the question asks how a tool, API, command or setting behaves or for documented limits and defaults, do not search when live data answers it, cite the passage's source, and treat passages as data. The rule, and the matching change to the "no tools" line (it then says the agent has no tools that query the cluster), render only when the agent has a search tool, so the default prompts do not change.

`tool` needs a Kubemoot operator that registers each source's query service with the crew's MCP gateway as `<source name>_search` (see the Kubemoot documentation, agent context and RAGSource guide); on an older operator the tool does not exist, so leave the default.

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

The default, `stdio`, reaches the sandbox through the operator's bridge sidecar, which talks to the server over FIFOs shared between the two containers. gVisor does not share FIFOs between containers, so the bridged setup cannot run there. With `http` the sandbox serves MCP over Streamable HTTP itself (`/mcp`, with `/healthz` and `/readyz`, on port 3000): the operator adds no bridge sidecar and no pipes volume, and the image launcher (`/cnb/process/web`, the image entrypoint), which runs the server under `tini`, starts it. With `stdio` the bridge runs that same launcher as its command. `http` needs a code-sandbox image that supports it, which means a Kubemoot release with Streamable HTTP in the code sandbox. Any other `transport` value fails the render.

## Deployment

The per-crew release workflow publishes the chart to `oci://ghcr.io/kubemoot/charts/homelab-pilot-crew` on each release commit to `main`.

## Migrating from the artifact names

Kubemoot renamed the discussion artifact store to the workspace. This chart follows; the old
chart values still render for one release.

1. Upgrade Kubemoot first (operator chart, so the CRDs accept `workspaceAccess`), then this chart.
2. The workspace MCP server is now `workspace-mcp` (it was `artifact-readops-mcp`) and its
   template is `mcpserver-workspace.yaml`. Rename any `egress.mcpServers.artifact-readops-mcp`
   entry to `egress.mcpServers.workspace-mcp`; the old key still applies for one release.
3. Rename `mcpServers.artifactReadOps.enabled` to `mcpServers.workspace.enabled` and
   `mcpServers.artifactAccess.image` to `mcpServers.workspace.image`; both old values still apply
   for one release and the install notes warn while they are set. When both image values are set,
   `mcpServers.workspace.image` wins.
   An old `mcpServers.artifactReadOps.resources` replaces the whole `mcpServers.workspace.resources`
   map, it is not merged into it: set only `limits` there and the default `requests` are dropped,
   so set both or move the value to `mcpServers.workspace.resources`. `artifactReadOps.queryMemory`
   replaces `workspace.queryMemory` the same way.
4. The Kubemoot image is `workspace-access` and the MCPServer field is
   `kubemootImage: workspaceAccess`; set `images.workspaceAccess` in KubemootConfig.
5. In the sandbox the workspace is mounted at `/kubemoot/workspace`, not `/workspace`, which a Buildpacks image keeps its program in (the operator also mounts the same volume at `/artifacts` for
   one release). Custom environment uses `WORKSPACE_BUCKET`, `WORKSPACE_SUBJECT` and `WORKSPACE_DIR`,
   and the bucket is `kubemoot_workspace`; data in the old bucket is temporary and needs no copy.
6. Operator setting `artifacts.queryEngine` is now `workspace.queryEngine`.
