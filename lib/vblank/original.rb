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
require_relative "original/releases"       # The releases a game knows, and the words for a copy that is none
require_relative "original/game"           # Where the player's copy is, and whether it is the right one
require_relative "original/facts_file"     # A facts file as text: values rewritten, comments kept
require_relative "original/facts"          # What the port measured from the original
require_relative "original/decompilation"  # The decompilation, built and proven to be the copy
require_relative "original/pack_note"      # One note of music in a data pack, a record of VBlank's own
require_relative "original/map_cell"       # One cell of a background's map in a data pack, a record of VBlank's own
require_relative "original/slot"           # One piece of the original's data: name, shape, size, place
require_relative "original/frame_layout"   # How the original keeps one frame of a sprite, piece by piece
require_relative "original/frame_reader"   # A piece read by a few lines of the game's own Ruby
require_relative "original/frame_record"   # One frame of a sprite in a data pack, a record of VBlank's own
require_relative "original/pack"          # The data pack holding every slot
require_relative "original/unpacking"      # The routine that fills the pack, as a program of its own
require_relative "original/pack_cache"     # What the routine wrote, kept between builds
# Must load before original/copy_reader, which mixes in each console's packed formats.
require_relative "original/packing"        # The packed formats an unpacking routine reads, by console
# The unpacking routine's handles do their work in game words, so they come in as a part of a game does.
VBlank.require_game_file "original/copy_reader"  # The copy and the pack as the unpacking routine sees them
VBlank.require_game_file "original/frame_rewrite"  # Each frame a game names, written again as a record of VBlank's own
require_relative "original/shell_facts"    # What every runtime is told about a shell
require_relative "original/shell"          # A port built with no data, which makes its pack on the player's machine
require_relative "original/data_guard"     # The pre-commit check keeping the original's data out of the port's history
# Its rake tasks, data_guard_tasks.rb, are a Rakefile's and are not required here.
