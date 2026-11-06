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
    #
    # The three at the top are what says whether a pack kept on a player's machine can still be
    # read: a format this build does not know, another copy, or another build of the game each
    # mean the pack is made again.
    Pack = Data.define(:format_version, :rom_sha1, :build_version, :slots)

    class Pack
      MAGIC = "VBLANKPK".b.freeze
      FORMAT_VERSION = 1

      # A pack of +slots+ (a list of Slot) cut from +copy+, the copy's whole file as a String, whose
      # SHA-1 is +sha1+; +build_version+ names the build that made it.
      def self.made_from(copy, sha1:, build_version:, slots:)
        copy = copy.b
        new(format_version: FORMAT_VERSION, rom_sha1: sha1, build_version: build_version.to_s,
            slots: slots.to_h { |slot| [slot.name, slot.cut_from(copy)] })
      end

      # The pack in the file at +path+.
      def self.read(path) = from_bytes(File.binread(path))

      # The pack +bytes+ hold. WrongPack when they are not a pack this build can read.
      def self.from_bytes(bytes)
        refuse_unless_pack!(bytes.b)
        reader = Reader.new(bytes.b)
        reader.bytes(MAGIC.bytesize)
        version = reader.number(2)
        refuse_unknown_format!(version)
        sha1 = reader.bytes(20).unpack1("H*")
        build_version = reader.bytes(reader.number(1)).force_encoding(Encoding::UTF_8)
        sizes = Array.new(reader.number(2)) { [reader.bytes(reader.number(1)).to_sym, reader.number(4)] }
        new(format_version: version, rom_sha1: sha1, build_version: build_version,
            slots: sizes.to_h { |name, size| [name, reader.bytes(size)] })
      end

      # The longest text the file can hold for the build's version or a slot's name, and the most
      # slots: each count is kept in one byte or two (see the layout above).
      MOST_TEXT_BYTES = 0xFF
      MOST_SLOTS = 0xFFFF

      # Everything is checked as the pack is made, so a pack that exists can always be written as a
      # file that reads back the same. The SHA-1 is kept in lower case, as the file reads it back.
      def initialize(format_version:, rom_sha1:, build_version:, slots:)
        refuse_unwritable_sha1!(rom_sha1)
        refuse_long_text!("The build version #{build_version.inspect}", build_version)
        slots.each_key { |name| refuse_long_text!("The slot name :#{name}", name.to_s) }
        if slots.size > MOST_SLOTS
          raise ArgumentError, "The data pack has #{slots.size} slots. A data pack can hold #{MOST_SLOTS} slots at most."
        end

        super(format_version: format_version, rom_sha1: rom_sha1.downcase.freeze, build_version: build_version.freeze,
              slots: slots.transform_values { |bytes| bytes.b.freeze }.freeze)
      end

      # The bytes slot +name+ holds.
      def bytes_of(name) = slots.fetch(name.to_sym)

      # The pack as its file holds it.
      def to_bytes
        names = slots.keys.map { |name| name.to_s.b }
        header = [MAGIC, [format_version].pack("v"), [rom_sha1].pack("H*"), [build_version.bytesize].pack("C"),
                  build_version.b, [slots.size].pack("v")]
        index = names.zip(slots.values).map { |name, bytes| [name.bytesize].pack("C") + name + [bytes.bytesize].pack("V") }
        (header + index + slots.values).join.b
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
      end
    end
  end
end
