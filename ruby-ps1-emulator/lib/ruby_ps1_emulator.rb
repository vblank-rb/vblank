# frozen_string_literal: true

# A headless PlayStation for checking programs from Ruby: Beetle PSX (Mednafen's PlayStation), built
# as a libretro core with a small patch that hands over the console's memories, driven through
# Fiddle. See RubyPS1Emulator::Core for what it plays and reads, and RubyPS1Emulator::CoreLibrary for
# where the core comes from.
require_relative "ruby_ps1_emulator/version"
require_relative "ruby_ps1_emulator/core_library"
require_relative "ruby_ps1_emulator/kept_copy"
require_relative "ruby_ps1_emulator/core"
