#!/usr/bin/env bash
# Resolve a product PR HEAD and check its patch against the actual source.
# Pure source verification: no proprietary ELF inspection or device access.
set -euo pipefail
if (( $# != 4 )); then
  echo "Usage: $0 repo-url branch-ref hwc-source-directory evidence-directory" >&2
  exit 2
fi
repo="$1"
branch="$2"
hwc="$3"
evidence="$4"
mkdir -p "$evidence"
head_sha="$(git ls-remote --exit-code "$repo" "$branch" | awk '{print $1}')"
if [[ ! "$head_sha" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "UNVERIFIED: product branch HEAD could not be resolved" >&2
  exit 3
fi
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
git -C "$temp" init -q
git -C "$temp" fetch -q --depth 1 "$repo" "$head_sha"
# A malicious/outdated manual SHA in another script is not accepted:
# source file must come from the fetched commit, not an assumed HEAD.
actual="$(git -C "$temp" rev-parse FETCH_HEAD)"
if [[ "$actual" != "$head_sha" ]]; then
  echo "UNVERIFIED: fetched product revision differs from branch HEAD" >&2
  exit 3
fi
patch_path="patches/lineage-22.1/drm_hwcomposer_i915_hdcp_desired.patch"
if ! git -C "$temp" show "FETCH_HEAD:$patch_path" > "$evidence/product-i915-hdcp.patch"; then
  echo "UNVERIFIED: current product patch missing" >&2
  exit 3
fi
sha256sum "$evidence/product-i915-hdcp.patch" > "$evidence/product-patch.sha256"
if ! git -C "$hwc" apply --reverse --check "$evidence/product-i915-hdcp.patch"; then
  echo "UNVERIFIED: HWC source does not match current product patch HEAD" >&2
  exit 3
fi
echo "$head_sha" > "$evidence/product-pr15-verified-head.txt"
printf '%s\n' "$head_sha"
