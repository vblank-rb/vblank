# frozen_string_literal: true

module VBlank
  module DSL
    # The random numbers, kept in a save
    #
    # `random_numbers` hands this back so a `save_data` record can keep the game's stream of
    # random numbers. Kept, a save holds where the stream had got to, and a load puts it back, so
    # a game loaded part way through a level rolls exactly what it would have rolled from there.
    #
    # ```ruby
    # progress = save_data :progress do
    #   keep hearts, random_numbers
    # end
    # ```
    #
    # It is nothing else a game can use: the stream is still read through `rand`, `roll` and
    # `chance`, and moved with `seed` and `randomize`. There is one stream in a game, so this is
    # always the same one.
    class RandomNumbers
      # The variable the stream's state is kept in.
      attr_reader :name # :nodoc:

      def initialize(name)
        @name = name
      end

      def inspect = "the random numbers" # :nodoc:
    end
  end
end
