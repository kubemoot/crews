# Constraint band, honor several explicit output constraints at once: namespace scope filter, alphabetical sort, single-field selection, exclusion.

List the Helm releases in the kube-system namespace, sorted alphabetically by release name, giving only the chart version for each, not the app version, and excluding every release from any other namespace.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "cilium" AND "metrics-server"
- synthesis does NOT CONTAIN "harbor"

```reflects
The kube-system namespace currently holds exactly two Helm releases, cilium and metrics-server, so a correct scoped answer lists just those two with their chart versions. It lists only the kube-system Helm releases, alphabetical by name, chart version only with no app version, and nothing from other namespaces; pulling in releases such as harbor that live elsewhere is a scoping failure. Correct scoping, sort, and field selection while honoring all the constraints is the point. (The exact releases may drift; the constant is listing only what kube-system actually owns in the required shape.)
```
