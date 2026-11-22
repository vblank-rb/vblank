# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # The pads, read by hand through the serial port the pads and memory cards share (SIO0), with no
          # help from the BIOS (psx-spx, "Controllers and Memory Cards").
          #
          # ### An exchange with a pad
          #
          # A read is a short exchange, a byte each way at a time: the console selects a port, sends 01h
          # ("a pad, please"), then 42h ("your buttons"), and the pad answers with what kind it is (41h for a
          # digital pad), then 5Ah ("here they come"), then the buttons, two bytes of them, a pressed button
          # reading 0. Each byte is written to the port's data register, and the byte that came back in the
          # same moment is read once the port has one. A pad answers each byte but the last by pulling its
          # acknowledge line low for a moment, and the next byte must wait for that, or the pad never hears
          # it. With no pad in the port nothing comes back, and the buttons read as none held.
          #
          # The two button bytes, bit by bit, turned into IR::Buttons's order: the first is Select, L3, R3,
          # Start, Up, Right, Down, Left; the second L2, R2, L1, R1, Triangle, Circle, Cross, Square. A game
          # names the PlayStation's buttons by the shared names (Console::PS1Answers): :a is Cross, :b
          # Circle, :x Triangle, :y Square, :l L1, :r R1, and :l2 and :r2 are L2 and R2.
          #
          # ### More players: the second port, and the Multitap
          #
          # A game for two reads the second port the same way, straight after the first: JOY_CTRL bit 13
          # chooses which port's select line goes low. A game for three or four reads Sony's Multitap
          # (SCPH-1070) there, which takes four pads. Sent 01h as the third byte, a Multitap reads all four
          # of its plugs in the next exchange (psx-spx, "Multitap"): it answers 80h in place of a pad's kind,
          # then 5Ah, then eight bytes for each plug in turn, A to D: the pad's own kind, 5Ah and its two
          # button bytes, then four more, FFh where a plug holds nothing. The console sends 42h as each
          # plug's first byte, which the tap hands that plug as its command next time. Until the tap has seen
          # that 01h it answers for its first plug alone, as a pad does, and a plain pad in the second port
          # ignores the 01h and answers as a pad: so the second player is the pad in the second port, or the
          # tap's first plug, and the third and fourth are its second and third plugs. Its fourth is not read.
          #
          # ### Read on every frame, with the game working meanwhile
          #
          # A byte takes the port about a thousand of the processor's cycles to send, and an exchange is five
          # (thirty-five with a Multitap). Each pad's acknowledge raises the port's own interrupt (IRQ7;
          # JOY_CTRL bit 12 turns it on, bit 4 lets the next one come), and the byte after it is sent from
          # there, so the processor is busy for a few instructions a byte, not for the whole exchange:
          #
          #   rt_pad_read          in the frame's interrupt: the exchanges of the frame before decoded
          #                        (rt_pad_finish), and the first port's begun (rt_pad_begin)
          #   rt_pad_acknowledged  in the pad's interrupt: the answer to the byte sent kept (PAD_ANSWERS),
          #                        and the next byte sent. The last byte is not acknowledged, so the port's
          #                        interrupt on a byte received is turned on for it (JOY_CTRL bit 11), and
          #                        its answer ends the exchange: the second port's is begun from there
          #   rt_pad_finish        the buttons made of the answers of every exchange that reached its end:
          #                        held now, and every one that went down since the frame before added to
          #                        those pressed during the pass
          #   rt_pad_await         as a pass's wait ends: waits for the exchanges the blank began, and
          #                        decodes them, so the pass has that frame's buttons
          #   rt_pads_now          at power-on, with the interrupts off: the same exchanges, the port's
          #                        interrupt flag watched in place of the interrupt
          #
          # A frame's buttons are a word for two players, the first's in the low half and the second's in
          # the high (Frame::HELD, as IR::Buttons.mask lays them out), and another for the third and fourth
          # (TAP_HELD), each a bit a button in IR::Buttons's order.
          module Pads
            # Each button, by its name in IR::Buttons, as [which byte of the two, which bit].
            BITS = Ractor.make_shareable({ select: [0, 0], start: [0, 3], up: [0, 4], right: [0, 5], down: [0, 6], left: [0, 7],
                                           l2: [1, 0], r2: [1, 1], l: [1, 2], r: [1, 3], x: [1, 4], b: [1, 5], a: [1, 6],
                                           y: [1, 7] })

            # JOY_MODE: a baud reload factor of 1, 8 bits a byte, no parity. JOY_BAUD: 250 kHz.
            MODE = 0x000D
            BAUD = 0x0088
            # JOY_CTRL through an exchange: the transmitter on, the port's select line low, and an interrupt
            # as the pad acknowledges; bit 13 for the second port's line in place of the first's; the bit
            # that lets the next acknowledge's interrupt come; and an interrupt on the byte received, for
            # the last byte, which no pad acknowledges.
            CONVERSING = 0x0003 | (1 << 12)
            SECOND_PORT_SHIFT = 13
            NEXT_ACKNOWLEDGE = 1 << 4
            LAST_ANSWER_INTERRUPT = 1 << 11

            # The bytes sent: 01h to start, then 42h to ask for the buttons, noughts after. 01h as the
            # third tells a Multitap to read all its plugs from the next exchange on, and 42h at each
            # plug's first byte is that plug's command.
            START = 0x01
            ASK_BUTTONS = 0x42
            READ_EVERY_PLUG = 0x01
            # The bytes of an exchange with a pad, and with a Multitap reading every plug.
            PAD_BYTES = 5
            TAP_BYTES = 3 + (8 * 4)
            # What a Multitap reading every plug answers in place of a pad's kind.
            TAP_KIND = 0x80
            # Where in PAD_ANSWERS the second port's answers start, and how many bytes are kept for each.
            SECOND_ANSWERS = 8
            # Where each plug's two button bytes are in a Multitap's answers.
            PLUG_BUTTONS = [5, 13, 21].freeze

            # How many times a wait looks for the next answer before it gives up: far longer than a pad
            # takes between two bytes.
            PATIENCE = 400

            # The third and fourth players' buttons, kept as Frame::HELD, SEEN, PRESSED, PAD_HELD and
            # PAD_PRESSED keep the first two's, in a game that reads a Multitap.
            TAP_HELD = "rt tap held"
            TAP_SEEN = "rt tap seen"
            TAP_PRESSED = "rt tap pressed"
            TAP_PAD_HELD = "rt tap pad held"
            TAP_PAD_PRESSED = "rt tap pad pressed"
            # Players past the first connected, as the interrupt finds them on every frame, and for the
            # pass (taken where the pass's buttons are): the highest player whose button has been down,
            # less one, which never falls.
            PAD_CONNECTED = "rt pad connected"
            CONNECTED = "rt connected"
            # The answers of the exchanges under way, a byte each; which reached their end, a bit for each
            # port; and which port the one under way is with.
            PAD_ANSWERS = "rt pad answers"
            PAD_DONE = "rt pad done"
            PAD_PORT = "rt pad port"

            module_function

            # How many pads +program+ reads: 1, 2 for one that reads the second pad (#reads_second_pad?),
            # or 4 for one that reads a Multitap (#reads_multitap?).
            def pads_read(program)
              return 4 if reads_multitap?(program)

              reads_second_pad?(program) ? 2 : 1
            end

            # Whether +program+ reads the second pad: a button on it, on its own or as any player's, or how
            # many players are connected, which counts the second once a button on it is down.
            def reads_second_pad?(program)
              program.walk.any? do |node|
                (%i[held pressed].include?(node.kind) && node.player != 1) || node.kind == :players_connected
              end
            end

            # Whether +program+ reads a Multitap: a third or fourth player's button, or in a game of more
            # than two, any player's button or how many are connected.
            def reads_multitap?(program)
              several = program.max_players.to_i > 2
              program.walk.any? do |node|
                if %i[held pressed].include?(node.kind)
                  (node.player.is_a?(Integer) && node.player > 2) || (several && node.player == Buttons::ANY)
                else
                  several && node.kind == :players_connected
                end
              end
            end

            # The places the exchanges keep their answers in, for +pads+ pads (#pads_read).
            def reserve(memory, pads:)
              memory.reserve(PAD_ANSWERS, pads == 1 ? PAD_BYTES : SECOND_ANSWERS + (pads == 4 ? TAP_BYTES : PAD_BYTES))
              memory.reserve(PAD_DONE, 4)
              return if pads == 1

              [PAD_PORT, PAD_CONNECTED, CONNECTED].each { |name| memory.reserve(name, 4) }
              [TAP_HELD, TAP_SEEN, TAP_PRESSED, TAP_PAD_HELD, TAP_PAD_PRESSED].each { |name| memory.reserve(name, 4) } if pads == 4
            end

            # How many pads the game whose places are in +memory+ reads (#reserve).
            def pads(memory)
              return 4 if memory.reserved?(TAP_HELD)

              memory.reserved?(PAD_PORT) ? 2 : 1
            end

            def emit(asm, memory)
              h = Console::PS1Hardware
              at = ->(name) { Runtime.at(memory, name) }
              pads = pads(memory)
              emit_start(asm, h)
              emit_begin(asm, at, h, pads)
              emit_acknowledged(asm, at, h, pads)
              emit_read(asm, at, pads)
              emit_finish(asm, at, pads)
              emit_connected(asm, at, pads) if pads > 1
              emit_await(asm, at, h, pads)
              emit_now(asm, at, h, pads)
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

            # rt_pad_begin: an exchange begun with the port in a0 (0 or 1; the first alone for a game of
            # one pad), its first byte sent. Changes t0 and t1.
            def emit_begin(asm, at, h, pads)
              asm.label("rt_pad_begin")
              asm.lui(:t1, h::IO >> 16)
              asm.sh(:zero, h::JOY_CTRL & 0xFFFF, :t1) # the last exchange's port let go
              if pads > 1
                asm.sw(:a0, at.call(PAD_PORT), :gp)
                asm.sll(:t0, :a0, SECOND_PORT_SHIFT)
                asm.ori(:t0, :t0, CONVERSING | NEXT_ACKNOWLEDGE)
              else
                asm.li(:t0, CONVERSING | NEXT_ACKNOWLEDGE)
              end
              asm.sh(:t0, h::JOY_CTRL & 0xFFFF, :t1)
              # The port takes a byte in only once the one before was read, so whatever is left is read
              # first and thrown away.
              asm.lbu(:t0, h::JOY_DATA & 0xFFFF, :t1)
              asm.li(:t0, START)
              asm.sb(:t0, h::JOY_DATA & 0xFFFF, :t1)
              asm.jr(:ra) { asm.sw(:t0, at.call(Frame::PAD_STEP), :gp) } # one byte sent
            end

            # rt_pad_acknowledged: the pad's interrupt. Frame::PAD_STEP is how many bytes of the exchange have
            # been sent, nought when none is under way. The answer to the last one sent is kept, and the next
            # byte sent; or, where that was the exchange's last byte, the exchange ends, and in a game of two
            # pads or more the second port's begins once the first's has ended. Changes t0 to t7 and a0.
            def emit_acknowledged(asm, at, h, pads)
              answers = at.call(PAD_ANSWERS)
              asm.label("rt_pad_acknowledged")
              asm.lui(:t1, h::IO >> 16)
              asm.lw(:t2, at.call(Frame::PAD_STEP), :gp)
              if pads > 1
                asm.lw(:t4, at.call(PAD_PORT), :gp)
                asm.sll(:t5, :t4, SECOND_PORT_SHIFT)
                asm.ori(:t5, :t5, CONVERSING)
              else
                asm.li(:t5, CONVERSING)
              end
              asm.ori(:t0, :t5, NEXT_ACKNOWLEDGE)
              asm.sh(:t0, h::JOY_CTRL & 0xFFFF, :t1)
              asm.li(:t0, ~h::IRQ_PAD & 0xFFFF_FFFF)
              asm.sw(:t0, h::I_STAT & 0xFFFF, :t1)
              asm.beq(:t2, :zero, "rt_pad_acknowledged_done")
              # The answer to byte PAD_STEP - 1, kept in its port's part of PAD_ANSWERS.
              asm.lbu(:t3, h::JOY_DATA & 0xFFFF, :t1)
              asm.addu(:t6, :gp, :t2)
              if pads > 1
                asm.sll(:t0, :t4, 3) # SECOND_ANSWERS
                asm.addu(:t6, :t6, :t0)
              end
              asm.sb(:t3, answers - 1, :t6)
              # t7: how many bytes this exchange is, which a Multitap's answer to the second byte decides.
              asm.li(:t7, PAD_BYTES)
              if pads == 4
                asm.beq(:t4, :zero, "rt_pad_acknowledged_length")
                asm.lbu(:t0, answers + SECOND_ANSWERS + 1, :gp)
                asm.xori(:t0, :t0, TAP_KIND)
                asm.bne(:t0, :zero, "rt_pad_acknowledged_length")
                asm.li(:t7, TAP_BYTES)
                asm.label("rt_pad_acknowledged_length")
              end
              asm.sltu(:t0, :t2, :t7)
              asm.beq(:t0, :zero, "rt_pad_acknowledged_last")
              emit_next_byte(asm, pads)
              # The last byte: no pad acknowledges it, so the byte received raises the interrupt instead.
              asm.addiu(:t0, :t2, 1)
              asm.bne(:t0, :t7, "rt_pad_acknowledged_send")
              asm.ori(:t0, :t5, LAST_ANSWER_INTERRUPT)
              asm.sh(:t0, h::JOY_CTRL & 0xFFFF, :t1)
              asm.label("rt_pad_acknowledged_send")
              asm.sb(:t3, h::JOY_DATA & 0xFFFF, :t1)
              asm.addiu(:t2, :t2, 1)
              asm.jr(:ra) { asm.sw(:t2, at.call(Frame::PAD_STEP), :gp) }

              # The last answer came: the exchange reached its end.
              asm.label("rt_pad_acknowledged_last")
              asm.lw(:t0, at.call(PAD_DONE), :gp)
              if pads > 1
                asm.li(:t3, 1)
                asm.sllv(:t3, :t3, :t4)
                asm.or(:t0, :t0, :t3)
              else
                asm.ori(:t0, :t0, 1)
              end
              asm.sw(:t0, at.call(PAD_DONE), :gp)
              asm.sw(:zero, at.call(Frame::PAD_STEP), :gp)
              asm.sh(:zero, h::JOY_CTRL & 0xFFFF, :t1)
              if pads > 1
                asm.bne(:t4, :zero, "rt_pad_acknowledged_done")
                asm.j("rt_pad_begin") { asm.li(:a0, 1) }
              end
              asm.label("rt_pad_acknowledged_done")
              asm.jr(:ra)
            end

            # t3 = the byte numbered t2 of the exchange (from nought) with the port in t4.
            def emit_next_byte(asm, pads)
              asm.move(:t3, :zero)
              asm.li(:t0, 1)
              asm.bne(:t2, :t0, "rt_pad_acknowledged_not_second")
              asm.li(:t3, ASK_BUTTONS)
              asm.label("rt_pad_acknowledged_not_second")
              return unless pads == 4

              # To the second port: 01h third, for a Multitap to read every plug, and 42h at each plug's
              # first byte (numbers 3, 11, 19 and 27: eight apart, 3 more than a multiple of eight).
              asm.beq(:t4, :zero, "rt_pad_acknowledged_byte")
              asm.li(:t0, 2)
              asm.bne(:t2, :t0, "rt_pad_acknowledged_not_third")
              asm.li(:t3, READ_EVERY_PLUG)
              asm.label("rt_pad_acknowledged_not_third")
              asm.andi(:t0, :t2, 7)
              asm.li(:t6, 3)
              asm.bne(:t0, :t6, "rt_pad_acknowledged_byte")
              asm.li(:t3, ASK_BUTTONS)
              asm.label("rt_pad_acknowledged_byte")
            end

            # rt_pad_read: in the frame's interrupt, the last frame's exchanges decoded, and the first port's
            # begun.
            def emit_read(asm, at, pads)
              asm.label("rt_pad_read")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.jal("rt_pad_finish")
              asm.sw(:zero, at.call(PAD_DONE), :gp)
              asm.move(:a0, :zero) if pads > 1
              asm.jal("rt_pad_begin")
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
            end

            # rt_pad_finish: the buttons of every exchange that reached its end (none held for a port whose
            # exchange did not), into Frame::PAD_HELD and TAP_PAD_HELD; and each that went down since the
            # frame before added to Frame::PAD_PRESSED and TAP_PAD_PRESSED. Decoding the same exchanges again
            # changes nothing, so the wait and the next frame's interrupt can both decode them. v0 = the first
            # two players' buttons and v1 the third and fourth's. Changes t0 to t9.
            def emit_finish(asm, at, pads)
              answers = at.call(PAD_ANSWERS)
              asm.label("rt_pad_finish")
              asm.lw(:t6, at.call(PAD_DONE), :gp)
              asm.li(:t5, 0xFFFF) # the two button bytes, none pressed
              asm.andi(:t0, :t6, 1)
              asm.beq(:t0, :zero, "rt_pad_finish_first_none")
              emit_button_bytes(asm, answers + 3, :t5)
              asm.label("rt_pad_finish_first_none")
              emit_buttons_of_bytes(asm, "rt_pad_finish_first", from: :t5, into: :v0)
              asm.move(:v1, :zero)
              emit_second_port_finished(asm, answers + SECOND_ANSWERS, pads) if pads > 1
              emit_edges(asm, at, :v0, Frame::SEEN, Frame::PAD_PRESSED, Frame::PAD_HELD)
              emit_edges(asm, at, :v1, TAP_SEEN, TAP_PAD_PRESSED, TAP_PAD_HELD) if pads == 4
              return asm.jr(:ra) if pads == 1

              asm.j("rt_pads_connected")
            end

            # The second port's buttons into v0's high half: the pad's, or a Multitap's first plug's, and for
            # a game of four the tap's second and third plugs' into v1.
            def emit_second_port_finished(asm, answers, pads)
              tap = pads == 4
              asm.li(:t5, 0xFFFF)
              if tap
                asm.li(:t8, 0xFFFF)
                asm.li(:t9, 0xFFFF)
              end
              asm.andi(:t0, :t6, 2)
              asm.beq(:t0, :zero, "rt_pad_finish_second_none")
              if tap
                asm.lbu(:t0, answers + 1, :gp)
                asm.xori(:t0, :t0, TAP_KIND)
                asm.beq(:t0, :zero, "rt_pad_finish_tap")
              end
              emit_button_bytes(asm, answers + 3, :t5)
              if tap
                asm.b("rt_pad_finish_second_none")
                asm.label("rt_pad_finish_tap")
                PLUG_BUTTONS.zip(%i[t5 t8 t9]) { |place, into| emit_button_bytes(asm, answers + place, into) }
              end
              asm.label("rt_pad_finish_second_none")
              emit_buttons_of_bytes(asm, "rt_pad_finish_second", from: :t5, into: :t7)
              asm.sll(:t7, :t7, Buttons::PLAYER_SHIFT)
              asm.or(:v0, :v0, :t7)
              return unless tap

              emit_buttons_of_bytes(asm, "rt_pad_finish_third", from: :t8, into: :v1)
              emit_buttons_of_bytes(asm, "rt_pad_finish_fourth", from: :t9, into: :t7)
              asm.sll(:t7, :t7, Buttons::PLAYER_SHIFT)
              asm.or(:v1, :v1, :t7)
            end

            # +into+ = the two button bytes from +place+ (a distance from gp), the first in the low byte.
            # Changes t3 and t4.
            def emit_button_bytes(asm, place, into)
              asm.lbu(:t3, place, :gp)
              asm.lbu(:t4, place + 1, :gp)
              asm.sll(:t4, :t4, 8)
              asm.or(into, :t3, :t4)
            end

            # The buttons in +word+ held now: each that went down since +seen+ added to +pressed+, and
            # +held+ and +seen+ set to them. Changes t0 and t1.
            def emit_edges(asm, at, word, seen, pressed, held)
              asm.lw(:t0, at.call(seen), :gp)
              asm.lw(:t1, at.call(pressed), :gp)
              asm.nor(:t0, :t0, :zero)
              asm.and(:t0, :t0, word)
              asm.or(:t1, :t1, :t0)
              asm.sw(:t1, at.call(pressed), :gp)
              asm.sw(word, at.call(held), :gp)
              asm.sw(word, at.call(seen), :gp)
            end

            # rt_pads_connected: PAD_CONNECTED raised to the highest player past the first with a button in
            # v0 (the first two players') or v1 (the third and fourth): it never falls. Changes t0 to t2.
            def emit_connected(asm, at, pads)
              asm.label("rt_pads_connected")
              asm.move(:t1, :zero)
              players = [[:srl, :v0, 1]]
              players += [[:low, :v1, 2], [:srl, :v1, 3]] if pads == 4
              players.each do |half, word, past_first|
                if half == :srl
                  asm.srl(:t2, word, Buttons::PLAYER_SHIFT)
                else
                  asm.andi(:t2, word, 0xFFFF)
                end
                asm.beq(:t2, :zero, "rt_pads_connected_#{past_first}")
                asm.li(:t1, past_first)
                asm.label("rt_pads_connected_#{past_first}")
              end
              asm.lw(:t0, at.call(PAD_CONNECTED), :gp)
              asm.sltu(:t2, :t0, :t1)
              asm.beq(:t2, :zero, "rt_pads_connected_done")
              asm.sw(:t1, at.call(PAD_CONNECTED), :gp)
              asm.label("rt_pads_connected_done")
              asm.jr(:ra)
            end

            # rt_pad_await: as a pass's wait ends, waits until the exchanges the blank began have ended, or
            # until no answer has come for a while, and decodes them with the interrupts off. The waiting's
            # labels are named as the wait for the screen is, so a profile counts it as time the game had
            # nothing to do.
            def emit_await(asm, at, h, pads)
              asm.label("rt_pad_await")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.li(:t2, PATIENCE)
              asm.li(:t3, -1)
              asm.label("rt_sleep_until_vblank_pad")
              emit_exchange_moved_on(asm, at, "rt_pad_awaited", "rt_sleep_until_vblank_pad_moved", pads)
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

            # A wait's look at the exchanges: to +ended+ where none is under way; otherwise, where another
            # byte has been answered since the last look (t3 is where they had got to), the wait's patience
            # (t2) starts again. +moved+ names the branch.
            def emit_exchange_moved_on(asm, at, ended, moved, pads, patience: :t2, got_to: :t3)
              asm.lw(:t0, at.call(Frame::PAD_STEP), :gp)
              asm.beq(:t0, :zero, ended)
              if pads > 1
                asm.lw(:t1, at.call(PAD_PORT), :gp)
                asm.sll(:t1, :t1, 8)
                asm.or(:t0, :t0, :t1)
              end
              asm.beq(:t0, got_to, moved)
              asm.move(got_to, :t0)
              asm.li(patience, PATIENCE)
              asm.label(moved)
            end

            # rt_pads_now: at power-on, with the interrupts off, the exchanges run to their end as the frame's
            # interrupt runs them, the port's interrupt flag in I_STAT watched in place of the interrupt. v0 =
            # the first two players' buttons held now, v1 the third and fourth's. Changes t0 to t9 and a0.
            def emit_now(asm, at, h, pads)
              asm.label("rt_pads_now")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.sw(:zero, at.call(PAD_DONE), :gp)
              asm.move(:a0, :zero) if pads > 1
              asm.jal("rt_pad_begin")
              asm.li(:t8, PATIENCE)
              asm.li(:t9, -1)
              asm.label("rt_pads_now_wait")
              asm.lui(:t1, h::IO >> 16)
              asm.lw(:t0, h::I_STAT & 0xFFFF, :t1)
              asm.andi(:t0, :t0, h::IRQ_PAD)
              asm.beq(:t0, :zero, "rt_pads_now_quiet")
              asm.jal("rt_pad_acknowledged")
              asm.label("rt_pads_now_quiet")
              emit_exchange_moved_on(asm, at, "rt_pads_now_ended", "rt_pads_now_moved", pads, patience: :t8, got_to: :t9)
              asm.addiu(:t8, :t8, -1)
              asm.bne(:t8, :zero, "rt_pads_now_wait")
              asm.label("rt_pads_now_ended")
              asm.jal("rt_pad_finish")
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
            end

            # For the pass about to start, as rt_read_buttons takes the first two players' (Frame): the third
            # and fourth players' buttons, and how many players are connected.
            def emit_taken_for_pass(asm, memory, at)
              pads = pads(memory)
              return if pads == 1

              if pads == 4
                asm.lw(:t0, at.call(TAP_PAD_PRESSED), :gp)
                asm.sw(:zero, at.call(TAP_PAD_PRESSED), :gp)
                asm.sw(:t0, at.call(TAP_PRESSED), :gp)
                asm.lw(:t0, at.call(TAP_PAD_HELD), :gp)
                asm.sw(:t0, at.call(TAP_HELD), :gp)
              end
              asm.lw(:t0, at.call(PAD_CONNECTED), :gp)
              asm.sw(:t0, at.call(CONNECTED), :gp)
            end

            # +into+ = the buttons of the two button bytes in +from+ (a pressed button reading 0), a bit each
            # in IR::Buttons's order. +tag+ starts its labels. Changes t0 and +from+.
            def emit_buttons_of_bytes(asm, tag, from:, into:)
              asm.nor(from, from, :zero) # a pressed button is a 1 from here on
              asm.move(into, :zero)
              BITS.each do |name, (which, bit)|
                asm.andi(:t0, from, 1 << ((which * 8) + bit))
                asm.beq(:t0, :zero, "#{tag}_not_#{name}")
                asm.ori(into, into, 1 << Buttons::NAMES.index(name))
                asm.label("#{tag}_not_#{name}")
              end
            end
          end
        end
      end
    end
  end
end
