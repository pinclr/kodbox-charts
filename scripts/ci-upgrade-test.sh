#!/usr/bin/env bash
# Upgrade test across minor versions.
#
# chart-testing's `ct install --upgrade` only tests upgrades within a minor
# version (it treats any minor bump of a 0.x chart as breaking and skips it).
# This installs the newest *published* release older than the working copy,
# with each CI values file from that release's git tag, upgrades it in place to
# the working copy with the current values file (as `helm upgrade -f` / GitOps
# would), and runs `helm test`.
#
# Usage: scripts/ci-upgrade-test.sh <chart dir> <namespace> <helm repo URL>
#   e.g. scripts/ci-upgrade-test.sh charts/kodbox kodbox-ci https://pinclr.github.io/kodbox-charts
set -euo pipefail

chart_dir=${1:?chart dir}
namespace=${2:?namespace}
repo_url=${3:?helm repo url}

name=$(sed -n 's/^name: //p' "$chart_dir/Chart.yaml")
new=$(sed -n 's/^version: //p' "$chart_dir/Chart.yaml")

helm repo add upgrade-test "$repo_url" --force-update >/dev/null
helm repo update upgrade-test >/dev/null

# Newest published version strictly lower than the working copy.
prev=$(helm search repo "upgrade-test/$name" --versions -o json \
  | python3 -c '
import json, sys
new = tuple(int(x) for x in sys.argv[1].split("-")[0].split("."))
versions = []
for e in json.load(sys.stdin):
    v = e["version"]
    if "-" in v:
        continue  # skip pre-releases
    t = tuple(int(x) for x in v.split("."))
    if t < new:
        versions.append((t, v))
print(max(versions)[1] if versions else "")
' "$new")

if [[ -z "$prev" ]]; then
  echo "No published $name release older than $new; nothing to upgrade from."
  exit 0
fi

IFS=. read -r new_major new_minor _ <<<"$new"
IFS=. read -r prev_major prev_minor _ <<<"$prev"
if [[ "$new_major" != "$prev_major" ]]; then
  echo "::notice::$name $prev -> $new is a major upgrade; skipped (major versions may need manual steps)."
  exit 0
fi
if [[ "$new_minor" == "$prev_minor" ]]; then
  echo "$name $prev -> $new is a patch upgrade; covered by ct install --upgrade."
  exit 0
fi

echo "Testing upgrade of $name from published $prev to working copy $new"
tested=0
for values in "$chart_dir"/ci/*-values.yaml; do
  file=$(basename "$values")
  old_values=$(mktemp)
  if ! git show "$name-$prev:$chart_dir/ci/$file" >"$old_values" 2>/dev/null; then
    echo "::group::skip $file (not in $prev)"; echo "::endgroup::"
    continue
  fi
  release="up-${file%-values.yaml}"
  release=${release:0:20}

  echo "::group::$file: install $prev"
  helm install "$release" "upgrade-test/$name" --version "$prev" \
    -n "$namespace" -f "$old_values" --wait --timeout 15m
  echo "::endgroup::"

  echo "::group::$file: upgrade to $new and helm test"
  helm upgrade "$release" "$chart_dir" -n "$namespace" -f "$values" --wait --timeout 15m
  helm test "$release" -n "$namespace" --logs
  echo "::endgroup::"

  helm uninstall "$release" -n "$namespace" --wait --timeout 5m
  kubectl -n "$namespace" delete pvc -l "app.kubernetes.io/instance=$release" --wait=false
  tested=$((tested + 1))
done

echo "Upgraded $tested release(s) of $name from $prev to $new."
