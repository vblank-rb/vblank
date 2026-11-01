require_relative "lib/vblank/version"

Gem::Specification.new do |spec|
  spec.name          = "vblank"
  spec.version       = VBlank::VERSION
  spec.authors       = ["James Cook"]
  spec.email         = ["jcook.rubyist@gmail.com"]

  spec.summary       = "Ruby DSL for building GBA ROMs"
  spec.description   = "A Ruby DSL that generates valid Game Boy Advance ROM files"
  spec.homepage      = "https://github.com/jamescook/vblank"
  # MIT, but for ruby-snes-emulator/core/bsnes-vblank-probe.patch, a change to bsnes and so under
  # bsnes's licence (ruby-snes-emulator/core/LICENSE.md says more).
  spec.licenses      = ["MIT", "GPL-3.0-or-later"]

  # compile_flags.txt is written for an editor on the machine it names folders on (see
  # Native::Zig), so it is no part of the gem.
  #
  # The two emulators are folders of this gem, not gems of their own: their source goes in, and
  # ext/vblank/Rakefile builds them when the gem is installed.
  spec.files         = Dir.glob("{lib,test,bin}/**/*").select { |f| File.file?(f) && !File.basename(f).start_with?("compile_flags.txt") } +
                       Dir.glob("ext/vblank/*") +
                       Dir.glob("ruby-gba-emulator/lib/**/*.rb") +
                       Dir.glob("ruby-gba-emulator/ext/ruby_gba_emulator_ext/*.{c,h,rb}") +
                       Dir.glob("ruby-snes-emulator/lib/**/*.rb") +
                       Dir.glob("ruby-snes-emulator/core/*.{patch,md}") +
                       %w[vblank.gemspec Rakefile LICENSE.md]
  spec.bindir        = "bin"
  spec.executables   = ["vblank"]
  spec.require_paths = ["lib"]
  spec.extensions    = ["ext/vblank/Rakefile"]
  spec.required_ruby_version = ">= 4.0"

  # The Super Nintendo's emulator and `vblank run` reach their libraries through Fiddle. It comes
  # with Ruby, but a game's bundle can load only what a gem names.
  spec.add_dependency "fiddle"
  spec.add_dependency "prism"
  # Runs ext/vblank/Rakefile when the gem is installed.
  spec.add_dependency "rake", "~> 13.0"
  spec.add_dependency "thor", "~> 1.3"

  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "rubocop", "~> 1.81"
  spec.add_development_dependency "rubocop-performance", "~> 1.26"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
