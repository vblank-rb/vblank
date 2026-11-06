# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # What a person calls each of the console's video memories.
      VIDEO_MEMORY_WORDS = { colors: "the colours", sprite_table: "the sprite table", scroll: "the scroll",
                             registers: "the video registers" }.freeze

      # ONE OF THE CONSOLE'S VIDEO MEMORIES THAT DIFFERED where two cartridges parted, and its
      # first difference: +memory+ is which (`:colors`, `:sprite_table`, `:scroll`, `:registers`;
      # see Diagnostics::Verifier#video_memories), +at+ where in it, and +first+ and +second+
      # what each cartridge held there.
      #
      # WHY IT IS SAID. Two pictures that differ show where on the screen and nothing about why.
      # The console builds its picture out of a few memories — the colours it draws from, the
      # table of where each sprite stands, how far each background is scrolled, the registers
      # that switch each part on — and which of those differ is most of the answer: a colour
      # table that differs is a palette fault, a sprite table that differs a sprite in the wrong
      # place, and none of them differing a difference in the pictures the tiles are made of.
      VideoDifference = Data.define(:memory, :at, :first, :second) do
        # The video memories that differ between two running cartridges, each with its first
        # difference, in the order the console's reader lists them; empty when none do, or
        # when the two do not hold the same memories at the same places (two consoles' cartridges).
        def self.between(first, second)
          return [] unless first.respond_to?(:video_memories) && second.respond_to?(:video_memories)

          our_memories = first.video_memories
          theirs = second.video_memories
          return [] unless our_memories.keys == theirs.keys && our_memories.all? { |memory, ours| ours.keys == theirs[memory].keys }

          our_memories.filter_map do |memory, ours|
            other = theirs[memory]
            at = ours.keys.find { |key| ours[key] != other[key] } or next
            new(memory: memory, at: at, first: ours[at], second: other[at])
          end
        end

        # As a person reads it: `the colours, first at 3: 0x7C00 on the first cartridge and
        # 0x03E0 on the second`.
        def in_words
          "#{VIDEO_MEMORY_WORDS.fetch(memory, memory.to_s)}, first at #{at}: #{number(first)} on the first cartridge and " \
            "#{number(second)} on the second"
        end

        private

        def number(value) = value.is_a?(Integer) ? format("0x%04X", value) : value.inspect
      end
    end
  end
end
