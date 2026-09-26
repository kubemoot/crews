# Constraint band: a compound exclusion filter (literal plus prefix) plus a composite key format and sort.

List the deployments in every namespace except kube-system and any namespace starting with kube-, one per line as namespace/deployment-name, sorted by namespace.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis matches "[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*" at least 40 times
- synthesis does NOT CONTAIN "kube-system/"

```reflects
The cluster runs many deployments across many namespaces, currently on the order of a hundred-plus outside the kube-* namespaces, so a correct answer is a long list, not a handful. It lists deployments from all namespaces while excluding kube-system and every kube-* namespace, formatted one per line as namespace/name and sorted by namespace, discovered live. Correct compound exclusion, format, sort, and completeness are scored; the specific deployment names are not. (The exact count drifts; the constant is enumerating every non-kube deployment in the required shape.)
```
