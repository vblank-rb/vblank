# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # A DOS program played in the emulator with nobody watching, driven and read back through the calls a
        # test makes on Backends::Reference (CartridgeHeadlessRun says how a pass is read). What is DOS's own:
        # its numbers read by offset into the data segment, low byte first; its picture read from the game's
        # own and the card's palette; its buttons as keys, by the shared names; and a run of no frames ending before
        # the picture is on.
        #
        # THE PICTURE A PASS DREW IS READ AS THE GAME WAITS AT ITS END. The program draws into a picture of its
        # own in memory and sends it to the card as the retrace begins, by when the next pass is drawing over
        # it. So the reader takes the game's own picture the moment the game is found waiting, and that is
        # the pass's picture; what the card shows a frame later is the same (test_dos_drawing.rb holds it to that).
        #
        # THE PICTURE'S COLOURS. The card keeps a number a pixel and a palette of 256 colours of six bits a
        # channel. The reader gives each pixel the 15-bit colour the interpreter paints with: its palette
        # entry's six bits a channel, less the lowest bit (Runtime.dac_of widened each of the five to six).
        class HeadlessRun < CartridgeHeadlessRun
          # The buttons a game names, as ruby-dos-emulator names the keys they are (Core::KEYS).
          KEYS = Ractor.make_shareable({ a: :ctrl, b: :alt, start: :enter, select: :shift, l: :z, r: :x,
                                         up: :up, down: :down, left: :left, right: :right })

          # A keyboard has no motor, so it never runs (Reference#motor_on?).
          def motor_on? = false

          # The build makes no sound yet, so the sound log is empty, as the interpreter's is for a game whose
          # sound the build refuses.
          def audio = []
          def audio_played = []

          # The rest of what the interpreter answers, each refused by name.
          refuses :mixed_sound, :active_samples

          # Give the PC's clock chip the date and time +time+ shows as the program starts, from which the
          # program counts on by its frames, as the interpreter's #clock_at does. With +set: false+ the chip
          # says its battery did not keep the time. A PC always has a clock, so a run never told one has
          # NO_TIME_GIVEN, and never the time of the machine the test runs on.
          def clock_at(time, set: true)
            @clock_started = time
            @clock_set = set
            self
          end

          NO_TIME_GIVEN = Ractor.make_shareable(Time.utc(2000, 1, 1))

          private

          # The time the clock chip is given, and whether it says its battery kept it: what the run was told,
          # to the whole second, since the chip holds no part of one. A checked run tells the interpreter
          # the same.
          def clock_given
            time = @clock_started || NO_TIME_GIVEN
            Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec)
          end

          def clock_given_set? = @clock_set != false

          def kit = Console.for(:dos)

          # The size of the screen the program was built for: its variant's, or the plain one.
          def screen_size = [screen_built_for.width, screen_built_for.height]

          # The screen the program was built for (DOS::Screen), worked out once for each program played.
          def screen_built_for = (@screens ||= {}.compare_by_identity)[@places] ||= Screen.of(@places.source_program)

          # THE PROGRAM IS HELD AT ITS START (the kit opens it so, see Core::START_GATE_AT) and is let go with
          # the frame about to be played, so its first pass ends in the first frame the reader sees. Nothing
          # is played before but the frames the program takes to reach its gate: DOS's own start-up is in them.
          def power_on
            @core.clock_at(clock_given, kept: clock_given_set?)
            frames = 0
            until @core.gate_closed?
              @core.run_frame
              frames += 1
              refuse_stuck_game! if frames > LONGEST_PASS_FRAMES
            end
            press_before_first_pass
            write32(runtime_place(Runtime::Frame::READER_HOLDS), 1) # each pass waits to be read (Frame::READER_HOLDS)
            @core.release_gate
            set_buttons(buttons_sent(1))
            @decided = 1
          end

          # A KEY PRESSED BEFORE A FRAME IS PLAYED IS READ AT THE RETRACE AFTER THAT FRAME'S. A frame ends as
          # the card finishes the picture's last line, a few lines before the retrace at which the program
          # takes its buttons, and the emulator hands a key to its keyboard once that retrace has ended
          # (ruby-dos-emulator's probe patch says why), so it is read at the next: which is what a person's key
          # is too, down some time in one frame and read as the next begins.
          #
          # So the keys sent now are the buttons of the frame after the one about to begin. The runtime counts
          # frames only where a wait ends (FRAMES), and a pass may be part way through several, so the frame
          # about to begin is counted from the timer as the runtime counts it: the frames to the last wait's
          # end, and the timer's ticks since, rounded to frames. The first frame's keys are sent as the gate
          # opens (#power_on), after the program has taken the ones held from power-on for its first pass.
          def next_screen_frame
            frame = Runtime::Frame
            ticks = read32(runtime_place(frame::TIMER_TICKS)) - read32(runtime_place(frame::TICKS_MARK))
            since_last_wait = (ticks + (Runtime::TICKS_A_FRAME / 2)) / Runtime::TICKS_A_FRAME
            read32(runtime_place(frame::FRAMES)) + since_last_wait + 1
          end

          # The buttons held from power-on are down before the game's first pass begins, as a console's are:
          # the keys are pressed while the program waits at its gate, and frames are played there until the
          # program's keyboard interrupt has heard of every one.
          def press_before_first_pass
            return if @held.empty?

            set_buttons(@held)
            down = Buttons.mask(@held.map(&:to_sym) & KEYS.keys)
            frames = 0
            until read32(runtime_place(Runtime::Frame::KEY_HELD)) & down == down
              @core.run_frame
              frames += 1
              next unless frames > LONGEST_PASS_FRAMES

              raise CannotAnswer, "the DOS program never heard the keys held from power-on " \
                                  "(#{@held.join(', ')}): its keyboard interrupt did not take them."
            end
          end

          # The buttons a game names, as keys. One the keyboard has no key for is one no program for it can
          # read, so it is not pressed.
          def set_buttons(buttons) = @core.press(buttons.filter_map { |button| KEYS[button.to_sym] })

          # A RUN OF NO FRAMES ends as the first pass does, before anything is shown. The interpreter shows a
          # display switched off as a plain white picture (Reference::Framebuffer::HELD_OFF), so that is the
          # picture the run ends on, and the game goes no further.
          def ends_before_first_picture?(frames) = frames.zero?

          def end_before_first_picture(variables, lists, sprites, sounds, camera)
            hold_after_this_pass
            @sprites = sprites
            width, height = screen_size
            off = Array.new(width * height, Reference::Framebuffer::HELD_OFF)
            picture = Picture.new(shown: off, width: width, height: height, camera_x: camera[0], camera_y: camera[1])
            record_moment(:end, variables, lists, picture, sounds)
          end

          # The buttons are decided from the first frame on, not from the first pass's end as on a console
          # (CartridgeHeadlessRun#decide_buttons): the runtime counts the frames of its first pass by the
          # timer, as it counts every pass's, so a first pass of several frames reads each frame's keys.
          def start_run(_program)
            @frames_played = 0
            @picture_before = nil
            @stopped = false
            @deciding = true
          end

          # EVERY FRAME'S BUTTONS ARE SENT, OR THE RUN SAYS IT COULD NOT. The frame about to begin is counted
          # from the timer (#next_screen_frame), and where the count moves on by more than one between two
          # frames played, the frames between were played with the keys sent last still down. The interpreter
          # is handed those keys for them, which is what the program read; a script that gives other buttons
          # for such a frame cannot be played as it was written, and the run refuses it.
          def decide_buttons
            return unless @deciding

            frame = next_screen_frame
            return if frame == @decided

            (@decided + 1...frame).each { |skipped| send_skipped_frame(skipped) }
            @decided = frame
            set_buttons(buttons_sent(frame))
          end

          # The frame +frame+, over which the keys of the frame before it stayed down.
          def send_skipped_frame(frame)
            down = scripted_buttons(frame - 1).map(&:to_sym).sort
            asked = scripted_buttons(frame).map(&:to_sym).sort
            unless asked == down
              raise CannotAnswer, "the #{kit.title} run could not send the buttons for frame #{frame} " \
                                  "(#{asked.join(', ')}): the program counted that frame and the one after it " \
                                  "between two frames the run played, so the keys of frame #{frame - 1} stayed down"
            end

            buttons_sent(frame)
          end

          # The game's own picture as the game waits at the end of the pass: the picture the pass drew, a
          # palette entry a pixel. Its colours are the card's palette once the pass is shown (#picture_of_pass).
          def read_picture_drawn = entries_drawn_now

          # THE CARD IS HELD TO THE GAME'S PICTURE on every pass. What a pass drew is read from the game's own
          # picture, so a row the runtime never sent to the card would otherwise go unseen. By the time a pass
          # is found waiting, the retrace before it has sent the card the pass before: the card's memory must
          # be that pass's picture, byte for byte. A game that stopped has shown its last picture, and the
          # card must be that one.
          def refuse_card_not_showing!(picture)
            return if picture.nil? || card_pixels(picture.bytesize) == picture

            raise CardNotSent, "the #{kit.title} program's card does not show the picture the game drew: " \
                               "a row that changed was not sent to it"
          end

          # The card's first +count+ pixels, a palette entry each, however the screen's mode keeps them in its
          # four planes: Mode X as the emulator keeps them, the plain mode spread out (Core#chained_pixels).
          def card_pixels(count)
            return @core.vga_memory.byteslice(0, count) if screen_built_for.mode == :mode_x

            @core.chained_pixels(count)
          end

          # The card showing something other than what the game drew.
          class CardNotSent < StandardError; end

          # THE COLOURS OF A PASS'S PICTURE ARE THE PALETTE AS THE PASS IS SHOWN. A fade or a tint moves the
          # palette and not the picture, and the program sends the moved palette to the card as the retrace
          # begins, with the picture. So the entries are taken as the game is found waiting and their colours
          # once that retrace has come, before the next one sends the next pass's.
          def picture_of_pass(camera, drawn) = picture_of(drawn, camera)

          # Where the view was over the game's picture when the picture shown was last made (Runtime::View);
          # [0, 0] for a game with neither a camera nor blocks, which has no such picture.
          def read_camera
            return [0, 0] unless @places.runtime.key?(Runtime::View::SHOWN_X)

            [Runtime::View::SHOWN_X, Runtime::View::SHOWN_Y].map { |name| [read32(runtime_place(name))].pack("V").unpack1("l<") }
          end

          # The sprites the pass placed, from the runtime's table (Runtime::Sprites), in the order they are drawn.
          def read_sprites
            sprites = Runtime::Sprites
            return [] unless @places.runtime.key?(sprites::PLACED)

            table = runtime_place(sprites::TABLE)
            row_bytes = @places.runtime.key?(sprites::TURNED) ? sprites::TURNED_ENTRY_BYTES : sprites::ENTRY_BYTES
            Array.new(half(runtime_place(sprites::PLACED))) do |i|
              name, picture, _, _, x, y = Diagnostics::DOSMemory.bytes(@core, table + (i * row_bytes), sprites::ENTRY_BYTES)
                                                               .unpack("s<2v2l<2")
              @drawn_sprites.row(name, picture, x, y)
            end
          end

          # The moment of +frame+ — a pass's number, or :end for the moment the run ended on.
          def record_moment(frame, variables, lists, picture, sounds)
            @vars = variables
            @lists = lists
            @screen = picture
            @moments << Moment.new(frame: frame, variables: variables, picture: picture_check_of(picture.shown),
                                   sounds: sounds, sprites: @sprites, collections: game_state.except(:vars), sounding: [])
            @on_vblank&.call(frame) unless frame == :end
          end

          # The game halted: its last picture is shown by the retrace that marks it, and the moment is the end
          # of the run. A halt places the sprites as the pass it ends would have, so they are read again.
          def finish_after_halt
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > LONGEST_PASS_FRAMES
              play_frame
              frames += 1
            end
            @stopped = true
            @sprites = read_sprites
            record_moment(:end, read_variables, read_lists, picture_now(nil), read_sounds)
          end

          # One frame is one retrace of the card's, as the shipped program sees it.
          def play_frame
            @frames_played += 1
            decide_buttons unless @frames_played == 1
            @core.run_frame
          end

          # The picture the game has drawn now, in the colours the card's palette has now.
          def picture_now(camera) = picture_of(entries_drawn_now, camera || read_camera)

          # The picture the player is shown as the game has drawn it now, a palette entry a pixel, with the
          # card held to the one before it (#refuse_card_not_showing!).
          def entries_drawn_now
            width, height = screen_size
            second = [Runtime::Sprites::PLACED, Runtime::View::SHOWN_X].any? { |name| @places.runtime.key?(name) }
            after_data = DOS.picture_shown_after_data(screen_built_for, second: second)
            drawn = Diagnostics::DOSMemory.picture(@core, width * height, after_data: after_data)
            # A pass taken after its retrace, held for the reader (Runtime::Frame::READER_HOLDS), is on the card already.
            late = !@stopped && shown_pass == passes
            refuse_card_not_showing!(@stopped || late ? drawn : @picture_before)
            @picture_before = drawn
          end

          # +entries+ as 15-bit colours, each through the card's palette as it is now.
          def picture_of(entries, camera)
            width, height = screen_size
            colors = @core.palette.map { |red, green, blue| (red >> 1) | ((green >> 1) << 5) | ((blue >> 1) << 10) }
            Picture.new(shown: entries.bytes.map { |entry| colors.fetch(entry) }, width: width, height: height,
                        camera_x: camera[0], camera_y: camera[1])
          end

          # The picture's check, worked out once for a picture shown frame after frame.
          def picture_check_of(shown)
            return @check_of_shown if shown == @shown_checked

            @shown_checked = shown
            @check_of_shown = RunComparison.picture_check(shown)
          end

          # The program's data segment, read and written by offset.
          def byte(offset) = Diagnostics::DOSMemory.read8(@core, offset)
          def half(offset) = Diagnostics::DOSMemory.read16(@core, offset)
          def read32(offset) = Diagnostics::DOSMemory.read32(@core, offset)
          def write32(offset, value) = Diagnostics::DOSMemory.write32(@core, offset, value)

          # The pass the program holds at its end has been read, so it goes on (Runtime::Frame::READER_HOLDS).
          def pass_taken(pass) = write32(runtime_place(Runtime::Frame::PASS_TAKEN), pass)

          def state = read32(runtime_place(Runtime::Frame::STATE))
          def waiting? = read32(runtime_place(Runtime::Frame::WAITING)) == 1

          # FAULT: what went wrong, the list's place, and two numbers that show how, a word each.
          def read_fault
            at = runtime_place(Runtime::Frame::FAULT)
            [read32(at), read32(at + Runtime::Frame::FAULT_LIST), word(at + Runtime::Frame::FAULT_FIRST),
             word(at + Runtime::Frame::FAULT_SECOND)]
          end
        end
      end
    end
  end
end
