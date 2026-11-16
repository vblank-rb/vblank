# frozen_string_literal: true

# A headless Sega Genesis (Mega Drive) for checking cartridges from Ruby: Genesis Plus GX, built as
# a libretro core with a small patch that hands over the console's memories, played through a
# libretro frontend written in C (RubyGenesisEmulator::Frontend), so a cartridge plays in any
# Ractor. See RubyGenesisEmulator::Core for what it plays and reads, and
# RubyGenesisEmulator::CoreLibrary for where the core comes from.
require_relative "ruby_genesis_emulator/version"
require_relative "ruby_genesis_emulator/built_for"
require_relative "ruby_genesis_emulator/built_from"
require_relative "ruby_genesis_emulator/core_library"

# The compiled half. A checkout's build lands under lib/<the Ruby that built it>/, put first on
# the load path so a Ruby finds its own build or none; a gem's is the one RubyGems built per ABI.
# A checkout's build is checked against the source beside it (built_from.rb).
built = File.join(__dir__, RubyGenesisEmulator::BUILT_FOR)
checkout_build = File.directory?(built)
$LOAD_PATH.unshift(built) if checkout_build && !$LOAD_PATH.include?(built)

begin
  require "ruby_genesis_emulator/ruby_genesis_emulator_ext"
rescue LoadError => e
  raise LoadError, RubyGenesisEmulator::CoreLibrary.extension_missing_message(e.message)
end
RubyGenesisEmulator.refuse_out_of_date_build! if checkout_build

require_relative "ruby_genesis_emulator/kept_copy"
require_relative "ruby_genesis_emulator/core"
