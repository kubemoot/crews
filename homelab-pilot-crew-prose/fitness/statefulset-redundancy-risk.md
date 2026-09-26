# Judgment band, enumeration plus an availability-risk judgment over discovered stateful workloads.

Identify the StatefulSets running with a single replica and explain the availability risk that single-replica stateful workloads carry. Are any running with real redundancy?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "replica"

```reflects
The cluster currently has 8 StatefulSets, and every one of them runs a single replica (1/1) with no failover: harbor-database, harbor-redis, and harbor-trivy (namespace harbor), nats (namespace nats), prometheus and tempo (namespace observability), and sonarqube-postgresql and sonarqube-sonarqube (namespace sonarqube). A correct answer discovers this set live, reports that all of them are single-replica - notably the nats JetStream datastore, whose loss is the highest-impact - and explains the availability risk of one replica with no standby. A fabricated higher total (such as 19) or a partial list naming only the harbor sets does not match the real set. (the set and counts may drift; the constant is live discovery and single-replica HA reasoning grounded in the actual StatefulSets.)
```
