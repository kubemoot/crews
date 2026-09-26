# Discovery + interpretation band, enumerate StatefulSets and explain each one's purpose; discovered, accurate, no fabrication.

Describe the purpose of each StatefulSet found in the cluster. For each, note its namespace,
replica count, and what workload it backs.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "StatefulSet"

```reflects
Describes each StatefulSet found (namespace, replica count, what workload it backs), discovered not assumed. The cluster currently runs about 8 single-replica StatefulSets across harbor (database, redis, trivy), nats, observability (prometheus, tempo), and sonarqube (postgresql, sonarqube) (may drift; the constant is enumerating the live StatefulSets and attributing each to its real backing workload). Real ones, accurate purpose, no fabrication. Count not scored.
```
