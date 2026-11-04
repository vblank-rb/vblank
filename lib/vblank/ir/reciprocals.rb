# frozen_string_literal: true

module VBlank
  module IR
    # HOW FAR AWAY A POINT ON A FACE IS, from one over its distance: the sum perspective needs at
    # every few pixels, written once so every target works it out to the same bits.
    #
    # WHY PERSPECTIVE NEEDS IT. Across a face that leans away, equal steps on the screen are not
    # equal steps on the picture: the far half of a wall squeezes more of the picture into each
    # pixel than the near half. What does step evenly across the screen is the place on the
    # picture divided by the distance, and one over the distance. So the fill steps those two, and
    # wherever it wants the place on the picture it divides them back, which is a multiply by the
    # distance: one over one over the distance. That reciprocal is what this works out.
    #
    # WHY A TABLE, NOT A DIVIDE. A divide is the dearest sum the consoles do, and the fill wants one
    # every eight pixels. One over a number is its leading bits looked up in a table of 1024 and
    # moved back into place, which costs a load and two shifts. It is a little off, by up to a part
    # in a thousand; and since every target uses this table and these shifts, every target is a
    # little off the same way, so all of them draw the same pixels.
    #
    # THE NUMBERS. One over the distance, +w+, has 26 bits of fraction (a distance of one is
    # 2**26), and the answer is the distance with 16 (a distance of one is 2**16), so the answer is
    # 2**42 / w. A distance past 16384 is taken as 16384.
    module Reciprocals
      # The leading bits looked up: eleven, the top one always set.
      LEADING = 1024

      # The least one over the distance taken: a distance of 16384.
      LEAST = 4096

      # 2**40 over each number with eleven bits, the top one set: from 1024 to 2047.
      TABLE = Ractor.make_shareable((LEADING...(2 * LEADING)).map { |leading| (1 << 40) / leading })

      module_function

      # The distance, with 16 bits of fraction, for one over it, +w+, with 26: the table's entry for
      # w's leading eleven bits, moved down by as many places as w was, less the two the table is
      # short of 2**42 by.
      def distance(w)
        w = LEAST if w < LEAST
        moved = w.bit_length - 11
        TABLE[(w >> moved) - LEADING] >> (moved - 2)
      end
    end
  end
end
