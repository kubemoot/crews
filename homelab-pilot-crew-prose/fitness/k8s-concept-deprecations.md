# Concept/RAG band: conceptual and tooling accuracy on API deprecations, with no version invention.

What is the recommended way to track and handle Kubernetes API deprecations before an upgrade?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "deprecat"

```reflects
Explains the Kubernetes API deprecation policy and the recommended detect-and-migrate workflow before an upgrade: run a deprecated-API detector (the canonical tools are kubent / kube-no-trouble and Pluto, optionally the apiserver audit logs and the apiserver_requested_deprecated_apis metric), review the target release notes and removed-API list, audit and convert manifests and Helm charts to the current apiVersion, then validate in a staging upgrade. A sound answer names at least one real detector (kubent or Pluto) and does not invent kubectl flags: there is no kubectl api-resources --deprecated and no kubectl get --show-deprecated flag, so citing them is fabrication. Accurate conceptual guidance with real tooling is scored; no fabricated version cutoffs or commands.
```
