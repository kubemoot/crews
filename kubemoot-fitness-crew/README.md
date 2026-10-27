# kubemoot-fitness-crew

A small judge crew that scores fitness results. When a fitness scenario asserts `DEFER synthesis REFLECTS "<reference>"`, the Kubemoot operator sends the scenario's question, the crew's answer, and the reference to this crew, and records the returned score as the scenario's quality measure. Install it once per cluster if you run fitness scenarios or suites that use `REFLECTS`.

- **Who it is for:** whoever measures crews with fitness scenarios or suites on the cluster; the `REFLECTS` assertions of every crew in this repository need it.
- **What it does:** it scores how closely a crew's answer matches a reference answer, and flags fabrication, for the operator. People do not talk to it.
- **What it needs from the cluster:** at least one chat model with reasoning in the cluster's model catalog, ideally a large one, and NATS JetStream. The crew ships no Model objects and names no model server; see [The judge's model](#the-judges-model). No MCP server, no database, and no Secret.
- **What it does not do:** it does not answer questions, call tools, start fitness runs, or choose the references; it scores what the operator hands it.

## What it deploys

- **fitness-coordinator**, a coordinator that relays the judging task and returns the verdict. It never answers on its own.
- **fitness-judge**, a reasoning agent with no tools. It reads the comparison document the operator hands it and returns a JSON verdict per answer: a score, plus flags such as fabrication.
- The Crew, its CrewSchedulingPolicy, and PromptModules.

The Crew carries the label `kubemoot.ai/adl-keyword: REFLECTS`, which is how the operator finds the judge for that assertion. To judge a different keyword, change `crew.adlKeyword` and the judge prompt together.

## Install

Prerequisites are the same as for the other crews (the Kubemoot operator, NATS, and a `ModelServer`); see the [repository README](../README.md#install). The operator must select models from the cluster's model catalog. No database or MCP server is needed.

```bash
helm upgrade --install kubemoot-fitness \
  oci://ghcr.io/kubemoot/charts/kubemoot-fitness-crew \
  --version <version> \
  -n crew-kubemoot-fitness --create-namespace
```

## The judge's model

The judge takes its model from the cluster's model catalog (the Model objects in the operator namespace plus the models each ModelServer reports), as the other crews do. Its CrewSchedulingPolicy asks the catalog for:

- **Reasoning, as a hard need.** Every phase requires `capability/reasoning: "true"`. A cluster with no reasoning model cannot schedule the crew: the scheduler reports `FailedScheduling` on the CrewSchedulingPolicy and the Agents, naming the missing label.
- **The largest model, as a preference.** `qualityBias` 0.9 scores a large model 90, a medium one 20, and a small one 10, so the judge binds to the largest reasoning model in the catalog. A judge's scores are only as steady as its model; on a cluster with only small models the crew still runs, on the best of them.
- **The same model on every run.** Fitness scores are comparable only when the same model judged them. The policy reads only catalog labels (no `preferFaster`, because measured speed changes from run to run), the operator breaks ties by the smaller declared `vramMib` (an entry that declares none after those that do) and then by name, and both agents set `KUBEMOOT_MODEL_CANDIDATE_TOLERANCE` to 0, so a call never runs on a lower-scoring model that happens to be loaded. While the catalog does not change, the judge uses the same model.

One case needs a value. When the catalog holds more than one large reasoning model, they score the same, and a call may run on whichever is loaded. Label the one that should judge, on its Model in the operator namespace, and require that label:

```yaml
scheduling:
  requireLabels:
    kubemoot.ai/fitness-judge: "true"
```

Then only that model is a candidate. If it leaves the catalog, the crew cannot be scheduled instead of scoring with another model.

To change the judge's model, change the catalog: add the model to the cluster (a larger reasoning model takes over on its own) or move the label. Compare fitness results only between runs judged by the same model; the model each call ran on is recorded on its signal as `metadata.model`.

## Network policies

When the Kubemoot operator generates network policies (its `security.networkPolicies.enabled` setting, off by default), a crew's discussion gateway admits only its own namespace and the operator. `network.allowedIngress` lists the other namespaces whose pods may reach it, such as the namespace of the web server that fronts the crew. Each entry is a Kubernetes namespace label selector:

```yaml
network:
  allowedIngress:
    - matchLabels:
        kubernetes.io/metadata.name: my-web-namespace
```

Empty, the default, renders no `network` field on the Crew, so the chart still installs on a Kubemoot operator whose Crew resource has no such field. Set it only on an operator that supports Crew network policies; see the Kubemoot documentation page on network policies.

## Fitness

`fitness/` holds three scenarios that test the judge itself: it scores a correct answer high, flags a fabricated one, and handles a method-regime question. The chart deploys them with the crew as one ConfigMap, `kubemoot-fitness-fitness`, labeled `kubemoot.ai/crew` and `kubemoot.ai/fitness-kind: scenarios`, so CrewForge and the dashboard list them; nothing runs until someone starts a run. Assemble them into one suite with [`scripts/build-suite.py`](../scripts/build-suite.py):

```bash
python3 scripts/build-suite.py kubemoot-fitness-crew/fitness \
  --namespace crew-kubemoot-fitness --crew-ref kubemoot-fitness --name judge-check --iterations 3
```
