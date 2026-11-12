# frozen_string_literal: true

module VBlank
  module Live
    # Which player each gamepad and key is, in the window a person plays in (SDL). The desktop
    # window keeps the same rule in C (rg_seats.h) and the web page in JavaScript (rg_page.js).
    #
    # Only a game whose `players:` seats two or more (#several_players?) is played this way; any
    # other plays as it always did, every gamepad and key player 1's.
    #
    # Each gamepad is a player. One plugged in takes the lowest player no gamepad has, from player
    # 1 up, and keeps it while it stays plugged in. So the first gamepad is player 1, beside the
    # keyboard, and the second player 2. A gamepad pulled out leaves its player free for the next
    # one plugged in, and nobody else's player changes.
    #
    # The keyboard is player 1, and its right hand player 2 (IR::ComputerControls::SECOND_PLAYER_KEYS:
    # I J K L, O, U, 7 to 0), where nobody else has the key: a key player 1 or a hotkey has, by
    # VBlank's layout, the game's or the player's settings, stays theirs. Players 3 and 4 are
    # gamepads only.
    class Seats
      SECOND_PLAYER_CODES = Ractor.make_shareable(IR::ComputerControls::SECOND_PLAYER_KEYS.to_h do |name, button|
        [IR::ComputerControls::KEYS.fetch(name), button]
      end)

      # Whether a game whose build seats +most_players+ (0 or nil for none named) gives each
      # gamepad a player of its own and player 2 keys.
      def self.several_players?(most_players) = most_players.to_i > 1

      def initialize = @players = {} # Each gamepad's player, by the window's number for the gamepad

      # Gamepad +id+ plugged in: its player, the lowest free one, or the one it has already.
      def join(id)
        @players[id] ||= (1..).find { |player| !@players.value?(player) }
      end

      # Gamepad +id+ pulled out: its player is free.
      def leave(id) = @players.delete(id)

      # The player gamepad +id+ is, or nil.
      def player_of(id) = @players[id]

      # Player 2's buttons held on the keyboard, by the names a run reads them by (:p2_left): each
      # whose key is down and +free+ (nobody else's). +down+ and +free+ are each given a scancode.
      def self.second_player_buttons(down:, free:)
        SECOND_PLAYER_CODES.filter_map do |code, button|
          IR::Buttons.name_for(button, 2) if free.call(code) && down.call(code)
        end
      end

      # +buttons+, plain names, as +player+'s (:left as player 3's is :p3_left).
      def self.buttons_as_player(buttons, player) = buttons.map { |button| IR::Buttons.name_for(button, player) }
    end
  end
end
