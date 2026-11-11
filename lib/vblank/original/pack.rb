# frozen_string_literal: true

module VBlank
  module Original
    # A FILE THAT CANNOT BE READ AS A DATA PACK: it is not one, it is cut short, or it is written in
    # a format this build of VBlank does not know. A pack can always be made again from the copy,
    # so the words say that.
    class WrongPack < CopyError; end

    # THE DATA PACK: everything a port reads from the original, in one file, made from the player's
    # copy. The port's code holds none of the original's data; it reads each piece from a slot of
    # this pack (Slot), by name.
    #
    # One mechanism, two ways to fill it. Built all-in-one, the build makes the pack from the copy
    # and the game is built with it. Built as a shell, the player's machine makes the same pack from
    # the player's copy on the first run and keeps it, and every later run reads the pack and never
    # the copy. Either way the pack is the same bytes, so it is written the same way here.
    #
    # The file, every number low byte first:
    #
    #   "VBLANKPK"           8 bytes, so a file that is not a pack is told apart at once
    #   format version       2 bytes, FORMAT_VERSION
    #   the copy's SHA-1     20 bytes
    #   build version        1 byte of length, then that many bytes of text
    #   slot count           2 bytes
    #   each slot            1 byte of length and its name, then 4 bytes: how many bytes it holds
    #   each slot's bytes    in the order the slots are listed
    #   the frame records    to the end of the file: each frame of a sprite the game names, written
    #                        again as a record of VBlank's own (FrameRecord::Section); none for a
    #                        game that names no frame
    #
    # The three at the top are what shows whether a pack kept on a player's machine can still be
    # read: a format this build does not know, another copy, or another build of the game each
    # mean the pack is made again.
    #
    # The frame records are no slot. A slot is named, shaped and sized by the game's `data_pack`
    # block, which is read before the game names a frame, and a build that leaves its pack out
    # fixes where each slot starts in the file there and then. So the records follow the last slot,
    # where nothing before them moves, and the file's size, which such a build checks, is what
    # says they are there.
    Pack = Data.define(:format_version, :rom_sha1, :build_version, :slots, :frame_records)

    class Pack
      MAGIC = "VBLANKPK".b.freeze
      # 2: the frame records after the last slot. A pack of format 1 kept a frame only as the
      # original's bytes, which nothing draws from now.
      FORMAT_VERSION = 2

      # A pack holding +slot_bytes+ (each slot's bytes by name, in the pack's order), cut from the
      # copy (Slot#cut_from) or written by the game's unpacking routine (Unpacking), made from the
      # copy whose SHA-1 is +sha1+; +build_version+ names the build that made it. +frame_records+
      # are the bytes of its frames' records (FrameRecord::Section#bytes), where the game names frames.
      def self.holding(slot_bytes, sha1:, build_version:, frame_records: "")
        new(format_version: FORMAT_VERSION, rom_sha1: sha1, build_version: build_version.to_s, slots: slot_bytes,
            frame_records: frame_records)
      end

      # The pack in the file at +path+.
      def self.read(path) = from_bytes(File.binread(path))

      # WHERE EVERYTHING IS IN THE FILE of a pack of +slots+ (Original::Slot), made for
      # +build_version+, worked out from the slots' names, shapes and sizes alone: a game built with
      # its pack left out knows this much and no more. +size+ is the file's up to the end of its last
      # slot, which is where its frame records start (the game adds their size as it names frames,
      # Builder::PackPoses#finalize_pack_frames), +slot_starts+
      # where each slot's bytes start, by name, and +checks+ the bytes (IR::StartFile::Check) every such
      # pack holds and a pack for another build or another format does not: the mark and the
      # format, and the build version with the list of slots. Only the copy's SHA-1, between the
      # two, and the slots' bytes are not known.
      Layout = Data.define(:size, :slot_starts, :checks)

      def self.layout(slots, build_version:)
        header = header_bytes(sha1: "0" * 40, build_version: build_version.to_s,
                              sizes: slots.to_h { |slot| [slot.name, slot.byte_size] })
        known = [IR::StartFile::Check.new(at: 0, bytes: header.byteslice(0, SHA1_AT)),
                 IR::StartFile::Check.new(at: BUILD_VERSION_AT, bytes: header.byteslice(BUILD_VERSION_AT..))]
        Layout.new(size: header.bytesize + slots.sum(&:byte_size), checks: known,
                   slot_starts: Unpacking.places_of(slots).transform_values { |at| header.bytesize + at })
      end

      # The pack +bytes+ hold. WrongPack when they are not a pack this build can read.
      def self.from_bytes(bytes)
        refuse_unless_pack!(bytes.b)
        reader = Reader.new(bytes.b)
        reader.bytes(MAGIC.bytesize)
        version = reader.number(FORMAT_VERSION_BYTES)
        refuse_unknown_format!(version)
        sha1 = reader.bytes(SHA1_BYTES).unpack1("H*")
        build_version = reader.bytes(reader.number(1)).force_encoding(Encoding::UTF_8)
        sizes = Array.new(reader.number(2)) { [reader.bytes(reader.number(1)).to_sym, reader.number(4)] }
        new(format_version: version, rom_sha1: sha1, build_version: build_version,
            slots: sizes.to_h { |name, size| [name, reader.bytes(size)] }, frame_records: reader.rest)
      end

      # The longest text the file can hold for the build's version or a slot's name, and the most
      # slots: each count is kept in one byte or two (see the layout above).
      MOST_TEXT_BYTES = 0xFF
      MOST_SLOTS = 0xFFFF

      # Everything is checked as the pack is made, so a pack that exists can always be written as a
      # file that reads back the same. The SHA-1 is kept in lower case, as the file reads it back.
      def initialize(format_version:, rom_sha1:, build_version:, slots:, frame_records: "")
        refuse_unwritable_sha1!(rom_sha1)
        refuse_long_text!("The build version #{build_version.inspect}", build_version)
        slots.each_key { |name| refuse_long_text!("The slot name :#{name}", name.to_s) }
        if slots.size > MOST_SLOTS
          raise ArgumentError, "The data pack has #{slots.size} slots. A data pack can hold #{MOST_SLOTS} slots at most."
        end

        super(format_version: format_version, rom_sha1: rom_sha1.downcase.freeze, build_version: build_version.freeze,
              slots: slots.transform_values { |bytes| bytes.b.freeze }.freeze, frame_records: frame_records.b.freeze)
      end

      # The bytes slot +name+ holds.
      def bytes_of(name) = slots.fetch(name.to_sym)

      # Where the fixed part of the file is (the layout atop the class): the format version after
      # the mark, the copy's SHA-1 after that, and the build version, which starts the part whose
      # length depends on the text in it.
      FORMAT_VERSION_BYTES = 2
      SHA1_AT = MAGIC.bytesize + FORMAT_VERSION_BYTES
      SHA1_BYTES = 20
      BUILD_VERSION_AT = SHA1_AT + SHA1_BYTES

      # The file up to the first slot's bytes, for a pack made from the copy whose SHA-1 is +sha1+
      # by the build +build_version+, holding slots of +sizes+ (bytes, by name, in the pack's order).
      def self.header_bytes(sha1:, build_version:, sizes:)
        index = sizes.map { |name, size| [name.to_s.bytesize].pack("C") + name.to_s.b + [size].pack("V") }
        [MAGIC, [FORMAT_VERSION].pack("v"), [sha1].pack("H*"), [build_version.bytesize].pack("C"), build_version.b,
         [sizes.size].pack("v"), *index].join.b
      end

      # The pack as its file holds it.
      def to_bytes
        header = Pack.header_bytes(sha1: rom_sha1, build_version: build_version, sizes: slots.transform_values(&:bytesize))
        [header, *slots.values, frame_records].join.b
      end

      # The pack written to the file at +path+.
      def write(path) = File.binwrite(path, to_bytes)

      def self.refuse_unless_pack!(bytes)
        return if bytes.byteslice(0, MAGIC.bytesize) == MAGIC

        raise WrongPack, "This file is not a data pack. Make the pack again from your copy of the original."
      end

      def self.refuse_unknown_format!(version)
        return if version == FORMAT_VERSION

        raise WrongPack, "This data pack is in format #{version}. This build reads format #{FORMAT_VERSION}. " \
                         "Make the pack again from your copy of the original."
      end
      private_class_method :refuse_unless_pack!, :refuse_unknown_format!

      private

      def refuse_unwritable_sha1!(sha1)
        return if sha1.is_a?(String) && sha1.match?(/\A\h{40}\z/)

        raise ArgumentError, "The copy's SHA-1 #{sha1.inspect} is not 40 hex digits. A data pack must name the SHA-1 " \
                             "of the copy it is made from."
      end

      def refuse_long_text!(what, text)
        return if text.bytesize.between?(1, MOST_TEXT_BYTES)

        raise ArgumentError, "#{what} is #{text.bytesize} bytes. In a data pack it must be 1 to #{MOST_TEXT_BYTES} bytes."
      end

      # Reads a pack's bytes from the front, and refuses a pack that ends early.
      class Reader
        NUMBER_READS = { 1 => "C", 2 => "v", 4 => "V" }.freeze

        def initialize(bytes)
          @bytes = bytes
          @at = 0
        end

        def bytes(count)
          if @at + count > @bytes.bytesize
            raise WrongPack, "This data pack is cut short: it ends at byte #{@bytes.bytesize}. Make the pack again " \
                             "from your copy of the original."
          end

          @bytes.byteslice(@at, count).tap { @at += count }
        end

        def number(size) = bytes(size).unpack1(NUMBER_READS.fetch(size))

        # Every byte not read yet.
        def rest = @bytes.byteslice(@at..).tap { @at = @bytes.bytesize }
      end
    end
  end
end
