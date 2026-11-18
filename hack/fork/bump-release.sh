#!/usr/bin/env bash
# Bump every "-jwk.N" fork version to the next release number.
#
#   hack/fork/bump-release.sh          # N = current + 1 (from TAG)
#   hack/fork/bump-release.sh 7        # explicit N
#
# Prints the new release version (e.g. v1.15.1-jwk.7) on the last line.

set -o errexit
set -o nounset
set -o pipefail

cd "$(dirname "$0")/../.."

cur="$(sed -nE 's/.*-jwk\.([0-9]+)$/\1/p' TAG)"
[ -n "$cur" ] || { echo "TAG does not end in -jwk.N: $(cat TAG)" >&2; exit 1; }
next="${1:-$((cur + 1))}"
[ "$next" -gt "$cur" ] || { echo "new number $next must be > $cur" >&2; exit 1; }

# Files that carry fork versions (images, charts, docs).
FILES=(
  TAG
  NGINX_BASE
  images/nginx/TAG
  images/kube-webhook-certgen/TAG
  charts/ingress-nginx/Chart.yaml
  charts/ingress-nginx/values.yaml
  charts/bitnami-nginx-ingress-controller/Chart.yaml
  charts/bitnami-nginx-ingress-controller/values.yaml
  README.md
)

for f in "${FILES[@]}"; do
  # only touch versions of our own artifacts: <semver>-jwk.<n>
  sed -i -E "s/(v?[0-9]+\.[0-9]+\.[0-9]+-jwk\.)[0-9]+/\1${next}/g" "$f"
done

# Sanity checks: every file still has a -jwk.<next> version, none left behind.
for f in "${FILES[@]}"; do
  grep -q -- "-jwk\.${next}\b" "$f" || { echo "no -jwk.${next} in $f" >&2; exit 1; }
done
if grep -nE -- "-jwk\.[0-9]+" "${FILES[@]}" | grep -vE -- "-jwk\.${next}\b"; then
  echo "stale -jwk versions left (above)" >&2; exit 1
fi

echo "$(cat TAG)"
