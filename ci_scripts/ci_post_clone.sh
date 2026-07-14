#!/bin/sh
# Xcode Cloud runs this after cloning the repo and resolving SPM packages,
# before build. CI_BUILD_NUMBER is an Xcode Cloud-provided counter that's
# unique and monotonically increasing across builds for this app -- using
# it as CURRENT_PROJECT_VERSION means every Cloud-built archive gets a
# fresh build number automatically, with no manual bump in project.yml
# (which stays the source of truth for local/manual builds).
set -e

if [ -n "$CI_BUILD_NUMBER" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"
    xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
fi
