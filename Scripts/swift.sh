#!/usr/bin/env bash
# Run `swift` against a usable Xcode SDK whatever `xcode-select` is set to.
# See Scripts/swift-env.sh for why this is needed.
#
#   Scripts/swift.sh build
#   Scripts/swift.sh test
#   Scripts/swift.sh test --filter ProjectSkillsTests
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=Scripts/swift-env.sh
source Scripts/swift-env.sh
exec xcrun swift "$@"
