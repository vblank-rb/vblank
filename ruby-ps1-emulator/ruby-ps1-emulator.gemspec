# frozen_string_literal: true

require_relative "lib/ruby_ps1_emulator/version"

Gem::Specification.new do |spec|
  spec.name        = "ruby-ps1-emulator"
  spec.version     = RubyPS1Emulator::VERSION
  spec.authors     = ["James Cook"]
  spec.summary     = "Headless Beetle PSX binding for PlayStation dev/test verification"
  spec.description = <<~DESC
    A lean, headless PlayStation: Beetle PSX, built as a libretro core with a small patch that hands
    over the console's memories, driven from Ruby through Fiddle. Play a PS-X EXE a frame at a time
    and read back main RAM, video RAM and the picture shown in it, the graphics chip's settings and
    the processor's registers. VBlank uses it to check the programs it builds; building one needs
    none of this.
  DESC
  spec.homepage    = "https://github.com/jamescook/vblank"
  spec.license     = "MIT" # our binding code; Beetle PSX is built separately, under GPL-2.0
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "core/*.patch", "core/LICENSE.md", "Rakefile", "README.md"]
  spec.require_paths = ["lib"]
  spec.add_dependency "fiddle"
  spec.metadata["rubygems_mfa_required"] = "true"
end
