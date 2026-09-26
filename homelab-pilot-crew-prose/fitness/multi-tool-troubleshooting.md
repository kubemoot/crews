# Multi-tool band, coordinate Helm health + pod readiness + k8sgpt diagnosis into a root cause; 'nothing failing' acceptable when true.

Which Helm releases are currently in a Failed or Pending state, what underlying pods are not
Ready, and what does k8sgpt diagnose as the root cause?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 600 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "Helm" AND "pod"

```reflects
Combines Helm release health, pod readiness, and a k8sgpt diagnosis to identify what (if anything) is failing and the root cause. The verified live state is dozens of Helm releases present in the cluster (around 86 release records) all currently deployed with no Failed or Pending release, so the correct answer is nothing currently failing, grounded in actually enumerating the releases (may drift; the constant is reading real release state, not an empty result). Asserting that helm returned empty or that there are no Helm releases contradicts reality and is wrong even when the cluster happens to be healthy. No fabricated failures.
```
