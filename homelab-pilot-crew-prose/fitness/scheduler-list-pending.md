# State-read band, report pending scheduled reminders/follow-ups; honest 'none' when empty, never fabricates.

List any pending scheduled reminders or follow-up discussions that are currently queued.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "schedul"

```reflects
Reports any pending scheduled reminders or queued follow-up discussions. Correctly reports that there are none when the queue is empty; never fabricates reminders.
```
