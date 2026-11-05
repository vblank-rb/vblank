# frozen_string_literal: true

# THE ORIGINAL A GAME IS MADE FROM. A port of a retail game reads the player's own copy of it, which
# no game may ship, and is checked against it:
#
#   ORIGINAL = VBlank::Original::Game.new(title: "Space Pinball", setting: "SPACE_PINBALL_ROM",
#                                         settings_file: "games/space_pinball/space_pinball.yml",
#                                         releases: JSON.parse(File.read("data/versions.json"))["releases"])
#   ORIGINAL.copy.path   # the copy, found and accepted, or one friendly error saying what to set
#
# A game's tests ask for it with Testing#original_copy, which stops a test on a machine that has
# none, saying what to set. What the port measured from it is kept in commented YAML files (Facts).
require_relative "original/game" # where the player's copy is, and whether it is the right one
require_relative "original/facts_file" # a facts file as text: its values rewritten, its comments kept
require_relative "original/facts" # ...and what the port measured from the original, read from those files
