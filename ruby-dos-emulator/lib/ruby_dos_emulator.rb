# frozen_string_literal: true

# A headless DOS machine for checking programs from Ruby: DOSBox, built as a libretro core with
# a small patch that hands over the PC's memories, driven through Fiddle. See RubyDOSEmulator::Core
# for what it plays and reads, and RubyDOSEmulator::CoreLibrary for where the core comes from.
require_relative "ruby_dos_emulator/version"
require_relative "ruby_dos_emulator/core_library"
require_relative "ruby_dos_emulator/core_copy"
require_relative "ruby_dos_emulator/core"
