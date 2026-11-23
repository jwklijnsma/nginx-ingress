#!/usr/bin/env bash
# Print the manifest digest (sha256:...) of an image reference.
#
# Right after a push, GHCR can briefly answer "not found" for the new tag, so
# retry with backoff instead of handing an empty digest to cosign.
#
#   hack/fork/image-digest.sh ghcr.io/owner/repo/image:tag

set -o errexit
set -o nounset
set -o pipefail

ref="${1:?image reference}"
for attempt in 1 2 3 4 5 6 7 8; do
  if d="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"')" \
     && [[ "$d" == sha256:* ]]; then
    echo "$d"
    exit 0
  fi
  echo "digest of $ref not available yet (attempt $attempt), retrying..." >&2
  sleep $((attempt * 3))
done
echo "ERROR: could not resolve digest of $ref" >&2
exit 1
