# frozen_string_literal: true

# A PLAYER WITH NO WINDOW AND NO PERSON: a Ruby script that joins a match like any machine, reads its own copy
# of the game, and chooses its buttons each pass. Every machine of a match runs the whole game, so a bot has
# the whole game to look at (the positions of every player, the score, whatever the game keeps), and the only
# thing it can do about it is press buttons.
#
#   VBlank.bot "chaser", plays: "wanderers.rb" do |game|
#     [:left] if game.var(:__obj2_x) > game.var(:__obj1_x)
#   end
#
# It is run by `vblank bot chaser.rb --join ADDRESS`, and plays in tests through the same device
# (Live::BotDevice) the command uses.
require_relative "bots/bot"        # A script that chooses buttons, and how a file names which one it is
require_relative "bots/tape_bot"   # A bot that plays the presses of a tape
require_relative "bots/game_view"  # A read-only view of a bot's own copy of the game
