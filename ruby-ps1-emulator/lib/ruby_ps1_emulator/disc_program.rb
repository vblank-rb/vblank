# frozen_string_literal: true

module RubyPS1Emulator
  # The program a disc image starts, found the way a console's BIOS finds it: the .cue sheet names the
  # .bin, the disc's file system (ISO 9660) has SYSTEM.CNF in its root directory, SYSTEM.CNF's BOOT
  # line names the program, and the program's PS-X EXE header says where in RAM its code goes (psx-spx,
  # "CDROM File Formats"). A Core playing a disc wants that last part, to know when the program has
  # begun (Core#program_running?).
  #
  # It reads raw images of 2352-byte sectors (MODE2/2352 and MODE1/2352 tracks), the kind a .cue names
  # for a PlayStation disc, and the first track only.
  module DiscProgram
    RAW = 2352
    SECTOR = 2048
    DESCRIPTOR_AT = 16

    class Unreadable < ArgumentError; end

    module_function

    # Where the program the disc at +cue_path+ boots puts its code: a range of addresses.
    def code_of(cue_path)
      image = File.binread(bin_path(cue_path))
      mode = File.read(cue_path)[/TRACK\s+\d+\s+MODE(\d)/i, 1] or raise Unreadable, "#{cue_path} names no data track"
      read = ->(sector) { image.byteslice((sector * RAW) + (mode == "2" ? 24 : 16), SECTOR) || "" }
      root = read.call(DESCRIPTOR_AT).byteslice(156, 34)
      files = directory(read, root.byteslice(2, 4).unpack1("V"), root.byteslice(10, 4).unpack1("V"))
      config = file(read, files.fetch("SYSTEM.CNF") { raise Unreadable, "#{cue_path}: the disc has no SYSTEM.CNF" })
      boot = config[/BOOT\s*=\s*cdrom:\\?([^;\r\n]+)/i, 1] or raise Unreadable, "#{cue_path}: SYSTEM.CNF names no program"
      header = read.call(files.fetch(boot.upcase) { raise Unreadable, "#{cue_path}: the disc has no #{boot}" }.first)
      load_at, length = header.byteslice(0x18, 8).unpack("VV")
      load_at...(load_at + length)
    end

    # The .bin the cue sheet's FILE line names, beside it.
    def bin_path(cue_path)
      name = File.read(cue_path)[/FILE\s+"([^"]+)"/i, 1] or raise Unreadable, "#{cue_path} names no image file"
      File.join(File.dirname(cue_path), name)
    end

    # The files of the directory at +sector+, +bytes+ long, by name without its version (";1"): each
    # its first sector and its length.
    def directory(read, sector, bytes)
      files = {}
      (bytes / SECTOR).times do |i|
        data = read.call(sector + i)
        at = 0
        while at < SECTOR && (length = data.getbyte(at)).positive?
          name = data.byteslice(at + 33, data.getbyte(at + 32))
          files[name.sub(/;\d+\z/, "")] = [data.byteslice(at + 2, 4).unpack1("V"), data.byteslice(at + 10, 4).unpack1("V")]
          at += length
        end
      end
      files
    end

    # The bytes of the file at +place+ ([first sector, length]).
    def file(read, place)
      first, length = place
      Array.new((length + SECTOR - 1) / SECTOR) { |i| read.call(first + i) }.join.byteslice(0, length)
    end
  end
end
