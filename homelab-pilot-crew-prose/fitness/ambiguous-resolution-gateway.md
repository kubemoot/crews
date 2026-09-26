# Selectivity band: an ambiguous referent (ingress gateway vs MCP gateway vs network gateway); resolve it by enumerating candidates.

Is the gateway up?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "Cilium"
- synthesis does NOT CONTAIN "no gateway"

```reflects
The cluster has a real, healthy gateway and its status IS determinable from live state. A correct answer recognizes 'the gateway' is ambiguous, discovers the gateway-like components rather than assuming absence, and reports each one's status. Currently a Cilium Gateway API gateway (default/homelab-gateway, class cilium) is PROGRAMMED and serving on 192.168.50.210 via a LoadBalancer service, fronting roughly a dozen HTTPRoutes; declaring no gateway exists or that it is unavailable is wrong. A correct answer names the discovered gateway and reports it up. (The exact name and address may drift; the constant is discovering and reporting the actual gateway present.)
```
