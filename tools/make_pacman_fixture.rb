#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds examples/pacman.rb as a cartridge and writes it, with the facts of where its data is, to
# test/fixtures/pacman_port/. Run on purpose, when the example or the Advance lowering changes what
# the port should read: the fixture is a stand-in for a retail cartridge and is not rebuilt by a test.
#
#   ruby tools/make_pacman_fixture.rb

require_relative "../test/fixtures/pacman_port/pacman_fixture"

built = PacmanFixture.build
PacmanFixture.write(built)
puts "Wrote #{PacmanFixture::ROM_PATH} (#{built.bytes.bytesize} bytes, SHA-1 #{Digest::SHA1.hexdigest(built.bytes)})"
puts "Wrote #{PacmanFixture::FACTS_PATH} (#{built.assets.size} assets)"
