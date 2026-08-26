#!/usr/bin/env bash
set -euo pipefail
OUT=${1:-weatherwrite-generator.zip}
echo "Packaging lambda into $OUT"
cwd=$(pwd)
cd "$(dirname "$0")"
zip -r "$cwd/$OUT" lambda || true
echo "Created $OUT"
