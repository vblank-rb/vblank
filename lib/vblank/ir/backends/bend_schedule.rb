# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # The order a game's row-by-row bends are worked out in at each frame boundary, written once for
      # every lowering that works them out ahead of the picture.
      #
      # Every console that bends a background row by row asks the game's block for each row of the
      # screen in the gap between frames, into a table, and then feeds that table to its display a
      # row at a time: the Advance by a copying engine or the line interrupt, the Color from a byte
      # table in its line interrupt, the Super Nintendo by HDMA, the Genesis from its scroll table,
      # the computer builds as they draw each line. The feed is the console's. The order the rows are
      # asked in is the program's, because a block can change the game (count, roll a random number,
      # read another bend's row), and asked in another order it plays another game. Written out in
      # each lowering, the copies drifted: two of them left a bend's row variable at 1 after its top
      # row, where the interpreter leaves it at nought.
      #
      # The order is Reference#work_out_bends: row 0 of every bend, then the rest of each bend in turn,
      # then that bend's row variable at the screen's height. Row 0 goes first because it is the row
      # a display reads before the picture starts, so it must not wait behind every other row.
      #
      # A lowering may take a bend's bands (RowBends#bands) and work it whole, band by band, when
      # every bend has them: such a block reads no other bend's row and writes nothing another block
      # reads, so no block can tell what order the rows went in.
      #
      # What the lowering supplies. This module is mixed into the part of a lowering that works the
      # bends out and calls these of it:
      #
      #   bends                                  the game's bends (RowBends#bends), in the order worked out
      #   bend_screen_height                     how many rows the console's screen has
      #   emit_bend_rows(bend, first, past)      rows first to past - 1 of the bend, each row's number in its
      #                                          row variable as its block runs; a single row leaves the
      #                                          variable at that row, as Reference#run_bend_for_row does
      #   emit_bend_bands(bend, bands)           (a lowering taking bands) every row of the bend, a band at a time
      #                                          from each first row in +bands+, leaving its row variable at the height
      #   emit_row_variable_set(bend, height)    the row variable at the height, after the bend's last row;
      #                                          a lowering whose loop counts in the row variable and stops
      #                                          at the height has nothing to write
      #
      # Each returns what it lowered to, for a lowering that builds statements rather than writing
      # instructions as it goes (Computer::Lowering), and #emit_bends_worked_out hands them back in order.
      module BendSchedule
        # Every method of this module a lowering writes its own way, by the method and then the
        # lowering, with why its way is cheaper there. A lowering takes the schedule as it is unless it
        # is named here (.claude/rules/adding-a-backend.md); test_bend_schedule.rb holds the lowerings
        # to this list, both ways.
        OWN_WAYS = Ractor.make_shareable(
          {
            bend_bands_taken: {
              "SNES" => "The 65816 multiplies and divides a little at a time, so a block with a table read in it " \
                        "asked for all 224 rows is about a frame on its own. SNES::Lowering#bend_bands_taken takes " \
                        "each bend's bands when every bend has them and asks its block once a band; the Advance, " \
                        "the Color and the computer builds ask every row, which their frames hold."
            }
          }
        )

        # Reference#work_out_bends: row 0 of every bend, then +after_first_rows+ (what a lowering feeds
        # with the first rows, before the picture starts), then the rest of each bend in turn, each
        # ending with its row variable at the screen's height. Where every bend's bands are taken
        # (#bend_bands_taken), each bend is worked whole instead, and the block comes after them all.
        # A game with no bend still has the block, which may feed rows of something else. What each
        # hook gave back, in order.
        def emit_bends_worked_out(&after_first_rows)
          all = bends
          return after_first_rows ? [yield] : [] if all.empty?

          height = bend_screen_height
          banded = all.map { |bend| bend_bands_taken(bend) }
          return emit_banded_bends(all.zip(banded), height, &after_first_rows) if banded.all?

          first = all.map { |bend| emit_bend_rows(bend, 0, 1) }
          between = after_first_rows ? [yield] : []
          rest = all.flat_map { |bend| [emit_bend_rows(bend, 1, height), emit_row_variable_set(bend, height)] }
          first + between + rest
        end

        # The first row of each band of +bend+ the lowering works it out by, or nil to ask every row.
        # A lowering whose processor asks a block cheaply enough asks every row, and is not named in
        # OWN_WAYS.
        def bend_bands_taken(_bend) = nil

        private

        def emit_banded_bends(banded, height)
          worked = banded.flat_map { |bend, bands| [emit_bend_bands(bend, bands), emit_row_variable_set(bend, height)] }
          block_given? ? worked + [yield] : worked
        end
      end
    end
  end
end
