# Discovery band: enumerate the Job and CronJob surface and report last-run status honestly.

List the CronJobs and recent Jobs in the cluster, and note any that failed on their last run.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "CronJob"

```reflects
The cluster runs two CronJobs, olabs-status/olabs-status-changed and olabs-status/olabs-status-weekly, and both succeeded on their most recent run; one older run of olabs-status-changed (Job olabs-status-changed-29825640) failed. The other Jobs are completed one-off Jobs (such as kubemoot/kubemoot-operator-nats-bootstrap, nats/reprojob, and olabs-status verification Jobs, plus resume/indexer Jobs while a re-index runs). A correct answer lists the real CronJobs with their last-run status, says none failed on its last run, and may note the older failed run; it never invents CronJobs or failures (the set may drift; the constant is reporting only the real discovered Jobs and CronJobs and each one's actual last-run status).
```
