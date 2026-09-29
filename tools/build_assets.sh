#!/bin/sh
# Regenerates the watch art from the source photos and fonts (macOS only: Swift + CoreText).
# The canonical renderer settings are the ones in the spec's "Asset pipeline" section.
# PT2 (emery) art is written untagged; Round 2 (gabbro) art gets the SDK's ~gabbro file tag.
set -eu
cd "$(dirname "$0")/../art"
swiftc -O ../tools/face.swift -o ../tools/face
# MB and MG are retuned for the full-moon source (the spec's 0.18 and 0.8 were set on the half-moon photo)
export MB=0.35 MW=0.9 MG=1.0 MD=300 MX=60 MY=114 CUW=0.6 CUX=0.1 CUY=0.05 CUT=0.45 SUNA=160 SUNW=1800 SEAM=0.08 BLOOM=44
export MOONFILE="${MOONFILE:-src/moon_full.jpg}"
FONT="${FONT:-fonts/InterDisplay-Black.ttf}"
# SUNY: the sun's limb sits 31 px below the minutes' cap top on both screens
SUNY=152 ../tools/face export "$FONT" out/export out
PW=260 PH=260 DIGIT_H=94 SUNY=168 ../tools/face export "$FONT" out/gabbro/export out/gabbro
python3 ../tools/pack.py out ../resources
python3 ../tools/pack.py out/gabbro ../resources gabbro
