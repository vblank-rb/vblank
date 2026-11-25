# frozen_string_literal: true

# A part of a game that steps the tile of a map cell in place, read from the cell's own bytes, and
# copies it to another slot each round.
class SteppedCellPart
  def initialize(cells, seen)
    @cells = cells
    @seen = seen
  end

  def count_up(rounds)
    @cells.write_cell(0, tile: 0)
    n = 0
    while n < rounds
      @seen[n] = @cells[0] | (@cells[1] << 8)
      @cells.write_cell(0, tile: (@cells[0] | (@cells[1] << 8)) + 1)
      n += 1
    end
  end
end
