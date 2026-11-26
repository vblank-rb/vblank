# frozen_string_literal: true

module VBlank
  module Cartridge
    # A PlayStation disc as an image: the sectors of a CD, written to a .bin, and the .cue sheet beside
    # it that tells an emulator (or a program that burns discs) how they are laid out.
    #
    # A console starts a disc through its BIOS. The BIOS reads the disc's file system (ISO 9660), finds
    # SYSTEM.CNF, and loads the program its BOOT line names, a PS-X EXE (psx-spx, "CDROM File Formats").
    # This disc holds three files, laid out so that the program can find its data without reading the
    # file system at all:
    #
    #   sector  0-15  the system area, all nought (a Sony disc keeps its licence text here: this never)
    #   sector 16     the primary volume descriptor: what the disc is, and where its root directory is
    #   sector 17     the end of the volume descriptors
    #   sector 18-19  the path table, low byte first and then high byte first
    #   sector 20     the root directory
    #   sector 21     SYSTEM.CNF
    #   sector 22-    DATA.BIN, the data the program reads as it runs (DATA_AT)
    #   then          SLUS_000.00, the program (PROGRAM_NAME)
    #
    # The data comes before the program because the program is built knowing the sector its data starts
    # at, and that sector must not depend on how long the program came to. The console's own games read
    # their data the same way: they found a file's first sector once, or had it written into the program
    # when the disc was made, and from then on read it by sector number.
    #
    # Every sector is a Mode 2 Form 1 sector (CDSector), 2048 bytes of data each.
    class PS1Disc
      SECTOR = CDSector::DATA

      # The sectors of the file system, and the first sector of the program's data.
      DESCRIPTOR_AT = 16
      TERMINATOR_AT = 17
      PATH_TABLE_AT = 18
      ROOT_AT = 20
      SYSTEM_CNF_AT = 21
      DATA_AT = 22

      DATA_NAME = "DATA.BIN"
      # The program's name: a product code's shape, a made-up one. A drive reads data only from a disc
      # it takes for a PlayStation disc, which on a console is the licence mark pressed into the disc
      # and a modchip's or loader's business here. Beetle PSX, the emulator, decides by the BOOT line of
      # SYSTEM.CNF instead: a program named like Sony's product codes (four letters, "S" then "C", "L"
      # or "I", then the region, here "U"), or the licence text in sector 4, which this disc never
      # holds. No product carries the number 000.00, as product numbers start at 1.
      PROGRAM_NAME = "SLUS_000.00"
      SYSTEM_CNF_NAME = "SYSTEM.CNF"

      # The system identifier a PlayStation disc's volume descriptor carries (psx-spx).
      SYSTEM_ID = "PLAYSTATION"

      # The disc's sectors, each 2352 bytes, as the .bin holds them.
      attr_reader :image

      # +program+ is the PS-X EXE's bytes, +data+ the bytes the program reads by sector from DATA_AT on,
      # and +title+ the volume's name. +stack+ is where SYSTEM.CNF tells the BIOS to start the stack.
      def initialize(program:, data:, title:, stack:)
        @program = program.b
        @data = data.b
        @title = volume_name(title)
        @stack = stack
        @image = sectors.join
      end

      # How many sectors the disc holds.
      def sector_count = @image.bytesize / CDSector::RAW

      # The .cue sheet for the image written as +bin_name+: one data track of raw Mode 2 sectors.
      def cue(bin_name) = %(FILE "#{bin_name}" BINARY\r\n  TRACK 01 MODE2/2352\r\n    INDEX 01 00:00:00\r\n)

      # Writes the image beside +cue_path+ (PS1Disc.bin_path_for), and the cue sheet at +cue_path+.
      def write(cue_path)
        bin_path = self.class.bin_path_for(cue_path)
        File.binwrite(bin_path, @image)
        File.binwrite(cue_path, cue(File.basename(bin_path)))
      end

      # Where the image of the disc whose cue sheet is +cue_path+ is written: beside it, with its name and .bin.
      def self.bin_path_for(cue_path) = cue_path.sub(/\.\w+\z/, "") + ".bin"

      # How many sectors +bytes+ take.
      def self.sectors_for(bytes) = (bytes + SECTOR - 1) / SECTOR

      private

      def program_at = DATA_AT + self.class.sectors_for(@data.bytesize)

      # A file in the root directory: its name, its first sector and how many bytes it holds.
      DiscFile = Data.define(:name, :sector, :bytes)

      def files
        [DiscFile.new(name: DATA_NAME, sector: DATA_AT, bytes: @data.bytesize),
         DiscFile.new(name: PROGRAM_NAME, sector: program_at, bytes: @program.bytesize),
         DiscFile.new(name: SYSTEM_CNF_NAME, sector: SYSTEM_CNF_AT, bytes: system_cnf.bytesize)].sort_by(&:name)
      end

      def total_sectors = program_at + self.class.sectors_for(@program.bytesize)

      def sectors
        out = Array.new(DESCRIPTOR_AT) { |n| CDSector.encode(n, "") }
        out << CDSector.encode(DESCRIPTOR_AT, primary_descriptor, submode: CDSector::DATA_SUBMODE | CDSector::END_OF_RECORD)
        out << CDSector.encode(TERMINATOR_AT, terminator, submode: last_submode)
        out << CDSector.encode(PATH_TABLE_AT, path_table(:little), submode: last_submode)
        out << CDSector.encode(PATH_TABLE_AT + 1, path_table(:big), submode: last_submode)
        out << CDSector.encode(ROOT_AT, root_directory, submode: last_submode)
        out << CDSector.encode(SYSTEM_CNF_AT, system_cnf, submode: last_submode)
        out.concat(file_sectors(DATA_AT, @data))
        out.concat(file_sectors(program_at, @program))
      end

      def last_submode = CDSector::DATA_SUBMODE | CDSector::END_OF_RECORD | CDSector::END_OF_FILE

      # +bytes+ as sectors from +first+ on, the last marked as the file's end.
      def file_sectors(first, bytes)
        count = [self.class.sectors_for(bytes.bytesize), 1].max
        Array.new(count) do |i|
          CDSector.encode(first + i, bytes.byteslice(i * SECTOR, SECTOR) || "",
                          submode: i == count - 1 ? last_submode : CDSector::DATA_SUBMODE)
        end
      end

      # The BIOS reads BOOT (the program), and the kernel's sizes and the stack, a line each.
      def system_cnf
        format("BOOT = cdrom:\\%<program>s;1\r\nTCB = 4\r\nEVENT = 10\r\nSTACK = %<stack>08X\r\n",
               program: PROGRAM_NAME, stack: @stack).b
      end

      # ECMA-119 8.4, the primary volume descriptor.
      def primary_descriptor
        d = "\0".b * SECTOR
        d[0, 7] = "\x01CD001\x01".b
        d[8, 32] = padded(SYSTEM_ID, 32)
        d[40, 32] = padded(@title, 32)
        d[80, 8] = both32(total_sectors)
        d[120, 4] = both16(1)
        d[124, 4] = both16(1)
        d[128, 4] = both16(SECTOR)
        d[132, 8] = both32(path_table(:little).bytesize)
        d[140, 4] = [PATH_TABLE_AT].pack("V")
        d[148, 4] = [PATH_TABLE_AT + 1].pack("N")
        d[156, 34] = record("\0".b, ROOT_AT, SECTOR, directory: true)
        [190, 318, 446, 574].each { |at| d[at, 128] = " " * 128 }
        [702, 739, 776].each { |at| d[at, 37] = " " * 37 }
        [813, 830, 847, 864].each { |at| d[at, 17] = ("0" * 16) + "\0" }
        d[881] = "\x01".b
        # The CD-ROM XA mark a PlayStation disc carries in its descriptor's application area (psx-spx).
        d[0x400, 8] = "CD-XA001"
        d
      end

      def terminator = "\xFFCD001\x01".b

      # ECMA-119 9.4, one entry: the root, its own parent.
      def path_table(order)
        ["\x01\x00".b, [ROOT_AT].pack(order == :little ? "V" : "N"), [1].pack(order == :little ? "v" : "n"), "\0\0".b].join
      end

      # ECMA-119 9.1: the root's own record and its parent's, then a record for each file, by name.
      def root_directory
        dir = record("\0".b, ROOT_AT, SECTOR, directory: true) + record("\x01".b, ROOT_AT, SECTOR, directory: true)
        files.each { |file| dir << record("#{file.name};1", file.sector, file.bytes) }
        dir
      end

      def record(name, sector, size, directory: false)
        name = name.b
        length = 33 + name.bytesize
        length += 1 if length.odd?
        r = "\0".b * length
        r[0] = length.chr
        r[2, 8] = both32(sector)
        r[10, 8] = both32(size)
        r[18, 7] = [126, 1, 1, 0, 0, 0, 0].pack("C7") # 2026-01-01, a fixed date so a build is the same twice
        r[25] = (directory ? 2 : 0).chr
        r[28, 4] = both16(1)
        r[32] = name.bytesize.chr
        r[33, name.bytesize] = name
        r
      end

      def both32(value) = [value].pack("V") + [value].pack("N")
      def both16(value) = [value].pack("v") + [value].pack("n")
      def padded(text, size) = text.b.byteslice(0, size).ljust(size, " ")

      # A volume's name in the letters ISO 9660 allows: capitals, digits and underscores.
      def volume_name(title)
        name = title.to_s.upcase.gsub(/[^A-Z0-9_]/, "_")
        name.empty? ? "VBLANK" : name
      end
    end
  end
end
