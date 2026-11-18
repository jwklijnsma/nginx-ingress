#!/usr/bin/env bash
# Fix vulnerable Go dependencies of the controller.
#
# 1. Raise modules to known-fixed minimum versions (advisories published after
#    ingress-nginx was retired at v1.15.1; see SECURITY-FORK.md).
# 2. Run govulncheck in *module* mode (what container scanners flag, not only
#    reachable code) and raise every module that has a fixed release.
#    Repeated until stable, because one bump can pull in another module.
# 3. go mod tidy, build, and exit non-zero if any fixable vulnerability remains.
#    Standard-library findings mean GOLANG_VERSION must be raised; the script
#    writes the needed version into GOLANG_VERSION and fails so CI reruns on it.
#
# Usage: hack/fork/fix-go-vulns.sh [--check] [MODULE_DIR]
#   --check     report only, change nothing
#   MODULE_DIR  Go module to fix (default: repo root; also used for
#               images/kube-webhook-certgen/rootfs)

set -o errexit
set -o nounset
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

CHECK_ONLY=false
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=true; shift; fi
cd "$ROOT/${1:-.}"
echo "==> Module: $(go list -m) in $(pwd)"

GOVULNCHECK="${GOVULNCHECK:-govulncheck}"
command -v "$GOVULNCHECK" >/dev/null || go install golang.org/x/vuln/cmd/govulncheck@latest
command -v "$GOVULNCHECK" >/dev/null || GOVULNCHECK="$(go env GOPATH)/bin/govulncheck"

# Minimum fixed versions. Raised, never lowered.
FLOORS=(
  "golang.org/x/net v0.62.0"                # CVE-2026-78661, -97045, -78659, -78660, -78663, -78669, -97032, -46600
  "golang.org/x/crypto v0.56.0"             # CVE-2026-56854, -56855, -78662 and the v0.52.0 batch
  "golang.org/x/text v0.39.0"               # CVE-2026-56852
  "golang.org/x/sys v0.45.0"                # CVE-2026-39824
  "google.golang.org/grpc v1.83.2"          # CVE-2026-84304, -84445, GHSA-hrxh-6v49-42gf
  "go.opentelemetry.io/otel v1.47.0"        # CVE-2026-41178, -128085
  "go.opentelemetry.io/otel/trace v1.47.0"  # CVE-2026-128085
  "helm.sh/helm/v4 v4.1.4"                  # CVE-2026-35204, -35205
)
# github.com/gomarkdown/markdown (CVE-2026-40890, CVE-2024-44337) has no tags;
# govulncheck reports its fixed pseudo-version and step 2 handles it.

current() { go list -m -f '{{.Version}}' "$1" 2>/dev/null || true; }

# true if $1 < $2 (Go semver, pseudo-versions included)
older() {
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

raise() {
  local mod="$1" want="$2" have
  have="$(current "$mod")"
  [ -z "$have" ] && return 0                   # not in the build list
  if older "$have" "$want"; then
    echo "  $mod $have -> $want"
    $CHECK_ONLY || go get "$mod@$want"
  fi
}

# Prints "module fixed_version" for every fixable non-stdlib finding and
# "stdlib fixed_version" lines; reads govulncheck JSON on stdin.
parse_findings() {
  python3 -c '
import json, sys
dec = json.JSONDecoder(); buf = sys.stdin.read(); i = 0; out = set()
while i < len(buf):
    while i < len(buf) and buf[i].isspace(): i += 1
    if i >= len(buf): break
    obj, i = dec.raw_decode(buf, i)
    f = obj.get("finding")
    if not f or not f.get("fixed_version"): continue
    mod = f["trace"][0]["module"]
    out.add((mod, f["fixed_version"], f["osv"]))
for mod, fixed, osv in sorted(out):
    print(mod, fixed, osv)
'
}

echo "==> Go: $(go version)"
echo "==> Raising known-vulnerable modules to fixed minimums"
for entry in "${FLOORS[@]}"; do raise $entry; done

stdlib_fix=""
for round in 1 2 3 4; do
  $CHECK_ONLY || go mod tidy
  echo "==> govulncheck (module scan), round $round"
  findings="$("$GOVULNCHECK" -scan module -format json | parse_findings)"
  [ -z "$findings" ] && { echo "  no fixable vulnerabilities"; break; }
  echo "$findings" | sed 's/^/  /'
  changed=false
  while read -r mod fixed _osv; do
    if [ "$mod" = "stdlib" ]; then
      stdlib_fix="$(printf '%s\n%s\n' "${stdlib_fix:-v0}" "$fixed" | sort -V | tail -n1)"
      continue
    fi
    have="$(current "$mod")"
    if [ -n "$have" ] && older "$have" "$fixed"; then
      echo "  raise $mod $have -> $fixed"
      $CHECK_ONLY || { go get "$mod@$fixed"; changed=true; }
    fi
  done <<< "$findings"
  $changed || break
done

$CHECK_ONLY || go mod tidy

status=0
if [ -n "$stdlib_fix" ]; then
  need="${stdlib_fix#v}"; need="${need#go}"
  echo "==> Go standard library needs >= $need (GOLANG_VERSION is $(cat "$ROOT/GOLANG_VERSION"))"
  $CHECK_ONLY || echo "$need" > "$ROOT/GOLANG_VERSION"
  status=3
fi

echo "==> Final check"
remaining="$("$GOVULNCHECK" -scan module -format json | parse_findings | grep -v '^stdlib ' || true)"
if [ -n "$remaining" ]; then
  echo "Fixable vulnerabilities remain:"; echo "$remaining" | sed 's/^/  /'
  status=2
fi

if ! $CHECK_ONLY; then
  echo "==> go build ./..."
  go build ./...
fi

# Informational: what is actually reachable from controller code
"$GOVULNCHECK" ./... || true

exit $status
