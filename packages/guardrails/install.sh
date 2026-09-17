#!/usr/bin/env bash
# Install harvested hooks into a coding-agent harness.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$here/adapters/hookjson/install.sh" "$@"
