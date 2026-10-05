<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/kubemoot-horizontal-white-text.png">
  <img src=".github/assets/kubemoot-horizontal-color.png" alt="Kubemoot" height="64">
</picture>

# Kubemoot Crews

[![Latest release](https://img.shields.io/github/v/release/kubemoot/crews?sort=semver&filter=homelab-pilot-crew-v*)](https://github.com/kubemoot/crews/releases) [![Build status](https://github.com/kubemoot/crews/actions/workflows/homelab-pilot-crew-release.yaml/badge.svg?branch=main)](https://github.com/kubemoot/crews/actions/workflows/homelab-pilot-crew-release.yaml?query=branch%3Amain) [![License: Apache 2.0](https://img.shields.io/github/license/kubemoot/crews)](https://github.com/kubemoot/crews/blob/main/LICENSE) [![OpenSSF Scorecard](https://img.shields.io/ossf-scorecard/github.com/kubemoot/crews?label=openssf%20scorecard)](https://scorecard.dev/viewer/?uri=github.com/kubemoot/crews)

Each subdirectory is an independently versioned Helm chart for a Kubemoot agent crew. Crews are the deployable unit of agent collaboration on the [Kubemoot](https://github.com/kubemoot/kubemoot) operator: a chart installs the Agents, PromptModules, MCP tool servers, Models, and the Crew resource that binds them, and the operator runs them.

## Crews in this repository

| Crew | What it is | Chart |
|---|---|---|
| [homelab-pilot-crew](./homelab-pilot-crew/) | The reference crew: a coordinator and up to 22 specialists that answer operational questions about a Kubernetes cluster, its observability stack, NVIDIA GPUs, and optionally Proxmox VE. Its prompts are written in ADL. | `oci://ghcr.io/kubemoot/charts/homelab-pilot-crew` |
| [kubemoot-fitness-crew](./kubemoot-fitness-crew/) | A one-agent judge crew that scores fitness-scenario answers against a reference (the `REFLECTS` assertion). Install it once per cluster if you run fitness suites. | `oci://ghcr.io/kubemoot/charts/kubemoot-fitness-crew` |

The reference crew was built for the maintainer's homelab: a Talos Kubernetes cluster on Proxmox VE with two GPU nodes, each serving Ollama. The chart defaults are generic, but read [Before you install](./homelab-pilot-crew/README.md#before-you-install) in its README for what you have to supply.

## Install

### Prerequisites

- Kubernetes 1.30 or later and Helm 3.8 or later (OCI chart support).
- The Kubemoot operator chart, `oci://ghcr.io/kubemoot/charts/kubemoot-operator`. The crews in this repository are tested against operator chart 0.92.x; see the [installation guide](https://github.com/kubemoot/kubemoot/blob/main/docs/introduction/installation.md).
- NATS JetStream, which carries the discussions. The operator docs and the quickstart install it as release `nats` in namespace `nats`; if yours differs, set `nats.url` and `nats.namespace`.
- At least one Ollama server registered as a `ModelProvider` (created through the operator chart's `modelProviders` values), with the models your crew's `models` values name already pulled. The Kubemoot quickstart creates one called `ollama-local`, which is the default `providerRef` in these charts.
- For `homelab-pilot-crew`: a PostgreSQL database with the pgvector extension for the RAG sources and the MCP gateway tool index, and a Secret with its credentials in the crew namespace. The charts do not install either.

### Install a crew

Pick a chart version from this repository's tags (`<crew>-v<version>`), then:

```bash
helm upgrade --install homelab-pilot \
  oci://ghcr.io/kubemoot/charts/homelab-pilot-crew \
  --version <version> \
  -n crew-homelab-pilot --create-namespace \
  -f my-values.yaml
```

A minimal `my-values.yaml` for one Ollama server and one pgvector database:

```yaml
models:
  - name: qwen3-8b
    model: "qwen3:8b"
    providerRef: ollama-local        # the ModelProvider name in the operator namespace
    family: qwen3
    params: "8B"
    latencyClass: low
    capabilities: [tool-calling, reasoning]
embeddingModel:
  providerRef: ollama-local          # serves nomic-embed-text
vectorStore:
  host: pgvector.databases.svc.cluster.local
  database: kubemoot
  existingSecret: crew-db-credentials   # keys: username, password
mcpGateway:
  toolIndex:
    embeddingModel:
      endpoint: http://ollama.ollama:11434
mcpServers:
  prometheus:
    endpoint: http://kube-prometheus-stack-prometheus.monitoring:9090
```

The fitness judge needs only a model. Its default is `qwen3:8b` on the `ollama-local` provider; override `models` the same way to point it at your strongest reasoning model:

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
