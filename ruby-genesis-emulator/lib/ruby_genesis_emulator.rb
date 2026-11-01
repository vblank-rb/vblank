# frozen_string_literal: true

# A headless Sega Genesis (Mega Drive) for checking cartridges from Ruby: Genesis Plus GX, built as
# a libretro core with a small patch that hands over the console's memories, driven through Fiddle.
# See RubyGenesisEmulator::Core for what it plays and reads, and RubyGenesisEmulator::CoreLibrary
# for where the core comes from.
require_relative "ruby_genesis_emulator/version"
require_relative "ruby_genesis_emulator/core_library"
require_relative "ruby_genesis_emulator/kept_copy"
require_relative "ruby_genesis_emulator/core"
