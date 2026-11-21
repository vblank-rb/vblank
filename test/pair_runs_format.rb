# frozen_string_literal: true

# A made-up packed format, written as a port writes one of its own (Original::Packing::Format), in
# normal Ruby: brought in by `VBlank.require_game_file` for test/copy_reader_tests.rb. Pairs of a
# count and a byte, the byte written that many times, each count multiplied by the `times:`
# setting, until a count of 0.
module PairRuns
  extend VBlank::Original::Packing::Format
  unpacks :pair_runs, times: 1

  # The most pairs a block can hold, a bound on the loop that reads them.
  MOST_PAIRS = 4096

  def self.routine(block)
    at = block.from
    many = block.byte(at)
    block.repeat(MOST_PAIRS, stop_when: (many == 0) | block.finished) do
      block.repeat(many * block.setting(:times), stop_when: block.finished) { block.write(block.byte(at + 1)) }
      at += 2
      many = block.byte(at)
    end
  end
end
