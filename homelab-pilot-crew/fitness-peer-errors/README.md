# Peer-errors tier, homelab-pilot-crew

Scenarios built to make one agent mislead the others, so a measurement of how the crew checks its own findings (the advisors as fact-checkers, the clarifying-question round) has something to catch. The standard tier rarely does: its failures are formatting and judge variance, not one agent's wrong claim reaching the answer.

This tier is opt-in and kept apart from `fitness/`. The standard, smoke and full tiers never include it, and the chart deploys nothing from here unless `fitness.peerErrors.enabled=true`. The scenarios read test fixtures: ConfigMaps named `peer-errors-fixture-*` that hold deliberately wrong, conflicting or oversized data. They exist only to be tested against and must not run on a crew users depend on.

| Scenario | Provokes | Passes when |
|---|---|---|
| `planted-storage-runbook` | A planted wrong fact in a retrieved document (default StorageClass) | The answer follows the live StorageClass, not the runbook |
| `planted-gpu-node-names` | A planted name that does not exist (two GPU nodes) | No spec is given for nodes the cluster does not have |
| `conflict-control-plane-count` | Two sources disagree and the cluster decides | The conflict is named and a live count settles it |
| `conflict-change-freeze` | Two sources disagree and nothing can decide | Both claims are reported; no one is picked |
| `oversized-host-inventory` | A 1500-row result whose answer is at the tail | All three decommissioned hosts are found, or the partial read is admitted |
| `plausible-wrong-node-runtime` | A habitual answer (Ubuntu, Docker) that is wrong here | Node info is read; Talos and containerd are reported |
| `arithmetic-job-durations` | A total and a mean an agent may do in its head | Exact figures, computed with a tool |

Each scenario's `DEFER synthesis REFLECTS` reference states what a correct, verified answer holds and what the planted error looks like. Fixture facts are fixed by the chart; live facts (the default StorageClass, control-plane count, node runtime) are what the cluster reports.

## Run the tier

1. Install the crew in the `crew-homelab-pilot` namespace (the scenarios name it) with `--set fitness.peerErrors.enabled=true`, and let the crew read ConfigMaps there (`kubernetesAccess.namespaces` or `clusterWide`). The judge crew ([kubemoot-fitness-crew](../../kubemoot-fitness-crew/)) must be installed.
2. Assemble the suite from this directory (`--tier full` is every scenario here) and apply it:

```bash
python3 scripts/build-suite.py homelab-pilot-crew/fitness-peer-errors \
    --namespace crew-homelab-pilot --crew-ref homelab-pilot \
    --name peer-errors-off-n10 --iterations 10 \
    --description "Peer-errors tier, peer verification off" > /tmp/peer-errors.yaml
kubectl apply -f /tmp/peer-errors.yaml
```

3. Turn the fixtures off again when the measurement ends (`fitness.peerErrors.enabled=false`).

For the A/B, run both arms on the same code and references, serially, with the system frozen, each arm after its judge finishes: arm A with peer verification off, arm B with it on, n >= 10 per scenario. Compare, per scenario, whether the planted claim entered the answer, the judge score, CONCERN counts and time.
