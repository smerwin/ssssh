#!/bin/sh
# Xcode Cloud runs this after ci_post_clone.sh, right before invoking
# xcodebuild. Writes a freshly generated haiku to the repo-root
# TestFlight/WhatToTest.<locale>.txt file, which Xcode Cloud picks up
# automatically as the build's TestFlight release notes -- no App Store
# Connect API call (and no credentials to manage) needed. Gated on
# CI_BUILD_NUMBER like ci_post_clone.sh, so this is a no-op unless
# Xcode Cloud itself is running the build.
set -e

if [ -n "$CI_BUILD_NUMBER" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"
    mkdir -p TestFlight
    python3 ci_scripts/generate_whattotest.py > TestFlight/WhatToTest.en-US.txt
fi
