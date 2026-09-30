# homelab-pilot-crew-prose

The prose arm of the ADL-vs-prose experiment. This chart is a copy of [homelab-pilot-crew](../homelab-pilot-crew/) with every PromptModule rewritten as natural prose instead of ADL. Agents, tools, RAG sources, models, the CrewSchedulingPolicy, and the archetype are the same, so prompt form is the only variable between the two crews.

The experiment asks whether ADL-structured prompts (WHEN/THEN/ASSERT rules) produce better or more consistent crew answers than the same intent written the way an engineer naturally would, on the same models. The two crews run the same fitness scenarios, one arm at a time, and a judge crew scores both.

## How the prose was written

The prose was authored blind: each agent's intent was distilled from the ADL into a short brief, and an author that had never seen the ADL wrote the prompts from the brief alone. Leakage and parity checks confirmed the prose carries the same intent without ADL syntax. The briefs, the pre-ADL historical prompts used for calibration, and the authored prose are in [`_authoring/`](./_authoring/), which is not part of the chart.

## Install

Install it like the ADL crew, into its own namespace, with the same values file you use for `homelab-pilot-crew`. See [Before you install](../homelab-pilot-crew/README.md#before-you-install) for the values you must set and the [repository README](../README.md#install) for prerequisites.

```bash
helm upgrade --install homelab-pilot-prose \
  oci://ghcr.io/kubemoot/charts/homelab-pilot-crew-prose \
  --version <version> \
  -n crew-homelab-pilot-prose --create-namespace \
  -f my-values.yaml
```

The Crew is named `homelab-pilot-prose`, so both arms can run in one cluster. Measure them one at a time: two crews sharing GPUs slow each other down and skew the comparison.

## Fitness

`fitness/` holds the same 76 scenarios as the ADL crew, written as prose Markdown (`*.md`). Questions and reference answers are identical between the arms. Scenarios that use `DEFER synthesis REFLECTS` need the [kubemoot-fitness-crew](../kubemoot-fitness-crew/) judge installed.

## Deployment

The per-crew release workflow publishes the chart to `oci://ghcr.io/kubemoot/charts/homelab-pilot-crew-prose` on each release commit to `main`.
