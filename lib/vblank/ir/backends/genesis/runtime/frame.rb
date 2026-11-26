# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # The frame: waiting for the screen, the buttons, stopping, and going wrong.
          #
          # The console draws the screen a line at a time, 224 of them, and then rests for 38 more
          # lines' worth of time — the vertical blank — before it starts again. A game changes the
          # picture's memories (video RAM, colour memory, scroll memory) in that rest, or with the
          # screen switched off, so a pass of the game loop ends by waiting for it (rt_wait_vblank): the
          # processor sleeps (stop) until the video chip's interrupt wakes it. Then what the pass
          # changed in the picture is copied to the console (Runtime::Picture), and the buttons are
          # taken for the next pass.
          #
          # A pass that takes longer than a frame finds the blank already gone by the time it waits,
          # and waits for the next one: the game slows down rather than tearing.
          #
          # What the run is doing is kept where a reader of the running cartridge can find it
          # (Genesis::HeadlessRun): how many passes have ended, which pass the screen is showing,
          # whether the game is waiting at a frame boundary, and whether it has stopped or gone
          # wrong and why. The names and their meanings are the Color's and the Super Nintendo's, so a
          # reader of any of them asks the same questions.
          module Frame
            # How the game stands, in STATE.
            RUNNING = 0
            HALTED = 1
            WENT_WRONG = 2

            # What went wrong, in FAULT's first word: the number every cartridge console's runtime
            # keeps for it (Backends::CartridgeFaults).
            include CartridgeFaults

            # FAULT: what went wrong (a word), the list's place (a long), and two numbers that give
            # how (a long each).
            FAULT_LIST = 2
            FAULT_FIRST = 6
            FAULT_SECOND = 10
            FAULT_BYTES = 14

            STATE = "rt state" # RUNNING, HALTED or WENT_WRONG
            WAITING = "rt waiting" # 1 while the game waits for its next frame's buttons
            PASSES = "rt passes" # Passes of the game loop ended, 32 bits
            SHOWN = "rt shown" # The pass whose picture the console shows, 32 bits
            HELD = "rt held" # The buttons held through the pass, a bit each in IR::Buttons's order
            SEEN = "rt seen"
            PRESSED = "rt pressed"
            FAULT = "rt fault"
            # Set by whoever reads the run when it has the pass it wanted last: the game shows that
            # pass and goes no further.
            HOLD = "rt hold"
            # Set by the same reader when it has taken the last pass it compares one by one: the
            # game's timers do not move on at the boundary after it, as the interpreter's do not.
            LAST_PASS_TAKEN = "rt last pass taken"
            # The number of the last pass that reader compares, in a game whose tick handler waits
            # (LoweringPlan#keeps_last_pass_number?), nought until it is written: a boundary ending a later pass
            # moves nothing on. Such a game can end two passes in one frame, the reader seeing neither.
            LAST_PASS = "rt last pass"
            # How many frames a pass took (IR::Frames): the interrupt counts every frame (FRAMES, 32
            # bits); where a pass's wait ends, the frames since the last wait ended are what that pass
            # answers for (FRAMES_TAKEN), and held between one and IR::Frames::MOST (STEP_TAKEN).
            FRAMES = "rt frames"
            FRAMES_MARK = "rt frames mark"
            STEP_TAKEN = "rt step"
            FRAMES_TAKEN = "rt frames taken"
            # ...and the real number for each of the last STEPS_KEPT passes, a byte each, by the
            # pass's number less its multiples of STEPS_KEPT, for a reader of the run.
            STEPS = "rt steps"
            STEPS_KEPT = 16
            # The buttons as the interrupt reads them on every frame: held at the last, and every
            # one that went down on any of them since the last wait ended.
            PAD_HELD = "rt pad held"
            PAD_PRESSED = "rt pad pressed"
            # The second pad's of each of those, in a game that reads it (#reads_second_pad?), and how
            # many players past the first are connected (PLAYERS_PAST_FIRST), for `players_connected`:
            # the highest player with a button down so far, less one.
            SECOND_HELD = "rt second held"
            SECOND_SEEN = "rt second seen"
            SECOND_PRESSED = "rt second pressed"
            SECOND_PAD_HELD = "rt second pad held"
            SECOND_PAD_PRESSED = "rt second pad pressed"
            PLAYERS_PAST_FIRST = "rt players past first"
            # The second to fifth players' buttons as the Team Player read last left them
            # (#emit_team_player_read), a word each, in a game that reads one (#reads_team_player?).
            TAP_BUTTONS = "rt tap buttons"
            # 1 once the interrupt has come since the game began to wait.
            VBLANK = "rt vblank"
            # 1 once the screen is on: before the end of the first pass it is off.
            DISPLAY_ON = "rt display on"

            # In a game that reads how many frames it has shown since power-on, the frames setting up takes
            # are counted too. COUNTING is 1 while setting up runs and the interrupt only counts FRAMES
            # (Boot#emit, #emit_interrupt); SETTING_UP is the frames setting up took, kept one more for a
            # reader of the run, so nought means not counted yet (#emit_setting_up_counted).
            COUNTING = "rt counting"
            SETTING_UP = "rt frames setting up"

            # The part of work RAM the interrupt touches while it only counts, which the boot clears
            # first (Boot#emit): +bytes+ from the start of work RAM, a whole number of long words, and the
            # distance of COUNTING from A5.
            CountingBlock = Data.define(:bytes, :flag_at)

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            # Each button's bit in the number the runtime keeps them in, in IR::Buttons's order: the
            # pad has seven of them and the order has thirteen, so the bits between are never set.
            BUTTON_BITS = Ractor.make_shareable(Buttons::NAMES.each_with_index.to_h { |name, bit| [name, 1 << bit] })

            # The status register's value that lets every interrupt in (supervisor mode, mask 0), and
            # the mask bits that keep every one out.
            INTERRUPTS_ON = 0x2000
            INTERRUPTS_OFF_BITS = 0x0700

            # Where one pad's buttons are kept: through the pass (+held+, +pressed+), as the interrupt
            # last read them (+seen+), and as the interrupt gathers them for the next pass (+pad_held+,
            # +pad_pressed+).
            Controller = Data.define(:held, :seen, :pressed, :pad_held, :pad_pressed)

            # The second pad's, then the third, fourth and fifth players' on a Team Player in the second port.
            OTHER_CONTROLLERS = Ractor.make_shareable([
                                                        Controller.new(SECOND_HELD, SECOND_SEEN, SECOND_PRESSED,
                                                                       SECOND_PAD_HELD, SECOND_PAD_PRESSED),
                                                        Controller.new("rt third held", "rt third seen", "rt third pressed",
                                                                       "rt third pad held", "rt third pad pressed"),
                                                        Controller.new("rt fourth held", "rt fourth seen", "rt fourth pressed",
                                                                       "rt fourth pad held", "rt fourth pad pressed"),
                                                        Controller.new("rt fifth held", "rt fifth seen", "rt fifth pressed",
                                                                       "rt fifth pad held", "rt fifth pad pressed")
                                                      ])

            # The Team Player's answer to the pad's two halves, read as a pad is (TH high, then TH
            # low): %0011 and %1111 in the low four bits, its peripheral ID of 7 (plutiedev, "Sega
            # multitap"). No pad answers %0011 with TH high: that is right and left held at once.
            TAP_TH_HIGH = 0b0011
            TAP_TH_LOW = 0b1111
            # The control byte that makes TH and TR outputs, the two lines the tap's handshake drives,
            # and the data byte that leaves the tap at rest (both high).
            TAP_CONTROL = 0x60
            TAP_REST = 0x60
            # The data port's TR (bit 5), which the console toggles for each nibble, and TL (bit 4),
            # which the tap sets to match once the nibble is there.
            TAP_TR = 0x20
            TAP_TL_BIT = 4
            # TR and TL's bits together: the console keeps the TR it drives in both, so one EOR of a
            # read leaves TL's bit clear when the tap has matched it. TL is an input, so its bit
            # written to the port changes nothing.
            TAP_TR_AND_TL = 0x30
            # The kinds of pad a plug can hold, in the header's nibbles (plutiedev): three buttons, six,
            # and nothing. Anything else ends the read, its plug and the ones after it read as empty.
            # Genesis Plus GX fills every plug with a pad, so the empty plug's way rests on plutiedev
            # alone and is played by no test.
            TAP_THREE_BUTTONS = 0b0000
            TAP_SIX_BUTTONS = 0b0001
            TAP_EMPTY = 0b1111
            # How many reads of the port a nibble is waited for before the tap is taken as gone, so a
            # tap pulled out mid-read cannot hang the game (plutiedev asks for a timeout and gives no
            # length). This one has no source: Genesis Plus GX answers on the first read, and the
            # number is a guard of ours, far more than an adapter on the hardware is known to need.
            TAP_WAIT_READS = 16

            module_function

            # Whether +program+ reads the third, fourth or fifth player: a button of theirs by number, or,
            # in a game that takes more than two players (`players:`), any player's button or how
            # many are connected, which they can be part of.
            def reads_team_player?(program)
              several = program.max_players.to_i > 2
              program.walk.any? do |node|
                if %i[held pressed pulled].include?(node.kind)
                  (node.player.is_a?(Integer) && node.player > 2) || (several && node.player == Buttons::ANY)
                else
                  several && node.kind == :players_connected
                end
              end
            end

            # Whether the game whose places are in +memory+ reads a Team Player (#reserve).
            def team_player?(memory) = memory.reserved?(TAP_BUTTONS)

            # The pads past the first a game whose places are in +memory+ reads.
            def other_controllers(memory) = OTHER_CONTROLLERS.select { |controller| memory.reserved?(controller.held) }

            # Whether +program+ reads the second pad: a button on it, on its own or as either player's, or
            # how many players are connected, which counts the second once a button on it is down. A game
            # that asks none of these reads the first pad alone, and builds as it did before there was a
            # second.
            def reads_second_pad?(program)
              program.walk.any? do |node|
                (%i[held pressed pulled].include?(node.kind) && node.player != 1) || node.kind == :players_connected
              end
            end

            # +counted+ for a game that reads how many frames it has shown since power-on (COUNTING,
            # SETTING_UP). Must be the first places reserved, so the interrupt's are at the start of
            # work RAM (#counting_block). +second_pad+ for a game that reads it (#reads_second_pad?), and
            # +team_player+ for one that reads the third to fifth players (#reads_team_player?).
            def reserve(memory, counted: false, second_pad: false, team_player: false)
              if counted
                memory.reserve(COUNTING, 2)
                memory.reserve(SETTING_UP, 2)
              end
              memory.reserve(STATE, 2)
              memory.reserve(WAITING, 2)
              memory.reserve(PASSES, 4)
              memory.reserve(SHOWN, 4)
              memory.reserve(HELD, 2)
              memory.reserve(SEEN, 2)
              memory.reserve(PRESSED, 2)
              memory.reserve(FAULT, FAULT_BYTES)
              memory.reserve(HOLD, 4)
              memory.reserve(LAST_PASS_TAKEN, 4)
              memory.reserve(FRAMES, 4)
              memory.reserve(FRAMES_MARK, 2)
              memory.reserve(STEP_TAKEN, 2)
              memory.reserve(FRAMES_TAKEN, 2)
              memory.reserve(STEPS, STEPS_KEPT)
              memory.reserve(PAD_HELD, 2)
              memory.reserve(PAD_PRESSED, 2)
              memory.reserve(VBLANK, 2)
              memory.reserve(DISPLAY_ON, 2)
              return unless second_pad

              [SECOND_HELD, SECOND_SEEN, SECOND_PRESSED, SECOND_PAD_HELD, SECOND_PAD_PRESSED, PLAYERS_PAST_FIRST].each do |name|
                memory.reserve(name, 2)
              end
              return unless team_player

              OTHER_CONTROLLERS.drop(1).each { |controller| controller.to_h.each_value { |name| memory.reserve(name, 2) } }
              memory.reserve(TAP_BUTTONS, 2 * OTHER_CONTROLLERS.size)
            end

            # Whether the game whose places are in +memory+ reads the second pad (#reserve).
            def second_pad?(memory) = memory.reserved?(SECOND_HELD)

            # The CountingBlock of a game that counts the frames setting up takes: COUNTING to FRAMES.
            def counting_block(memory)
              raise LoweringError, "the frame counter's places must be reserved first" unless memory[COUNTING] == Memory::FIRST

              bytes = memory[FRAMES] + 4 - Memory::FIRST
              CountingBlock.new(bytes: (bytes + 3) & ~3, flag_at: memory.displacement(COUNTING))
            end

            # LAST_PASS, in a game whose tick handler waits (LoweringPlan#keeps_last_pass_number?).
            def reserve_last_pass(memory) = memory.reserve(LAST_PASS, 4)

            # The routines that end a pass and start the next: the interrupt, the wait, the buttons,
            # stopping and going wrong. +sound+ for a game that makes sound, whose wait ends in Sound's
            # rt_sound_frame; +samples+ for one that plays recordings, whose interrupt reads the buttons
            # with the Z80 kept off the cartridge (Recordings#emit_z80_kept_off_for_pad).
            # +count_at+ is where a game that reads how many frames it has shown since power-on keeps that
            # count, and nil for any other.
            def emit(asm, memory, sound: false, samples: false, count_at: nil)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_interrupt(asm, at, samples, counting: !count_at.nil?, strikes: Strikes.strikes?(memory))
              emit_wait(asm, at, sound, memory.reserved?(LAST_PASS), strikes: Strikes.strikes?(memory))
              emit_show_pass(asm, at, count_at && asm.disp(5, Memory.displacement(count_at)), strikes: Strikes.strikes?(memory))
              emit_buttons(asm, memory, at)
              emit_stopping(asm, at)
            end

            # The interrupt that signals a frame has been drawn. It keeps every register it touches, counts
            # the frame and reads the buttons, so a pass that spans several frames answers for each of
            # them, as the interpreter's does. A5 is the game's own and is never changed. In a game that
            # plays recordings the buttons are read with the Z80 kept off the cartridge.
            #
            # +counting+ for a game that counts the frames setting up takes: while COUNTING is set the
            # interrupt only counts the frame, since the buttons' reading would let the Z80 go before
            # its program is in, and work RAM past the counting block is still being cleared.
            #
            # +strikes+ for a game whose sound effects are struck inside the frame: the frame's lines go on
            # their clock, and what is due as the blank begins is made (Strikes#emit_blank).
            def emit_interrupt(asm, at, samples, counting: false, strikes: false)
              asm.label("rt_vblank_interrupt")
              if counting
                asm.tst(:w, at.call(COUNTING))
                asm.branch(:ne, "rt_vblank_interrupt_counting")
              end
              asm.movem_push(:l, :d0, :d1, :d2, :d3)
              asm.jsr(asm.abs_l(samples ? "rt_z80_kept_off_for_pad" : "rt_pad_read"))
              asm.addq(:l, 1, at.call(FRAMES))
              asm.move(:w, asm.imm(1), at.call(VBLANK))
              Strikes.emit_blank(asm, at) if strikes
              asm.movem_pop(:l, :d0, :d1, :d2, :d3)
              asm.rte
              if counting
                asm.label("rt_vblank_interrupt_counting")
                asm.addq(:l, 1, at.call(FRAMES))
                asm.rte
              end
              asm.label("rt_unused_interrupt")
              asm.rte
            end

            # The end of a pass: count it, move on what keeps time by the frame, mark the game as
            # waiting, and wait for the screen. What keeps time by the frame moves on here, before
            # the game is marked as waiting, because that is where the interpreter moves it on: at
            # the frame boundary, before anything is read of the frame (Reference#advance_frame).
            #
            # +numbered+ for a game whose reader names the last pass it compares by number (LAST_PASS).
            # +strikes+ for a game whose sound effects are struck inside the frame: the line interrupt switched
            # off before the wait when nothing is listed (Strikes's rt_strikes_quiet).
            def emit_wait(asm, at, sound, numbered, strikes: false)
              asm.label("rt_wait_vblank")
              asm.addq(:l, 1, at.call(PASSES))
              asm.jsr(asm.abs_l("rt_frame_begins_unless_last"))
              asm.jsr(asm.abs_l("rt_tint_prepare"))
              asm.jsr(asm.abs_l("rt_picture_prepare"))
              asm.jsr(asm.abs_l("rt_strikes_quiet")) if strikes
              asm.move(:w, asm.imm(1), at.call(WAITING))
              asm.jsr(asm.abs_l("rt_show_pass"))
              asm.tst(:l, at.call(HOLD))
              asm.branch(:eq, "rt_wait_vblank_buttons")
              asm.jmp(asm.abs_l("rt_stopped"))
              asm.label("rt_wait_vblank_buttons")
              asm.jsr(asm.abs_l("rt_read_buttons"))
              asm.clr(:w, at.call(WAITING))
              asm.jsr(asm.abs_l("rt_sound_frame")) if sound # the music of the frames the pass took (Sound)
              asm.rts

              # What keeps time by the frame, moved on — unless the reader has taken the last pass it
              # compares, after which the interpreter moves nothing on (LAST_PASS_TAKEN).
              asm.label("rt_frame_begins_unless_last")
              asm.tst(:l, at.call(LAST_PASS_TAKEN))
              asm.branch(:ne, "rt_frame_begins_skipped")
              emit_skip_past_last_pass(asm, at) if numbered
              asm.jsr(asm.abs_l("rt_frame_begins"))
              asm.label("rt_frame_begins_skipped")
              asm.rts
            end

            # Branches to rt_frame_begins_skipped when LAST_PASS is written and the pass that just ended
            # (PASSES) comes after it. D0 is free: the game's timers run here otherwise, code of the game's
            # own, which changes any register it likes.
            def emit_skip_past_last_pass(asm, at)
              asm.move(:l, at.call(LAST_PASS), asm.d(0))
              asm.branch(:eq, "rt_frame_begins_not_past")
              asm.cmp(:l, at.call(PASSES), asm.d(0))
              asm.branch(:cs, "rt_frame_begins_skipped")
              asm.label("rt_frame_begins_not_past")
            end

            # rt_show_pass: what the pass drew, on the screen, and SHOWN saying so. The first time, the
            # screen is still off, so everything set up so far is copied while nothing is drawn, and
            # the screen comes on in the blank after, showing it; after that, the pass's changes are
            # copied in the blank.
            #
            # The frames are counted from the screen coming on. Setting up and the first copy take
            # several frames of the console's time with nothing to see, and the interpreter's first
            # pass takes one: the count starts again as the picture first shows, with that frame as
            # the first, so a game counting frames (a timer, an effect that runs every frame) counts
            # the same ones, and the buttons the interrupt of that frame read are the first frame's.
            # +count+ is the place of the count of frames since power-on in a game that reads it
            # (#emit_setting_up_counted).
            #
            # +strikes+ for a game whose sound effects are struck inside the frame: with nothing listed the game
            # sleeps with the line interrupt held off, so it is not woken every few lines for nothing
            # (Strikes#emit_line).
            def emit_show_pass(asm, at, count, strikes: false)
              asm.label("rt_show_pass")
              asm.tst(:w, at.call(DISPLAY_ON))
              asm.branch(:ne, "rt_show_pass_on")
              asm.jsr(asm.abs_l("rt_upload_whole"))
              asm.jsr(asm.abs_l("rt_sleep_until_vblank"))
              asm.jsr(asm.abs_l("rt_screen_on"))
              emit_setting_up_counted(asm, at, count) if count
              asm.move(:l, asm.imm(1), at.call(FRAMES))
              asm.move(:w, asm.imm(1), at.call(FRAMES_MARK))
              asm.move(:w, asm.imm(1), at.call(DISPLAY_ON))
              asm.bra("rt_show_pass_shown")
              asm.label("rt_show_pass_on")
              asm.jsr(asm.abs_l("rt_sleep_until_vblank"))
              asm.jsr(asm.abs_l("rt_upload"))
              asm.label("rt_show_pass_shown")
              asm.move(:l, at.call(PASSES), at.call(SHOWN))
              asm.rts

              # Sleep until the blank's interrupt has come since this was called. The interrupt is
              # held off while the flag is looked at, so one cannot come between the look and the sleep
              # and be waited a whole frame for; stop lets the pending one in as it sleeps.
              asm.label("rt_sleep_until_vblank")
              asm.ori_to_sr(INTERRUPTS_OFF_BITS)
              asm.clr(:w, at.call(VBLANK))
              asm.label("rt_sleep_until_vblank_wait")
              asm.ori_to_sr(INTERRUPTS_OFF_BITS)
              asm.tst(:w, at.call(VBLANK))
              asm.branch(:ne, "rt_sleep_until_vblank_done")
              if strikes # D0 kept: the upload sleeps here in the middle of its work
                asm.movem_push(:l, :d0)
                asm.move(:w, at.call(Strikes::HEAD), asm.d(0))
                asm.cmp(:w, at.call(Strikes::TAIL), asm.d(0))
                asm.movem_pop(:l, :d0) # the flags are the compare's
                asm.branch(:ne, "rt_sleep_until_vblank_listed")
                asm.stop(INTERRUPTS_ON | Strikes::LINE_INTERRUPT_MASK)
                asm.bra("rt_sleep_until_vblank_wait")
                asm.label("rt_sleep_until_vblank_listed")
              end
              asm.stop(INTERRUPTS_ON)
              asm.bra("rt_sleep_until_vblank_wait")
              asm.label("rt_sleep_until_vblank_done")
              asm.move_to_sr(asm.imm(INTERRUPTS_ON))
              asm.rts
            end

            # The frames setting up took, counted all the same, in a game that reads how many frames it
            # has shown since power-on. Such a game counts blanks from near the top of setting up
            # (Boot#emit), so FRAMES holds every blank since, the one just waited for included, which ends
            # the first pass's frame; the rest are setting up's. They go into the game's count at +count+
            # now, which the first pass reads only once its wait is over, the frames of the pass itself
            # added after (Lowering#emit_wait_vblank): where the interpreter adds them
            # (Reference#store_frame_counters). SETTING_UP keeps them one more, for a reader of the run. No
            # interrupt comes between: one has just come.
            def emit_setting_up_counted(asm, at, count)
              asm.move(:l, at.call(FRAMES), asm.d(0))
              asm.move(:w, asm.d(0), at.call(SETTING_UP))
              asm.subq(:l, 1, asm.d(0))
              asm.add(:l, asm.d(0), count)
            end

            # BUTTONS. The pad is read by hand through its port: with its select line high it shows C,
            # B, right, left, down and up, and with it low start and A, a pressed button reading 0.
            # The pad needs a moment after the line changes, which is two instructions that do
            # nothing. The bits are turned into IR::Buttons's order.
            #
            # The second pad is read the same way through the next port along ($A10005), in a game that
            # reads it (#reads_second_pad?). A port with nothing plugged in reads every line high, so no
            # button of it is down.
            def emit_buttons(asm, memory, at)
              h = Console::GenesisHardware
              second = second_pad?(memory)
              # rt_buttons_now: D0 = the first pad's buttons held now, a bit each in IR::Buttons's order;
              # rt_second_buttons_now the second's.
              emit_pad_now(asm, "rt_buttons_now", h::PAD1_DATA)
              emit_pad_now(asm, "rt_second_buttons_now", h::PAD2_DATA) if second

              # In the interrupt, every frame: the buttons held now, and every one that went down
              # since the frame before added to those pressed during the pass.
              asm.label("rt_pad_read")
              asm.jsr(asm.abs_l("rt_buttons_now"))
              emit_pad_noted(asm, at, SEEN, PAD_PRESSED, PAD_HELD)
              if team_player?(memory)
                asm.jsr(asm.abs_l("rt_tap_read"))
                OTHER_CONTROLLERS.each_with_index do |controller, index|
                  asm.move(:w, at.call(TAP_BUTTONS, index * 2), asm.d(0))
                  emit_pad_noted(asm, at, controller.seen, controller.pad_pressed, controller.pad_held)
                end
              elsif second
                asm.jsr(asm.abs_l("rt_second_buttons_now"))
                emit_pad_noted(asm, at, SECOND_SEEN, SECOND_PAD_PRESSED, SECOND_PAD_HELD)
              end
              asm.rts

              emit_read_buttons(asm, memory, at)
              return unless team_player?(memory)

              emit_team_player_read(asm, at)
              emit_tap_held_from_power_on(asm, at)
            end

            # ### The Team Player
            #
            # Two adapters let more than two people play: Sega's Team Player, which plugs into one port and has
            # four plugs of its own, and EA's 4 Way Play, which takes both ports. The Team Player is the
            # one read here: the first port's pad stays the first player, as on a console with no
            # adapter, the adapter in the second port gives the console's pads 2 to 5, and the Super
            # Nintendo's Multitap is read the same way round. Genesis Plus GX emulates both adapters.
            #
            # It is read the way plutiedev's "Sega multitap" gives. Read as a pad is (TH high, then
            # low), it answers %0011 and %1111, its peripheral ID; a pad never does, nor an empty port.
            # Then TH and TR are made outputs ($60 to the control port), TH is set high then low with
            # TR high, and each toggle of TR after hands over a nibble in the low four bits once TL
            # matches it: two noughts, the kind of pad in each of its four plugs, then each plug's
            # buttons in turn, two nibbles for a pad of three buttons (right, left, down, up; then
            # start, A, C, B) and three for one of six, 0 where a button is down. The third, fourth and fifth
            # players are its second, third and fourth plugs.
            # After it, the data port goes back to $60 and the control port to the pad's own $40, so
            # the next frame reads the port as a pad again.
            #
            # A port with no Team Player is a pad, read as one, and the third to fifth players hold
            # nothing. A tap that stops answering, or answers out of turn, holds nothing at all.
            #
            # rt_tap_read: TAP_BUTTONS holds the second to fifth players' buttons, a bit each in
            # IR::Buttons's order. D0 to D3 are used.
            def emit_team_player_read(asm, at)
              h = Console::GenesisHardware
              asm.label("rt_tap_read")
              asm.jsr(asm.abs_l("rt_second_buttons_now"))
              asm.move(:w, asm.d(0), at.call(TAP_BUTTONS))
              asm.clr(:l, at.call(TAP_BUTTONS, 2))
              asm.clr(:w, at.call(TAP_BUTTONS, 6))
              # rt_second_buttons_now leaves the port's two halves in D1 and D2, turned over.
              asm.move(:b, asm.d(1), asm.d(3))
              asm.and(:b, asm.imm(0x0F), asm.d(3))
              asm.cmp(:b, asm.imm(~TAP_TH_HIGH & 0x0F), asm.d(3))
              asm.branch(:ne, "rt_tap_read_done")
              asm.move(:b, asm.d(2), asm.d(3))
              asm.and(:b, asm.imm(0x0F), asm.d(3))
              asm.cmp(:b, asm.imm(~TAP_TH_LOW & 0x0F), asm.d(3))
              asm.branch(:ne, "rt_tap_read_done")
              asm.movem_push(:l, :d4, :d5, :d6, :d7, :a0, :a1, :a2)
              asm.lea(at.call(TAP_BUTTONS), asm.a(0))
              asm.lea(asm.abs_l("rt_tap_buttons_table"), asm.a(1))
              asm.lea(asm.abs_l(h::PAD2_DATA), asm.a(2)) # the port, nearer through a register
              asm.clr(:w, asm.ind(0)) # the port read as a pad was the tap's ID, not a pad's buttons
              asm.move(:b, asm.imm(TAP_CONTROL), asm.abs_l(h::PAD2_CONTROL))
              asm.move(:b, asm.imm(TAP_REST), asm.ind(2))
              2.times { asm.nop }
              asm.move(:b, asm.imm(TAP_TR), asm.ind(2))
              asm.moveq(0, asm.d(3)) # TR as the next nibble asks for it
              # The two noughts.
              2.times do |nibble|
                emit_tap_nibble(asm, "rt_tap_read_start_#{nibble}")
                asm.branch(:ne, "rt_tap_read_lost")
              end
              # The four plugs' kinds, the first plug's in D4's top nibble.
              asm.moveq(0, asm.d(4))
              4.times do |plug|
                emit_tap_nibble(asm, "rt_tap_read_kind_#{plug}")
                asm.lsl(:w, 4, asm.d(4))
                asm.or(:w, asm.d(0), asm.d(4))
              end
              # The four plugs' buttons, the second to fifth players'.
              asm.moveq(OTHER_CONTROLLERS.size - 1, asm.d(5))
              asm.label("rt_tap_read_plug")
              asm.rol(:w, 4, asm.d(4))
              asm.move(:b, asm.d(4), asm.d(6))
              asm.and(:b, asm.imm(0x0F), asm.d(6)) # TAP_THREE_BUTTONS is nought, the kind most plugs hold
              asm.branch(:eq, "rt_tap_read_pad")
              asm.cmp(:b, asm.imm(TAP_SIX_BUTTONS), asm.d(6))
              asm.branch(:eq, "rt_tap_read_pad")
              asm.cmp(:b, asm.imm(TAP_EMPTY), asm.d(6))
              asm.branch(:eq, "rt_tap_read_empty")
              asm.bra("rt_tap_read_rest")
              asm.label("rt_tap_read_pad")
              emit_tap_nibble(asm, "rt_tap_read_directions")
              asm.move(:w, asm.d(0), asm.d(7))
              asm.lsl(:w, 4, asm.d(7))
              emit_tap_nibble(asm, "rt_tap_read_buttons")
              asm.or(:w, asm.d(0), asm.d(7))
              asm.tst(:b, asm.d(6))
              asm.branch(:eq, "rt_tap_read_three")
              emit_tap_nibble(asm, "rt_tap_read_six") # mode, X, Y and Z, which a game cannot ask for yet
              asm.label("rt_tap_read_three")
              asm.not(:b, asm.d(7))
              # D7's high byte is nought already: both nibbles came in as words of four bits.
              asm.add(:w, asm.d(7), asm.d(7))
              asm.move(:w, asm.idx(1, 0, 7, :w), asm.post(0))
              asm.dbra(asm.d(5), "rt_tap_read_plug")
              asm.bra("rt_tap_read_rest")
              asm.label("rt_tap_read_empty")
              asm.clr(:w, asm.post(0))
              asm.dbra(asm.d(5), "rt_tap_read_plug")
              asm.bra("rt_tap_read_rest")
              asm.label("rt_tap_read_lost")
              asm.clr(:l, at.call(TAP_BUTTONS))
              asm.clr(:l, at.call(TAP_BUTTONS, 4))
              asm.label("rt_tap_read_rest")
              asm.move(:b, asm.imm(TAP_REST), asm.ind(2))
              asm.move(:b, asm.imm(h::PAD_TH), asm.abs_l(h::PAD2_CONTROL))
              asm.movem_pop(:l, :d4, :d5, :d6, :d7, :a0, :a1, :a2)
              asm.label("rt_tap_read_done")
              asm.rts

              # A plug's two nibbles of buttons (right, left, down and up above start, A, C and B), each
              # bit 1 where a button is down, to the buttons in IR::Buttons's order.
              asm.label("rt_tap_buttons_table")
              asm.data_words(Array.new(256) { |byte| tap_buttons(byte) })
            end

            # One nibble of the Team Player, written in place, its labels named from +label+: TR set to
            # D3's bit 5 (D3 holds it in bit 4 too, TAP_TR_AND_TL), then D0 = the nibble once TL
            # matches, with the flags on it, and D3 turned for the next. If TL never does, to
            # rt_tap_read_lost. A2 is the port; D1 is used.
            def emit_tap_nibble(asm, label)
              asm.move(:b, asm.d(3), asm.ind(2))
              asm.moveq(TAP_WAIT_READS - 1, asm.d(1))
              asm.label("#{label}_wait")
              asm.move(:b, asm.ind(2), asm.d(0))
              asm.eor(:b, asm.d(3), asm.d(0)) # TL matching TR leaves bit 4 clear; the nibble is untouched
              asm.btst(TAP_TL_BIT, asm.d(0))
              asm.branch(:eq, "#{label}_there")
              asm.dbra(asm.d(1), "#{label}_wait")
              asm.bra("rt_tap_read_lost")
              asm.label("#{label}_there")
              asm.eor(:b, asm.imm(TAP_TR_AND_TL), asm.d(3))
              asm.and(:w, asm.imm(0x0F), asm.d(0))
            end

            # The tap's pad bits for one plug (right, left, down, up, start, A, C, B from the top), 1
            # where down, in IR::Buttons's order.
            def tap_buttons(byte)
              %i[right left down up start a c b].each_with_index.sum do |name, place|
                byte.anybits?(0x80 >> place) ? BUTTON_BITS.fetch(name) : 0
              end
            end

            # rt_tap_held_from_power_on: the Team Player's buttons held from power-on, read once work RAM
            # is cleared, made the first pass's, as Boot makes the first pad's; and the players past
            # the first holding any connected from the first pass (Reference#count_connected_players).
            def emit_tap_held_from_power_on(asm, at)
              asm.label("rt_tap_held_from_power_on")
              asm.jsr(asm.abs_l("rt_tap_read"))
              OTHER_CONTROLLERS.each_with_index do |controller, index|
                asm.move(:w, at.call(TAP_BUTTONS, index * 2), at.call(controller.held))
              end
              emit_players_past_first_raised(asm, at, OTHER_CONTROLLERS.map(&:held), "rt_tap_held_joined")
              asm.rts
            end

            # PLAYERS_PAST_FIRST raised to each player past the first whose word at +names+ (theirs in
            # order, the second player's first) holds a button: the highest such player less one, which
            # never falls. +label+ names the branches.
            def emit_players_past_first_raised(asm, at, names, label)
              names.each.with_index(1) do |name, past_first|
                skip = "#{label}_#{past_first}"
                asm.tst(:w, at.call(name))
                asm.branch(:eq, skip)
                asm.cmp(:w, asm.imm(past_first), at.call(PLAYERS_PAST_FIRST))
                asm.branch(:hs, skip)
                asm.move(:w, asm.imm(past_first), at.call(PLAYERS_PAST_FIRST))
                asm.label(skip)
              end
            end

            # +label+: D0 = the buttons held now on the pad whose data port is +data+. D1 and D2 are used.
            def emit_pad_now(asm, label, data)
              h = Console::GenesisHardware
              asm.label(label)
              asm.move(:b, asm.imm(h::PAD_TH), asm.abs_l(data))
              2.times { asm.nop }
              asm.move(:b, asm.abs_l(data), asm.d(1))
              asm.move(:b, asm.imm(0), asm.abs_l(data))
              2.times { asm.nop }
              asm.move(:b, asm.abs_l(data), asm.d(2))
              asm.not(:b, asm.d(1))
              asm.not(:b, asm.d(2))
              asm.moveq(0, asm.d(0))
              h::PAD_BITS.each do |name, (half, bit)|
                asm.btst(bit, asm.d(half == :high ? 1 : 2))
                asm.branch_over(:eq, 4)
                asm.or(:w, asm.imm(BUTTON_BITS.fetch(name)), asm.d(0))
              end
              asm.rts
            end

            # D0, the buttons held now on a pad, kept in +held+ and +seen+, and those that were not
            # down the frame before added to +pressed+.
            def emit_pad_noted(asm, at, seen, pressed, held)
              asm.move(:w, at.call(seen), asm.d(2))
              asm.not(:w, asm.d(2))
              asm.and(:w, asm.d(0), asm.d(2))
              asm.or(:w, at.call(pressed), asm.d(2))
              asm.move(:w, asm.d(2), at.call(pressed))
              asm.move(:w, asm.d(0), at.call(held))
              asm.move(:w, asm.d(0), at.call(seen))
            end

            # Where a pass's wait ends: the buttons for the pass about to start, from every frame the
            # last one took, and how many frames that was. The interrupt is held off while they are
            # taken, so a press it reads cannot fall between the two; one that came while it was held
            # off is taken as soon as it is allowed again.
            def emit_read_buttons(asm, memory, at)
              asm.label("rt_read_buttons")
              asm.ori_to_sr(INTERRUPTS_OFF_BITS)
              asm.move(:w, at.call(PAD_PRESSED), at.call(PRESSED))
              asm.clr(:w, at.call(PAD_PRESSED))
              asm.move(:w, at.call(PAD_HELD), at.call(HELD))
              if team_player?(memory)
                emit_tap_buttons_for_pass(asm, at)
              elsif second_pad?(memory)
                emit_second_pad_taken(asm, at)
              end
              asm.move(:l, at.call(FRAMES), asm.d(0))
              asm.move_to_sr(asm.imm(INTERRUPTS_ON))
              asm.move(:l, asm.d(0), asm.d(1))
              asm.sub(:w, at.call(FRAMES_MARK), asm.d(1))
              asm.move(:w, asm.d(0), at.call(FRAMES_MARK))
              asm.and(:l, asm.imm(0xFF), asm.d(1))
              asm.branch(:ne, "rt_read_buttons_some")
              asm.moveq(1, asm.d(1)) # a pass is worth at least the frame it ran in
              asm.label("rt_read_buttons_some")
              asm.move(:w, asm.d(1), at.call(FRAMES_TAKEN))
              asm.move(:l, at.call(PASSES), asm.d(2))
              asm.and(:l, asm.imm(STEPS_KEPT - 1), asm.d(2))
              asm.lea(asm.abs_l(memory[STEPS]), asm.a(0))
              asm.move(:b, asm.d(1), asm.idx(0, 0, 2))
              asm.cmp(:w, asm.imm(IR::Frames::MOST + 1), asm.d(1))
              asm.branch(:cs, "rt_read_buttons_step")
              asm.move(:w, asm.imm(IR::Frames::MOST), asm.d(1))
              asm.label("rt_read_buttons_step")
              asm.move(:w, asm.d(1), at.call(STEP_TAKEN))
              asm.rts
            end

            # The second pad's buttons for the pass about to start, as the first's are taken; and the
            # second player connected from the first pass a button of theirs went down in the frames
            # the last one took (Reference#count_connected_players). A button down from power-on is
            # Boot's to count.
            def emit_second_pad_taken(asm, at)
              asm.move(:w, at.call(SECOND_PAD_PRESSED), at.call(SECOND_PRESSED))
              asm.branch(:eq, "rt_read_buttons_second_quiet")
              asm.move(:w, asm.imm(1), at.call(PLAYERS_PAST_FIRST))
              asm.label("rt_read_buttons_second_quiet")
              asm.clr(:w, at.call(SECOND_PAD_PRESSED))
              asm.move(:w, at.call(SECOND_PAD_HELD), at.call(SECOND_HELD))
            end

            # The second to fifth players' buttons for the pass about to start, as the first's
            # are taken; and each connected from the first pass a button of theirs went down in the
            # frames the last one took (Reference#count_connected_players).
            def emit_tap_buttons_for_pass(asm, at)
              OTHER_CONTROLLERS.each do |controller|
                asm.move(:w, at.call(controller.pad_pressed), at.call(controller.pressed))
                asm.clr(:w, at.call(controller.pad_pressed))
                asm.move(:w, at.call(controller.pad_held), at.call(controller.held))
              end
              emit_players_past_first_raised(asm, at, OTHER_CONTROLLERS.map(&:pressed), "rt_read_buttons_joined")
            end

            # STOPPING. rt_halt stops the game where it is: what it drew since its last frame is
            # copied to the console in the next blank (or with the screen switched on, for a game
            # that never got as far as a frame), SHOWN marks that the end is on the screen, and the
            # processor sleeps from then on. Going wrong is the same, with what went wrong written
            # down first (rt_fault, D0 = what went wrong, the list and the numbers already in FAULT).
            def emit_stopping(asm, at)
              asm.label("rt_halt")
              asm.moveq(HALTED, asm.d(0))
              asm.label("rt_stop_with_state")
              asm.move(:w, asm.d(0), at.call(STATE))
              asm.jsr(asm.abs_l("rt_tint_prepare"))
              asm.jsr(asm.abs_l("rt_picture_prepare"))
              asm.jsr(asm.abs_l("rt_show_pass"))
              asm.move(:l, asm.imm(END_SHOWN), at.call(SHOWN))
              asm.label("rt_stopped")
              asm.stop(INTERRUPTS_ON)
              asm.bra("rt_stopped")

              asm.label("rt_fault")
              asm.move(:w, asm.d(0), at.call(FAULT))
              asm.moveq(WENT_WRONG, asm.d(0))
              asm.bra("rt_stop_with_state")

              # Where the processor lands when it meets something it cannot do (an odd address, a
              # bad instruction, a division by nought): the game stops, saying so.
              asm.label("rt_exception")
              asm.moveq(CPU_EXCEPTION, asm.d(0))
              asm.bra("rt_fault")
            end
          end
        end
      end
    end
  end
end
