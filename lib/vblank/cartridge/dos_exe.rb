# frozen_string_literal: true

module VBlank
  module Cartridge
    # A DOS PROGRAM AS AN MZ EXE: the code and data the DOS lowering linked, with the header DOS reads in
    # front of them. DOS loads the image into free memory at a segment of its own choosing, adds that
    # segment to every place the header lists (the relocations), points SS:SP and CS:IP where the header
    # says and starts the program.
    #
    # THE HEADER, every number a 16-bit word, low byte first (the "MZ" format, DOS's own):
    #
    #   00h  "MZ"
    #   02h  how many bytes of the file's last 512-byte page are used (0 for a full page)
    #   04h  how many pages the file takes, the header included
    #   06h  how many relocations there are, and 18h where the table of them starts
    #   08h  the header's size in 16-byte paragraphs
    #   0Ah  the least memory wanted beyond the image, in paragraphs, and 0Ch the most (FFFFh is "all of it")
    #   0Eh  the stack segment, 10h the stack pointer; both relative to where the image was loaded
    #   12h  a checksum nobody checks (0)
    #   14h  the instruction pointer, and 16h the code segment (relative), where the program starts
    #
    # A relocation is an offset and a segment (two words), naming a word of the image that holds a
    # segment number the loader must add the load segment to. The code that reads its data through DS
    # sets it with `MOV AX, segment`, and every one of those words is listed here.
    #
    # The header is 512 bytes (32 paragraphs) so a title fits in it, in the padding after the table
    # (TITLE_AT). DOS never reads it. A program with more relocations than fit before the title, a game
    # whose many lines each name the art's segment, has its table after the title instead, and the
    # header as many paragraphs longer as the table takes: the header's word at 18h says where the table
    # is and DOS reads it from there. The count is a word, so more than MOST_RELOCATIONS is refused.
    class DOSEXE
      MAGIC = "MZ"
      PAGE = 512
      HEADER_SIZE = 512
      TABLE_AT = 0x1C
      TITLE_AT = 0x1C0
      TITLE_LENGTH = 64
      ROOM_BEFORE_TITLE = (TITLE_AT - TABLE_AT) / 4
      MOST_RELOCATIONS = 0xFFFF

      attr_reader :bytes

      # What the build worked out about the program, for the tools that read a running one back, or nil.
      attr_reader :built

      # +image+ is the linked bytes. +entry+ and +stack+ are [segment, offset] pairs, the segments relative
      # to the image's start. +relocations+ are [segment, offset] pairs of the words that name a segment.
      # +extra_paragraphs+ is the memory the program wants beyond the image (its far segments).
      def initialize(image, title:, entry:, stack:, relocations: [], extra_paragraphs: 0, built: nil)
        @built = built
        if relocations.size > MOST_RELOCATIONS
          raise ArgumentError, "A DOS program can name #{MOST_RELOCATIONS} segments in its header, and this one names " \
                               "#{relocations.size}."
        end

        @bytes = header(title, entry, stack, relocations, extra_paragraphs, image.bytesize) + image.b
      end

      def size = @bytes.bytesize

      # The console a program of this kind is for; whether +bytes+ are one; and its title field.
      def self.console = :dos
      def self.header?(bytes) = bytes.bytesize >= HEADER_SIZE && bytes.byteslice(0, MAGIC.bytesize) == MAGIC
      def self.title_field_of(bytes) = bytes.byteslice(TITLE_AT, TITLE_LENGTH)

      def console = self.class.console
      def header_title = self.class.title_field_of(@bytes)
      alias buffer bytes
      def var_addresses = @built&.variables
      def source_program = @built&.source_program

      # The game's title as the header holds it.
      def title = header_title.delete("\0").rstrip

      def write(path) = File.binwrite(path, @bytes)

      # DOS has no profiler yet: where a frame's time went is read from the processor's own count, which the
      # DOSBox core does not hand over.
      def profile(**)
        raise ProfileError, "A DOS program cannot be profiled yet. The DOSBox core does not say where the " \
                            "processor spent its time. To fix this, profile the game on another console."
      end

      private

      def header(title, entry, stack, relocations, extra_paragraphs, image_size)
        table_at = relocations.size > ROOM_BEFORE_TITLE ? HEADER_SIZE : TABLE_AT
        header_size = table_at == TABLE_AT ? HEADER_SIZE : HEADER_SIZE + (((relocations.size * 4) + 15) & ~15)
        file_size = header_size + image_size
        bytes = "\0".b * header_size
        bytes[0, 2] = MAGIC
        words = [file_size % PAGE, (file_size + PAGE - 1) / PAGE, relocations.size, header_size / 16,
                 extra_paragraphs, 0xFFFF, stack[0], stack[1], 0, entry[1], entry[0], table_at, 0]
        bytes[2, words.size * 2] = words.pack("v*")
        relocations.each_with_index do |(segment, offset), at|
          bytes[table_at + (at * 4), 4] = [offset, segment].pack("v2")
        end
        text = title.to_s.gsub(/[^ -~]/, " ").byteslice(0, TITLE_LENGTH).b
        bytes[TITLE_AT, text.bytesize] = text
        bytes
      end
    end
  end
end
