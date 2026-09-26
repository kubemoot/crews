#!/usr/bin/env python3
"""Assemble the committed fitness/*.yaml scenarios into a single reproducible
CrewFitnessSuite manifest.

The scenarios in this directory are the source of truth. This script emits a
CrewFitnessSuite that runs every one of them N times, with each scenario's ADL
inlined as `testContent` (the reconciler reads testContent/configMapRef). That
makes a baseline run reproducible from version control instead of an ad-hoc
hand-assembled CR.

Usage:
    python3 build-suite.py --name baseline-n10 --iterations 10 \
        --description "26-scenario READ-query baseline across all four homelab layers" \
        > /tmp/baseline-suite.yaml
    kubectl apply -f /tmp/baseline-suite.yaml

Every committed scenario is included; nothing is silently dropped. The scenario
count is printed to stderr so a run can't quietly cover fewer than expected.
"""
import argparse
import os
import sys

FITNESS_DIR = os.path.dirname(os.path.abspath(__file__))
NAMESPACE = "crew-homelab-pilot"
CREW_REF = "homelab-pilot"


def scenarios():
    """Return (testRef, content) for every scenario file, sorted by name.

    A scenario is declared in ADL (.adl) or prose Markdown (.md); the runner
    detects the form from content, so both are picked up here. README.md is
    documentation, not a scenario.
    """
    out = []
    for fn in sorted(os.listdir(FITNESS_DIR)):
        if fn == "README.md" or not (fn.endswith(".adl") or fn.endswith(".md")):
            continue
        path = os.path.join(FITNESS_DIR, fn)
        with open(path) as f:
            out.append((os.path.splitext(fn)[0], f.read().rstrip("\n")))
    return out


def indent(text, spaces):
    pad = " " * spaces
    return "\n".join(pad + line if line else line for line in text.split("\n"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True, help="CrewFitnessSuite metadata.name")
    ap.add_argument("--iterations", type=int, required=True, help="iterations per scenario")
    ap.add_argument("--description", default="", help="suite purpose/scope (spec.description)")
    ap.add_argument("--per-iteration-timeout", default="10m")
    ap.add_argument("--artifact-retention", default="720h")
    args = ap.parse_args()

    scn = scenarios()
    print(f"assembling {len(scn)} scenarios x {args.iterations} = "
          f"{len(scn) * args.iterations} runs", file=sys.stderr)

    lines = [
        "apiVersion: kubemoot.ai/v1alpha1",
        "kind: CrewFitnessSuite",
        "metadata:",
        f"  name: {args.name}",
        f"  namespace: {NAMESPACE}",
        "spec:",
        f"  crewRef: {CREW_REF}",
    ]
    if args.description:
        lines.append(f"  description: {args.description!r}")
    lines += [
        f"  iterations: {args.iterations}",
        "  concurrency: 1",
        f"  perIterationTimeout: {args.per_iteration_timeout}",
        f"  artifactRetention: {args.artifact_retention}",
        "  scripts:",
    ]
    for ref, content in scn:
        lines.append(f"    - testRef: {ref}")
        lines.append("      testContent: |")
        lines.append(indent(content, 8))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
