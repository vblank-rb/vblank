# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # The frame: waiting for the screen, the buttons, stopping, and going wrong.
          #
          # The console draws the screen a line at a time, 224 of them, and then rests for 38 more
          # lines' worth of time — the vertical blank — before it starts again. Only in that rest
          # (or with the screen switched off) can video RAM, the colour memory and the sprite table
          # be written, so a pass of the game loop ends by waiting for it (rt_wait_vblank): the
          # processor sleeps (WAI) until the blank's interrupt (the NMI) wakes it. Then what the
          # pass changed in the picture is copied to the console (Runtime::Picture), and the
          # buttons are taken for the next pass.
          #
          # A pass that takes longer than a frame finds the blank already gone by the time it waits,
          # and waits for the next one: the game slows down rather than tearing.
          #
          # What the run is doing is kept where a reader of the running cartridge can find it
          # (SNES::HeadlessRun): how many passes have ended, which pass the screen is showing,
          # whether the game is waiting at a frame boundary, and whether it has stopped or gone
          # wrong and why. The names and their meanings are the Game Boy Color runtime's, so a
          # reader of either asks the same questions.
          module Frame
            # How the game stands, in STATE.
            RUNNING = 0
            HALTED = 1
            WENT_WRONG = 2

            # What went wrong, in FAULT's first word: the number every cartridge console's runtime
            # keeps for it (Backends::CartridgeFaults, Frame::LIST_FULL and the rest).
            include CartridgeFaults

            # FAULT: what went wrong (a word), the list's place (three bytes and a spare), and two
            # numbers that give how (four bytes each).
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
            # bits); where a pass's wait ends, the frames since the last wait ended are what that
            # pass answers for (FRAMES_TAKEN), and held between one and IR::Frames::MOST (STEP_TAKEN).
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
            # The second controller's of each of those, in a game that reads it.
            SECOND_HELD = "rt second held"
            SECOND_SEEN = "rt second seen"
            SECOND_PRESSED = "rt second pressed"
            SECOND_PAD_HELD = "rt second pad held"
            SECOND_PAD_PRESSED = "rt second pad pressed"
            # 1 when the console's own read of the controllers in this blank is still to be taken
            # from its registers (#emit_auto_read).
            PAD_DUE = "rt pad due"
            # How many players past the first are connected, in a game that asks (`players_connected`):
            # the highest player with a button down so far, less one, so nought is the first alone.
            PLAYERS_PAST_FIRST = "rt players past first"
            # 1 once the interrupt has come since the game began to wait.
            VBLANK = "rt vblank"
            # 1 once the screen is on: before the end of the first pass it is off.
            DISPLAY_ON = "rt display on"
            # The frames spent setting up, before the one the first pass is shown in: from the
            # interrupt being switched on (Runtime#emit_start, or near the top of setting up in a game that
            # reads the count: Boot#emit_memories_cleared_counted), through the game's first pass and the
            # copy of its picture. They are frames of a screen still off, so they move nothing on but
            # the count of frames since power-on, as the interpreter is told
            # (Reference#frames_setting_up): the first pass answers for one frame, and the music, the
            # buttons and the game's catching up start there, however long setting up took. Kept
            # one more, for a reader of the run, so nought means not counted yet; 16 bits.
            SETTING_UP = "rt frames setting up"
            # ...and the same, not one more, until it is added to the game's count of frames since
            # power-on (#emit_setting_up_added), in a game that keeps one.
            SETTING_UP_UNCOUNTED = "rt frames setting up uncounted"

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            # The buttons as the controller hands them over, a bit each in a 16-bit word with B at
            # the top (Console::SNESHardware::JOYPAD_BITS), to the bit each has in IR::Buttons's
            # order. X and Y are turned round only for a game that can ask about them, since this
            # runs in the interrupt on every frame and a game that never reads them should not pay.
            BUTTON_BITS = Ractor.make_shareable(Buttons::NAMES.each_with_index.filter_map do |name, bit|
              [name, [1 << Console::SNESHardware::JOYPAD_BITS.fetch(name), 1 << bit]] if Console::SNESHardware::JOYPAD_BITS.key?(name)
            end.to_h)

            EXTRA_BUTTONS = %i[x y].freeze

            # Where one controller's buttons are kept: through the pass (+held+, +pressed+), as the
            # interrupt last read them (+seen+), and as the interrupt gathers them for the next pass
            # (+pad_held+, +pad_pressed+).
            Controller = Data.define(:held, :seen, :pressed, :pad_held, :pad_pressed)

            # Every controller a game can read, the first player's first: the two ports, then the
            # third and fourth players on a Super Multitap in the second port.
            CONTROLLERS = Ractor.make_shareable([
                                                  Controller.new(HELD, SEEN, PRESSED, PAD_HELD, PAD_PRESSED),
                                                  Controller.new(SECOND_HELD, SECOND_SEEN, SECOND_PRESSED,
                                                                 SECOND_PAD_HELD, SECOND_PAD_PRESSED),
                                                  Controller.new("rt third held", "rt third seen", "rt third pressed",
                                                                 "rt third pad held", "rt third pad pressed"),
                                                  Controller.new("rt fourth held", "rt fourth seen", "rt fourth pressed",
                                                                 "rt fourth pad held", "rt fourth pad pressed")
                                                ])

            # The controllers a game reads through a Super Multitap: the first port's, and the
            # tap's first three plugs. Its fourth plug, the console's fifth controller, is not read.
            MULTITAP_CONTROLLERS = 4

            # WRIO's top bit picks which two of the tap's plugs the second port's two lines carry:
            # set, its first two (the second and third controllers); clear, its last two. Set is
            # also what the picture's line latch needs (Blank#emit_line_now), so it is put back.
            TAP_FIRST_PLUGS = 0x80
            TAP_LAST_PLUGS = 0x00

            # The ports the controllers are read through (fullsnes, "SNES Controllers I/O Ports").
            JOYSER0 = Console::SNESHardware::JOYSER0
            JOYSER1 = Console::SNESHardware::JOYSER1
            # ...and the registers the console's own read leaves each one in, the first's then the
            # second's.
            AUTO_READ_REGISTERS = [Console::SNESHardware::JOY1L, Console::SNESHardware::JOY2L].freeze

            # Where in a Super Multitap's four words of the direct page (#emit_tap_bits) each part
            # is: controllers 2, 3 and 4 as read, then whether the tap answered.
            TAP_WORDS = { 2 => 0, 3 => 2, 4 => 4 }.freeze
            TAP_ANSWERED = 6

            module_function

            # The controllers past the first of a game that reads +controllers+.
            def other_controllers(controllers) = CONTROLLERS.drop(1).first(controllers - 1)

            # Whether +program+ reads X or Y, by name or as any button at all.
            def reads_extra_buttons?(program)
              program.walk.any? { |node| %i[held pressed pulled].include?(node.kind) && (EXTRA_BUTTONS + [Buttons::ANY]).include?(node.button) }
            end

            # How many controllers +program+ reads: 1; 2 for a game that reads the second
            # controller, on its own or as any player's, or asks how many are connected; or
            # MULTITAP_CONTROLLERS for one that reads a Super Multitap (#reads_multitap?). A game
            # that reads fewer is built without the rest, the same bytes as before there were any.
            def controllers_read(program)
              return MULTITAP_CONTROLLERS if reads_multitap?(program)

              reads_second_controller?(program) ? 2 : 1
            end

            def reads_second_controller?(program)
              program.walk.any? do |node|
                (%i[held pressed pulled].include?(node.kind) && node.player != 1) || node.kind == :players_connected
              end
            end

            # Whether +program+ reads the third or fourth player: a button of theirs by number, or,
            # in a game that takes more than two players (`players:`), any player's button or how
            # many are connected, which they can be part of.
            def reads_multitap?(program)
              several = program.max_players.to_i > 2
              program.walk.any? do |node|
                if %i[held pressed pulled].include?(node.kind)
                  (node.player.is_a?(Integer) && node.player > 2) || (several && node.player == Buttons::ANY)
                else
                  several && node.kind == :players_connected
                end
              end
            end

            # Whether +program+ asks how many players are connected.
            def counts_players?(program) = program.walk.any? { |node| node.kind == :players_connected }

            # How many controllers the runtime laid out in +memory+ reads.
            def controllers_reserved(memory) = CONTROLLERS.count { |controller| memory.reserved?(controller.held) }

            def reserve(memory, controllers: 1, counts_players: false)
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
              memory.reserve(SETTING_UP, 2)
              memory.reserve(SETTING_UP_UNCOUNTED, 2)
              other_controllers(controllers).each do |controller|
                controller.to_h.each_value { |name| memory.reserve(name, 2) }
              end
              memory.reserve(PLAYERS_PAST_FIRST, 2) if counts_players
              memory.reserve(PAD_DUE, 2)
            end

            # What NMITIMEN holds once the game's buttons have been read at power-on, with the
            # blank's interrupt on, and held off. The console's read of the controllers stays on
            # through both, since switching it off part way through leaves its registers half
            # filled (fullsnes, "SNES Controllers I/O Ports, Automatic Reading").
            INTERRUPT_HELD_OFF = Console::SNESHardware::AUTO_JOYPAD
            INTERRUPT_ON = Console::SNESHardware::NMI_ON | INTERRUPT_HELD_OFF

            # NMITIMEN written with +value+, A 16 bits wide before and after.
            def emit_interrupt_setting(asm, value)
              asm.sep(0x20)
              asm.lda(value)
              asm.sta(asm.abs(Console::SNESHardware::NMITIMEN))
              asm.rep(0x20)
            end

            # LAST_PASS, in a game whose tick handler waits (LoweringPlan#keeps_last_pass_number?).
            def reserve_last_pass(memory) = memory.reserve(LAST_PASS, 4)

            # Branches to rt_frame_begins_skipped when LAST_PASS is written and the pass that just ended
            # (PASSES) comes after it: LAST_PASS less PASSES, a half at a time, borrows out of the top half.
            # Neither count is ever negative, so the borrow is the answer.
            def emit_skip_past_last_pass(asm, at)
              asm.lda(at.call(LAST_PASS))
              asm.ora(at.call(LAST_PASS, 2))
              asm.beq("rt_frame_begins_not_past")
              asm.lda(at.call(LAST_PASS))
              asm.sec
              asm.sbc(at.call(PASSES))
              asm.lda(at.call(LAST_PASS, 2))
              asm.sbc(at.call(PASSES, 2))
              asm.bcc("rt_frame_begins_skipped")
              asm.label("rt_frame_begins_not_past")
            end

            # +pad+ is two words of the direct page, the same on the game's page and the
            # interrupt's, that reading the controller works in, and +tap+ four more, for a game that
            # reads MULTITAP_CONTROLLERS (#emit_tap_bits). +controllers+ is how many the game reads
            # (#controllers_read). +sound+ for a game that makes sound,
            # whose wait ends in Sound's rt_sound_frame. +sleeps_every_pass+ for the cartridge a checked
            # run reads (#emit_sleep_unless_in_blank gives the reason). +count_at+ is where the game
            # keeps its count of frames since power-on (#emit_setting_up_counted).
            def emit(asm, memory, pad:, tap: nil, sound: false, extra_buttons: false, controllers: 1, dims: false,
                     sleeps_every_pass: false, count_at: nil)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }

              asm.label("rt_vblank_interrupt")
              emit_interrupt_body(asm, memory) do
                asm.jsr(asm.abs("rt_pad_read"))
                # A picture of big pixels sent behind the game, a blank at a time.
                asm.jsr(asm.abs("rt_paint_doubled_behind")) if PaintDoubledSend.behind?(memory)
              end

              # The end of a pass: count it, move on what keeps time by the frame, mark the game as
              # waiting, and wait for the screen. What keeps time by the frame moves on here, before
              # the game is marked as waiting, because that is where the interpreter moves it on: at
              # the frame boundary, before anything is read of the frame (Reference#advance_frame).
              asm.label("rt_wait_vblank")
              asm.inc(at.call(PASSES))
              asm.bne("rt_wait_vblank_counted")
              asm.inc(at.call(PASSES, 2))
              asm.label("rt_wait_vblank_counted")
              asm.jsr(asm.abs("rt_frame_begins_unless_last"))
              asm.jsl(asm.long("rt_tint_prepare"))
              asm.jsl(asm.long("rt_picture_prepare"))
              asm.lda(1)
              asm.sta(at.call(WAITING))
              asm.jsr(asm.abs("rt_show_pass"))
              asm.lda(at.call(HOLD))
              asm.beq("rt_wait_vblank_buttons")
              asm.jml(asm.long("rt_stopped"))
              asm.label("rt_wait_vblank_buttons")
              asm.jsr(asm.abs("rt_read_buttons"))
              asm.stz(at.call(WAITING))
              emit_setting_up_added(asm, at, count_at) if count_at
              asm.jsl(asm.long("rt_sound_frame")) if sound # the music of the frames the pass took (Sound)
              asm.rtl

              emit_show_pass_routines(asm, memory, at, dims, goes_on_in_blank: memory.reserved?(Sound::QUEUE) && !sleeps_every_pass,
                                                             count_at: count_at)
              emit_buttons(asm, memory, Reading.new(pad: pad, tap: tap, extra_buttons: extra_buttons, controllers: controllers))
              emit_stopping(asm, memory)
            end

            # How a runtime reads its controllers: the direct page it works in (+pad+, and +tap+ for
            # a Super Multitap), whether it turns X and Y round, and how many it reads.
            Reading = Data.define(:pad, :tap, :extra_buttons, :controllers) do
              def multitap? = controllers == MULTITAP_CONTROLLERS
            end

            # The interrupt that signals a frame has been drawn. Everything it touches is saved, and it
            # works on a direct page of its own. The frame is counted and the buttons read (the
            # block emits the reading), so a pass that spans several frames answers for each of them,
            # as the interpreter's does.
            def emit_interrupt_body(asm, memory)
              h = Console::SNESHardware
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              asm.rep(0x30)
              asm.pha
              asm.phx
              asm.phy
              asm.phb
              asm.phd
              asm.lda(Memory::INTERRUPT_PAGE)
              asm.tcd
              asm.sep(0x20)
              asm.lda(0x80)
              asm.pha
              asm.plb
              asm.lda(asm.abs(h::RDNMI)) # read, so the interrupt is not taken again
              asm.rep(0x20)
              yield
              asm.inc(at.call(FRAMES))
              asm.bne("rt_vblank_counted")
              asm.inc(at.call(FRAMES, 2))
              asm.label("rt_vblank_counted")
              asm.lda(1)
              asm.sta(at.call(VBLANK))
              asm.pld
              asm.plb
              asm.ply
              asm.plx
              asm.pla
              asm.rti
            end

            # A blank counted by hand, while the screen's interrupt is held off: FRAMES one more if a
            # blank has begun since RDNMI was last read. A blank sets RDNMI's top bit as it begins,
            # whether the interrupt is on or not, and the bit stays until it is read or the blank ends,
            # so code that looks more often than a blank lasts counts each one once. A 8 bits wide
            # before and after; +label+ names the place after it.
            def emit_blank_counted_by_hand(asm, memory, label)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              asm.lda(asm.abs(Console::SNESHardware::RDNMI))
              asm.bpl(label)
              asm.rep(0x20)
              asm.inc(at.call(FRAMES))
              asm.bne("#{label}_high")
              asm.inc(at.call(FRAMES, 2))
              asm.label("#{label}_high")
              asm.sep(0x20)
              asm.label(label)
            end

            # The same interrupt, as a routine of its own with the buttons' reading written into it
            # rather than called, for a copy of it that runs from work RAM (Runtime::Chip). Its
            # branches are relative and every address it names is fixed, so it runs wherever it is
            # copied to. The controllers are turned into IR::Buttons's order bit by bit here, not
            # through the table rt_buttons_remapped reads, which is in the cartridge and out of the
            # processor's reach while the chip runs. The chip runs inside a pass, so the console's
            # own read is taken here at once, as rt_pad_take takes it.
            def emit_interrupt_whole(asm, memory, pad:, tap: nil, extra_buttons: false, controllers: 1)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              emit_interrupt_body(asm, memory) do
                emit_auto_read_awaited(asm, "rt_whole_auto_read")
                asm.stz(at.call(PAD_DUE))
                remapped = lambda do |controller, label|
                  emit_controller_update(asm, at, pad, controller) do
                    asm.lda(controller_word_place(asm, tap, controllers, controller))
                    asm.sta(asm.direct(pad))
                    emit_buttons_remapped_in_place(asm, pad, label, extra_buttons)
                  end
                end
                remapped.call(CONTROLLERS.first, "rt_whole_auto_read_0")
                emit_tap_bits_after_auto_read(asm, tap, "rt_whole_tap") if controllers == MULTITAP_CONTROLLERS
                other_controllers(controllers).each_with_index do |controller, index|
                  remapped.call(controller, "rt_whole_auto_read_#{index + 1}")
                end
                emit_line_latched_again(asm) if controllers == MULTITAP_CONTROLLERS
              end
            end

            # Where +controller+'s word is, as the console hands it over: through a Super Multitap,
            # the word #emit_tap_bits_after_auto_read left; else the console's own read's register.
            def controller_word_place(asm, tap, controllers, controller)
              player = CONTROLLERS.index(controller) + 1
              return asm.direct(tap + TAP_WORDS.fetch(player)) if controllers == MULTITAP_CONTROLLERS && player > 1

              asm.abs(AUTO_READ_REGISTERS.fetch(player - 1))
            end

            # Waits while HVBJOY's bit 0 shows the console still reading the controllers. A 16 bits
            # wide before and after; +label+ names the loop.
            def emit_auto_read_awaited(asm, label)
              asm.sep(0x20)
              asm.label(label)
              asm.lda(asm.abs(Console::SNESHardware::HVBJOY))
              asm.lsr
              asm.bcs(label)
              asm.rep(0x20)
            end

            # rt_show_pass: what the pass drew, on the screen, and SHOWN saying so. The first time,
            # the screen is still off, so everything set up so far is copied while nothing is drawn,
            # and the screen comes on in the blank after, showing it; after that, the pass's changes
            # are copied in the blank. Then the sleeps it waits for the blank in, and the step that
            # moves on what keeps time by the frame. +goes_on_in_blank+ for a pass that ends inside the
            # blank to go straight on to the copying (#emit_sleep_unless_in_blank).
            def emit_show_pass_routines(asm, memory, at, dims, goes_on_in_blank:, count_at: nil)
              h = Console::SNESHardware
              asm.label("rt_show_pass")
              asm.lda(at.call(DISPLAY_ON))
              asm.bne("rt_show_pass_on")
              asm.jsl(asm.long("rt_upload_whole"))
              emit_setting_up_counted(asm, at, count_at)
              asm.jsr(asm.abs("rt_sleep_until_vblank"))
              if Letterbox.named_band?(memory)
                asm.jsr(asm.abs("rt_letterbox_show_band")) # the screen on for the band the game named alone
              elsif dims
                Tint.emit_brightness(asm, memory)
              else
                asm.sep(0x20)
                asm.lda(h::FULL_BRIGHTNESS)
                asm.sta(asm.abs(h::INIDISP))
                asm.rep(0x20)
              end
              Mosaic.emit_write(asm, memory) if Mosaic.kept?(memory)
              asm.lda(1)
              asm.sta(at.call(DISPLAY_ON))
              asm.bra("rt_show_pass_shown")
              asm.label("rt_show_pass_on")
              if Letterbox.kept?(memory)
                # The copy starts wherever the screen is off, and the blank's interrupt is waited
                # for after it (rt_show_pass_shown).
                asm.jsr(asm.abs("rt_letterbox_wait"))
              else
                asm.jsr(asm.abs(goes_on_in_blank ? "rt_sleep_unless_in_blank" : "rt_sleep_until_vblank"))
              end
              asm.jsl(asm.long("rt_upload"))
              # After it, since a big change takes several blanks and the brightness belongs to
              # the picture it arrives with, as the colours do.
              if dims
                Tint.emit_brightness(asm, memory)
              elsif memory.reserved?(Picture::SCENE_BACKGROUND_TILES) && !Letterbox.named_band?(memory) # the picture was off for a scene's tiles
                asm.sep(0x20)
                asm.lda(h::FULL_BRIGHTNESS)
                asm.sta(asm.abs(h::INIDISP))
                asm.rep(0x20)
              end
              # ...and the size of the blocks the same way (Mosaic).
              Mosaic.emit_write(asm, memory) if Mosaic.kept?(memory)
              asm.label("rt_show_pass_shown")
              asm.jsr(asm.abs("rt_letterbox_shown")) if Letterbox.kept?(memory)
              # A picture of big pixels still being sent behind the game has SHOWN set when it is all
              # there (PaintDoubledSend).
              PaintDoubledSend.emit_branch_if_sending(asm, memory, "rt_show_pass_sending")
              asm.lda(at.call(PASSES))
              asm.sta(at.call(SHOWN))
              asm.lda(at.call(PASSES, 2))
              asm.sta(at.call(SHOWN, 2))
              asm.label("rt_show_pass_sending")
              asm.rts

              emit_sleep_unless_in_blank(asm, at) if goes_on_in_blank
              asm.label("rt_sleep_until_vblank")
              asm.stz(at.call(VBLANK))
              asm.label("rt_sleep_until_vblank_wait")
              emit_due_read_taken(asm, memory, "rt_sleep_until_vblank_read")
              Sound.emit_idle_step(asm, memory)
              asm.lda(at.call(VBLANK))
              asm.beq("rt_sleep_until_vblank_wait")
              asm.rts

              # What keeps time by the frame, moved on — unless the reader has taken the last pass it
              # compares, after which the interpreter moves nothing on (LAST_PASS_TAKEN).
              asm.label("rt_frame_begins_unless_last")
              asm.lda(at.call(LAST_PASS_TAKEN))
              asm.bne("rt_frame_begins_skipped")
              emit_skip_past_last_pass(asm, at) if memory.reserved?(LAST_PASS)
              asm.jsl(asm.long("rt_frame_begins"))
              asm.label("rt_frame_begins_skipped")
              asm.rts
            end

            # The first pass's picture is copied and the screen is about to come on in the next blank.
            # Every frame counted so far is SETTING_UP, and the count starts again from nought, so the
            # blank's interrupt counts frame 1, the first pass's: that pass answers for one frame
            # (#emit_buttons' rt_read_buttons), and a reader numbers the frames from it as the
            # interpreter does. The interrupt is held off while the count is taken, as where a wait
            # ends, so none falls between the read and the nought. The game's own count of frames since
            # power-on, at +count_at+, takes them all (nil for a game that keeps none).
            def emit_setting_up_counted(asm, at, count_at)
              emit_interrupt_setting(asm, INTERRUPT_HELD_OFF)
              asm.lda(at.call(FRAMES))
              asm.stz(at.call(FRAMES))
              asm.stz(at.call(FRAMES, 2))
              asm.tay
              emit_interrupt_setting(asm, INTERRUPT_ON)
              asm.tya
              asm.inc
              asm.sta(at.call(SETTING_UP)) # one more, so nought is a count not taken yet
              return unless count_at

              asm.sty(at.call(SETTING_UP_UNCOUNTED))
            end

            # The frames setting up took, added to the game's count of frames since power-on at
            # +count_at+ once, as the first pass's wait ends: where the interpreter adds them
            # (Reference#store_frame_counters), after the game was found waiting.
            def emit_setting_up_added(asm, at, count_at)
              place = ->(plus) { count_at + plus > 0xFFFF ? asm.long(count_at + plus) : asm.abs(count_at + plus) }
              asm.lda(at.call(SETTING_UP_UNCOUNTED))
              asm.beq("rt_setting_up_added")
              asm.clc
              asm.adc(place.call(0))
              asm.sta(place.call(0))
              asm.lda(place.call(2))
              asm.adc(0)
              asm.sta(place.call(2))
              asm.stz(at.call(SETTING_UP_UNCOUNTED))
              asm.label("rt_setting_up_added")
            end

            # A pass that ends a little into the blank still makes it. Music plays where a wait ends,
            # so a frame on which many parts start their notes takes a good part of the time the next
            # pass was counting on, and that pass can end a few lines after the blank begins. Sleeping
            # then would lose a whole frame over those few lines, with most of the blank unused. So in
            # a game with music (Sound::QUEUE), a pass that finds the blank it was aiming for still
            # going goes straight on to the copying, whose every piece asks the line first and waits
            # for the next blank if it has run out of time (Blank).
            #
            # FRAMES still at FRAMES_MARK means no blank has begun since the last wait ended: a pass
            # so short that it ends in the blank it started in, which is still the frame before's,
            # and it sleeps.
            #
            # A checked run's cartridge sleeps at every pass (SNES#initialize's +sleeps_every_pass+).
            # A pass that goes straight on is waiting only while the blank lasts, and the emulator
            # stops only as a blank begins, so a reader that looks once a frame never finds it waiting
            # and never reads its numbers (CartridgeHeadlessRun#passes_missed). The cartridge a checked
            # run builds therefore leaves this routine out, and each such pass takes one frame more;
            # the interpreter is told the frames each pass took, so the two still agree. What that
            # costs: checked runs never play the copying started late in a blank. The headless run's
            # own tests of the shipped cartridge (its frames, its torn frames) are where it is played.
            def emit_sleep_unless_in_blank(asm, at)
              asm.label("rt_sleep_unless_in_blank")
              asm.lda(at.call(FRAMES))
              asm.cmp(at.call(FRAMES_MARK))
              asm.beq("rt_sleep_until_vblank")
              Blank.emit_line_now(asm)
              asm.cmp(Blank::FIRST_BLANK_LINE)
              asm.bcc("rt_sleep_until_vblank")
              asm.rts
            end

            # BUTTONS. As each blank begins, the console reads both ports by itself, with NMITIMEN's
            # bit 0 set: it clocks each controller's sixteen bits into JOY1L/JOY1H and JOY2L/JOY2H,
            # B at the top (JOYPAD_BITS), in about three lines, while the processor gets on with
            # other work, and HVBJOY's bit 0 is set until they are all there (fullsnes, "SNES
            # Controllers I/O Ports, Automatic Reading"; SNESdev wiki, "Controller reading"). The
            # console's own games read a controller that way, with one load once the bit clears,
            # and so does this runtime (#emit_auto_read). Each controller is then turned into
            # IR::Buttons's order through a table worked out as the cartridge is built
            # (rt_buttons_remapped), a few instructions in place of a test of each button.
            #
            # A controller can also be read by hand, through its serial port: a write of 1 and then
            # 0 to JOYSER0 tells it to take hold of its buttons, and each read of the port hands over
            # the next of them in bit 0, B first, then Y, Select, Start, Up, Down, Left, Right, A, X,
            # L, R and four that are always 0. Read sixteen times and turned in from the right, they
            # come out laid out as the automatic read lays them out. That costs sixteen slow reads,
            # so it is done only where the automatic read cannot serve: once at power-on, before the
            # console has read anything (rt_buttons_from_power_on, which switches the automatic read
            # on after it, so the two never clock the ports at once), and for a Super Multitap's
            # last controller (#emit_tap_bits_after_auto_read). The second controller is the same
            # read through JOYSER1. Both take hold of their buttons from the one write to JOYSER0,
            # and each read here is two bytes wide, which walks the next port on too: so the read of
            # the first controller has already used the second's up, and the second's read starts
            # by telling them both to take hold again.
            def emit_buttons(asm, memory, reading)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              pad = reading.pad
              # rt_buttons_now: A = the buttons held now, a bit each in IR::Buttons's order.
              emit_controller_read(asm, pad, "rt_buttons_now", JOYSER0, reading.extra_buttons)
              if reading.multitap?
                asm.label("rt_tap_read_by_hand")
                emit_tap_bits(asm, reading.tap, "rt_tap_read_by_hand")
                asm.rts
                asm.label("rt_tap_read")
                emit_tap_bits_after_auto_read(asm, reading.tap, "rt_tap_read")
                asm.rts
              elsif reading.controllers == 2
                emit_controller_read(asm, pad, "rt_second_buttons_now", JOYSER1, reading.extra_buttons)
              end
              emit_buttons_remapped_by_table(asm, pad, reading.extra_buttons)
              others = other_controllers(reading.controllers)
              emit_auto_read(asm, at, reading)

              # Where a pass's wait ends: the buttons for the pass about to start, from every frame
              # the last one took, and how many frames that was. The interrupt is held off while they
              # are taken, so a press it reads cannot fall between the two; one that came while it was
              # held off is taken as soon as it is allowed again. A read of the console's still due is
              # taken first.
              asm.label("rt_read_buttons")
              emit_interrupt_setting(asm, INTERRUPT_HELD_OFF)
              asm.lda(at.call(PAD_DUE))
              asm.beq("rt_read_buttons_none_due")
              asm.jsr(asm.abs("rt_pad_take"))
              asm.label("rt_read_buttons_none_due")
              asm.lda(at.call(PAD_PRESSED))
              asm.sta(at.call(PRESSED))
              asm.stz(at.call(PAD_PRESSED))
              asm.lda(at.call(PAD_HELD))
              asm.sta(at.call(HELD))
              others.each do |controller|
                asm.lda(at.call(controller.pad_pressed))
                asm.sta(at.call(controller.pressed))
                asm.stz(at.call(controller.pad_pressed))
                asm.lda(at.call(controller.pad_held))
                asm.sta(at.call(controller.held))
              end
              counted = memory.reserved?(PLAYERS_PAST_FIRST)
              emit_players_counted(asm, at, others.map(&:pressed), "rt_read_buttons_joined") if counted
              asm.lda(at.call(FRAMES))
              asm.tay
              emit_interrupt_setting(asm, INTERRUPT_ON)
              asm.tya
              asm.sec
              asm.sbc(at.call(FRAMES_MARK))
              asm.sty(at.call(FRAMES_MARK))
              asm.bne("rt_read_buttons_some")
              asm.lda(1) # a pass is worth at least the frame it ran in
              asm.label("rt_read_buttons_some")
              asm.sta(at.call(FRAMES_TAKEN))
              asm.tay
              asm.lda(at.call(PASSES))
              asm.and_a(STEPS_KEPT - 1)
              asm.tax
              asm.tya
              asm.sep(0x20)
              asm.sta(asm.abs_x(memory[STEPS]))
              asm.rep(0x20)
              asm.cmp(IR::Frames::MOST + 1)
              asm.bcc("rt_read_buttons_step")
              asm.lda(IR::Frames::MOST)
              asm.label("rt_read_buttons_step")
              asm.sta(at.call(STEP_TAKEN))
              asm.rts

              # Held from power-on: down before the first frame boundary, and not yet seen there, so
              # the first boundary still finds them going down — the interpreter's `hold`.
              asm.label("rt_buttons_from_power_on")
              asm.jsr(asm.abs("rt_buttons_now"))
              asm.sta(at.call(HELD))
              asm.jsr(asm.abs("rt_tap_read_by_hand")) if reading.multitap?
              others.each.with_index(2) do |controller, player|
                emit_buttons_now(asm, reading, player)
                asm.sta(at.call(controller.held))
              end
              # A player holding a button from power-on is connected from the first pass, as the
              # interpreter counts the buttons it is told to hold before the game starts.
              emit_players_counted(asm, at, others.map(&:held), "rt_buttons_from_power_on_joined") if counted
              # Read by hand, the console's own read is switched on only now, so the two never
              # clock the ports at once. The interrupt is on by now.
              emit_interrupt_setting(asm, INTERRUPT_ON)
              asm.rtl
            end

            # The console's own read of the controllers, taken from its registers.
            #
            # It is there from about three lines into the blank (#emit_buttons), so the blank's
            # interrupt, which comes as the blank begins, would have to wait for it. It does that
            # only while a pass is running, since then the frame's buttons are wanted before the
            # pass goes on and nothing else will take them. A game waiting at a frame boundary is
            # copying its picture to the console as the blank begins, as the console's own games
            # are, and takes the read once that is done, where its wait ends (rt_read_buttons):
            # the interrupt only marks it due (PAD_DUE). The copy of the sprite table alone takes
            # longer than the console's read, so the read is there by then. A wait that runs into
            # another blank first takes a read still due as it waits (#emit_due_read_taken).
            #
            # A Super Multitap's first two plugs come through the second port's two lines, so the
            # console's read leaves them in JOY2L and JOY4L, as Nintendo's MULTI5 routine takes
            # them; its last plug alone is read by hand (#emit_tap_bits_after_auto_read).
            #
            #   rt_pad_read   in the interrupt: the read marked due, or taken now in a pass
            #   rt_pad_take   (JSR, the interrupt held off or running): the read taken, once there
            #   rt_pad_take_due (JSR): a read still due taken, the interrupt held off meanwhile; X kept
            def emit_auto_read(asm, at, reading)
              pad = reading.pad
              asm.label("rt_pad_read")
              asm.lda(at.call(WAITING))
              asm.beq("rt_pad_take")
              asm.lda(at.call(PAD_DUE))
              asm.bne("rt_pad_take")
              asm.inc(at.call(PAD_DUE))
              asm.rts

              asm.label("rt_pad_take")
              emit_auto_read_awaited(asm, "rt_pad_take_wait")
              asm.stz(at.call(PAD_DUE))
              asm.jsr(asm.abs("rt_tap_read")) if reading.multitap?
              CONTROLLERS.first(reading.controllers).each do |controller|
                emit_controller_update(asm, at, pad, controller) do
                  asm.lda(controller_word_place(asm, reading.tap, reading.controllers, controller))
                  asm.jsr(asm.abs("rt_buttons_remapped"))
                end
              end
              emit_line_latched_again(asm) if reading.multitap?
              asm.rts

              asm.label("rt_pad_take_due")
              emit_interrupt_setting(asm, INTERRUPT_HELD_OFF)
              asm.phx
              asm.jsr(asm.abs("rt_pad_take"))
              asm.plx
              emit_interrupt_setting(asm, INTERRUPT_ON)
              asm.rts
            end

            # A read of the console's still due (#emit_auto_read) taken now if it is there, for a
            # wait that can span a blank: a read left due when the next blank's begins is lost. One
            # still coming in is left to the wait's next look rather than waited for, since the
            # wait may be for the blank's copying to start. A 16 bits wide; +label+ names the place
            # after.
            def emit_due_read_taken(asm, memory, label)
              asm.lda(asm.abs(memory[PAD_DUE]))
              asm.beq(label)
              asm.lda(asm.abs(Console::SNESHardware::HVBJOY)) # and RDIO, read for nothing
              asm.lsr
              asm.bcs(label)
              asm.jsr(asm.abs("rt_pad_take_due"))
              asm.label(label)
            end

            # A = the buttons held now on +player+'s controller (2 or more), a bit each in
            # IR::Buttons's order: through a Super Multitap, as rt_tap_read last left them.
            def emit_buttons_now(asm, reading, player)
              return asm.jsr(asm.abs("rt_second_buttons_now")) unless reading.multitap?

              asm.lda(asm.direct(reading.tap + TAP_WORDS.fetch(player)))
              asm.jsr(asm.abs("rt_buttons_remapped"))
            end

            # The count of players past the first (PLAYERS_PAST_FIRST) raised to each player past the
            # first whose word at +names+ (theirs in order, the second player's first) holds a
            # button: so it is the highest such player less one, and never falls
            # (Reference#count_connected_players). +label+ names the branches.
            def emit_players_counted(asm, at, names, label)
              names.each.with_index(1) do |name, past_first|
                skip = "#{label}_#{past_first}"
                asm.lda(at.call(name))
                asm.beq(skip)
                asm.lda(past_first)
                asm.cmp(at.call(PLAYERS_PAST_FIRST))
                asm.bcc(skip)
                asm.sta(at.call(PLAYERS_PAST_FIRST))
                asm.label(skip)
              end
            end

            # ### The Super Multitap
            #
            # It plugs into the second port and has four plugs of its own, the
            # console's controllers 2 to 5. Both its lines are read at once: each read of JOYSER1
            # hands over a bit of one plug in bit 0 and of another in bit 1, and WRIO's top bit
            # picks which two (TAP_FIRST_PLUGS: controllers 2 and 3; TAP_LAST_PLUGS: 4 and 5). It
            # is read the way fullsnes gives ("SNES Controllers Multiplayer 5"): the latch held high
            # while eight reads of the second line find it 1 (a tap pulls it high; a plain
            # controller, or none, leaves it 0), the latch let go, sixteen reads of controllers 2
            # and 3, WRIO's bit cleared, sixteen of controller 4, and the bit set again. A tap whose
            # third controller's first eight buttons read all held is not believed either, since
            # nobody holds all four ways of the cross at once. Nintendo's own MULTI5 routine reads it
            # the same way, taking the first sixteen bits from the console's automatic read.
            #
            # With no tap there, the third and fourth controllers hold nothing, and the last
            # sixteen reads are never made: a plain controller would hand over sixteen bits of 1
            # past its own, which a game would read as every button down.
            #
            # WRIO's top bit going from 1 to 0 also latches the picture's line counters, as a read of
            # SLHV does (fullsnes, "SNES PPU Timers and Status"). So a line asked for by
            # Blank#emit_line_now that this interrupt lands in the middle of would read the line
            # the tap was read on, with the rest of the interrupt still to run: lines of the blank
            # counted as left that are gone. The interrupt latches the line again as it ends
            # (#emit_line_latched_again), so such a reading is the line the interrupt ended on.
            #
            # On every frame, controllers 2 and 3 come from the console's automatic read instead,
            # which WRIO's top bit, set, lets through the second port's two lines into JOY2L and
            # JOY4L (#emit_tap_bits_after_auto_read); only the tap's answer and controller 4 are
            # read by hand, as MULTI5 does. At power-on, before the console has read anything, all
            # three are read by hand.
            #
            # +tap+ is four words of the direct page: controllers 2, 3 and 4 as read, B at the top
            # (JOYPAD_BITS), then whether the tap answered. A is 16 bits wide after, X is used.
            def emit_tap_bits(asm, tap, label) = emit_tap_bits_read(asm, tap, label, after_auto_read: false)

            # The same, with controllers 2 and 3 taken from the console's read of this blank, once
            # it is there.
            def emit_tap_bits_after_auto_read(asm, tap, label) = emit_tap_bits_read(asm, tap, label, after_auto_read: true)

            def emit_tap_bits_read(asm, tap, label, after_auto_read:)
              h = Console::SNESHardware
              answered = tap + TAP_ANSWERED
              asm.sep(0x20)
              asm.lda(TAP_FIRST_PLUGS)
              asm.sta(asm.abs(h::WRIO))
              asm.lda(1)
              asm.sta(asm.abs(JOYSER0))
              asm.lda(0b10)
              asm.sta(asm.direct(answered))
              asm.ldx(8)
              asm.label("#{label}_seen")
              asm.lda(asm.abs(JOYSER1))
              asm.and_a(asm.direct(answered))
              asm.sta(asm.direct(answered))
              asm.dex
              asm.bne("#{label}_seen")
              asm.stz(asm.abs(JOYSER0))
              asm.rep(0x20)
              asm.stz(asm.direct(tap + TAP_WORDS.fetch(4)))
              if after_auto_read
                asm.lda(asm.abs(h::JOY2L))
                asm.sta(asm.direct(tap + TAP_WORDS.fetch(2)))
                asm.lda(asm.abs(h::JOY4L))
                asm.sta(asm.direct(tap + TAP_WORDS.fetch(3)))
              else
                asm.stz(asm.direct(tap + TAP_WORDS.fetch(2)))
                asm.stz(asm.direct(tap + TAP_WORDS.fetch(3)))
                asm.ldx(16)
                asm.label("#{label}_first_plugs")
                asm.lda(asm.abs(JOYSER1))
                asm.lsr
                asm.rol(asm.direct(tap + TAP_WORDS.fetch(2)))
                asm.lsr
                asm.rol(asm.direct(tap + TAP_WORDS.fetch(3)))
                asm.dex
                asm.bne("#{label}_first_plugs")
              end
              asm.lda(asm.direct(answered))
              asm.and_a(0b10)
              asm.beq("#{label}_none")
              asm.lda(asm.direct(tap + TAP_WORDS.fetch(3)))
              asm.and_a(0xFF00)
              asm.cmp(0xFF00)
              asm.beq("#{label}_none")
              asm.sep(0x20)
              asm.lda(TAP_LAST_PLUGS)
              asm.sta(asm.abs(h::WRIO))
              asm.rep(0x20)
              asm.ldx(16)
              asm.label("#{label}_last_plugs")
              asm.lda(asm.abs(JOYSER1))
              asm.lsr
              asm.rol(asm.direct(tap + TAP_WORDS.fetch(4)))
              asm.dex
              asm.bne("#{label}_last_plugs")
              asm.sep(0x20)
              asm.lda(TAP_FIRST_PLUGS)
              asm.sta(asm.abs(h::WRIO))
              asm.rep(0x20)
              asm.bra("#{label}_done")
              asm.label("#{label}_none")
              asm.stz(asm.direct(tap + TAP_WORDS.fetch(3)))
              asm.label("#{label}_done")
            end

            # The picture's line counters latched now, by a read of SLHV a byte wide (two would read
            # the sprite table's port next to it, which moves its address on). A is 16 bits wide
            # before and after.
            def emit_line_latched_again(asm)
              asm.sep(0x20)
              asm.lda(asm.abs(Console::SNESHardware::SLHV))
              asm.rep(0x20)
            end

            # rt_buttons_remapped (JSR): A = the buttons in A as a controller hands them over
            # (JOYPAD_BITS), a bit each in IR::Buttons's order, X used. The top byte (B to Right)
            # and the next four bits (A, X, L and R) are each looked up in a table worked out as the
            # cartridge is built, a few instructions in place of a test of each button.
            def emit_buttons_remapped_by_table(asm, pad, extra_buttons)
              asm.label("rt_buttons_remapped")
              asm.sta(asm.direct(pad))
              asm.xba
              asm.and_a(0x00FF)
              asm.asl
              asm.tax
              asm.lda(asm.long_x("rt_buttons_remapped_high"))
              asm.sta(asm.direct(pad + 2))
              asm.lda(asm.direct(pad))
              asm.and_a(0x00F0)
              asm.lsr
              asm.lsr
              asm.lsr
              asm.tax
              asm.lda(asm.long_x("rt_buttons_remapped_low"))
              asm.ora(asm.direct(pad + 2))
              asm.rts
              asm.label("rt_buttons_remapped_high")
              asm.data_words(Array.new(256) { |byte| buttons_remapped(byte << 8, extra_buttons) })
              asm.label("rt_buttons_remapped_low")
              asm.data_words(Array.new(16) { |nibble| buttons_remapped(nibble << 4, extra_buttons) })
            end

            # The bits of +word+, as a controller hands them over, in IR::Buttons's order.
            def buttons_remapped(word, extra_buttons)
              BUTTON_BITS.sum do |name, (from, to)|
                next 0 if EXTRA_BUTTONS.include?(name) && !extra_buttons

                word.anybits?(from) ? to : 0
              end
            end

            # The routine at +label+: A = the buttons held now on the controller read through
            # +port+, a bit each in IR::Buttons's order.
            def emit_controller_read(asm, pad, label, port, extra_buttons)
              asm.label(label)
              emit_controller_bits(asm, pad, label, port, extra_buttons)
              asm.rts
            end

            # What that routine does, written in place: A = the buttons, its labels named from +label+.
            def emit_controller_bits(asm, pad, label, port, extra_buttons)
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.abs(JOYSER0))
              asm.stz(asm.abs(JOYSER0))
              asm.rep(0x20)
              asm.stz(asm.direct(pad))
              asm.ldx(16)
              asm.label("#{label}_bit")
              asm.lda(asm.abs(port))
              asm.lsr
              asm.rol(asm.direct(pad))
              asm.dex
              asm.bne("#{label}_bit")
              emit_buttons_remapped_in_place(asm, pad, label, extra_buttons)
            end

            # The word at +pad+, as a controller hands it over, turned into IR::Buttons's order a
            # button at a time: A = the buttons, and the word at +pad+ + 2 too.
            def emit_buttons_remapped_in_place(asm, pad, label, extra_buttons)
              asm.stz(asm.direct(pad + 2))
              BUTTON_BITS.each do |name, (from, to)|
                next if EXTRA_BUTTONS.include?(name) && !extra_buttons

                skip = "#{label}_not_#{to}"
                asm.lda(asm.direct(pad))
                asm.bit(from)
                asm.beq(skip)
                asm.lda(asm.direct(pad + 2))
                asm.ora(to)
                asm.sta(asm.direct(pad + 2))
                asm.label(skip)
              end
              asm.lda(asm.direct(pad + 2))
            end

            # One controller's frame: the buttons read (the block emits that, leaving them in A), and
            # what they show kept.
            def emit_controller_update(asm, at, pad, controller)
              yield
              asm.sta(asm.direct(pad))
              asm.lda(at.call(controller.seen))
              asm.eor(0xFFFF)
              asm.and_a(asm.direct(pad))
              asm.ora(at.call(controller.pad_pressed))
              asm.sta(at.call(controller.pad_pressed))
              asm.lda(asm.direct(pad))
              asm.sta(at.call(controller.pad_held))
              asm.sta(at.call(controller.seen))
            end

            # STOPPING. rt_halt stops the game where it is: what it drew since its last frame is
            # copied to the console in the next blank (or with the screen switched on, for a game
            # that never got as far as a frame), SHOWN marks that the end is on the screen, and the
            # processor sleeps from then on. Going wrong is the same, with what went wrong written
            # down first (rt_fault, A = what went wrong, the list and the numbers already in FAULT).
            def emit_stopping(asm, memory)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              asm.label("rt_halt")
              asm.rep(0x30)
              asm.lda(HALTED)
              asm.label("rt_stop_with_state")
              asm.sta(at.call(STATE))
              asm.jsl(asm.long("rt_tint_prepare"))
              asm.jsl(asm.long("rt_picture_prepare"))
              asm.jsr(asm.abs("rt_show_pass"))
              asm.lda(END_SHOWN & 0xFFFF)
              asm.sta(at.call(SHOWN))
              asm.sta(at.call(SHOWN, 2))
              asm.label("rt_stopped")
              Sound.emit_idle_step(asm, memory)
              asm.bra("rt_stopped")

              asm.label("rt_fault")
              asm.rep(0x30)
              asm.sta(at.call(FAULT))
              asm.lda(WENT_WRONG)
              asm.bra("rt_stop_with_state")
            end
          end
        end
      end
    end
  end
end
