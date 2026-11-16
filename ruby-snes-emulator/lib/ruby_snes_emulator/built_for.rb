# frozen_string_literal: true

require "rbconfig"

module RubySNESEmulator
  # WHICH RUBY A CHECKOUT'S BUILT EXTENSION BELONGS TO, as the name of the directory under lib/ it is
  # built into. An extension is tied to the Ruby that built it, so a Ruby with no directory of its own
  # finds nothing and builds one, rather than a binary it cannot load (ruby-gba-emulator's
  # built_for.rb tells the whole of it). A gem install never sees this: RubyGems builds the
  # extension per ABI itself. Frozen so a Ractor worker may read it.
  BUILT_FOR = "#{RUBY_VERSION}-#{RbConfig::CONFIG['arch']}".freeze
end
