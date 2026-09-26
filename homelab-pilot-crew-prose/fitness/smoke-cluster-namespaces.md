# Smoke/discovery band, basic namespace enumeration; gateway reachable, discovery works, real names.

What namespaces exist in the Kubernetes cluster?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "connected" event
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 300 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "namespace"

```reflects
The cluster currently has about 28 namespaces, discovered via kubectl get ns and not assumed. They include the standard Kubernetes namespaces (kube-system, kube-public, kube-node-lease, default), the platform namespaces (flux-system, cert-manager, cilium-secrets, cloudflared, gpu-operator, democratic-csi, keda, harbor, sonarqube, observability, nats, kubemoot, headlamp, arc-runners, arc-systems, ollama-rig0, ollama-rig1), and the application and crew namespaces (homelab-pilot, crew-forge, plus transient fitness and crew namespaces). A correct answer lists real namespace names with the printed list internally consistent with any stated count - it does not claim 28 then enumerate only 25, and it does not omit the two GPU ollama namespaces or sonarqube. (the exact set may drift; the constant is live discovery and a self-consistent enumeration.)
```
