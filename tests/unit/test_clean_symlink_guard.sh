#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/project/tools" "$tmp/external/build/dev" "$tmp/external/upstream/openwrt"
cp "$repo/tools/clean-dev.sh" "$tmp/project/tools/clean-dev.sh"
printf 'preserve me\n' >"$tmp/external/build/dev/cache-sentinel"
ln -s "$tmp/external/build" "$tmp/project/build"
ln -s "$tmp/external/upstream" "$tmp/project/upstream"

if printf 'DELETE\n' | bash "$tmp/project/tools/clean-dev.sh" --all >"$tmp/output" 2>&1; then
	echo "FAIL cleanup accepted external symlink targets" >&2
	exit 1
fi

if ! grep -q 'refusing target outside this project' "$tmp/output"; then
	echo "FAIL cleanup did not explain the refused target" >&2
	cat "$tmp/output" >&2
	exit 1
fi

if [ "$(cat "$tmp/external/build/dev/cache-sentinel")" != 'preserve me' ]; then
	echo "FAIL external cache sentinel changed" >&2
	exit 1
fi

echo "PASS cleanup refuses symlinked caches outside the project"