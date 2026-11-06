# frozen_string_literal: true

# WHAT A CHECKED PROGRAM BECOMES: the bytes on the card, and everything about the card itself —
# the header, the four characters an emulator tells one cartridge from another by, the checks a
# finished one has to pass. The machine code inside it is the lowering's business, not this
# module's (see IR::Backends::GBA).

require_relative "cartridge/header"          # Where each header field sits, and the logo
require_relative "cartridge/constants"       # The old name for the hardware table, for games that still use it
require_relative "cartridge/rom_validator"
require_relative "cartridge/build_record"    # What the build worked out, carried by the cartridge
require_relative "cartridge/game_code"       # The four characters an emulator tells one cartridge from another by
require_relative "cartridge/rom"
require_relative "cartridge/gbc_rom"         # A Game Boy Color cartridge: header and checksums
require_relative "cartridge/snes_rom"        # A Super Nintendo cartridge: header, vectors and checksum
require_relative "cartridge/genesis_rom"     # A Sega Genesis cartridge: vectors, header and checksum
require_relative "cartridge/ps1_exe"         # A PlayStation program: PS-X EXE header and code
require_relative "cartridge/players"         # How many players a game takes, by console
require_relative "cartridge/options"         # How a game is built, as one value
require_relative "cartridge/evaluated_game"  # The one place a game's block becomes a program
require_relative "cartridge/build_request"   # What a console's build is handed once the game is checked
require_relative "cartridge/advance_build"   # The Game Boy Advance's build, which lowers to ARM
require_relative "cartridge/lowered_build"   # The Game Boy Color's and Super Nintendo's builds
require_relative "cartridge/game"
require_relative "cartridge/test_patterns"
