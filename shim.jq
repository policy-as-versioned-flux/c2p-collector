# The single source of truth for the PolicyReport -> C2P shim (ADR-0009, issue 20; skip-filter,
# ticket 08 follow-up real-estate epic). run.sh and verify.sh both read this file instead of each
# carrying their own copy of the expression -- a wave-3 audit found verify.sh's own hand-duplicated
# copy had silently drifted out of sync with a real fix to this logic (the skip-filter), and kept
# reporting PASS on stale behavior because nothing forced the two copies to match.
#
# Two normalizations:
#  1. Drop `skip` results before they reach result2oscal: a skip means the policy declined to
#     evaluate the resource at all (e.g. missing labels a version-scoped rule expects) -- never a
#     compliance signal, and result2oscal only publishes one finding per rule, so a skipped
#     resource can silently win the slot over a real pass/fail claim.
#  2. scope -> results[].resources (Kyverno >=1.18 per-resource reports), and strip the coexistence
#     nameSuffix (results[].policy comes back as e.g. require-s3-bucket-encryption-2.2.0; the
#     component-definition's Check_Id is the unsuffixed base name) so one component-definition
#     matches every coexisting version.
.items |= (map(.scope as $s | .results |= (
        map(select(.result != "skip")) | map(
          .policy    = (.policy | sub("-[0-9]+\\.[0-9]+\\.[0-9]+$"; "")) |
          .resources = [{apiVersion:$s.apiVersion, kind:$s.kind, namespace:$s.namespace, name:$s.name, uid:$s.uid}])
        )) | map(select(.results | length > 0)))
