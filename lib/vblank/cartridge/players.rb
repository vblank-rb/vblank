# frozen_string_literal: true

module VBlank
  module Cartridge
    # HOW MANY PLAYERS A GAME TAKES, as it is set where the game is named:
    #
    #   VBlank.game "PARTY", consoles: %i[gba snes], players: 4               # 1 to 4, on every build
    #   VBlank.game "PARTY", consoles: %i[gba snes], players: 2..4            # at least 2, at most 4
    #   VBlank.game "PARTY", consoles: %i[gba snes], players: { gba: 1, snes: 1..2, computer: 1..8 }
    #
    # By console, because each seats a different number: a key is a console's name, `computer:` (a
    # build that plays on a computer, whichever console it is made as) or `else:` (every build the
    # others do not name). A computer build reads `computer:`, then its console's, then `else:`; a
    # cartridge its console's, then `else:`.
    #
    # Setting none is fine: the game reads whichever players its lines name, and each console
    # refuses what it cannot seat. Setting it lets the build check every line against it, and refuse
    # a console that cannot seat that many even where no line names the last player yet (a game
    # that reads `player: :any` would otherwise lose players quietly). The fewest is kept for a
    # game's joining screen to wait for; nothing else reads it yet.
    module Players
      KEYS = %i[computer else].freeze

      module_function

      # +said+ as { key => Range }, or an empty Hash for nothing given; a friendly error for anything
      # that is not a number of players.
      def refuse_unusable!(said)
        return {} if said.nil?
        return { else: range_of!(said, said) } unless said.is_a?(Hash)

        said.to_h { |key, count| [key_of!(key, said), range_of!(count, said)] }
      end

      # The players the game takes on a build for +console+ (nil for a test's program, which names
      # none), as [fewest, most], or nil where it gave nothing for that build.
      def fewest_and_most_on_build(players, console:, for_computer:)
        keys = [(:computer if for_computer), console, :else].compact
        range = players.values_at(*keys).compact.first or return nil
        [range.first, range.last]
      end

      def key_of!(key, said)
        return key if KEYS.include?(key)

        Console.named(key)
      rescue ArgumentError, NoMethodError
        raise ArgumentError, "`players: #{said.inspect}` names #{key.inspect}, which is not a console. A key must be " \
                             "a console name, `computer:` or `else:`. To fix this, change #{key.inspect} to one of them."
      end

      def range_of!(count, said)
        range = count.is_a?(Integer) ? (1..count) : count
        if range.is_a?(Range) && range.first.is_a?(Integer) && range.last.is_a?(Integer) && !range.exclude_end? &&
           range.first >= 1 && range.first <= range.last && range.last <= IR::Buttons::MOST_PLAYERS
          return range
        end

        raise ArgumentError, "`players: #{said.inspect}` is not a number of players. Give a number from 1 to " \
                             "#{IR::Buttons::MOST_PLAYERS}, like `players: 4`, or the fewest and the most, like " \
                             "`players: 2..4`."
      end
    end
  end
end
