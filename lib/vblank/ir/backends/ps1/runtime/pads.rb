# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE PAD, read by hand through the serial port the pads and memory cards share (SIO0), with no
          # help from the BIOS (psx-spx, "Controllers and Memory Cards").
          #
          # A read is a short conversation, a byte each way at a time: the console selects the first port,
          # sends 01h ("a pad, please"), then 42h ("your buttons"), and the pad answers with what kind it is
          # (41h for a digital pad), then 5Ah ("here they come"), then the buttons, two bytes of them, a
          # pressed button reading 0. Each byte is written to the port's data register, and the byte that
          # came back in the same moment is read once the port signals it has one. A pad answers each byte but
          # the last by pulling its acknowledge line low for a moment, and the next byte must wait for that,
          # or the pad never hears it: the port's status shows when the line is low. With no pad in the port
          # nothing comes back, so every wait gives up after a while, and the buttons read as none held.
          #
          # The two button bytes, bit by bit, turned into IR::Buttons's order: the first is Select, L3, R3,
          # Start, Up, Right, Down, Left; the second L2, R2, L1, R1, Triangle, Circle, Cross, Square. A game
          # names the PlayStation's buttons by the shared names (Console::PS1Answers): :a is Cross, :b
          # Circle, :x Triangle, :y Square, :l L1 and :r R1.
          module Pads
            # Each button, by its name in IR::Buttons, as [which byte of the two, which bit].
            BITS = Ractor.make_shareable({ select: [0, 0], start: [0, 3], up: [0, 4], right: [0, 5], down: [0, 6], left: [0, 7],
                                           l: [1, 2], r: [1, 3], x: [1, 4], b: [1, 5], a: [1, 6], y: [1, 7] })

            # JOY_CTRL: the transmitter on, and the first port selected (its /JOY line low).
            SELECT_FIRST_PORT = 0x0003
            # JOY_MODE: a baud reload factor of 1, 8 bits a byte, no parity. JOY_BAUD: 250 kHz.
            MODE = 0x000D
            BAUD = 0x0088
            # JOY_STAT: a byte has come back; and the acknowledge line is low.
            RECEIVED = 1 << 1
            ACKNOWLEDGED = 1 << 7
            # How many times a wait looks before it gives up: far longer than a pad ever takes.
            PATIENCE = 2000

            # The conversation, the bytes sent in order.
            SENT = [0x01, 0x42, 0x00, 0x00, 0x00].freeze

            module_function

            def emit(asm, memory)
              h = Console::PS1Hardware
              at = ->(name) { Runtime.at(memory, name) }
              emit_start(asm, h)
              emit_buttons_now(asm, h)
              emit_exchange(asm, h)
              emit_pad_read(asm, at)
            end

            # rt_pads_start: the port set to the speed and the shape of byte a pad talks in.
            def emit_start(asm, h)
              asm.label("rt_pads_start")
              asm.lui(:t1, h::IO >> 16)
              asm.sh(:zero, h::JOY_CTRL & 0xFFFF, :t1)
              asm.li(:t0, MODE)
              asm.sh(:t0, h::JOY_MODE & 0xFFFF, :t1)
              asm.li(:t0, BAUD)
              asm.jr(:ra) { asm.sh(:t0, h::JOY_BAUD & 0xFFFF, :t1) }
            end

            # rt_buttons_now: v0 = the buttons held on the first pad now, a bit each in IR::Buttons's
            # order. Nought when no pad answers. Changes t0 to t5 and a0.
            def emit_buttons_now(asm, h)
              asm.label("rt_buttons_now")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.lui(:t1, h::IO >> 16)
              asm.li(:t0, SELECT_FIRST_PORT)
              asm.sh(:t0, h::JOY_CTRL & 0xFFFF, :t1)
              asm.li(:t5, 0xFFFF) # the two button bytes, none pressed until the pad reports them
              # The port takes a byte in only once the one before was read, so whatever is left from the
              # last conversation is read first and thrown away.
              asm.lbu(:t0, h::JOY_DATA & 0xFFFF, :t1)
              SENT.each_with_index do |byte, i|
                asm.li(:a0, byte)
                asm.jal("rt_pad_exchange")
                asm.bne(:v1, :zero, "rt_buttons_now_no_pad")
                last = i == SENT.size - 1
                if i == 3
                  asm.andi(:t5, :v0, 0xFF)
                elsif last
                  asm.sll(:t0, :v0, 8)
                  asm.or(:t5, :t5, :t0)
                end
                next if last

                asm.jal("rt_pad_acknowledge")
                asm.bne(:v1, :zero, "rt_buttons_now_no_pad")
              end
              asm.b("rt_buttons_now_answered")
              asm.label("rt_buttons_now_no_pad")
              asm.li(:t5, 0xFFFF)
              asm.label("rt_buttons_now_answered")
              asm.lui(:t1, h::IO >> 16)
              asm.sh(:zero, h::JOY_CTRL & 0xFFFF, :t1)
              asm.nor(:t5, :t5, :zero) # a pressed button is a 1 from here on
              asm.move(:v0, :zero)
              BITS.each do |name, (which, bit)|
                asm.andi(:t0, :t5, 1 << ((which * 8) + bit))
                asm.beq(:t0, :zero, "rt_buttons_now_not_#{name}")
                asm.ori(:v0, :v0, 1 << Buttons::NAMES.index(name))
                asm.label("rt_buttons_now_not_#{name}")
              end
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
            end

            # rt_pad_exchange: the byte in a0 sent, and v0 = the byte that came back; v1 = 0, or 1 when
            # nothing came back in time. rt_pad_acknowledge: waits for the pad to acknowledge the byte, v1
            # as before.
            def emit_exchange(asm, h)
              asm.label("rt_pad_exchange")
              asm.lui(:t1, h::IO >> 16)
              asm.sb(:a0, h::JOY_DATA & 0xFFFF, :t1)
              asm.li(:t2, PATIENCE)
              asm.label("rt_pad_exchange_wait")
              asm.lhu(:t0, h::JOY_STAT & 0xFFFF, :t1)
              asm.andi(:t0, :t0, RECEIVED)
              asm.bne(:t0, :zero, "rt_pad_exchange_came")
              asm.addiu(:t2, :t2, -1)
              asm.bne(:t2, :zero, "rt_pad_exchange_wait")
              asm.jr(:ra) { asm.li(:v1, 1) }
              asm.label("rt_pad_exchange_came")
              asm.lbu(:v0, h::JOY_DATA & 0xFFFF, :t1)
              asm.jr(:ra) { asm.move(:v1, :zero) }

              asm.label("rt_pad_acknowledge")
              asm.li(:t2, PATIENCE)
              asm.label("rt_pad_acknowledge_wait")
              asm.lhu(:t0, h::JOY_STAT & 0xFFFF, :t1)
              asm.andi(:t0, :t0, ACKNOWLEDGED)
              asm.bne(:t0, :zero, "rt_pad_acknowledge_came")
              asm.addiu(:t2, :t2, -1)
              asm.bne(:t2, :zero, "rt_pad_acknowledge_wait")
              asm.jr(:ra) { asm.li(:v1, 1) }
              asm.label("rt_pad_acknowledge_came")
              asm.jr(:ra) { asm.move(:v1, :zero) }
            end

            # In the interrupt, every frame: the buttons held now, and every one that went down since the
            # frame before added to those pressed during the pass.
            def emit_pad_read(asm, at)
              asm.label("rt_pad_read")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.jal("rt_buttons_now")
              asm.lw(:t0, at.call(Frame::SEEN), :gp)
              asm.lw(:t1, at.call(Frame::PAD_PRESSED), :gp)
              asm.nor(:t0, :t0, :zero)
              asm.and(:t0, :t0, :v0)
              asm.or(:t1, :t1, :t0)
              asm.sw(:t1, at.call(Frame::PAD_PRESSED), :gp)
              asm.sw(:v0, at.call(Frame::PAD_HELD), :gp)
              asm.sw(:v0, at.call(Frame::SEEN), :gp)
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
            end
          end
        end
      end
    end
  end
end
