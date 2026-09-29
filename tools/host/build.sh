#!/bin/sh
# Builds the host previews and tests from the watch sources (src/c) with -DHOST.
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build/host
SRC="src/c/engine.c src/c/sky.c src/c/moon.c src/c/face.c"
FLAGS="-DHOST -std=c11 -O2 -Wall -Wextra -Werror -Isrc/c"
cc $FLAGS $SRC tools/host/preview.c -lz -lm -o build/host/preview
if [ -f tools/host/test.c ]; then cc $FLAGS -fsanitize=address,undefined $SRC tools/host/test.c -lm -o build/host/test; fi
