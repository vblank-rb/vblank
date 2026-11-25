# frozen_string_literal: true

module VBlank
  module DSL
    # Words with a game number in them
    #
    # `"HP #{hp}"` or `hp.to_s` in game code, where hp is a number the game keeps, makes one of
    # these: the words, and each number where it was put. Its number has no digits until the game
    # plays, so it is not a String. `draw_text` draws it: the words as written, and each number as
    # `draw_number` draws it, where the words before it end.
    #
    # ```ruby
    # draw_text "HP #{hp}", 8, 8, :white
    # ```
    #
    # Anything else a String does (`upcase`, `+`, `length`) is refused, since the letters are not
    # known while the game is built.
    class TextWithNumbers
      # The words and the numbers, in order: Strings and Values.
      attr_reader :parts # :nodoc:

      def initialize(parts)
        @parts = parts.each_with_object([]) do |part, kept|
          if part.is_a?(String) && kept.last.is_a?(String)
            kept[-1] = kept.last + part
          elsif !(part.is_a?(String) && part.empty?)
            kept << part
          end
        end.freeze
      end

      # More words or numbers after these, as `+` on a String gives.
      def +(other)
        more = case other
               when TextWithNumbers then other.parts
               when Value then [other]
               else [other.to_str]
               end
        TextWithNumbers.new(parts + more)
      end

      # The words with each number left out, for a message.
      def inspect = parts.map { |part| part.is_a?(String) ? part : "\#{...}" }.join.inspect # :nodoc:

      def to_s = self # :nodoc:

      # Ruby asks this where it needs a real String: refused, since the number has no letters yet.
      def to_str = refuse_as_string!(:to_str) # :nodoc:

      def method_missing(name, *, &) # :nodoc:
        return super unless "".respond_to?(name)

        refuse_as_string!(name)
      end

      def respond_to_missing?(name, include_private = false) = !"".respond_to?(name) && super

      private

      def refuse_as_string!(name)
        PlainRuby::Steps.refuse_game_code!("This text holds a number the game works out as it plays, so its letters " \
                                           "are not known while the game is built, and it does not answer " \
                                           "`#{name}`. A game can only draw it: `draw_text #{inspect}, 8, 8, :white`.")
      end
    end
  end
end
