#!/bin/sh
# Run inside a machine that has the gem and both emulators (see the Dockerfile).
set -eu

vblank build walk.rb

for lowering in gba gbc snes; do
  echo "== $lowering, from the installed gem"
  VBLANK_LOWERING=$lowering ruby test_walk.rb
done

echo "== snes, in a game's bundle"
bundle install --local --quiet
VBLANK_LOWERING=snes bundle exec ruby test_walk.rb
