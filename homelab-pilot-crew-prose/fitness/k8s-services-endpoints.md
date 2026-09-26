# Discovery band, list LoadBalancer/NodePort Services with ports and Ingress host rules; real entries, correct absence reporting.

List the Services of type LoadBalancer or NodePort with their ports, and any Ingresses with
their host rules.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "Service"

```reflects
The cluster has exactly one externally-typed Service: default/cilium-gateway-homelab-gateway, type LoadBalancer (external IP 192.168.50.210, ports 80:31030 and 443:30986); there are NO NodePort Services and NO Ingress resources (external HTTP routing uses Gateway API HTTPRoutes such as grade-discussion and homelab-pilot, not Ingress). A correct answer names this one LoadBalancer Service and does not claim there are none, and does not mislabel an HTTPRoute as an Ingress (the set may drift; the constant is reporting only the real discovered LoadBalancer and NodePort Services and real Ingresses, never inventing or mis-typing entries).
```
