<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/kubemoot-horizontal-white-text.png">
  <img src=".github/assets/kubemoot-horizontal-color.png" alt="Kubemoot" height="64">
</picture>

# Kubemoot Crews

[![Latest release](https://img.shields.io/github/v/release/kubemoot/crews?sort=semver&filter=homelab-pilot-crew-v*)](https://github.com/kubemoot/crews/releases) [![Build status](https://github.com/kubemoot/crews/actions/workflows/homelab-pilot-crew-release.yaml/badge.svg?branch=main)](https://github.com/kubemoot/crews/actions/workflows/homelab-pilot-crew-release.yaml?query=branch%3Amain) [![License: Apache 2.0](https://img.shields.io/github/license/kubemoot/crews)](https://github.com/kubemoot/crews/blob/main/LICENSE) [![OpenSSF Scorecard](https://img.shields.io/ossf-scorecard/github.com/kubemoot/crews?label=openssf%20scorecard)](https://scorecard.dev/viewer/?uri=github.com/kubemoot/crews)

Each subdirectory is an independently versioned Helm chart for a Kubemoot agent crew. Crews are the deployable unit of agent collaboration on the [Kubemoot](https://github.com/kubemoot/kubemoot) operator: a chart installs the Agents, PromptModules, MCP tool servers, the CrewSchedulingPolicy that says what models each phase needs, and the Crew resource that binds them, and the operator runs them.

## Crews in this repository

| Crew | What it is | Chart |
|---|---|---|
| [homelab-pilot-crew](./homelab-pilot-crew/) | Answers cluster operators' questions about their Kubernetes cluster, its observability stack, its GPUs, and optionally Proxmox VE; the reference crew for the others. | `oci://ghcr.io/kubemoot/charts/homelab-pilot-crew` |
| [kubemoot-fitness-crew](./kubemoot-fitness-crew/) | Scores crews' fitness-scenario answers against a reference (the `REFLECTS` assertion); install it once per cluster if you run fitness suites. | `oci://ghcr.io/kubemoot/charts/kubemoot-fitness-crew` |
| [oguide-crew](./oguide-crew/) | O'guide finds, ranks, and links O'Reilly library material for subscribers, as catalog metadata with reader links; bring your own O'Reilly key. | `oci://ghcr.io/kubemoot/charts/oguide-crew` |

The reference crew was built for the maintainer's homelab: a Talos Kubernetes cluster on Proxmox VE with two GPU nodes, each serving Ollama. The chart defaults are generic, but read [Before you install](./homelab-pilot-crew/README.md#before-you-install) in its README for what you have to supply.

## Install

### Prerequisites

- Kubernetes 1.30 or later and Helm 3.8 or later (OCI chart support).
- The Kubemoot operator chart, `oci://ghcr.io/kubemoot/charts/kubemoot-operator`. `homelab-pilot-crew` and `kubemoot-fitness-crew` need an operator that registers model servers as the `ModelServer` kind and selects models from the cluster's model catalog, `homelab-pilot-crew` one that treats `preferFaster` on a scheduling rule as an explicit preference, and one that binds an `EmbeddingModel` with no `serverRef` to a model server from the cluster's catalog; see the [installation guide](https://github.com/kubemoot/kubemoot/blob/main/docs/introduction/installation.md).
- NATS JetStream, which carries the discussions. The operator docs and the quickstart install it as release `nats` in namespace `nats`; if yours differs, set `nats.url` and `nats.namespace`.
- At least one model server registered as a `ModelServer` (created through the operator chart's `modelServers` values). The Kubemoot quickstart creates one called `ollama-local`. The embedding model (`nomic-embed-text`) must be on a server, or a Model must ask for it on one (`kmctl model add`); the crews name the model, never the server. `homelab-pilot-crew` and `kubemoot-fitness-crew` ship no Model objects: they select chat models from the cluster's model catalog (the Model objects in the operator namespace plus the models each ModelServer reports). `homelab-pilot-crew` needs at least one chat model with tool-calling there, and the fitness judge at least one with reasoning.
- For `homelab-pilot-crew`: a PostgreSQL database with the pgvector extension for the RAG sources and the MCP gateway tool index, and a Secret with its credentials in the crew namespace. The charts do not install either.
- For `oguide-crew`: an O'Reilly subscription and a Secret with your own O'Reilly key in the crew namespace; see [Add your O'Reilly key](./oguide-crew/README.md#add-your-oreilly-key).

### Install a crew

Pick a chart version from this repository's tags (`<crew>-v<version>`), then:

```bash
helm upgrade --install homelab-pilot \
  oci://ghcr.io/kubemoot/charts/homelab-pilot-crew \
  --version <version> \
  -n crew-homelab-pilot --create-namespace \
  -f my-values.yaml
```

A minimal `my-values.yaml` for one pgvector database. It names no chat model and no model server; the crew takes models from the cluster's model catalog, and the embedding model (`nomic-embed-text`) is bound to a server that has it:

```yaml
vectorStore:
  host: pgvector.databases.svc.cluster.local
  database: kubemoot
  existingSecret: crew-db-credentials   # keys: username, password
mcpServers:
  prometheus:
    endpoint: http://kube-prometheus-stack-prometheus.monitoring:9090
```

The fitness judge needs no values. It binds to the largest reasoning model in the catalog and keeps the same one while the catalog does not change (see [The judge's model](kubemoot-fitness-crew/README.md#the-judges-model)):

```bash
helm upgrade --install kubemoot-fitness \
  oci://ghcr.io/kubemoot/charts/kubemoot-fitness-crew \
  --version <version> \
  -n crew-kubemoot-fitness --create-namespace
```

### Cluster permissions

The Kubernetes tools in the reference crews are read-only by default. `kubernetesAccess.secretRead` adds Secret reads (needed by `helm_list`), and `kubernetesAccess.writeAccess` adds pod exec, workload patch and scale, and the matching agent tools. Agents act on text from tools and the web, so enable these only on a cluster where you accept that risk.

## Layout

```
crews/
  <crew-name>/
    Chart.yaml          # versioned independently per crew
    values.yaml
    templates/          # Agents, PromptModules, MCPServers, CrewSchedulingPolicy, Crew CR
    fitness/            # CrewFitness scenarios for measuring this crew
    README.md           # what this crew does
  scripts/
    build-suite.py      # assembles a crew's fitness/ scenarios into one CrewFitnessSuite
```

A crew chart deploys:

- **Agents**, the participants in the discussion
- **PromptModules**, composable ADL behavior modules referenced by agents
- **MCPServers**, the tool servers the agents call
- **CrewSchedulingPolicy**, phase rules and `qualityBias` for model selection
- **Crew**, the top-level resource binding everything together
- **CrewFitness** scenarios (under `fitness/`), measurable test cases

To run every scenario of a crew as one reproducible suite, assemble a `CrewFitnessSuite` from the committed scenarios. Pass the crew's `fitness/` directory, its namespace, and its Crew name:

```bash
python3 scripts/build-suite.py homelab-pilot-crew/fitness \
  --namespace crew-homelab-pilot --crew-ref homelab-pilot \
  --name baseline-n10 --iterations 10 \
  --description "Full baseline across all four homelab layers" > baseline-suite.yaml
kubectl apply -f baseline-suite.yaml
```

The script includes every `.adl` and `.md` scenario except `README.md`, prints the scenario count to stderr, and fails when the directory holds no scenarios. Its tests run with `python3 -m unittest discover -s scripts -p 'test_*.py'`.

## Versioning

Each crew chart is independently versioned. CI runs per crew:

- `.github/workflows/<crew-name>-release.yaml` triggers on `<crew-name>/**`
- The version comes from conventional commits scoped to the changed crew's path
- Each crew has its own tag stream (for example `homelab-pilot-crew-v1.2.3`)
- Each merge to `main` builds a release candidate for the maintainers' registry; a maintainer runs Publish Release to tag the final version and push the chart to `oci://ghcr.io/kubemoot/charts/<crew-name>`

## Consumers

- **[Kubemoot operator](https://github.com/kubemoot/kubemoot)** reconciles the Crew resource and its child resources.
- **CrewForge**, the Kubemoot VS Code extension, lists crews in a cluster and opens a chat with them from the editor.
- **kmctl**, the Kubemoot CLI, runs fitness scenarios against a crew (`kmctl fitness run`).
- **Homelab Pilot**, the maintainer's homelab web app, talks to the reference crew through the crew's discussion gateway.

## Community and contributing

Kubemoot is an independent open-source project under the Apache License 2.0. Contributing, support, governance, the code of conduct, security reporting, and releases are documented in one place: the [Community section of kubemoot.org](https://kubemoot.org/docs/community/). Ask questions and share ideas in [GitHub Discussions](https://github.com/orgs/kubemoot/discussions). Write to moot@kubemoot.org for anything else. Use security@kubemoot.org only to report a vulnerability, privately.

To add a crew:

1. Create a new subdirectory `<your-crew>/` with the layout above.
2. Add a per-crew workflow `.github/workflows/<your-crew>-release.yaml` modeled on the existing ones.
3. Commit with a conventional-commit message. CI builds a release candidate of the chart; a maintainer publishes a tested candidate as a public release.
