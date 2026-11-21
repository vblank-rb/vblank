# frozen_string_literal: true

module VBlank
  module DSL
    # Lists of songs and sound effects
    #
    # What a list of songs (from `songs`) and a list of sound effects (from `sound_effects`) both
    # answer: how many there are, and the number each name has in the list. A name or a number
    # the list does not have is a friendly error when the game is built. A number the game works
    # out as it runs is checked as it plays.
    #--
    # The class including it sets what one entry is called (#entry_noun), for the errors.
    #++
    module ScoreList
      def initialize(builder, name, keys)
        @builder = builder
        @name = name
        @keys = keys
      end

      # The list's name, as given to `songs` or `sound_effects`.
      attr_reader :name

      # How many songs or sound effects the list holds.
      #
      # ```ruby
      # music = songs :music, [title_theme, forest]
      # music.count   # 2
      # ```
      def count = @keys.length

      # The number of the entry the list was given under a name, counting from 0.
      #
      # ```ruby
      # sfx = sound_effects :sfx, { hit: hit, spark: spark }
      # sfx.number_of(:spark)   # 1
      # ```
      def number_of(key)
        at = @keys.index(key)
        return at if at

        raise ArgumentError, "The #{entry_noun} list :#{@name} has no #{entry_noun} #{key.inspect}. " \
                             "It has #{@keys.map(&:inspect).join(', ')}."
      end

      private

      def entry_number(which)
        case which
        when Symbol then number_of(which)
        when Integer
          return which if which.between?(0, count - 1)

          raise ArgumentError, "The #{entry_noun} list :#{@name} has #{count} #{count == 1 ? entry_noun : "#{entry_noun}s"}, " \
                               "so it has no #{entry_noun} #{which}. The #{entry_noun}s are numbered from 0 to #{count - 1}."
        else which
        end
      end
    end
  end
end
