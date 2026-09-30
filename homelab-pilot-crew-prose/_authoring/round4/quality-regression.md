# Round 4: premises, verdicts, and the Helm tools

The prose sections changed in this round were authored blind: a fresh sub-agent with
no access to the repository or to the ADL modules wrote them from the intent briefs
below and the existing prose sections they amend, then they were placed verbatim
(re-wrapped) in the templates named under each brief. The ADL crew carries the same
intent in `promptmodule-coordinator.yaml` (the `review-decision` module and the
`step-2-brief` component), `promptmodule-analyst-review.yaml` (the
`analyst-concurrence-check` component), and the `k8s-helm-system` module.

Examples use subjects outside the fitness scenarios, so no prompt is tuned to the
evaluation set; the premise examples were removed from the prose for that reason,
and neither arm names an example premise or an example unavailable action.

Parity check, after authoring: three prose sentences with no counterpart in the
briefs or the ADL were removed (grouping Helm workloads by release, reading one
workload with resources_get, and a closing hint in the concurrence section), and the
prose Helm example uses the same labelSelector call form as the ADL. Each brief
bullet appears in both arms. With Secret reads on, the Helm tooler's rendered prompt
is unchanged in both arms.

## Intent brief: coordinator, deciding how the results get checked

Amends "Deciding how the results get checked" in `promptmodule-coordinator.yaml`.

- Two more reasons to choose "full":
  - a gathered result is empty, is an error, or covers only part of what the
    question asks;
  - the question states something about this cluster as fact (that a named
    component, product, or kind of resource is present, or that a named cause
    produced an effect). The review checks that premise; it is never taken as given.

## Intent brief: coordinator, the framing brief

Amends the framing-brief guidance in `promptmodule-coordinator.yaml`, next to the
paragraph on ambiguous referents.

- When the question states something about this cluster as fact (a named component,
  product, or kind of resource is present, or a named cause produced an effect), the
  brief has the tool agents verify that premise first:
  discover what is actually installed or what the evidence actually shows. It tells
  the synthesis to correct a false premise plainly and report what is there instead.
  The brief never assumes the premise is true.
- When the question asks for an action or access that no agent has a tool for, the
  brief says the crew
  cannot do that and frames what the crew's tools can show toward the same goal. It
  never describes how to perform the action the crew cannot do.

## Intent brief: analyst, the concurrence check

Replaces "When you are asked to concur" in `promptmodule-analyst-review.yaml`, and
scopes the review-phase guidance above it ("do the work the tool agents did not") to
the full review.

- A concurrence reply is a verdict on results the coordinator judged sufficient, not
  a new answer. The review-phase guidance to compute, enumerate, and correlate does
  not apply to it.
- The analyst checks that the results answer the question as asked: the right
  scope, complete, consistent with each other, and backing any premise the question
  states.
- If they do, the reply starts with the exact text "CONCUR:" followed by at most one
  sentence of caveat it is sure of.
- If something is missing, wrong, cut off, or not backed by the gathered data, the
  reply starts with the exact text "CONCERN:" followed by what is missing or wrong,
  which sends the question to a full review.
- A reply that starts with neither counts as no verdict, and the crew runs the full
  review.
- It never answers the question, computes, enumerates, or correlates in a concurrence
  reply, and never names a value, resource, or mapping that is not literally in the
  gathered results.

## Intent brief: the Helm tooler without Secret reads

An alternative "Tools" and "Completeness" text in the `k8s-helm-system` module of
`promptmodule-specialists.yaml`, rendered when `kubernetesAccess.secretRead` is off.
With Secret reads on, the existing text stays as it is, and the install and uninstall
tools are listed only when write access is on too.

- Without Secret reads there is no helm_list. Native Helm releases are found by
  listing Deployments, DaemonSets, and StatefulSets (apiVersion apps/v1) labeled
  `app.kubernetes.io/managed-by=Helm`, cluster-wide by leaving out the namespace. Each
  names its release in the `meta.helm.sh/release-name` annotation and its chart and
  chart version in the `helm.sh/chart` label.
- Flux HelmReleases are listed as before, with resources_list, cluster-wide by
  leaving out the namespace.
- Both sources are reported together, and "none found" is rechecked with both
  listings without a namespace before it is ever the answer.
