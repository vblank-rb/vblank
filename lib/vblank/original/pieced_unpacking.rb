# frozen_string_literal: true

require "etc"

module VBlank
  module Original
    # An unpacking split for several workers. A port's routine can spend most of its time in one
    # part that does the same work over and over on things that never meet: a port that renders
    # each of its songs from a sound chip's writes, where one song never reads another. A player's
    # machine has several cores, and the routine as one program keeps one of them busy.
    #
    # The decision: the game declares its
    # pieces, and VBlank never works out by itself what may run side by side. A slot is declared in
    # pieces (`slots.samples :music, count: rooms.sum, pieces: rooms`), and a part of the routine
    # given as many pieces writes it a piece at a time (`slots.fill_from_copy :music, pieces: 27 do
    # |copy, pack, release, song| ... end`, `pack[:music].piece(song)[i] = sample`). Its block is
    # built once, handed the piece's number as a game value, which the program reads as it runs:
    # so the part's code is in every program once, as a part that loops over its pieces itself
    # is, and costs no more to build, to write out or to play than it did. What makes a piece safe
    # to make on its own is checked as the routine is built, and refused in plain words
    # (UnpackingPartBuilding, Builder::DataPacks):
    #
    # - a part in pieces writes only its own piece: not a whole slot, not another piece's number;
    # - a part in pieces reads only the copy and its own piece, never a slot another part writes;
    # - no part but the one that writes a slot in pieces reads it, and one part writes it;
    # - a part's pieces: and the piece count of each slot it writes are the same;
    # - no frame of a sprite reads a slot in pieces (the frames are written after every slot).
    #
    # What the checks cannot see is what a piece's Ruby shares with another piece's as the game is
    # built, or a variable one piece leaves for the next: a piece must set each variable before it
    # reads it. Each piece is played on its own here, so a piece that leans on the last one's
    # numbers makes a different pack. The test of a port's own pack (one worker against several)
    # finds that.
    #
    # How it runs. The whole routine is one program, a part in pieces a loop over its pieces
    # (Builder::DataPacks#unpacking_program): every build that makes the pack here, every test, and
    # a shell that unpacks on one worker as it always did (the desktop program's, a Ruby script's)
    # play that. A shell that can unpack on workers (Live::Shell, the web page) plays the split
    # instead, on as many as it has, one too, so it holds each part's code once: #main, the parts
    # not in pieces as one program, and each piece on its own (#pieces), a program for each part
    # in pieces (#part_programs) playing the one piece its start file names after the copy
    # (Piece#start_file) and holding that piece's bytes alone. The pieces are
    # handed out from a queue, the most work first (#queue_order), so the longest is not left to
    # start last. Once all have ended the pack is #main's bytes with each piece's copied over its
    # places, in the order the pieces are declared (#join), and the fault a run stops on is the
    # first one, #main's and then the pieces' in their order (ShellFacts::PiecePlan): a part not in
    # pieces declared after a part in pieces is in #main, so where both go wrong the split names
    # #main's fault and the whole routine the piece's, and the build stops either way. A shell's
    # bar adds up what every worker has done (ShellFacts::PiecePlan#bar_width).
    #
    # The number of workers is the player's machine's to choose, never the game's: Live::Shell and
    # the web page take it as a setting (`--unpack-workers`, #worker_count), one a processor unless
    # told otherwise.
    #
    # The programs are built when first asked for (#programs). What a runtime is told of the split
    # (#plan) follows from the slots and the pieces alone, so a shell whose runtime plays the whole
    # routine (the desktop program's, a Ruby script's) is built with no more programs than before.
    class PiecedUnpacking
      # One piece: the +part+ that writes it, its +number+ in that part (0 first), the +program+
      # that plays it (its place in #programs), and +places+, where in the pack's list each piece of
      # a slot the program writes is copied (each a Place, in the order the program's list holds
      # them, from its first byte). +work+ is what its bytes cost to make (Slot#cost), its share of a
      # shell's bar.
      #
      # A part's program names the whole pack's slots, so a fault it meets names the slot by its
      # number in the pack, as the whole routine's does.
      Piece = Data.define(:part, :number, :program, :places, :work) do
        # How many bytes of the program's list are the piece's.
        def byte_size = places.sum(&:size)

        # The file the piece's program is handed as it starts (ShellFacts.piece_start_file).
        def start_file(copy) = ShellFacts.piece_start_file(copy, number)
      end

      # +size+ bytes of the pack's list from +at+ on.
      Place = Data.define(:at, :size)

      # +slots+ are the whole pack's, in its order; +pieces+ each a Piece; +part_count+ how many
      # parts are in pieces. +make_programs+ builds #programs when they are first asked for.
      def initialize(slots:, pieces:, part_count:, make_programs:)
        @slots = slots
        @pieces = pieces
        @part_count = part_count
        @make_programs = make_programs
      end

      attr_reader :slots, :pieces

      # The workers an unpacking plays on: +asked+, or one a processor of this machine where it is
      # nil, never more than it has processors, and one at least.
      def self.worker_count(asked = nil, processors: Etc.nprocessors)
        return processors if asked.nil?

        unless asked.is_a?(Integer) && asked.positive?
          raise ArgumentError, "The unpacking was asked for #{asked.inspect} workers. Give a whole number, 1 or more."
        end

        [asked, processors].min
      end

      # Every program a worker plays, each an Unpacking: #main first, then each part in pieces'
      # in the order declared, one program a part, which names the whole pack's slots.
      def programs = @programs ||= @make_programs.call

      # The parts not in pieces, as one program.
      def main = programs.first

      # Piece +piece+ (a Piece) of the split, ready to play on +copy+: its part's program, handed
      # the piece's start file.
      def piece_unpacking(piece, copy) = programs.fetch(piece.program).with(copy_bytes: piece.start_file(copy))

      # The pieces' numbers in #pieces in the order a queue hands them out: the most work first,
      # and pieces of equal work in the order declared.
      def queue_order = pieces.each_index.sort_by { |index| [-pieces.fetch(index).work, index] }

      # The pack's list of bytes: +main_bytes+ (what #main wrote, a binary String) with each piece's
      # bytes (+piece_bytes+, a String for each of #pieces in their order) copied over its places,
      # in the order the pieces are declared (ShellFacts::PiecePlan#join, which a runtime plays).
      def join(main_bytes, piece_bytes) = plan.join(main_bytes, piece_bytes)

      # How many #programs there are, known without building them: #main and one a part in pieces.
      def program_count = 1 + @part_count

      # The split as a runtime plays it (ShellFacts::PiecePlan): what is told to every runtime of a
      # shell. +first_program+ is where #main is in the runtime's list of worker programs, each
      # part's program after it in order (#programs).
      def plan(first_program = 0)
        main_slots = slots.reject(&:pieced?)
        main_work = main_slots.sum { |slot| slot.byte_size * slot.cost }
        planned = pieces.map do |piece|
          ShellFacts::PlannedPiece.new(program: first_program + piece.program, number: piece.number,
                                       places: piece.places.map { |place| [place.at, place.size] }, bytes: piece.byte_size,
                                       work: piece.work)
        end
        ShellFacts::PiecePlan.new(main: first_program, main_bytes: main_slots.sum(&:byte_size), main_work: main_work,
                                  whole_work: main_work + pieces.sum(&:work), queue: queue_order, pieces: planned)
      end
    end
  end
end
