#!/usr/bin/env bash
set -euo pipefail

ZIG_VERSION="${1:?usage: install-zig.sh <version>}"
ARCH="$(uname -m)"

case "${ARCH}" in
  x86_64) ZIG_ARCH="x86_64" ;;
  aarch64|arm64) ZIG_ARCH="aarch64" ;;
  *)
    echo "unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

TARGET_KEY="${ZIG_ARCH}-linux"
ARCHIVE="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}"
TARBALL="${ARCHIVE}.tar.xz"
export ZIG_VERSION TARGET_KEY

if [ ! -x "zig-${ZIG_VERSION}/zig" ]; then
  curl -fsSL https://ziglang.org/download/index.json -o /tmp/zig-index.json
  mapfile -t VALUES < <(python3 - <<'PY'
import json, os
version = os.environ["ZIG_VERSION"]
target = os.environ["TARGET_KEY"]
idx = json.load(open("/tmp/zig-index.json"))
pkg = idx[version][target]
print(pkg["tarball"])
print(pkg["shasum"])
PY
  )

  curl -fsSL "${VALUES[0]}" -o "/tmp/${TARBALL}"
  echo "${VALUES[1]}  /tmp/${TARBALL}" | sha256sum --check --strict
  tar -xJf "/tmp/${TARBALL}"
  mv "${ARCHIVE}" "zig-${ZIG_VERSION}"
fi
