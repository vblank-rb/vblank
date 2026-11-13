# frozen_string_literal: true

# BYTES UNPACKED BY FLAGS, written in normal Ruby in a file of a game's own, as a port writes the
# original's unpacking: brought in by `VBlank.require_game_file` for
# test/all/vblank/dsl/test_plain_ruby_parts.rb, test/copy_reader_tests.rb and test/pack_games.rb.
#
# The packed bytes are groups of a byte of flags and the BYTES_PER_FLAGS bytes it rules, until an
# END_BYTE. Each bit of the flags, lowest first, says whether its byte is written or a
# 0 in its place. Each local is set from a byte read at `at`, and `at` moves on before it is used,
# so a local that read the byte again where it is used would read the next one.
module FlaggedBytes
  BYTES_PER_FLAGS = 4
  END_BYTE = 0xFF
  # Flags 0b0101 then 0b1110: read one byte on, they are 10 and 50, and pick other bytes.
  PACKED = [0b0101, 10, 20, 30, 40, 0b1110, 50, 60, 70, 80, END_BYTE].freeze
  UNPACKED_COUNT = 8

  # The answer key, in Ruby: what the unpacking writes from +packed+.
  def self.unpacked(packed)
    packed.take_while { |byte| byte != END_BYTE }.each_slice(BYTES_PER_FLAGS + 1).flat_map do |flags, *bytes|
      bytes.each_with_index.map { |byte, bit| flags[bit] == 1 ? byte : 0 }
    end
  end
end

# The unpacking as a method a routine calls: +packed+ is read a byte at a time and +out+ written,
# a table and a list of a game, or two slots of a data pack.
def unpack_flagged_bytes(packed, out)
  at = 0
  put = 0
  while packed[at] != FlaggedBytes::END_BYTE
    flags = packed[at]
    at += 1
    FlaggedBytes::BYTES_PER_FLAGS.times do |bit|
      byte = packed[at]
      at += 1
      out[put] = byte if flags & (1 << bit) != 0
      put += 1
    end
  end
end

# The same lines written in the routine's own block: a game whose loop unpacks the table into the
# list `unpacked` once, then waits.
def flagged_bytes_game(build)
  packed = build.table :packed, FlaggedBytes::PACKED, width: :byte
  out = build.list :unpacked, capacity: FlaggedBytes::UNPACKED_COUNT, full_of: 0
  build.game_loop do
    at = 0
    put = 0
    while packed[at] != FlaggedBytes::END_BYTE
      flags = packed[at]
      at += 1
      FlaggedBytes::BYTES_PER_FLAGS.times do |bit|
        byte = packed[at]
        at += 1
        out[put] = byte if flags & (1 << bit) != 0
        put += 1
      end
    end
    build.halt
  end
end

# The same game, its loop calling #unpack_flagged_bytes.
def flagged_bytes_game_by_method(build)
  packed = build.table :packed, FlaggedBytes::PACKED, width: :byte
  out = build.list :unpacked, capacity: FlaggedBytes::UNPACKED_COUNT, full_of: 0
  build.game_loop do
    unpack_flagged_bytes(packed, out)
    build.halt
  end
end

# A data pack whose unpacking routine is written in this file: the packed bytes copied as they are
# into the slot :packed, and unpacked into :unpacked by the routine's own lines, or by
# #unpack_flagged_bytes when +by_method+.
def flagged_bytes_pack(build, from, by_method:)
  build.data_pack(from: from, version: "1") do |slots|
    slots.numbers :packed, at: 0, count: FlaggedBytes::PACKED.length, width: :byte, signed: false
    slots.numbers :unpacked, count: FlaggedBytes::UNPACKED_COUNT, width: :byte, signed: false
    slots.fill_from_copy do |_copy, pack|
      next unpack_flagged_bytes(pack[:packed], pack[:unpacked]) if by_method

      packed = pack[:packed]
      out = pack[:unpacked]
      at = 0
      put = 0
      while packed[at] != FlaggedBytes::END_BYTE
        flags = packed[at]
        at += 1
        FlaggedBytes::BYTES_PER_FLAGS.times do |bit|
          byte = packed[at]
          at += 1
          out[put] = byte if flags & (1 << bit) != 0
          put += 1
        end
      end
    end
  end
end
