# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE FRAME: waiting for the screen, the buttons, stopping, and going wrong.
          #
          # The console draws the screen a line at a time, 224 of them, and then rests for 38 more
          # lines' worth of time — the VERTICAL BLANK — before it starts again. Only in that rest
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
            # HOW MANY FRAMES A PASS TOOK (IR::Frames): the interrupt counts every frame (FRAMES, 32
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
            # 1 once the interrupt has come since the game began to wait.
            VBLANK = "rt vblank"
            # 1 once the screen is on: before the end of the first pass it is off.
            DISPLAY_ON = "rt display on"

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

            module_function

            # Whether +program+ reads X or Y, by name or as any button at all.
            def reads_extra_buttons?(program)
              program.walk.any? { |node| %i[held pressed].include?(node.kind) && (EXTRA_BUTTONS + [Buttons::ANY]).include?(node.button) }
            end

            # Whether +program+ reads the second controller, on its own or as either of the two. A
            # game that never does is built without it, the same bytes as before there was one.
            def reads_second_controller?(program)
              program.walk.any? { |node| %i[held pressed].include?(node.kind) && node.player != 1 }
            end

            def reserve(memory, second_controller: false)
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
              return unless second_controller

              [SECOND_HELD, SECOND_SEEN, SECOND_PRESSED, SECOND_PAD_HELD, SECOND_PAD_PRESSED].each { |name| memory.reserve(name, 2) }
            end

            # +pad+ is two words of the direct page, the same on the game's page and the
            # interrupt's, that reading the controller works in. +sound+ for a game that makes sound,
            # whose wait ends in Sound's rt_sound_frame.
            def emit(asm, memory, pad:, sound: false, extra_buttons: false, second_controller: false, dims: false)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }

              asm.label("rt_vblank_interrupt")
              emit_interrupt_body(asm, memory) { asm.jsr(asm.abs("rt_pad_read")) }

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
              asm.jsl(asm.long("rt_sound_frame")) if sound # the music of the frames the pass took (Sound)
              asm.rtl

              emit_show_pass_routines(asm, memory, at, dims)
              emit_buttons(asm, memory, pad, extra_buttons, second_controller)
              emit_stopping(asm, memory)
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

            # The same interrupt, as a routine of its own with the buttons' reading written into it
            # rather than called, for a copy of it that runs from work RAM (Runtime::Chip). Its
            # branches are relative and every address it names is fixed, so it runs wherever it is
            # copied to.
            def emit_interrupt_whole(asm, memory, pad:, extra_buttons: false, second_controller: false)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              emit_interrupt_body(asm, memory) do
                emit_controller_update(asm, at, pad, SEEN, PAD_PRESSED, PAD_HELD) do
                  emit_controller_bits(asm, pad, "rt_whole_buttons", 0x4016, extra_buttons)
                end
                if second_controller
                  emit_controller_update(asm, at, pad, SECOND_SEEN, SECOND_PAD_PRESSED, SECOND_PAD_HELD) do
                    emit_controller_bits(asm, pad, "rt_whole_second_buttons", 0x4017, extra_buttons)
                  end
                end
              end
            end

            # rt_show_pass: what the pass drew, on the screen, and SHOWN saying so. The first time,
            # the screen is still off, so everything set up so far is copied while nothing is drawn,
            # and the screen comes on in the blank after, showing it; after that, the pass's changes
            # are copied in the blank. Then the sleeps it waits for the blank in, and the step that
            # moves on what keeps time by the frame.
            def emit_show_pass_routines(asm, memory, at, dims)
              h = Console::SNESHardware
              asm.label("rt_show_pass")
              asm.lda(at.call(DISPLAY_ON))
              asm.bne("rt_show_pass_on")
              asm.jsl(asm.long("rt_upload_whole"))
              asm.jsr(asm.abs("rt_sleep_until_vblank"))
              if dims
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
                asm.jsr(asm.abs(memory.reserved?(Sound::QUEUE) ?"rt_sleep_unless_in_blank" : "rt_sleep_until_vblank"))
              end
              asm.jsl(asm.long("rt_upload"))
              # After it, since a big change takes several blanks and the brightness belongs to
              # the picture it arrives with, as the colours do.
              if dims
                Tint.emit_brightness(asm, memory)
              elsif memory.reserved?(Picture::SCENE_BACKGROUND_TILES) # the picture was off for a scene's tiles
                asm.sep(0x20)
                asm.lda(h::FULL_BRIGHTNESS)
                asm.sta(asm.abs(h::INIDISP))
                asm.rep(0x20)
              end
              # ...and the size of the blocks the same way (Mosaic).
              Mosaic.emit_write(asm, memory) if Mosaic.kept?(memory)
              asm.label("rt_show_pass_shown")
              asm.jsr(asm.abs("rt_letterbox_shown")) if Letterbox.kept?(memory)
              asm.lda(at.call(PASSES))
              asm.sta(at.call(SHOWN))
              asm.lda(at.call(PASSES, 2))
              asm.sta(at.call(SHOWN, 2))
              asm.rts

              emit_sleep_unless_in_blank(asm, at) if memory.reserved?(Sound::QUEUE)
              asm.label("rt_sleep_until_vblank")
              asm.stz(at.call(VBLANK))
              asm.label("rt_sleep_until_vblank_wait")
              Sound.emit_idle_step(asm, memory)
              asm.lda(at.call(VBLANK))
              asm.beq("rt_sleep_until_vblank_wait")
              asm.rts

              # What keeps time by the frame, moved on — unless the reader has taken the last pass it
              # compares, after which the interpreter moves nothing on (LAST_PASS_TAKEN).
              asm.label("rt_frame_begins_unless_last")
              asm.lda(at.call(LAST_PASS_TAKEN))
              asm.bne("rt_frame_begins_skipped")
              asm.jsl(asm.long("rt_frame_begins"))
              asm.label("rt_frame_begins_skipped")
              asm.rts
            end

            # A PASS THAT ENDS A LITTLE INTO THE BLANK STILL MAKES IT. Music plays where a wait ends,
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

            # BUTTONS. The controller is read by hand, through its serial port: a write of 1 and then
            # 0 to JOYSER0 tells it to take hold of its buttons, and each read of the port hands over
            # the next of them in bit 0, B first, then Y, Select, Start, Up, Down, Left, Right, A, X,
            # L, R and four that are always 0. Read sixteen times and turned in from the right, they
            # come out laid out as the console's own automatic read lays them out (JOYPAD_BITS). That
            # read happens by itself at the start of the blank and takes three lines; reading by hand
            # takes a few dozen instructions and needs nothing waited for.
            #
            # The second controller is the same read through JOYSER1, the next port along. Both
            # controllers take hold of their buttons from the one write to JOYSER0, and each read
            # here is two bytes wide, which walks the next port on too: so the read of the first
            # controller has already used the second's up, and the second's read starts by telling
            # them both to take hold again.
            def emit_buttons(asm, memory, pad, extra_buttons, second_controller)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              # rt_buttons_now: A = the buttons held now, a bit each in IR::Buttons's order.
              emit_controller_read(asm, pad, "rt_buttons_now", 0x4016, extra_buttons)
              emit_controller_read(asm, pad, "rt_second_buttons_now", 0x4017, extra_buttons) if second_controller

              # In the interrupt, every frame: the buttons held now, and every one that went down
              # since the frame before added to those pressed during the pass.
              asm.label("rt_pad_read")
              emit_controller_update(asm, at, pad, SEEN, PAD_PRESSED, PAD_HELD) { asm.jsr(asm.abs("rt_buttons_now")) }
              if second_controller
                emit_controller_update(asm, at, pad, SECOND_SEEN, SECOND_PAD_PRESSED, SECOND_PAD_HELD) do
                  asm.jsr(asm.abs("rt_second_buttons_now"))
                end
              end
              asm.rts

              # Where a pass's wait ends: the buttons for the pass about to start, from every frame
              # the last one took, and how many frames that was. The interrupt is held off while they
              # are taken, so a press it reads cannot fall between the two; one that came while it was
              # held off is taken as soon as it is allowed again.
              asm.label("rt_read_buttons")
              asm.sep(0x20)
              asm.stz(asm.abs(Console::SNESHardware::NMITIMEN))
              asm.rep(0x20)
              asm.lda(at.call(PAD_PRESSED))
              asm.sta(at.call(PRESSED))
              asm.stz(at.call(PAD_PRESSED))
              asm.lda(at.call(PAD_HELD))
              asm.sta(at.call(HELD))
              if second_controller
                asm.lda(at.call(SECOND_PAD_PRESSED))
                asm.sta(at.call(SECOND_PRESSED))
                asm.stz(at.call(SECOND_PAD_PRESSED))
                asm.lda(at.call(SECOND_PAD_HELD))
                asm.sta(at.call(SECOND_HELD))
              end
              asm.lda(at.call(FRAMES))
              asm.tay
              asm.sep(0x20)
              asm.lda(Console::SNESHardware::NMI_ON)
              asm.sta(asm.abs(Console::SNESHardware::NMITIMEN))
              asm.rep(0x20)
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
              if second_controller
                asm.jsr(asm.abs("rt_second_buttons_now"))
                asm.sta(at.call(SECOND_HELD))
              end
              asm.rtl
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
              joyser = 0x4016
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.abs(joyser))
              asm.stz(asm.abs(joyser))
              asm.rep(0x20)
              asm.stz(asm.direct(pad))
              asm.ldx(16)
              asm.label("#{label}_bit")
              asm.lda(asm.abs(port))
              asm.lsr
              asm.rol(asm.direct(pad))
              asm.dex
              asm.bne("#{label}_bit")
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
            def emit_controller_update(asm, at, pad, seen, pressed, held)
              yield
              asm.sta(asm.direct(pad))
              asm.lda(at.call(seen))
              asm.eor(0xFFFF)
              asm.and_a(asm.direct(pad))
              asm.ora(at.call(pressed))
              asm.sta(at.call(pressed))
              asm.lda(asm.direct(pad))
              asm.sta(at.call(held))
              asm.sta(at.call(seen))
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
