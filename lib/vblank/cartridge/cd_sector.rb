# frozen_string_literal: true

module VBlank
  module Cartridge
    # One sector of a CD as the drive reads it off the disc: 2352 bytes, of which 2048 are the data a
    # program asked for. The rest is how the drive finds the sector and checks it.
    #
    # A PlayStation disc keeps its data in Mode 2 Form 1 sectors (psx-spx, "CDROM Sector Encoding"):
    #
    #   000h  12  sync: 00h, ten FFh, 00h, where a sector starts
    #   00Ch   4  header: the sector's place as minute, second and frame, in BCD, then the mode (2)
    #   010h   8  subheader: file, channel, submode, coding, written twice
    #   018h 800h the data
    #   818h   4  EDC: a 32-bit check over the subheader and the data
    #   81Ch 114h ECC: Reed-Solomon parity, from which the drive mends a damaged byte
    #
    # The drive checks the EDC and the ECC as it reads (Beetle PSX does so too, and says "Bad sector"
    # when they are wrong), so they are worked out here by the rules every CD writer follows
    # (ECMA-130, annexes A and B).
    #
    # A place on the disc is a sector number counted from the first data sector. The header gives it
    # as a time: 75 sectors a second, and the first data sector sits two seconds in (150 sectors).
    module CDSector
      RAW = 2352
      DATA = 2048
      SYNC = ("\x00".b + ("\xFF".b * 10) + "\x00".b).freeze
      LEAD_IN = 150
      SECTORS_A_SECOND = 75

      # The submode bits a sector's subheader carries (psx-spx, "CDROM XA Subheader").
      DATA_SUBMODE = 0x08
      END_OF_RECORD = 0x01
      END_OF_FILE = 0x80

      # The tables the EDC and the ECC are worked out with (ECMA-130): the EDC's polynomial
      # x^32 + x^31 + x^16 + x^15 + x^4 + x^3 + x + 1 taken a byte at a time, and the field GF(2^8)
      # with x^8 + x^4 + x^3 + x^2 + 1 that the ECC's parity is counted in.
      EDC_TABLE = Array.new(256) do |i|
        8.times.reduce(i) { |edc, _| (edc >> 1) ^ (edc.odd? ? 0xD801_8001 : 0) }
      end.freeze
      ECC_FORWARD = Array.new(256) { |i| ((i << 1) ^ (i & 0x80 != 0 ? 0x11D : 0)) & 0xFF }.freeze
      ECC_BACK = Array.new(256).tap { |back| 256.times { |i| back[i ^ ECC_FORWARD[i]] = i } }.freeze

      module_function

      # Sector +number+ holding +data+ (up to 2048 bytes, the rest nought), its subheader's submode
      # +submode+.
      def encode(number, data, submode: DATA_SUBMODE)
        raise ArgumentError, "a sector holds #{DATA} bytes, not #{data.bytesize}" if data.bytesize > DATA

        sector = SYNC + header(number) + ([0, 0, submode, 0] * 2).pack("C8") + data.b + ("\0".b * (DATA - data.bytesize))
        sector << [edc(sector.byteslice(0x10, 0x808))].pack("V")
        sector << ("\0".b * (RAW - sector.bytesize))
        bytes = sector.bytes
        # In Mode 2 the header is counted as nought for the parity, so a sector copied to another place
        # keeps its parity (ECMA-130 annex A, as Form 1 of CD-ROM XA applies it).
        parity_input = bytes.dup
        parity_input[0xC, 4] = [0, 0, 0, 0]
        parity(parity_input, 86, 24, 2, 86, 0x81C)
        parity(parity_input, 52, 43, 86, 88, 0x8C8)
        bytes[0x81C, 0x114] = parity_input[0x81C, 0x114]
        bytes.pack("C*")
      end

      # The header of sector +number+: its time in BCD, and mode 2.
      def header(number)
        at = number + LEAD_IN
        minute, rest = at.divmod(60 * SECTORS_A_SECOND)
        second, frame = rest.divmod(SECTORS_A_SECOND)
        [minute, second, frame].map { |part| bcd(part) }.pack("C3") + "\x02".b
      end

      def bcd(number) = ((number / 10) << 4) | (number % 10)

      # The EDC of +bytes+, as the drive works it out.
      def edc(bytes)
        bytes.each_byte.reduce(0) { |edc, byte| (edc >> 8) ^ EDC_TABLE[(edc ^ byte) & 0xFF] }
      end

      # One of the two parities, P (86 columns of 24) or Q (52 diagonals of 43), worked out over the
      # 2064 bytes from the header on and written into +sector+ at +into+ (ECMA-130 annex A).
      def parity(sector, majors, minors, major_step, minor_step, into)
        size = majors * minors
        majors.times do |major|
          index = ((major >> 1) * major_step) + (major & 1)
          a = 0
          b = 0
          minors.times do
            byte = sector[0xC + index]
            index += minor_step
            index -= size if index >= size
            a ^= byte
            b ^= byte
            a = ECC_FORWARD[a]
          end
          a = ECC_BACK[ECC_FORWARD[a] ^ b]
          sector[into + major] = a
          sector[into + major + majors] = a ^ b
        end
      end
    end
  end
end
