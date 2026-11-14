# frozen_string_literal: true

module VBlank
  module IR
    # A TILE PICKED AS THE PROGRAM RUNS (Nodes::SetTile#picked_by), AS THE TESTS IT STANDS FOR.
    #
    # A backend that keeps a table of its console's cells indexes it with the number (the
    # Genesis's, the Super Nintendo's and the Color's lowerings). One that does not writes this
    # instead (the Advance's and the computer builds'): tests that halve the numbers standing for a tile, and under
    # each the same change with that tile written in, which it writes as it writes any other. A
    # number standing for no tile matches none, and the cell is left alone.
    #
    # The trees are of new nodes with copies of the step's values, so the program is untouched.
    module PickedTile
      module_function

      # The statement that does what +node+ does, or nil where no number stands for a tile.
      def tests(node)
        numbers = node.picks.each_index.select { |at| node.picks[at] }.map { |at| [node.picks_from + at, node.picks[at]] }
        numbers.empty? ? nil : tests_between(node, numbers)
      end

      # +numbers+ are pairs of a number and its tile, in order.
      def tests_between(node, numbers)
        return test_of_one(node, *numbers.first) if numbers.one?

        lower, upper = numbers.each_slice(numbers.length.ceildiv(2)).to_a
        which = Build.if_(Build.binop(:<, node.picked_by.copy, Build.int(upper.first.first)), tests_between(node, lower))
        which.else = Build.else_(tests_between(node, upper))
        which
      end

      def test_of_one(node, number, tile)
        Build.if_(Build.binop(:==, node.picked_by.copy, Build.int(number)),
                  Build.set_tile(node.name, node.col.copy, node.row.copy, tile, now: node.now, held: node.held))
      end
    end
  end
end
