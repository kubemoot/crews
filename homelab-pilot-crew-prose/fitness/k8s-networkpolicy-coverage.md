# Discovery band: enumerate NetworkPolicies and report the gap (namespaces with no isolation).

Which namespaces have NetworkPolicies defined, and which have none?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "flux-system"
- synthesis matches "[a-z0-9][a-z0-9-]*" at least 15 times

```reflects
NetworkPolicies exist in exactly 3 namespaces: crew-homelab-pilot and crew-homelab-pilot-prose (each a code-sandbox-egress policy) and flux-system (several flux policies); every other namespace in the cluster (the large majority of about 28) has NONE. A correct answer reports both sides, naming the 3 covered namespaces and stating the rest are uncovered; the without-policies side is obtainable from the namespace list and should not be left as 'unknown' (the set may drift; the constant is reporting only the real discovered policies and the real uncovered namespaces, never invented ones).
```
