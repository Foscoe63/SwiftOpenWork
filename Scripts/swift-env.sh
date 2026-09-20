#!/usr/bin/env bash
# Resolve a DEVELOPER_DIR that can actually build this package.
#
# SwiftPM needs a full Xcode SDK here. When `xcode-select -p` points at
# /Library/Developer/CommandLineTools, swift-frontend rejects `-target-arch-variant` and then
# crashes compiling a dependency's `Package.swift` — a stack dump whose message says nothing
# about the SDK, and which reads as a bug in this repository rather than a local setup problem.
#
# Fixing it globally is `sudo xcode-select -s`, which needs a password and changes every project
# on the machine. Sourcing this file pins the right toolchain for one invocation instead.
#
# Usage:
#   source Scripts/swift-env.sh && swift build
#   Scripts/swift.sh test

swiftopenwork_resolve_developer_dir() {
    # An explicit DEVELOPER_DIR wins, as long as it is a real Xcode and not the CLT stub.
    if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR/Platforms" ]]; then
        printf '%s' "$DEVELOPER_DIR"
        return 0
    fi

    # A correctly configured xcode-select already works; do not second-guess it.
    local selected
    selected="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "$selected" && -d "$selected/Platforms" ]]; then
        printf '%s' "$selected"
        return 0
    fi

    local candidate
    for candidate in \
        /Applications/Xcode.app/Contents/Developer \
        /Applications/Xcode-beta.app/Contents/Developer; do
        if [[ -d "$candidate/Platforms" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

if swiftopenwork_resolved="$(swiftopenwork_resolve_developer_dir)"; then
    export DEVELOPER_DIR="$swiftopenwork_resolved"

    # A pinned TOOLCHAINS pairs a newer swift-frontend with this SDK, which is the same mismatch
    # by another route.
    unset TOOLCHAINS

    # DEVELOPER_DIR alone is not enough. A swiftly- or Toolchains-managed `swift` earlier on PATH
    # still wins for a bare `swift`, so anything not going through `xcrun` gets the wrong
    # compiler and the same crash. Put the selected toolchain's own bin directory first.
    swiftopenwork_toolchain_bin=""
    for candidate in \
        "$swiftopenwork_resolved/Toolchains/XcodeDefault.xctoolchain/usr/bin" \
        "$swiftopenwork_resolved/usr/bin"; do
        if [[ -x "$candidate/swift" ]]; then
            swiftopenwork_toolchain_bin="$candidate"
            break
        fi
    done
    if [[ -n "$swiftopenwork_toolchain_bin" ]]; then
        export PATH="$swiftopenwork_toolchain_bin:$PATH"
    fi
    unset swiftopenwork_toolchain_bin swiftopenwork_resolved
else
    echo "error: no full Xcode SDK found — only the Command Line Tools." >&2
    echo "Install Xcode, then either:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "  # or, without sudo, for this shell only:" >&2
    echo "  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >&2
    unset swiftopenwork_resolved
    return 1 2>/dev/null || exit 1
fi
