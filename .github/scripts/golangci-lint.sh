#!/usr/bin/env bash
# Runs golangci-lint on the Go module in the current directory with the shared .golangci.yml at
# the repository root (the same linters and limits as kubemoot/kubemoot: cyclomatic complexity
# at most 10). The linter version is the one pin below, so every module and CI agree.
# Env: GOLANGCI_LINT_VERSION overrides the pin (a local run with a newer binary).
set -euo pipefail

version="${GOLANGCI_LINT_VERSION:-v2.14.0}"

bin="$(go env GOPATH)/bin/golangci-lint"
# Reuse an installed binary of the pinned version (a warm self-hosted runner).
if ! "${bin}" version 2>/dev/null | grep -q "version ${version#v} "; then
  go install "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${version}"
fi
"${bin}" run ./...
