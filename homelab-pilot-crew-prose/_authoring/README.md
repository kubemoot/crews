# homelab-pilot-crew-prose: authoring workspace

This directory stages the inputs for the **prose counterfactual crew** in the
ADL-vs-prose experiment. The hypothesis under test:

> Does ADL-structured prompting (WHEN/THEN/ASSERT, exhaustive and explicit)
> produce better/more-consistent crew behavior than the **same intent** written
> the way a human naturally would - narrative, incomplete, implicit - at a
> constant model tier?

The deployable chart (Chart.yaml, templates/ with prose PromptModules) is added
LATER, once the prose is authored. This `_authoring/` folder is not part of any
chart - it's the experiment's provenance + working material.

## The validity problem this guards against

ADL-first is backward: the truest experiment runs prose-first, then formalizes to
ADL. We can't un-ring that, so we **reconstruct** the prose-first condition. The
failure mode to avoid is **information-content leakage** - a faithful ADL→prose
translation preserves the ADL's completeness, turning the prose arm into "ADL
with the syntax removed." Then we'd only measure *format*, not the real
hypothesis. The defense is structural, not a promise to "write naturally":

1. **`intent/<agent>.md` - the controlled variable.** Each agent's intent
   distilled UP from the current ADL: role, scope, the tools/RAG it has, what a
   good answer looks like, what to avoid. It deliberately DROPS the rule
   structure and the exhaustive case/tool-selection tables. A maintainer reviews each
   brief so we agree it is the SAME intent - neither enriched nor starved.

2. **Blind authoring (later step).** The prose system prompts are written FROM
   THE INTENT BRIEF ALONE, by an author that has never seen the ADL - a fresh
   sub-agent (clean context, only the brief) and/or an external model
   (Gemini 2.5 Pro, GPT-5, a fresh Claude.ai session). It cannot mirror what it
   never read. Author as a competent engineer would on a first/second pass -
   narrative, an example or two, NOT an exhaustive rule list. Warts stay.

3. **Two guards.** *Leakage scan:* prose containing ADL tells (WHEN/THEN/ASSERT,
   the same edge cases in the same order) transliterated → redo. *Parity check:*
   an independent reader confirms the prose pursues the same intent (didn't drop
   a responsibility or invent one). Genuine ≠ sabotaged.

## `historical/` - calibration, not the arm

The genuine pre-ADL prose prompts, pulled verbatim from homelab-pilot
`4cc99e9^` (the commit before `feat: extract specialist prompts to ADL
PromptModules`). These are real human artifacts - semi-structured markdown with
narrative, examples, and motivational fluff. They PREDATE later hardening, so
they are **not constant-intent enough to be the experiment arm**. They are a
reality check on how natural the authored prose should read, and a check on
whether the intent briefs quietly added intent the humans never had.

## Roster mapping (current 21 agents → historical prose)

`historical/` = 20 files; `intent/` = 22. The two agents with no historical pair
(coordinator, scheduler-advisor) genuinely never had inline prose → brief-only.

- **Direct history (17, verbatim single-agent prose):** internet-search,
  k8s-advisor, k8s-config, k8s-helm, k8s-metrics, k8s-nodes, k8s-scaling,
  k8s-services, k8s-storage, k8s-workloads, k8sgpt, nvidia-gpu-advisor,
  obs-advisor, observability, proxmox-advisor, **proxmox-pve**, **proxmox-qm**.
  (`agent-proxmox.yaml` defined two agents, each with its own inline prose block;
  each block went verbatim to its own file.)
- **Split-offs - PARTITIONED (3):** nvidia-gpu-now / nvidia-gpu-history /
  nvidia-gpu-meta were one `nvidia-gpu` agent. The genuine combined prose was
  broken up by scope into three files - verbatim sentences routed to the split
  they belong to (now = instant value queries; history = range/trend + metadata;
  meta = topology/metric discovery + scrape health). NOT enriched to current
  intent. One wart this surfaced: the original discovered topology via
  instant `count by(...)` queries, a tool the split `meta` agent no longer has,
  left visible, not rewritten.
- **No history → brief-only:** scheduler-advisor (added post-ADL) and coordinator
  (never had a single inline prose prompt - its behavior lived in the advisory /
  triage / decision / synthesis modules). Both authored from intent alone.

RAG (verified against `values.yaml`): RAGSources are cluster-wide collections
with no per-agent CR binding (`ragRefs` does not exist). The four advisors'
briefs name domain-correct collections (k8s-advisor → kubernetes_concepts /
kubectl_reference / helm_reference / talos_reference / kubernetes_mcp_tools;
nvidia-gpu-advisor → nvidia_gpu_reference; obs-advisor → prometheus_reference;
proxmox-advisor → proxmox_api_reference / proxmox_pve_docs) - all exist; phrased
as indexed knowledge, not tools.

## Shared behavior modules (`shared/`, round 2)

Beyond the per-agent prompts, every agent inherits crew-wide modules. For a
genuinely all-prose crew these need prose too (else the prose arm keeps ADL's
strongest shared enforcement). Staged in `shared/historical/` + `shared/intent/`:

- **discussion-protocol** - how each agent participates in the group discussion
  (contribute / stand aside / TOOL_GAP / review). Genuine prose pulled from
  `cb2bdd9^` (before its ADL restructure).
- **response-style** - how agents present answers. Genuine prose from `4cc99e9^`.
- **tool-using-specialist-discipline** - the "drill until answered, don't defer"
  enforcement. Post-ADL only (no prior prose) → **brief-only**; category-2
  explicitness, so its prose form is deliberately loose.

## Status

- [x] per-agent historical prose extracted (20 files; GPU partitioned, proxmox split)
- [x] per-agent intent briefs written (22; leakage-clean, RAG-verified)
- [x] shared-module historical (2) + intent briefs (3) staged
- [x] handoff zips built (per-agent + shared), README excluded
- [x] prose authored blind from briefs (external Claude.ai) - round1/ + round2/
- [x] leakage + parity guards run (25/25 PASS, 0 ADL DSL); the authored files were
      committed before the interface-contract fix (coordinator JSON, REMEMBER) for
      auditability (the authoring chat transcripts are not kept in this repository)
- [x] chart assembled - clone of the ADL crew with prose PromptModules; crew renamed
      `homelab-pilot-prose`, all-prose verified (0 ADL syntax), tiering parity kept
- [ ] deployed + baseline run vs the ADL crew (waits for baseline-v4 to free the GPUs)

## Chart assembly notes

`homelab-pilot-crew-prose/` is the deployable chart: a clone of `homelab-pilot-crew`
with every PromptModule's `content` replaced by the blind-authored prose (per-agent
at order 30, shared at 10/20/25, and the coordinator's four ADL modules collapsed
into one `coordinator-system` prose module with promptRefs updated). Everything else
is identical - agents, tools, RAG, CrewSchedulingPolicy (incl. the triage `prefer`
tiering block), models, archetype - so prompt FORM is the only variable. Crew identity
retargeted to `homelab-pilot-prose` (the agent templates hardcoded `kubemoot.ai/crew:
homelab-pilot`; fixed so the prose crew is isolated). Deploy target namespace:
`crew-homelab-pilot-prose`.

**One direct-prose exception:** the three GPU split agents carry an LLM-facing
`discussRelevance.promptHint` (ADL) that was NOT part of the round-1 system-prompt
briefs. I prose-ified those three hints directly from the agents' already-blind-authored
scope (now/history/meta), rather than through a separate blind round - they're a minor
triage-relevance surface, and the prose is a faithful restatement of scope, not new
intent. Flagged here for transparency.
