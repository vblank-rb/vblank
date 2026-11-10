# frozen_string_literal: true

require_relative "lib/ruby_dos_emulator/version"

Gem::Specification.new do |spec|
  spec.name        = "ruby-dos-emulator"
  spec.version     = RubyDOSEmulator::VERSION
  spec.authors     = ["James Cook"]
  spec.summary     = "Headless DOSBox Pure binding for DOS dev/test verification"
  spec.description = <<~DESC
    A lean, headless DOS machine: DOSBox Pure, built as a libretro core with a small patch that hands
    over the PC's memory, driven from Ruby through Fiddle. Run a DOS program a frame at a time, press
    keys, and read back the picture shown, the first megabyte of memory, the video card's memory,
    palette and mode, and the sound made. VBlank uses it to check the programs it builds; building
    one needs none of this.
  DESC
  spec.homepage    = "https://github.com/vblank-rb/vblank"
  spec.license     = "MIT" # our binding code; DOSBox Pure is built separately, under GPL-2.0
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "core/*.patch", "core/LICENSE.md", "Rakefile", "README.md"]
  spec.require_paths = ["lib"]
  spec.add_dependency "fiddle"
  spec.metadata["rubygems_mfa_required"] = "true"
end
