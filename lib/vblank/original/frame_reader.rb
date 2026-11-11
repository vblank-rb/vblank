# frozen_string_literal: true

module VBlank
  module Original
    # A PIECE READ BY A FEW LINES OF THE GAME'S OWN RUBY (`FrameLayout.new(..., piece: READER)`), for
    # an original that keeps a frame in a way no option of FrameLayout says. The reader is handed
    # the piece's bytes and the values the pose gives (`frame(at, layout:, with: { block: 5 })`), and
    # gives back a FrameLayout::Piece:
    #
    #   READER = lambda do |bytes, pose|
    #     block = (bytes[2] + pose[:block]) & 15
    #     big = (bytes[4] >> 5) & 1
    #     VBlank::Original::FrameLayout::Piece.new(
    #       x: bytes.signed(0), y: bytes.signed(1), tile: BLOCK_START.(block) | bytes[3],
    #       columns: big + 1, rows: big + 1, row_step: 16,
    #       mirrored: (bytes[4] >> 6) & 1, upside_down: (bytes[4] >> 7) & 1
    #     )
    #   end
    #
    # IT RUNS TWO WAYS, as everything in FrameLayout does (see WHAT READS A FRAME'S BYTES there).
    # The build that holds the pack hands it numbers. The pack's unpacking hands it the game's
    # values (DSL::Value), read from the pack as the game starts, and keeps the sums it gives back
    # as the routine (FrameRewrite). So a reader is arithmetic both read alike: + - * & | ^ and the
    # shifts, the byte on the LEFT of a shift. A Ruby `if`, a comparison, or a lookup in a Ruby
    # Array or Hash by a byte decides once, as the game is built, with nothing to decide on.
    #
    # SO A READER IS TRIED ONCE WHEN ITS LAYOUT IS MADE, on stand-ins (Probe) that do the
    # arithmetic and refuse the rest in plain words, the same in every build: a comparison (`==`,
    # `<`, `zero?`, `case`, a `?:` on one), a byte as the index of an Array or the key of a Hash,
    # a byte on the right of a shift, a byte past the piece, and an answer that is not a Piece.
    # The same try says which of the pose's values it reads (#pose_names), so a frame given others
    # is refused at its line, and whether it names a bank of colours.
    #
    # WHAT THE TRY CANNOT SEE: a test Ruby makes without asking the byte. `if bytes[4]`,
    # `bytes[4] && 1` and `bytes[4].nil?` take any byte as true, in both builds, so they choose
    # the same branch always and nothing differs to catch. A branch on something other than a
    # byte (a constant, a setting) is ordinary Ruby and fine.
    module FrameReader
      # The bytes of one piece, as a reader is handed them: `bytes[at]` is byte +at+ (0 first), 0
      # to 255, and `bytes.signed(at)` the same byte read as -128 to 127.
      class PieceBytes
        def initialize(piece_bytes, &byte)
          @piece_bytes = piece_bytes
          @byte = byte
        end

        def [](at)
          unless at.is_a?(Integer) && at.between?(0, @piece_bytes - 1)
            raise ArgumentError, "A frame layout's piece: reader reads byte #{at.inspect} of a piece, and a piece is " \
                                 "#{@piece_bytes} bytes (piece_bytes: #{@piece_bytes}). To fix this, read bytes 0 to " \
                                 "#{@piece_bytes - 1}, or give the layout more piece_bytes:."
          end

          @byte.call(at)
        end

        def signed(at) = (self[at] ^ 0x80) - 0x80
      end

      # The values the pose gives the reader (`frame(at, layout:, with: { block: 5 })`), each read
      # by its name: `pose[:block]` or `pose.fetch(:block)`.
      class PoseValues
        def initialize(&value)
          @value = value
        end

        def [](name)
          unless name.is_a?(Symbol)
            raise ArgumentError, "A frame layout's piece: reader reads pose value #{name.inspect}. A pose value is read " \
                                 "by its name, a Symbol, like `pose[:block]`."
          end

          @value.call(name)
        end

        def fetch(name) = self[name]
      end

      TESTED = "A frame layout's piece: reader tests a byte or a pose value (%<how>s). When the data pack is read as the " \
               "game starts, the reader runs as game code, and the byte is not a number yet. So a Ruby `if`, `case`, " \
               "`?:` or comparison cannot choose the answer. To fix this, work the answer out with shifts, masks and " \
               "sums: `((bytes[4] >> 5) & 1) + 1` is 2 where bit 5 is set and 1 where it is not."
      INDEXED = "A frame layout's piece: reader uses a byte or a pose value as a plain Ruby number: as the index of a " \
                "Ruby Array, or on the right of `<<` or `>>`. When the data pack is read as the game starts, the byte " \
                "is not a number yet. To fix this, put the byte on the left of a shift, like `(bytes[2] & 1) << 3`. " \
                "Work a table out with shifts, masks and sums instead of reading an Array."
      LOOKED_UP = "A frame layout's piece: reader uses a byte or a pose value as the key of a Ruby Hash. When the data " \
                  "pack is read as the game starts, the byte is not a number yet. To fix this, work the answer out " \
                  "with shifts, masks and sums instead of a Hash."

      # A STAND-IN FOR A BYTE, OR FOR A NUMBER WORKED OUT FROM ONE, for the try. It does what a
      # game's value does as arithmetic, and refuses what only a number can do, in the words above.
      class Probe
        def self.operand!(other, op)
          return other if other.is_a?(Integer) || other.is_a?(Probe)

          raise ArgumentError, "A frame layout's piece: reader works out `#{op}` with #{other.inspect}. Each part of a " \
                               "piece is a whole number, worked out from the piece's bytes and the pose's values."
        end

        # Written out one by one, not made from a block: a method made from a block in one Ractor
        # cannot be called in another, and a game's tests build in Ractors.
        def +(other) = Probe.worked_out(other, :+)
        def -(other) = Probe.worked_out(other, :-)
        def *(other) = Probe.worked_out(other, :*)
        def /(other) = Probe.worked_out(other, :/)
        def %(other) = Probe.worked_out(other, :%)
        def &(other) = Probe.worked_out(other, :&)
        def |(other) = Probe.worked_out(other, :|)
        def ^(other) = Probe.worked_out(other, :^)
        def <<(other) = Probe.worked_out(other, :<<)
        def >>(other) = Probe.worked_out(other, :>>)

        def self.worked_out(other, op)
          operand!(other, op)
          new
        end

        def -@ = Probe.new
        def ~ = Probe.new
        def abs = Probe.new
        def to_i = self

        def clamp(low, high)
          Probe.operand!(low, :clamp)
          Probe.operand!(high, :clamp)
          Probe.new
        end

        # A number on the left: `16 * bytes[2]`.
        def coerce(other) = [Probe.operand!(other, :coerce) && Probe.new, self]

        def to_int = raise(ArgumentError, INDEXED)
        def hash = raise(ArgumentError, LOOKED_UP)
        def eql?(_other) = raise(ArgumentError, LOOKED_UP)

        def self.refuse_test!(op) = raise(ArgumentError, format(TESTED, how: "`#{op}`"))

        def ==(_other) = Probe.refuse_test!(:==)
        def !=(_other) = Probe.refuse_test!(:!=)
        def <(_other) = Probe.refuse_test!(:<)
        def <=(_other) = Probe.refuse_test!(:<=)
        def >(_other) = Probe.refuse_test!(:>)
        def >=(_other) = Probe.refuse_test!(:>=)
        def <=>(_other) = Probe.refuse_test!(:<=>)
        def between?(*) = Probe.refuse_test!(:between?)
        def ! = Probe.refuse_test!(:!)
        def then(*) = Probe.refuse_test!(:then)

        def method_missing(name, *)
          raise ArgumentError, format(TESTED, how: "`#{name}`") if name.end_with?("?")

          raise ArgumentError, "A frame layout's piece: reader asks a byte for `#{name}`. A byte there is worked with " \
                               "+, -, *, &, |, ^, << and >> alone."
        end

        def respond_to_missing?(*) = false

        def inspect = "a byte of the piece"
      end

      # What the try found: the names of the pose's values the reader reads, in the order read, and
      # whether its pieces name a bank of colours.
      Tried = Data.define(:pose_names, :names_bank)

      # The try of +reader+ on a piece of +piece_bytes+ bytes, or a refusal in plain words.
      def self.try(reader, piece_bytes)
        refuse_not_callable!(reader)
        names = []
        bytes = PieceBytes.new(piece_bytes) { Probe.new }
        pose = PoseValues.new do |name|
          names << name unless names.include?(name)
          Probe.new
        end
        answer = answer_of(reader, bytes, pose)
        refuse_bad_parts!(answer)
        Tried.new(pose_names: names.freeze, names_bank: !answer.bank.equal?(0))
      end

      # The piece +reader+ reads (a FrameRecord::Piece), its bytes handed by the block and the
      # pose's values by +pose+ (a Hash, or a block given the name). Each part is a number in the
      # build that holds the pack, and a game's value in the unpacking.
      def self.piece(reader, piece_bytes, pose, &byte)
        values = pose.is_a?(Hash) ? PoseValues.new { |name| pose.fetch(name) } : PoseValues.new(&pose)
        answer = answer_of(reader, PieceBytes.new(piece_bytes, &byte), values)
        refuse_bad_parts!(answer)
        answer.record
      end

      def self.answer_of(reader, bytes, pose)
        answer = reader.arity == 1 ? reader.call(bytes) : reader.call(bytes, pose)
        return answer if answer.is_a?(FrameLayout::Piece)

        raise ArgumentError, "A frame layout's piece: reader must give back a VBlank::Original::FrameLayout::Piece, " \
                             "like `FrameLayout::Piece.new(x: bytes.signed(0), y: bytes.signed(1), tile: bytes[2])`. " \
                             "It gave back #{answer.class}."
      end

      def self.refuse_not_callable!(reader)
        return if reader.respond_to?(:call) && reader.respond_to?(:arity) && [1, 2].include?(reader.arity)

        raise ArgumentError, "A frame layout's piece: is a reader of one piece, like `piece: ->(bytes, pose) { ... }`. " \
                             "It takes the piece's bytes, and the pose's values where it reads some. Got #{reader.inspect}."
      end

      PARTS_OF_ONE_OR_TWO = %i[mirrored upside_down].freeze

      def self.refuse_bad_parts!(answer)
        answer.to_h.each do |part, value|
          next if value.is_a?(Integer) || value.is_a?(Probe) || value.is_a?(DSL::Value)
          next if value.nil? && part == :row_step
          next if [true, false].include?(value) && PARTS_OF_ONE_OR_TWO.include?(part)

          raise ArgumentError, "A frame layout's piece: reader gave #{part}: #{value.inspect}. Each part of a piece is a " \
                               "whole number, worked out from the piece's bytes and the pose's values."
        end
      end
    end
  end
end
