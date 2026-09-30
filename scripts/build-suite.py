#!/usr/bin/env python3
"""Assemble a crew's committed fitness scenarios into a single reproducible
CrewFitnessSuite manifest.

The scenarios in a crew's fitness/ directory are the source of truth. This
script emits a CrewFitnessSuite that runs every one of them N times, with each
scenario's text inlined as `testContent` (the reconciler reads
testContent/configMapRef). That makes a baseline run reproducible from version
control instead of an ad-hoc hand-assembled CR.

Usage (from the repository root):
    python3 scripts/build-suite.py homelab-pilot-crew/fitness \
        --namespace crew-homelab-pilot --crew-ref homelab-pilot \
        --name baseline-n10 --iterations 10 \
        --description "Full baseline across all four homelab layers" \
        > /tmp/baseline-suite.yaml
    kubectl apply -f /tmp/baseline-suite.yaml

Every committed scenario is included; nothing is silently dropped. The scenario
count is printed to stderr so a run cannot quietly cover fewer than expected,
and a directory with no scenarios is an error rather than an empty suite.
"""
import argparse
import os
import sys

SCENARIO_EXTENSIONS = (".adl", ".md")
DOCUMENTATION_FILE = "README.md"
CONTENT_INDENT = 8


def is_scenario(filename):
    """A scenario is declared in ADL (.adl) or prose Markdown (.md); the runner
    detects the form from content. README.md is documentation, not a scenario.
    """
    return filename != DOCUMENTATION_FILE and filename.endswith(SCENARIO_EXTENSIONS)


def scenarios(fitness_dir):
    """Return (testRef, content) for every scenario file, sorted by name."""
    out = []
    for fn in sorted(os.listdir(fitness_dir)):
        if not is_scenario(fn):
            continue
        with open(os.path.join(fitness_dir, fn), encoding="utf-8") as f:
            out.append((os.path.splitext(fn)[0], f.read().rstrip("\n")))
    return out


def indent(text, spaces):
    """Indent every non-empty line; empty lines stay empty so YAML block
    scalars carry no trailing whitespace."""
    pad = " " * spaces
    return "\n".join(pad + line if line else line for line in text.split("\n"))


def yaml_quote(text):
    """Return text as a YAML single-quoted scalar. Inside single quotes YAML
    has no escapes: a quote is written twice and a backslash is literal."""
    return "'" + text.replace("'", "''") + "'"


def render(scn, args):
    """Render the CrewFitnessSuite manifest for the given scenarios."""
    lines = [
        "apiVersion: kubemoot.ai/v1alpha1",
        "kind: CrewFitnessSuite",
        "metadata:",
        f"  name: {args.name}",
        f"  namespace: {args.namespace}",
        "spec:",
        f"  crewRef: {args.crew_ref}",
    ]
    if args.description:
        lines.append(f"  description: {yaml_quote(args.description)}")
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
        lines.append(indent(content, CONTENT_INDENT))
    return "\n".join(lines)


def single_line(text):
    """argparse type: a description is one line of text."""
    if "\n" in text or "\r" in text:
        raise argparse.ArgumentTypeError("must be a single line")
    return text


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument("fitness_dir", help="the crew's fitness/ directory")
    ap.add_argument("--namespace", required=True, help="the crew's namespace (metadata.namespace)")
    ap.add_argument("--crew-ref", required=True, help="the Crew resource name (spec.crewRef)")
    ap.add_argument("--name", required=True, help="CrewFitnessSuite metadata.name")
    ap.add_argument("--iterations", type=int, required=True, help="iterations per scenario")
    ap.add_argument("--description", default="", type=single_line, help="suite purpose/scope (spec.description)")
    ap.add_argument("--per-iteration-timeout", default="10m")
    ap.add_argument("--artifact-retention", default="720h")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if not os.path.isdir(args.fitness_dir):
        print(f"error: fitness directory not found: {args.fitness_dir}", file=sys.stderr)
        return 2
    scn = scenarios(args.fitness_dir)
    if not scn:
        print(f"error: no .adl or .md scenarios in {args.fitness_dir}", file=sys.stderr)
        return 1
    print(f"assembling {len(scn)} scenarios x {args.iterations} = "
          f"{len(scn) * args.iterations} runs", file=sys.stderr)
    print(render(scn, args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
