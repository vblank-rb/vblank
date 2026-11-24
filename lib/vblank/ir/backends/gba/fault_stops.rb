# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # Where the game stops when a step finds what the interpreter stops on: a push onto a full
        # list (Reference#exec_list_push) or a full pool told to stop (Reference#exec_stop_full).
        #
        # ### Out of line
        #
        # A push that fits is the common case, run every pass, and the test it makes stays one
        # compare and one branch not taken. What the stop does — keep what went wrong and stop —
        # is written after the routine the step is in (#later, #emit_pending), so the branch goes
        # there only when the list is full. It stays inside the routine's span, so a routine
        # copied into the quick memory takes its stops with it and its jumps reach them. A routine
        # that pushes onto one list in several places has one stop for it.
        #
        # ### What it keeps
        #
        # A stop hands what it knows to the routine for its kind (#emit_fault_routine), which
        # writes the four numbers every console's runtime keeps (Backends::CartridgeFaults;
        # CartridgeHeadlessRun#fault_message) to the fault record: what went wrong, the place of
        # the list it is about, and the two numbers that say how. Then the game stops: a checked
        # build through its bookkeeping (PassBookkeeping#emit_went_wrong), which shows the last
        # picture and marks the end; a cartridge for a player as `halt` stops, its sprites put
        # back and the screen and sound left running. A reader finds the record by the build
        # record's runtime places (Diagnostics::AdvanceReading#went_wrong).
        class FaultStops
          include Console::Hardware

          Frame = Runtime::Frame

          # A push onto a full list: r1 holds its capacity and r3 its place.
          LIST_FULL_ROUTINE = :__list_full_stop
          # A full pool told to stop: r2 holds its capacity and r3 the stop's number.
          STOP_FULL_ROUTINE = :__stop_full_stop

          # The steps that stop the game through here.
          STOPPING_KINDS = %i[list_push stop_full].freeze

          # +bookkeeping+ is a checked build's (PassBookkeeping), nil for a player's. +placement+
          # says whether the code being written runs from the quick memory.
          def initialize(emitter:, memory:, bookkeeping:, placement:)
            @emitter = emitter
            @memory = memory
            @bookkeeping = bookkeeping
            @placement = placement
            @pending = {}
            @wanted = false
          end

          # Whether +program+ has a step that can stop this way, asked before anything is written,
          # so the record is placed and cleared at power-on only in a program that can use it.
          def prepare(program)
            @wanted = program.walk.any? { |node| STOPPING_KINDS.include?(node.kind) }
            @stop_numbers = Nodes::StopFull.numbers(program)
          end

          # The record cleared, in a cartridge for a player that can stop: the console's memory is
          # not cleared at power-on, and a reader takes what went wrong from it. A checked build's
          # bookkeeping clears its own (PassBookkeeping#emit_at_power_on).
          def emit_at_power_on
            return if @bookkeeping || !@wanted

            @emitter.emit_number(ACC, 0)
            @emitter.emit_number(ADDR, fault_at)
            (Frame::FAULT_BYTES / 4).times { |k| @emitter.emit(ASM.str_offset(ACC, ADDR, k * 4)) }
          end

          # The label a push onto the full list kept at +place+ jumps to, its capacity in r1. One
          # stop serves every push onto that list in the routine being written.
          def list_full_stop(place)
            later([:list_full, place]) do
              @emitter.emit_number(3, place)
              emit_jump(LIST_FULL_ROUTINE)
            end
          end

          # A full pool told to stop (Nodes::StopFull): its capacity, and the number its words are
          # found by (Nodes::StopFull.words).
          def emit_stop_full(node)
            @emitter.emit_number(2, node.capacity)
            @emitter.emit_number(3, @stop_numbers.fetch(Nodes::StopFull.key(node)))
            emit_jump(STOP_FULL_ROUTINE)
          end

          # A label for code that runs only when a step stops the game: the block writes it,
          # out of line, when the routine being written ends (#emit_pending). Asked again with the
          # same +key+ before then, the same label.
          def later(key = Object.new, &body)
            (@pending[key] ||= [@emitter.gensym, body]).first
          end

          # Whether a stop is waiting to be written.
          def pending? = !@pending.empty?

          # The stops the routine just written jumps to, after its last instruction.
          def emit_pending
            until @pending.empty?
              _key, (label, body) = @pending.shift
              @emitter.place_label(label)
              body.call
            end
          end

          # The routines every stop jumps to, written once at the end of the program, where a
          # program with no stop writes nothing. Each puts its numbers where the record keeps them
          # (r0 what went wrong, r1 the list's place, r2 and r3 how), and they end alike.
          def emit_fault_routine(&sprites_back)
            return unless @wanted

            raise LoweringError, "a stop was left unwritten after its routine" if pending?

            done = @emitter.gensym
            @emitter.place_label(LIST_FULL_ROUTINE)
            @emitter.emit(ASM.mov_reg(2, 1))                   # the capacity
            @emitter.emit(ASM.mov_reg(1, 3))                   # the list's place
            @emitter.emit_number(3, 0)
            @emitter.emit_number(ACC, Frame::LIST_FULL)
            @emitter.emit_branch(:b, done)
            @emitter.place_label(STOP_FULL_ROUTINE)
            @emitter.emit_number(1, 0)                         # no list's place: its number names it
            @emitter.emit_number(ACC, Frame::STOP_FULL)
            @emitter.place_label(done)
            @emitter.emit_number(ADDR, fault_at)
            [ACC, 1, 2, 3].each_with_index { |reg, k| @emitter.emit(ASM.str_offset(reg, ADDR, k * 4)) }
            return @bookkeeping.emit_went_wrong if @bookkeeping

            sprites_back&.call
            @emitter.emit(ASM.loop_forever)
          end

          # Where the fault record is, for the reader, in a cartridge for a player that can stop;
          # a checked build's bookkeeping names it with the rest of its words.
          def places
            return {} if @bookkeeping || !@wanted

            { Frame::FAULT => fault_at }
          end

          private

          # A jump to +routine+, which is in the cartridge: one branch from code there, its whole
          # address from code that runs in the quick memory (Placement#emit_jump_to_cold_routine).
          def emit_jump(routine)
            raise LoweringError, "a stop was written in a program #prepare found none in" unless @wanted

            @placement.emit_jump_to_cold_routine(routine)
          end

          # Where what went wrong is kept: the checked build's record, or one of its own.
          def fault_at = @fault_at ||= @bookkeeping ? @bookkeeping.fault_at : @memory.alloc(Frame::FAULT_BYTES)
        end
      end
    end
  end
end
