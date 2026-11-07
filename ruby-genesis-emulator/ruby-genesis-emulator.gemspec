# frozen_string_literal: true

require_relative "lib/ruby_genesis_emulator/version"

Gem::Specification.new do |spec|
  spec.name        = "ruby-genesis-emulator"
  spec.version     = RubyGenesisEmulator::VERSION
  spec.authors     = ["James Cook"]
  spec.summary     = "Headless Genesis Plus GX binding for Sega Genesis dev/test verification"
  spec.description = <<~DESC
    A lean, headless Sega Genesis: Genesis Plus GX, built as a libretro core with a small patch that
    hands over the console's memories, driven from Ruby through Fiddle. Play a cartridge a frame at
    a time and read back its picture, work RAM, video RAM, colour memory, scroll memory and
    registers. VBlank uses it to check the cartridges it builds; building one needs none of this.
  DESC
  spec.homepage    = "https://github.com/vblank-rb/vblank"
  spec.license     = "MIT" # our binding code; Genesis Plus GX is built separately, and bars commercial use
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "core/*.patch", "Rakefile", "README.md"]
  spec.require_paths = ["lib"]
  spec.add_dependency "fiddle"
  spec.metadata["rubygems_mfa_required"] = "true"
end
