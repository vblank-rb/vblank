# frozen_string_literal: true

# A made-up packed format of VBLANK's own, unpacked twice over as an original's map might be: brought
# in by `VBlank.require_game_file` for test/copy_reader_tests.rb. It keeps as many counters as a real
# one does, changed in loops inside loops and on both sides of tests the routine makes, so it shows
# a format's routine written in normal Ruby keeps them all.
#
# The block starts with two bytes, low first: how many bytes the first pass makes. Then tokens, each
# a byte whose top two bits are its kind and whose low six are a count:
#
#   LITERAL  the next +count+ bytes, made as they are
#   NEAR     the +count+ bytes from the next byte's worth back in what is made, made again
#   FAR      the +count+ bytes from the place the next two bytes give, low first, made again
#
# What the first pass makes starts with two bytes, low first, of how many the block unpacks to,
# then runs: a byte equal to the `tag:` setting, then a count and a byte, is that byte that many
# times; any other byte is itself.
module BackCopies
  LITERAL = 0
  NEAR = 1
  FAR = 2
  COUNT_BITS = 0x3F

  # The most bytes the first pass may make.
  MOST_MADE = 1024

  # The answer key, in Ruby: what a block of +packed+ bytes unpacks to with the tag +tag+.
  def self.unpacked(packed, tag)
    made = first_pass(packed)
    out = []
    cell = 2
    while cell < made.length
      if made[cell] == tag
        made[cell + 1].times { out << made[cell + 2] }
        cell += 3
      else
        out << made[cell]
        cell += 1
      end
    end
    out
  end

  def self.first_pass(packed)
    total = packed[0] | (packed[1] << 8)
    at = 2
    made = []
    while made.length < total
      token = packed[at]
      at += 1
      count = token & COUNT_BITS
      case token >> 6
      when LITERAL
        made.concat(packed[at, count])
        at += count
      else
        back = token >> 6 == NEAR ? made.length - packed[at] : packed[at] | (packed[at + 1] << 8)
        at += token >> 6 == NEAR ? 1 : 2
        count.times do
          made << made[back]
          back += 1
        end
      end
    end
    made
  end

  # A block using every token and a run at each end, the tag 0xEE: eight bytes as they are, five
  # copied from three back (so the copy reads bytes it makes), four copied from the third byte made,
  # and one more as it is. It unpacks to 18 bytes.
  TAG = 0xEE
  PACKED = [18, 0,
            (LITERAL << 6) | 8, 18, 0, TAG, 4, 7, 1, 2, 3,
            (NEAR << 6) | 5, 3,
            (FAR << 6) | 4, 2, 0,
            (LITERAL << 6) | 1, 9].freeze
end

# The format, in normal Ruby: each counter is a local, set with `=` and moved on with `+=`.
module BackCopiesFormat
  extend VBlank::Original::Packing::Format
  unpacks :back_copies, tag: 0xFF

  def self.routine(block)
    made_bytes = block.list(:back_copies_made, capacity: BackCopies::MOST_MADE, width: :half)
    at = block.from
    total = block.byte(at) | (block.byte(at + 1) << 8)
    at += 2
    made = 0
    block.emit_wrong_format_fault if total > BackCopies::MOST_MADE

    block.repeat(BackCopies::MOST_MADE, stop_when: (made >= total) | block.finished) do
      token = block.byte(at)
      at += 1
      count = token & BackCopies::COUNT_BITS
      if (token >> 6) == BackCopies::LITERAL
        block.repeat(count, stop_when: made >= total) do
          made_bytes[made] = block.byte(at)
          at += 1
          made += 1
        end
      else
        if (token >> 6) == BackCopies::NEAR
          back = made - block.byte(at)
          at += 1
        else
          back = block.byte(at) | (block.byte(at + 1) << 8)
          at += 2
        end
        block.repeat(count, stop_when: made >= total) do
          made_bytes[made] = made_bytes[back]
          made += 1
          back += 1
        end
      end
    end

    block.expect_size(made_bytes[0] | (made_bytes[1] << 8))
    cell = 2
    block.repeat(BackCopies::MOST_MADE, stop_when: (cell >= total) | block.finished) do
      byte = made_bytes[cell]
      if byte == block.setting(:tag)
        block.repeat(made_bytes[cell + 1], stop_when: block.finished) { block.write(made_bytes[cell + 2]) }
        cell += 3
      else
        block.write(byte)
        cell += 1
      end
    end
  end
end

# The same format with each counter a `block.variable`, set with `store!` and `increase!`: the way
# a format was written before its routine could be normal Ruby, which still builds.
module BackCopiesByVariablesFormat
  extend VBlank::Original::Packing::Format
  unpacks :back_copies_by_variables, tag: 0xFF

  def self.routine(block)
    made_bytes = block.list(:back_copies_by_variables_made, capacity: BackCopies::MOST_MADE, width: :half)
    at = block.variable(:at)
    total = block.variable(:total)
    made = block.variable(:made)
    back = block.variable(:back)
    token = block.variable(:token)
    count = block.variable(:count)
    cell = block.variable(:cell)
    at.store!(block.from)
    total.store!(block.byte(at) | (block.byte(at + 1) << 8))
    at.increase!(2)
    made.store!(0)
    block.emit_wrong_format_fault if total > BackCopies::MOST_MADE

    block.repeat(BackCopies::MOST_MADE, stop_when: (made >= total) | block.finished) do
      token.store!(block.byte(at))
      at.increase!(1)
      count.store!(token & BackCopies::COUNT_BITS)
      if (token >> 6) == BackCopies::LITERAL
        block.repeat(count, stop_when: made >= total) do
          made_bytes[made] = block.byte(at)
          at.increase!(1)
          made.increase!(1)
        end
      else
        if (token >> 6) == BackCopies::NEAR
          back.store!(made - block.byte(at))
          at.increase!(1)
        else
          back.store!(block.byte(at) | (block.byte(at + 1) << 8))
          at.increase!(2)
        end
        block.repeat(count, stop_when: made >= total) do
          made_bytes[made] = made_bytes[back]
          made.increase!(1)
          back.increase!(1)
        end
      end
    end

    block.expect_size(made_bytes[0] | (made_bytes[1] << 8))
    cell.store!(2)
    block.repeat(BackCopies::MOST_MADE, stop_when: (cell >= total) | block.finished) do
      if made_bytes[cell] == block.setting(:tag)
        block.repeat(made_bytes[cell + 1], stop_when: block.finished) { block.write(made_bytes[cell + 2]) }
        cell.increase!(3)
      else
        block.write(made_bytes[cell])
        cell.increase!(1)
      end
    end
  end
end
