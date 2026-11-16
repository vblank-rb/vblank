# frozen_string_literal: true

require_relative "lib/ruby_snes_emulator/version"

Gem::Specification.new do |spec|
  spec.name        = "ruby-snes-emulator"
  spec.version     = RubySNESEmulator::VERSION
  spec.authors     = ["James Cook"]
  spec.summary     = "Headless bsnes binding for Super Nintendo dev/test verification"
  spec.description = <<~DESC
    A lean, headless Super Nintendo: bsnes, built as a libretro core with a small patch that
    hands over the console's memories, played through a small C extension that works in any
    Ractor. Play a cartridge a frame at a time and read back its picture, work RAM, video RAM,
    colour memory, sprite table and registers. VBlank uses it to check the cartridges it
    builds; building one needs none of this.
  DESC
  spec.homepage    = "https://github.com/vblank-rb/vblank"
  spec.license     = "MIT" # our binding code; bsnes is built separately (GPLv3)
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "ext/ruby_snes_emulator_ext/*.{c,h,rb}", "core/*.patch", "Rakefile", "README.md"]
  # lib only: RubyGems puts the extension it builds on the load path itself (ruby-gba-emulator's
  # gemspec says why the source directory must not be).
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/ruby_snes_emulator_ext/extconf.rb"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
