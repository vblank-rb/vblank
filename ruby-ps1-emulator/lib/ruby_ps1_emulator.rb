# frozen_string_literal: true

# A headless PlayStation for checking programs from Ruby: Beetle PSX (Mednafen's PlayStation), built
# as a libretro core with a small patch that hands over the console's memories, played through a
# libretro frontend written in C (RubyPS1Emulator::Frontend), so a program plays in any Ractor. See
# RubyPS1Emulator::Core for what it plays and reads, and RubyPS1Emulator::CoreLibrary for where the
# core comes from.
require_relative "ruby_ps1_emulator/version"
require_relative "ruby_ps1_emulator/built_for"
require_relative "ruby_ps1_emulator/built_from"
require_relative "ruby_ps1_emulator/core_library"

# The compiled half. A checkout's build lands under lib/<the Ruby that built it>/, put first on
# the load path so a Ruby finds its own build or none; a gem's is the one RubyGems built per ABI.
# A checkout's build is checked against the source beside it (built_from.rb).
built = File.join(__dir__, RubyPS1Emulator::BUILT_FOR)
checkout_build = File.directory?(built)
$LOAD_PATH.unshift(built) if checkout_build && !$LOAD_PATH.include?(built)

begin
  require "ruby_ps1_emulator/ruby_ps1_emulator_ext"
rescue LoadError => e
  raise LoadError, RubyPS1Emulator::CoreLibrary.extension_missing_message(e.message)
end
RubyPS1Emulator.refuse_out_of_date_build! if checkout_build

require_relative "ruby_ps1_emulator/kept_copy"
require_relative "ruby_ps1_emulator/core"
