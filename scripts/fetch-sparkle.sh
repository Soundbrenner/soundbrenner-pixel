#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
version=2.10.1
destination="$root/.build/distribution/Sparkle-$version"
if [[ ! -x "$destination/bin/generate_appcast" ]]; then
    mkdir -p "$(dirname "$destination")"
    staging="$(mktemp -d "$root/.build/distribution/sparkle.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    curl -fsSL --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$staging/Sparkle.tar.xz"
    expected=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
    (cd "$staging" && printf '%s  Sparkle.tar.xz\n' "$expected" | shasum -a 256 -c - >&2)
    mkdir "$staging/Sparkle"
    tar -xJf "$staging/Sparkle.tar.xz" -C "$staging/Sparkle"
    mv "$staging/Sparkle" "$destination"
fi
printf '%s\n' "$destination"
