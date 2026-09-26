# Discovery + interpretation band, enumerate namespaces and infer each one's purpose from labels and workloads; discovered, grounded, honest about the undeterminable, no fabrication.

List the namespaces in the cluster, and for each, infer its purpose from its labels and the
workloads it contains. Say so explicitly when a namespace's purpose cannot be determined rather
than guessing.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "namespace"

```reflects
The cluster currently has about 28 namespaces; a complete inventory includes the standard Kubernetes ones (kube-system, kube-public, kube-node-lease, default), platform namespaces (cert-manager, cilium-secrets, cloudflared, flux-system, harbor, headlamp, democratic-csi, gpu-operator, keda, nats, observability), the GPU model-serving namespaces ollama-rig0 and ollama-rig1, the sonarqube quality-gate namespace, and the crew and app namespaces (crew-forge, crew-grade, crew-test, crew-homelab-pilot, crew-homelab-pilot-prose, crew-kubemoot-fitness, homelab-pilot, kubemoot, arc-runners, arc-systems). A correct answer enumerates the real namespaces and infers each purpose from its labels and workloads (the set may drift; the constant is reporting only the real discovered namespaces, never inventing any and never silently dropping live ones such as the two GPU rigs or sonarqube).
```
