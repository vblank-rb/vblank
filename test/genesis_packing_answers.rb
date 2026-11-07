# frozen_string_literal: true

# THE PACKED FORMATS OF SEGA GENESIS GAMES, in plain Ruby, for the tests of `copy.unpack_nemesis`
# and `copy.unpack_enigma` (Original::Packing::Genesis). Each decoder here is the answer key,
# written from the 68000 routine retail games run (`NemDec` and `EniDec`, as Dr. Robotnik's Mean
# Bean Machine has them), never from another program's reading of the format. Each writer makes a
# made-up block for a test, so no game's data is ever in the suite.
module GenesisPackingAnswers
  module_function

  # The bits of a byte string from +at+, the top bit of each byte first. A byte is read only when
  # one of its bits is needed.
  class BitReader
    def initialize(bytes, at)
      @bytes = bytes
      @at = at * 8
    end

    def peek(count) = (0...count).reduce(0) { |value, i| (value << 1) | bit(@at + i) }

    def skip(count) = @at += count

    def take(count) = peek(count).tap { skip(count) }

    private

    # A bit past the end reads 0, as the routines read on into whatever follows a block.
    def bit(place) = ((@bytes.getbyte(place >> 3) || 0) >> (7 - (place & 7))) & 1
  end

  # Bits written top bit first, the last byte filled with zeros.
  class BitWriter
    def initialize = @bits = []

    def put(value, count)
      (count - 1).downto(0) { |at| @bits << ((value >> at) & 1) }
      self
    end

    def bytes = @bits.each_slice(8).map { |eight| eight.fill(0, eight.length...8).reduce(0) { |byte, bit| (byte << 1) | bit } }
  end

  # NEMESIS (NemDec): the tiles the block at +at+ holds, 32 bytes each, each row of eight pixels a
  # word written high byte first. The header word's top bit is XOR mode (each row stored as how it
  # differs from the row before) and its low 13 bits the tile count, since the routine counts rows
  # in 16 bits (`lsl.w #3`). Then the code table: a byte with its top bit set names a colour (the
  # first byte is taken as one whatever it is), each byte after it below 0x80 is an entry (bits 4
  # to 6 the run less one, bits 0 to 3 the code's length) followed by its code, and 0xFF ends the
  # table. A code is looked up by the next 8 bits; 0xFC and up are 111111 and 7 bits spelt out.
  def nemesis_tiles(bytes, at = 0)
    header = (bytes.getbyte(at) << 8) | bytes.getbyte(at + 1)
    rows = (header & 0x1FFF) * 8
    codes, place = nemesis_codes(bytes, at + 2)
    stream = BitReader.new(bytes, place)
    out = []
    row = 0
    pixels = 0
    previous = 0
    while out.length < rows
      if stream.peek(8) >= 0xFC
        stream.skip(6)
        spelt = stream.take(7)
        run = spelt >> 4
        colour = spelt & 0xF
      else
        entry = codes[stream.peek(8)]
        stream.skip(entry >> 8)
        run = (entry >> 4) & 7
        colour = entry & 0xF
      end
      (run + 1).times do
        row = ((row << 4) | colour) & 0xFFFF_FFFF
        pixels += 1
        next unless pixels == 8

        previous = header.anybits?(0x8000) ? previous ^ row : row
        out << previous
        row = 0
        pixels = 0
        break if out.length == rows
      end
    end
    out.pack("N*")
  end

  # The code table from +place+: 256 entries (the length in bits 8 to 11, the run in 4 to 6, the
  # colour in 0 to 3), and the place after the table. An entry is put in every place its 8-bit
  # lookup lands; one of a length past 8 is left out, as no real table has one.
  def nemesis_codes(bytes, place)
    codes = Array.new(256, 0)
    byte = bytes.getbyte(place)
    place += 1
    while byte != 0xFF
      colour = byte
      loop do
        byte = bytes.getbyte(place)
        place += 1
        break if byte >= 0x80

        length = byte & 0xF
        code = bytes.getbyte(place)
        place += 1
        next if length > 8

        spread = 8 - length
        (1 << spread).times do |low|
          lookup = (code << spread) + low
          codes[lookup] = (colour & 0xF) | (byte & 0x70) | (length << 8) if lookup < 256
        end
      end
    end
    [codes, place]
  end

  # The codes a made-up block gives its runs, most used first: one of 2 bits, four of 4, sixteen
  # of 6 and sixteen of 8, so every kind of entry is in a table. A run past the first +listed+ is
  # spelt out (111111, then its length less one and its colour).
  # Each group is its first bits, how many those are, the code's whole length and how many codes.
  NEMESIS_CODE_GROUPS = Ractor.make_shareable([[0b00, 2, 2, 1], [0b01, 2, 4, 4], [0b10, 2, 6, 16], [0b1100, 4, 8, 16]])

  # A Nemesis block holding +tiles+ (32 bytes each), written for a test: XOR mode if +xor+.
  def nemesis_block(tiles, xor:, listed: 37)
    rows = tiles.unpack("N*")
    stored = xor ? rows.each_with_index.map { |row, i| i.zero? ? row : row ^ rows[i - 1] } : rows
    runs = []
    stored.flat_map { |row| 7.downto(0).map { |at| (row >> (at * 4)) & 0xF } }.each do |colour|
      if runs.last && runs.last[0] == colour && runs.last[1] < 8
        runs.last[1] += 1
      else
        runs << [colour, 1]
      end
    end
    codes = nemesis_code_list(runs.tally.sort_by { |run, uses| [-uses, run] }.map(&:first).first(listed))
    table = codes.group_by { |(colour, _), _| colour }.sort.flat_map do |colour, entries|
      [0x80 | colour] + entries.flat_map { |(_, length), (code, bits)| [((length - 1) << 4) | bits, code] }
    end
    stream = BitWriter.new
    runs.each do |run|
      code, bits = codes[run]
      code ? stream.put(code, bits) : stream.put(0b111111, 6).put(((run[1] - 1) << 4) | run[0], 7)
    end
    [((xor ? 0x8000 : 0) | (tiles.bytesize / 32)) >> 8, (tiles.bytesize / 32) & 0xFF, *table, 0xFF, *stream.bytes].pack("C*")
  end

  # Each of +runs+ given its code, in NEMESIS_CODE_GROUPS order: { [colour, length] => [code, bits] }.
  def nemesis_code_list(runs)
    places = NEMESIS_CODE_GROUPS.flat_map do |prefix, prefix_bits, bits, many|
      (0...many).map { |i| [(prefix << (bits - prefix_bits)) | i, bits] }
    end
    runs.zip(places).to_h
  end

  # ENIGMA (EniDec): the cells the map at +at+ holds, a word each, with +base+ added. Six bytes of
  # header: the width of a spelt cell in bits; which flips a spelt cell carries a bit for (bit 1 the
  # vertical, $1000, read first; bit 0 the horizontal, $800); the counting word and the repeating
  # word, high byte first, each with +base+ added. Then the ops, each a code and a count less one in
  # 4 bits. THIS GAME'S EniDec READS ONLY THE TWO FLIP BITS of a spelt cell, not the palette and
  # priority bits the format's usual reading has; the flips are OR'd into the base and the cell's
  # bits added to that.
  def enigma_cells(bytes, at = 0, base: 0)
    width = bytes.getbyte(at)
    flips = bytes.getbyte(at + 1)
    counting = (bytes.byteslice(at + 2, 2).unpack1("n") + base) & 0xFFFF
    repeating = (bytes.byteslice(at + 4, 2).unpack1("n") + base) & 0xFFFF
    stream = BitReader.new(bytes, at + 6)
    spell = lambda do
      high = base
      high |= 0x1000 if flips.anybits?(2) && stream.take(1) == 1
      high |= 0x800 if flips.anybits?(1) && stream.take(1) == 1
      (stream.take(width) + high) & 0xFFFF
    end
    cells = []
    loop do
      peeked = stream.peek(7)
      op = peeked >> 4
      count = (peeked < 0x40 ? peeked >> 1 : peeked) & 0xF
      stream.skip(peeked < 0x40 ? 6 : 7)
      case op
      when 0, 1 then (count + 1).times { cells << counting; counting = (counting + 1) & 0xFFFF }
      when 2, 3 then (count + 1).times { cells << repeating }
      when 4 then cell = spell.call; (count + 1).times { cells << cell }
      when 5 then cell = spell.call; (count + 1).times { |i| cells << ((cell + i) & 0xFFFF) }
      when 6 then cell = spell.call; (count + 1).times { |i| cells << ((cell - i) & 0xFFFF) }
      else
        return cells if count == 15

        (count + 1).times { cells << spell.call }
      end
    end
  end

  # An Enigma map written for a test, op by op: the block's ops are calls on the writer handed to
  # the block, and its end mark is written after them.
  def enigma_block(width:, flips:, counting:, repeating:)
    writer = EnigmaWriter.new(width, flips)
    yield writer
    writer.put(0b111, 3).put(15, 4)
    [width, flips, counting >> 8, counting & 0xFF, repeating >> 8, repeating & 0xFF, *writer.bytes].pack("C*")
  end

  # The ops of an Enigma map. A spelt cell is [cell, vertical, horizontal], the flips true or false.
  class EnigmaWriter < BitWriter
    def initialize(width, flips)
      super()
      @width = width
      @flips = flips
    end

    def counting(many) = put(0b00, 2).put(many - 1, 4)

    def repeating(many) = put(0b01, 2).put(many - 1, 4)

    def same(spelt, many) = put(0b100, 3).put(many - 1, 4).spell(*spelt)

    def counting_up(spelt, many) = put(0b101, 3).put(many - 1, 4).spell(*spelt)

    def counting_down(spelt, many) = put(0b110, 3).put(many - 1, 4).spell(*spelt)

    def each_spelt(spelts)
      put(0b111, 3).put(spelts.length - 1, 4)
      spelts.each { |spelt| spell(*spelt) }
      self
    end

    def spell(cell, vertical = false, horizontal = false)
      put(vertical ? 1 : 0, 1) if @flips.anybits?(2)
      put(horizontal ? 1 : 0, 1) if @flips.anybits?(1)
      put(cell, @width)
    end
  end
end
