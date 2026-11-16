# frozen_string_literal: true

# A headless Super Nintendo for checking cartridges from Ruby: bsnes, built as a libretro core
# with a small patch that hands over the console's memories, played through a libretro frontend
# written in C (RubySNESEmulator::Frontend), so a cartridge plays in any Ractor. See
# RubySNESEmulator::Core for what it plays and reads, and RubySNESEmulator::CoreLibrary for
# where the core comes from.
require_relative "ruby_snes_emulator/version"
require_relative "ruby_snes_emulator/built_for"
require_relative "ruby_snes_emulator/built_from"
require_relative "ruby_snes_emulator/core_library"

# The compiled half. A checkout's build lands under lib/<the Ruby that built it>/, put first on
# the load path so a Ruby finds its own build or none; a gem's is the one RubyGems built per ABI.
# A checkout's build is checked against the source beside it (built_from.rb).
built = File.join(__dir__, RubySNESEmulator::BUILT_FOR)
checkout_build = File.directory?(built)
$LOAD_PATH.unshift(built) if checkout_build && !$LOAD_PATH.include?(built)

begin
  require "ruby_snes_emulator/ruby_snes_emulator_ext"
rescue LoadError => e
  raise LoadError, RubySNESEmulator::CoreLibrary.extension_missing_message(e.message)
end
RubySNESEmulator.refuse_out_of_date_build! if checkout_build

require_relative "ruby_snes_emulator/kept_copy"
require_relative "ruby_snes_emulator/core"
