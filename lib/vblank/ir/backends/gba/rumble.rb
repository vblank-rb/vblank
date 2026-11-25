# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # The cartridge's rumble motor, for the game's `rumble` (Nodes::Rumble).
        #
        # The hardware. A cartridge with a motor takes its orders from the same four pins at the
        # bottom of the cartridge's address space that a clock chip uses (GBATEK, "GBA Cart I/O Port
        # (GPIO)", "GBA Cart Rumble"). Pin 3 is the motor: a 1 written there runs it and a 0 stops
        # it. The console may only drive a pin once the direction register says the pin is an
        # output, so the motor's bit is set there as the game starts.
        #
        # A rumble is a number of frames and a pattern of eight, one a frame (IR::Rumble). The game's
        # `rumble` only notes both. The screen's own interrupt does the rest, once for every frame
        # shown, as the interpreter does (Reference#step_motor): it turns the pattern a place, sets the
        # motor from its lowest bit, and counts a frame off; with none left it sets the motor to 0. So a
        # pass that takes two frames steps the motor twice, as the interpreter's does.
        #
        # A clock chip talks on pins 0 to 2 of the same port (GBATEK, "GBA Cart Real-Time Clock"), so
        # a cartridge carries both, as one with a tilt sensor and a motor does (GBATEK, "GBA Cart
        # Rumble"). A write to the port sets all four pins at once, so in a game with both each side
        # keeps the other's: the motor's bit is kept in MOTOR_ON, which every write of the clock's
        # adds in (ClockChip#motor_shared), and while the clock talks (TALKING) the interrupt's step
        # only notes the motor's bit, since a write then would cut into the talk. The clock's last
        # write of a talk puts the motor's bit as it stands then.
        class Rumble
          include Console::Hardware

          # What the interrupt reads and the game writes: frames still to run, and the pattern.
          LEFT = :__rumble_left
          BITS = :__rumble_bits

          # The cartridge's general-purpose port: what is on the pins, which way each points (a 1 is
          # the console driving it) and, in the pin's bit, the motor.
          PINS = 0x080000C4
          DIRECTION = 0x080000C6
          MOTOR = 8

          # The bytes put in the cartridge's data to say it carries a motor. An emulator gives a port
          # a motor only for the few real cartridges it knows by game code, so the one that checks
          # this framework's games (ruby-gba-emulator) looks for these.
          MARK = "VBLANK_RUMBLE_MOTOR_V1"
          MARK_BLOB = :__rumble_motor_mark

          # In a game that reads the clock as well: the motor's bit as the step last set it (0 or
          # MOTOR), and whether the clock is part way through a talk on the port.
          MOTOR_ON = :__rumble_motor_on
          TALKING = :__clock_talking

          STATEMENT_KINDS = %i[rumble].freeze

          def initialize(emitter:, primitives:, lowering:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @used = false
          end

          # Whether the program rumbles. Nothing is emitted for one that does not, and its bytes are
          # the same as before there was a motor.
          def used? = @used

          # Does the clock share the port (#prepare)?
          def shares_port? = @shares_port

          # Note whether the program rumbles, give the numbers their places and put the mark in the
          # cartridge's data. A game that reads the clock as well shares the port with it.
          def prepare(program, clock_used:)
            @used = program.walk.any? { |node| node.kind == :rumble }
            @shares_port = @used && clock_used
            return unless @used

            @primitives.var_addr(LEFT)
            @primitives.var_addr(BITS)
            [MOTOR_ON, TALKING].each { |name| @primitives.var_addr(name) } if @shares_port
            @emitter.data_blobs[MARK_BLOB] = MARK.b
          end

          def emit_statement(node)
            case node.kind
            when :rumble then emit_rumble(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          # The motor's pin an output, and still: at power-on, where the memory holds anything.
          def emit_at_power_on
            return unless @used

            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, LEFT)
            @primitives.store_var(ACC, BITS)
            [MOTOR_ON, TALKING].each { |name| @primitives.store_var(ACC, name) } if @shares_port
            @emitter.write_reg16(DIRECTION, MOTOR)
            @emitter.write_reg16(PINS, 0)
          end

          # `rumble frames:, pattern:` as the game runs it: the frames held to what one rumble lasts
          # (IR::Rumble.frames), and the pattern to its eight bits. The next frame shown starts it.
          #
          # Numbers written in the game are held there while building, as IR::Rumble.frames holds them.
          def emit_rumble(node)
            frames = @primitives.const_int(node.frames)
            pattern = @primitives.const_int(node.pattern)
            if frames && pattern
              @primitives.store_word_immediate(IR::Rumble.frames(frames), @primitives.var_addr(LEFT))
              @primitives.store_word_immediate(pattern & 0xFF, @primitives.var_addr(BITS))
              return
            end

            @lowering.value(node.frames)
            @emitter.emit_number(TMP, IR::Rumble::MOST_FRAMES)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit(ASM.mov_reg_cond(:gt, ACC, TMP))   # more than 16 bits hold: as many as they do
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:lt, ACC, 0))     # fewer than none: none
            @primitives.store_var(ACC, LEFT)
            @lowering.value(node.pattern)
            @emitter.emit(ASM.and_imm(ACC, ACC, 0xFF))
            @primitives.store_var(ACC, BITS)
          end

          # One frame of the motor, in the screen's interrupt. r0, r1 and r2 are saved by the console's
          # own interrupt code, and r12 holds where the variables are.
          #
          #   LEFT > 0:  LEFT -= 1; BITS = BITS turned a place right (8 bits round);
          #              pin 3 = the lowest bit of BITS
          #   LEFT = 0:  pin 3 = 0
          def emit_step
            return unless @used

            write = @emitter.gensym
            @primitives.load_var(ACC, LEFT)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, write, cond: :eq)         # none left: r0 is 0, the motor stops
            @emitter.emit(ASM.sub_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, LEFT)
            @primitives.load_var(TMP, BITS)
            @emitter.emit(ASM.lsr_imm(SPARE, TMP, 1))              # the bits one place right...
            @emitter.emit(ASM.lsl_imm(TMP, TMP, 7))                # ...and the lowest one round to the top
            @emitter.emit(ASM.orr_reg(TMP, TMP, SPARE))
            @emitter.emit(ASM.and_imm(TMP, TMP, 0xFF))
            @primitives.store_var(TMP, BITS)
            @emitter.emit(ASM.and_imm(ACC, TMP, 1))
            @emitter.emit(ASM.lsl_imm(ACC, ACC, 3))                # bit 0 of the pattern is pin 3
            @emitter.place_label(write)
            if @shares_port
              # Noted for the clock's writes; the pins are left alone while it talks.
              talking = @emitter.gensym
              @primitives.store_var(ACC, MOTOR_ON)
              @primitives.load_var(TMP, TALKING)
              @emitter.emit(ASM.cmp_imm(TMP, 0))
              @emitter.emit_branch(:bcond, talking, cond: :ne)
              emit_store_pins
              @emitter.place_label(talking)
            else
              emit_store_pins
            end
          end

          # The motor's bit in r0 onto the port.
          def emit_store_pins
            @emitter.emit_number(TMP, PINS)
            @emitter.emit(ASM.store_halfword(ACC, TMP))
          end

          # A game that halts shakes nothing more, as the interpreter's does (Reference#stop_motor).
          def emit_stop
            return unless @used

            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, LEFT)
            @primitives.store_var(ACC, MOTOR_ON) if @shares_port
            emit_store_pins
          end
        end
      end
    end
  end
end
