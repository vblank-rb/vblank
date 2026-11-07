# frozen_string_literal: true

# A BOT FOR WANDERERS (examples/wanderers.rb): a player with no window and no person. It joins a match as a
# player of its own and walks its walker toward the other player's, a person at another computer, or
# another bot. With more than two players it chases the first (or the second, if it is the first).
#
# A bot plays through the same match as everybody: every computer runs the whole game, so the bot has its own
# copy to read, and the first player's place is in it as much as its own. All it does about what it reads is
# choose which buttons its player holds. It cannot write to the game, and it does not need to: the buttons
# are sent to the other computers, which play them as they play a person's.
#
# Run a match with a person as the host, and the bot joining:
#   vblank run examples/wanderers.rb --host
#   vblank bot examples/chaser_bot.rb --join 127.0.0.1:7777
# or the bot hosts, and a person joins:
#   vblank bot examples/chaser_bot.rb --host
#   vblank run examples/wanderers.rb --join 127.0.0.1:7777
#
# Wanderers calls each player's walker by its number (`called: :walker1`), so the bot reads a walker's
# place by that name.

require_relative "../lib/vblank"

VBlank.bot "chaser", plays: "wanderers.rb" do |game|
  here = game.sprite(:"walker#{game.player}")
  there = game.sprite(game.player == 1 ? :walker2 : :walker1)

  buttons = []
  buttons << :left if here.x > there.x
  buttons << :right if here.x < there.x
  buttons << :up if here.y > there.y
  buttons << :down if here.y < there.y
  buttons
end
