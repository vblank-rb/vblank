#!/bin/sh
# Run inside a machine that has the gem and its emulators (see the Dockerfile).
set -eu

vblank build walk.rb
vblank build drift.rb

for lowering in gba gbc snes; do
  echo "== $lowering, from the installed gem"
  VBLANK_LOWERING=$lowering ruby test_walk.rb
done

echo "== dos, from the installed gem"
VBLANK_LOWERING=dos ruby test_drift.rb

echo "== snes, in a game's bundle"
bundle install --local --quiet
VBLANK_LOWERING=snes bundle exec ruby test_walk.rb
