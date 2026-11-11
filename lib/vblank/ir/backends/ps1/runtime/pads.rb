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
              emit_buttons_of_bytes(asm, "rt_buttons_now")
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

            # EVERY FRAME, THE PAD IS ASKED WITHOUT WAITING FOR IT. A byte takes the port about a thousand of
            # the processor's cycles to send, and the conversation is five: read by sending each and going
            # round a loop until its answer came (rt_buttons_now, which power-on still does, once), the
            # frame's interrupt held the game for a hundredth of every frame. The pad says when it has
            # taken a byte, by its acknowledge line, and the port can raise an interrupt of its own on that
            # (IRQ7; JOY_CTRL bit 12 turns it on, bit 4 lets the next one come). So:
            #
            #   rt_pad_read          in the frame's interrupt: the conversation begun last frame is finished
            #                        (rt_pad_finish) and a new one begun, its first byte sent
            #   rt_pad_acknowledged  in the pad's interrupt: the answer to the byte sent is read, and the
            #                        next byte sent
            #   rt_pad_finish        the last byte's answer taken, and the buttons made of the two bytes:
            #                        held now, and every one that went down since the frame before added to
            #                        those pressed during the pass. THE LAST BYTE IS NOT ACKNOWLEDGED, so no
            #                        interrupt says it came: the port's own flag does
            #   rt_pad_await         as a pass's wait ends: waits for the conversation the blank began,
            #                        and finishes it, so the pass has that frame's buttons, as before
            #
            # Frame::PAD_STEP counts the bytes sent, nought when no conversation is under way. A game whose
            # pass takes several frames is where this is felt: the frames in the middle of it no longer
            # stop for the pad. With no pad in the port no byte is acknowledged, the conversation stays at
            # its first, and it is finished as no buttons held.
            def emit_pad_read(asm, at)
              h = Console::PS1Hardware
              emit_pad_begin(asm, at, h)
              emit_pad_acknowledged(asm, at, h)
              emit_pad_finish(asm, at, h)
              emit_pad_await(asm, at, h)
            end

            # JOY_CTRL through a conversation: the transmitter on, the first port selected, an interrupt
            # as the pad acknowledges; and the bit that lets the next such interrupt come.
            CONVERSING = SELECT_FIRST_PORT | (1 << 12)
            NEXT_ACKNOWLEDGE = 1 << 4

            def emit_pad_begin(asm, at, h)
              asm.label("rt_pad_read")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.jal("rt_pad_finish")
              asm.lui(:t1, h::IO >> 16)
              asm.li(:t0, CONVERSING | NEXT_ACKNOWLEDGE)
              asm.sh(:t0, h::JOY_CTRL & 0xFFFF, :t1)
              # The port takes a byte in only once the one before was read, so whatever is left is read
              # first and thrown away.
              asm.lbu(:t0, h::JOY_DATA & 0xFFFF, :t1)
              asm.li(:t0, 0xFF) # the first button byte, none pressed until the pad reports it
              asm.sw(:t0, at.call(Frame::PAD_BYTE), :gp)
              asm.li(:t0, SENT.first)
              asm.sb(:t0, h::JOY_DATA & 0xFFFF, :t1)
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(Frame::PAD_STEP), :gp)
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
            end

            # The pad acknowledged byte PAD_STEP of the conversation: its answer is read (the fourth's is
            # the first button byte), and the next byte sent. Nothing is read where no conversation waits
            # for an acknowledge: none under way, or the last byte sent, whose answer rt_pad_finish takes.
            def emit_pad_acknowledged(asm, at, h)
              asm.label("rt_pad_acknowledged")
              asm.lui(:t1, h::IO >> 16)
              asm.li(:t0, CONVERSING | NEXT_ACKNOWLEDGE)
              asm.sh(:t0, h::JOY_CTRL & 0xFFFF, :t1)
              asm.li(:t0, ~h::IRQ_PAD & 0xFFFF_FFFF)
              asm.sw(:t0, h::I_STAT & 0xFFFF, :t1)
              asm.lw(:t2, at.call(Frame::PAD_STEP), :gp)
              asm.addiu(:t0, :t2, -1)
              asm.sltiu(:t0, :t0, SENT.size - 1)
              asm.beq(:t0, :zero, "rt_pad_acknowledged_done")
              asm.lbu(:t3, h::JOY_DATA & 0xFFFF, :t1)
              asm.li(:t0, SENT.size - 1)
              asm.bne(:t2, :t0, "rt_pad_acknowledged_next")
              asm.sw(:t3, at.call(Frame::PAD_BYTE), :gp)
              asm.label("rt_pad_acknowledged_next")
              # The second byte asks for the buttons, and the rest are noughts (SENT).
              asm.li(:t0, 1)
              asm.bne(:t2, :t0, "rt_pad_acknowledged_send") { asm.move(:t3, :zero) }
              asm.li(:t3, SENT[1])
              asm.label("rt_pad_acknowledged_send")
              asm.sb(:t3, h::JOY_DATA & 0xFFFF, :t1)
              asm.addiu(:t2, :t2, 1)
              asm.sw(:t2, at.call(Frame::PAD_STEP), :gp)
              asm.label("rt_pad_acknowledged_done")
              asm.jr(:ra)
            end

            # The conversation under way finished, with the interrupts off: the buttons it read, or none
            # where it did not reach its end. Nothing where none is under way.
            def emit_pad_finish(asm, at, h)
              asm.label("rt_pad_finish")
              asm.lw(:t2, at.call(Frame::PAD_STEP), :gp)
              asm.beq(:t2, :zero, "rt_pad_finish_done")
              asm.lui(:t1, h::IO >> 16)
              asm.li(:t5, 0xFFFF) # the two button bytes, none pressed
              asm.addiu(:t0, :t2, -SENT.size)
              asm.bne(:t0, :zero, "rt_pad_finish_none")
              asm.lhu(:t0, h::JOY_STAT & 0xFFFF, :t1)
              asm.andi(:t0, :t0, RECEIVED)
              asm.beq(:t0, :zero, "rt_pad_finish_none")
              asm.lbu(:t3, h::JOY_DATA & 0xFFFF, :t1)
              asm.lw(:t4, at.call(Frame::PAD_BYTE), :gp)
              asm.sll(:t3, :t3, 8)
              asm.or(:t5, :t3, :t4)
              asm.label("rt_pad_finish_none")
              asm.sh(:zero, h::JOY_CTRL & 0xFFFF, :t1)
              asm.sw(:zero, at.call(Frame::PAD_STEP), :gp)
              emit_buttons_of_bytes(asm, "rt_pad_finish")
              asm.lw(:t0, at.call(Frame::SEEN), :gp)
              asm.lw(:t1, at.call(Frame::PAD_PRESSED), :gp)
              asm.nor(:t0, :t0, :zero)
              asm.and(:t0, :t0, :v0)
              asm.or(:t1, :t1, :t0)
              asm.sw(:t1, at.call(Frame::PAD_PRESSED), :gp)
              asm.sw(:v0, at.call(Frame::PAD_HELD), :gp)
              asm.sw(:v0, at.call(Frame::SEEN), :gp)
              asm.label("rt_pad_finish_done")
              asm.jr(:ra)
            end

            # Waits until the conversation under way has had its last answer, or gives up as a wait for
            # a pad does, and finishes it. The waiting's labels are named as the wait for the screen is,
            # so a profile counts it as time the game had nothing to do.
            def emit_pad_await(asm, at, h)
              asm.label("rt_pad_await")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.lui(:t1, h::IO >> 16)
              asm.li(:t2, PATIENCE)
              asm.label("rt_sleep_until_vblank_pad")
              asm.lw(:t0, at.call(Frame::PAD_STEP), :gp)
              asm.beq(:t0, :zero, "rt_pad_awaited")
              asm.addiu(:t0, :t0, -SENT.size)
              asm.bne(:t0, :zero, "rt_sleep_until_vblank_pad_not_yet")
              asm.lhu(:t0, h::JOY_STAT & 0xFFFF, :t1)
              asm.andi(:t0, :t0, RECEIVED)
              asm.bne(:t0, :zero, "rt_pad_awaited")
              asm.label("rt_sleep_until_vblank_pad_not_yet")
              asm.addiu(:t2, :t2, -1)
              asm.bne(:t2, :zero, "rt_sleep_until_vblank_pad")
              asm.label("rt_pad_awaited")
              asm.mtc0(:zero, R3000::COP0_STATUS)
              asm.jal("rt_pad_finish")
              asm.li(:t0, h::SR_INTERRUPTS_ON)
              asm.mtc0(:t0, R3000::COP0_STATUS)
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
            end

            # v0 = the buttons of the two button bytes in t5 (a pressed button reading 0), a bit each in
            # IR::Buttons's order. +tag+ starts its labels. Changes t0 and t5.
            def emit_buttons_of_bytes(asm, tag)
              asm.nor(:t5, :t5, :zero) # a pressed button is a 1 from here on
              asm.move(:v0, :zero)
              BITS.each do |name, (which, bit)|
                asm.andi(:t0, :t5, 1 << ((which * 8) + bit))
                asm.beq(:t0, :zero, "#{tag}_not_#{name}")
                asm.ori(:v0, :v0, 1 << Buttons::NAMES.index(name))
                asm.label("#{tag}_not_#{name}")
              end
            end
          end
        end
      end
    end
  end
end
