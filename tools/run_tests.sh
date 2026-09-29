#!/bin/sh
# All tests that run without a watch: the portable C (host build, sanitizers) and the phone JS.
set -eu
cd "$(dirname "$0")/.."
tools/host/build.sh
build/host/test
node tools/test/phone.test.js
