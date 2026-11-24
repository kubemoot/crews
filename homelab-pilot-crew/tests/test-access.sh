#!/usr/bin/env bash
# Render tests for who may ask the crew: crew.discussion.access becomes the Crew's
# spec.discussion.access as given, and an empty value renders no access block (anonymous
# callers accepted, as before). Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-access.sh
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"

crew_access() { render "$@" | yq -N -o=json -I=0 'select(.kind == "Crew") | .spec.discussion.access'; }

check "no access block by default" "null" "$(crew_access)"
check "access renders as given" '{"allowAnonymous":false,"tokenReview":true}' \
  "$(crew_access --set crew.discussion.access.tokenReview=true --set crew.discussion.access.allowAnonymous=false)"
check "discussion stays enabled with access set" "true" \
  "$(render --set crew.discussion.access.tokenReview=true | yq -N 'select(.kind == "Crew") | .spec.discussion.enabled')"

[ "$failures" = 0 ] || exit 1
echo "all passed"
