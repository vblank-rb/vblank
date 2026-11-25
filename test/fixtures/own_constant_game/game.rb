# frozen_string_literal: true

# A game whose block gives a constant of Ruby's to a constant of its own, then reads it: still
# outside the game. Run as a program of its own by test/all/vblank/dsl/test_plain_ruby_refusals.rb,
# since a test's game block is not checked, and Ruby refuses a constant given a value in a method.

require_relative "../../../lib/vblank"

GAME = VBlank.game("OWN DIR", consoles: %i[gba]) do
  Dir = Dir
  here = Dir.pwd.size
  game_loop { here += 1 }
end

GAME.program
