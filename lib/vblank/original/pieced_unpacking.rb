# frozen_string_literal: true

require "etc"

module VBlank
  module Original
    # AN UNPACKING SPLIT FOR SEVERAL WORKERS. A port's routine can spend most of its time in one
    # part that does the same work over and over on things that never meet: Wolfenstein renders
    # each of its songs from the AdLib chip's writes, and one song never reads another. A player's
    # machine has several cores, and the routine as one program keeps one of them busy.
    #
    # THE DECISION, agreed with the operator and with the Wolfenstein port: THE GAME DECLARES ITS
    # PIECES, and VBlank never works out by itself what may run side by side. A slot is declared in
    # pieces (`slots.samples :music, count: rooms.sum, pieces: rooms`), and a part of the routine
    # given as many pieces writes it a piece at a time (`slots.fill_from_copy :music, pieces: 27 do
    # |copy, pack, release, song| ... end`, its block built once for each piece, `pack[:music]
    # .piece(song)[i] = sample`). What makes a piece safe to make on its own is checked as the
    # routine is built, and refused in plain words (UnpackingPartBuilding, Builder::DataPacks):
    #
    # - a part in pieces writes only its own piece: not a whole slot, not another piece's number;
    # - a part in pieces reads only the copy and its own piece, never a slot another part writes;
    # - no part but the one that writes a slot in pieces reads it, and one part writes it;
    # - a part's pieces: and the piece count of each slot it writes are the same;
    # - no frame of a sprite reads a slot in pieces (the frames are written after every slot).
    #
    # What the checks cannot see is what a piece's Ruby shares with another piece's as the game is
    # built, or a variable one piece leaves for the next: a piece must set each variable before it
    # reads it. Each piece is a program of its own here, so a piece that leans on the last one's
    # numbers makes a different pack. The test of a port's own pack (one worker against several)
    # finds that.
    #
    # HOW IT RUNS. One worker plays the whole routine as one program, exactly as before pieces
    # (Builder::DataPacks#unpacking_program): every build that makes the pack here, and every test,
    # plays that. Several workers play #main, the parts not in pieces as one program, and each
    # piece as a program of its own (#pieces), which holds its piece's bytes alone. The pieces are
    # handed out from a queue, the most work first (#queue_order), so the longest is not left to
    # start last. Once all have ended the pack is #main's bytes with each piece's copied over its
    # places, in the order the pieces are declared (#join), and the fault a run stops on is the
    # first one, #main's and then the pieces' in their order (#first_fault). A shell's bar adds up
    # what every worker has done (#bar_width).
    #
    # The number of workers is the player's machine's to choose, never the game's: Live::Shell and
    # the web page take it as a setting (`--unpack-workers`, #worker_count), one a processor unless
    # told otherwise.
    #
    # +slots+ are the whole pack's, in its order. +main+ is an Unpacking; each of +pieces+ a Piece.
    PiecedUnpacking = Data.define(:slots, :main, :pieces)

    class PiecedUnpacking
      # One piece's program: the +part+ that writes it, its +number+ in that part (0 first), its
      # Unpacking, whose list of bytes holds the piece of each slot it writes, one after another,
      # and +places+, where in the pack's list each of those is copied (each a Place, in the order
      # the program holds them). +work+ is what its bytes cost to make (Slot#cost), its share of a
      # shell's bar.
      #
      # The piece's Unpacking names the whole pack's slots, so a fault it meets names the slot by its
      # number in the pack, as the whole routine's does.
      Piece = Data.define(:part, :number, :unpacking, :places, :work) do
        # How many bytes the piece's program holds.
        def byte_size = places.sum(&:size)
      end

      # +size+ bytes of the pack's list from +at+ on.
      Place = Data.define(:at, :size)

      # The workers an unpacking plays on: +asked+, or one a processor of this machine where it is
      # nil, never more than it has processors, and one at least.
      def self.worker_count(asked = nil, processors: Etc.nprocessors)
        return processors if asked.nil?

        unless asked.is_a?(Integer) && asked.positive?
          raise ArgumentError, "The unpacking was asked for #{asked.inspect} workers. Give a whole number, 1 or more."
        end

        [asked, processors].min
      end

      # Every program a worker plays: #main first, then each piece in the order declared.
      def programs = [main, *pieces.map(&:unpacking)]

      # The pieces' numbers in #pieces in the order a queue hands them out: the most work first,
      # and pieces of equal work in the order declared.
      def queue_order = pieces.each_index.sort_by { |index| [-pieces.fetch(index).work, index] }

      # The pack's list of bytes: +main_bytes+ (what #main wrote, a binary String) with each piece's
      # bytes (+piece_bytes+, a String for each of #pieces in their order) copied over its places,
      # in the order the pieces are declared (ShellFacts::PiecePlan#join, which a runtime plays).
      def join(main_bytes, piece_bytes) = plan.join(main_bytes, piece_bytes)

      # The fault a run of every program stops on: the first of +faults+ (one for each of #programs,
      # in their order, each nil where nothing went wrong), #main's before the pieces'. A part not
      # in pieces written after the part in pieces is in #main, so where it and a piece both go
      # wrong this names #main's, where the whole routine would name the piece's: the build stops
      # either way.
      def first_fault(faults) = faults.compact.first

      # How wide a shell's bar is, of +across+ pixels, once each of #programs has written so many
      # bytes (+done+, a count for each, in their order, from its BYTES_DONE): each held to its
      # program's size and weighed by its work, so a slot whose bytes cost more moves the bar
      # further a byte (ShellFacts::PiecePlan#bar_width).
      def bar_width(done, across) = plan.bar_width(done, across)

      # The split as a runtime plays it (ShellFacts::PiecePlan): what is told to every runtime of a
      # shell. +first_program+ is where #main is in the runtime's list of worker programs, each
      # piece's program after it in order.
      def plan(first_program = 0)
        main_slots = slots.reject(&:pieced?)
        main_work = main_slots.sum { |slot| slot.byte_size * slot.cost }
        planned = pieces.each_with_index.map do |piece, index|
          ShellFacts::PlannedPiece.new(program: first_program + 1 + index, places: piece.places.map { |place| [place.at, place.size] },
                                       bytes: piece.byte_size, work: piece.work)
        end
        ShellFacts::PiecePlan.new(main: first_program, main_bytes: main_slots.sum(&:byte_size), main_work: main_work,
                                  whole_work: main_work + pieces.sum(&:work), queue: queue_order, pieces: planned)
      end
    end
  end
end
