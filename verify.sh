#!/usr/bin/env bash
# Runnable self-check for this component (the established idiom). Builds
# the real image and proves two things without needing a live cluster:
# (1) the binaries this component bakes in are present and runnable, (2)
# the PolicyReport -> OSCAL shim (ADR-0009, proven in issue 20) transforms
# a fixture the same way the live collector does -- strips the
# coexistence version suffix, reshapes scope into results[].resources,
# and drops skip-result items entirely (see shim.jq for why).
set -euo pipefail
command -v docker >/dev/null || { echo "SKIP: docker not on PATH"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="c2p-collector:verify-$$"
trap 'docker rmi -f "$IMG" >/dev/null 2>&1 || true' EXIT

echo "== build =="
docker build -q -t "$IMG" "$HERE" >/dev/null

echo "== binaries present and runnable =="
docker run --rm --entrypoint sh "$IMG" -c '
  set -eu
  c2pcli --help >/dev/null
  test -x /usr/local/bin/kyverno-plugin
  kubectl version --client >/dev/null
  jq --version >/dev/null
  echo OK
' | grep -qx OK || { echo "FAIL: a baked-in binary is missing or broken"; exit 1; }
echo "OK: c2pcli, kyverno-plugin, kubectl, jq all present and runnable"

echo "== PolicyReport -> OSCAL shim transform (fixture, no live cluster) =="
# wave-3 audit (2026-07-18): this used to be a hand-duplicated copy of run.sh's jq expression,
# which drifted out of sync with a real fix (the skip-filter, ticket 08 follow-up) and kept
# reporting PASS on stale behavior. Reads the same shim.jq run.sh does -- the two cannot drift
# apart again, and the fixture below specifically exercises the skip-filter so a regression here
# fails loudly instead of silently.
FIXTURE=$(mktemp)
cat > "$FIXTURE" <<'EOF'
{
  "items": [
    {
      "scope": {"apiVersion": "v1", "kind": "Pod", "namespace": "default", "name": "web-1", "uid": "abc-123"},
      "results": [
        {"policy": "require-s3-bucket-encryption-2.2.0", "result": "pass", "resources": []}
      ]
    },
    {
      "scope": {"apiVersion": "v1", "kind": "Pod", "namespace": "default", "name": "unlabelled-fixture", "uid": "def-456"},
      "results": [
        {"policy": "require-rds-multi-az-2.2.0", "result": "skip", "resources": []}
      ]
    }
  ]
}
EOF
got=$(jq -f "$HERE/shim.jq" "$FIXTURE")
item_count=$(jq '.items | length' <<<"$got")
policy=$(jq -r '.items[0].results[0].policy' <<<"$got")
resource_name=$(jq -r '.items[0].results[0].resources[0].name' <<<"$got")
rm -f "$FIXTURE"

[ "$item_count" = "1" ] || { echo "FAIL: expected the skip-result item to be dropped entirely, got $item_count items"; exit 1; }
[ "$policy" = "require-s3-bucket-encryption" ] || { echo "FAIL: version suffix not stripped, got '$policy'"; exit 1; }
[ "$resource_name" = "web-1" ] || { echo "FAIL: scope not reshaped into resources[], got '$resource_name'"; exit 1; }
echo "OK: version suffix stripped, scope reshaped into resources[], skip-result item dropped entirely"

echo "== verify.sh: PASS =="
