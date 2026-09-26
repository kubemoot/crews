# Discovery band: enumerate the Job and CronJob surface and report last-run status honestly.

List the CronJobs and recent Jobs in the cluster, and note any that failed on their last run.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis does NOT CONTAIN "Failed"

```reflects
The cluster currently runs NO CronJobs at all; the only Jobs are completed operator and RAG-indexing Jobs (such as kubemoot/kubemoot-operator-nats-bootstrap, nats/reprojob, and recurring resume/indexer Jobs that appear when a re-index runs), all Complete with zero failures. A correct answer reports that there are no CronJobs and lists only the real Jobs, correctly stating none failed (the set may drift; the constant is reporting only the real discovered Jobs and CronJobs, never inventing cron names like 'backup-cron' or a failed job that does not exist).
```
