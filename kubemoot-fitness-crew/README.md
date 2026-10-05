# kubemoot-fitness-crew

A small judge crew that scores fitness results. When a fitness scenario asserts `DEFER synthesis REFLECTS "<reference>"`, the Kubemoot operator sends the scenario's question, the crew's answer, and the reference to this crew, and records the returned score as the scenario's quality measure. Install it once per cluster if you run fitness scenarios or suites that use `REFLECTS`.

## What it deploys

- **fitness-coordinator**, a coordinator that relays the judging task and returns the verdict. It never answers on its own.
- **fitness-judge**, a reasoning agent with no tools. It reads the comparison document the operator hands it and returns a JSON verdict per answer: a score, plus flags such as fabrication.
- The Crew, its CrewSchedulingPolicy, PromptModules, and the Model resources from `models`.

The Crew carries the label `kubemoot.ai/adl-keyword: REFLECTS`, which is how the operator finds the judge for that assertion. To judge a different keyword, change `crew.adlKeyword` and the judge prompt together.

## Install

Prerequisites are the same as for the other crews (the Kubemoot operator, NATS, and an Ollama `ModelProvider`); see the [repository README](../README.md#install). No database or MCP server is needed.

```bash
helm upgrade --install kubemoot-fitness \
  oci://ghcr.io/kubemoot/charts/kubemoot-fitness-crew \
  --version <version> \
  -n crew-kubemoot-fitness --create-namespace \
  -f judge-values.yaml
```

`models` defaults to `qwen3:8b` on the provider `ollama-local`. A judge's scores are only as steady as its model, so point it at the strongest reasoning model you run:

```yaml
models:
  - name: qwen3-32b
    model: "qwen3:32b"
    providerRef: my-gpu-ollama
    family: qwen3
    params: "32B"
    latencyClass: high
    vramMib: 20480
    capabilities: [reasoning]
```

## Fitness

`fitness/` holds three scenarios that test the judge itself: it scores a correct answer high, flags a fabricated one, and handles a method-regime question. The chart deploys them with the crew as one ConfigMap, `kubemoot-fitness-fitness`, labeled `kubemoot.ai/crew` and `kubemoot.ai/fitness-kind: scenarios`, so CrewForge and the dashboard list them; nothing runs until someone starts a run. Assemble them into one suite with [`scripts/build-suite.py`](../scripts/build-suite.py):

```bash
python3 scripts/build-suite.py kubemoot-fitness-crew/fitness \
  --namespace crew-kubemoot-fitness --crew-ref kubemoot-fitness --name judge-check --iterations 3
```
