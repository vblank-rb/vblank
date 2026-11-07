# frozen_string_literal: true

# THE PACKED FORMATS AN UNPACKING ROUTINE CAN READ, a module for each console whose games keep their
# data in them, each mixed into Original::CopyReader. They are game code, so each comes in the way a
# part of a game does.

VBlank.require_game_file "packing/gba"  # The Game Boy Advance BIOS's LZ77 and RLE
