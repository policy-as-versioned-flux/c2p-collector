#!/bin/sh
# Ticket 04 (real-estate): the collection logic, trimmed of the
# build-from-source step ticket 21's original CronJob paid every run --
# c2pcli/kyverno-plugin/kubectl are baked into this image (see Dockerfile).
# Behaviour (PolicyReports in, shimmed, result2oscal, ConfigMap out) is
# unchanged from the original infrastructure/c2p/run.sh.
set -eu
WORK=${WORK:-/work}
mkdir -p "$WORK"
cd "$WORK"

echo "== assemble C2P inputs =="
mkdir -p plugins policy-resources tmp tmp-out reports
cp /usr/local/bin/kyverno-plugin plugins/kyverno-plugin
sum=$(sha256sum plugins/kyverno-plugin | cut -d' ' -f1)
cat > plugins/c2p-kyverno-manifest.json <<EOF
{ "metadata": { "id": "kyverno", "description": "Kyverno PVP Plugin", "version": "0.0.1", "types": ["pvp"] },
  "executablePath": "kyverno-plugin", "sha256": "$sum",
  "configuration": [
    { "name": "policy-dir", "required": true },
    { "name": "policy-results-dir", "required": true },
    { "name": "temp-dir", "required": true },
    { "name": "output-dir", "required": false, "default": "." } ] }
EOF
cat > c2p-config.yaml <<EOF
component-definition: ${COMPONENT_DEFINITION:-/config/component-definition.json}
plugins:
  kyverno:
    policy-dir: $WORK/policy-resources
    policy-results-dir: $WORK/reports
    temp-dir: $WORK/tmp
    output-dir: $WORK/tmp-out
EOF
empty(){ printf 'apiVersion: v1\nkind: List\nitems: []\n' > "$1"; }
empty reports/policies.kyverno.io.yaml
empty reports/clusterpolicies.kyverno.io.yaml
empty reports/clusterpolicyreports.wgpolicyk8s.io.yaml

echo "== collect PolicyReports from the live cluster, shim, run result2oscal =="
# The shim (ADR-0009, proven in issue 20): scope -> results[].resources
# (Kyverno >=1.18 per-resource reports), and strip the coexistence
# nameSuffix (results[].policy comes back as e.g.
# require-s3-bucket-encryption-2.2.0; the component-definition's Check_Id
# is the unsuffixed base name) so one component-definition matches every
# coexisting version.
kubectl get policyreports.wgpolicyk8s.io -A -o json \
  | jq '.items |= map(.scope as $s | .results |= map(
          .policy    = (.policy | sub("-[0-9]+\\.[0-9]+\\.[0-9]+$"; "")) |
          .resources = [{apiVersion:$s.apiVersion, kind:$s.kind, namespace:$s.namespace, name:$s.name, uid:$s.uid}]))' \
  > reports/policyreports.wgpolicyk8s.io.yaml

c2pcli result2oscal -c c2p-config.yaml -n nist_800_53 -o assessment-results.json -p plugins

echo "== publish as a ConfigMap for Grafana's infinity datasource to read =="
kubectl create configmap oscal-assessment-results -n "${NAMESPACE:-monitoring}" \
  --from-file=assessment-results.json=assessment-results.json \
  --dry-run=client -o yaml | kubectl apply -f -

echo "== done: $(jq '[.["assessment-results"].results[0].findings[]?]|length' assessment-results.json) finding(s) =="
