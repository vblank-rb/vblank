# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # A DOS program played in the emulator with nobody watching, driven and read back through the calls a
        # test makes on Backends::Reference (CartridgeHeadlessRun says how a pass is read). What is DOS's own:
        # its numbers read by offset into the data segment, low byte first; its picture read from the card's
        # memory and palette; its buttons as keys, by the shared names; and a run of no frames ending before
        # the picture is on.
        #
        # THE PICTURE A PASS DREW IS READ AS THE GAME WAITS AT ITS END. The program draws straight into the
        # card's memory, which is shown as it is written, so by the time the reader sees the pass on the
        # screen the next pass may have drawn over it. The reader takes the card's memory the moment the game
        # is found waiting, and that is the pass's picture.
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
            @core.release_gate
            set_buttons(buttons_sent(1))
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

          def end_before_first_picture(variables, lists, sprites, sounds, _camera)
            hold_after_this_pass
            @sprites = sprites
            width, height = kit.description.screen_size
            off = Array.new(width * height, Reference::Framebuffer::HELD_OFF)
            record_moment(:end, variables, lists, Picture.new(shown: off, width: width, height: height, camera_x: 0, camera_y: 0),
                          sounds)
          end

          def start_run(_program)
            @frames_played = 0
          end

          # The card's memory as the game waits at the end of the pass: the picture the pass drew.
          def read_picture_drawn = picture_now(nil)

          def picture_of_pass(_camera, drawn) = drawn

          def read_sprites = []

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
          # of the run.
          def finish_after_halt
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > LONGEST_PASS_FRAMES
              play_frame
              frames += 1
            end
            record_moment(:end, read_variables, read_lists, picture_now(nil), read_sounds)
          end

          # One frame is one retrace of the card's, as the shipped program sees it.
          def play_frame
            @frames_played += 1
            decide_buttons unless @frames_played == 1
            @core.run_frame
          end

          # The picture the card shows now, as 15-bit colours: each pixel's palette entry, through the palette.
          def picture_now(_camera)
            width, height = kit.description.screen_size
            colors = @core.palette.map { |red, green, blue| (red >> 1) | ((green >> 1) << 5) | ((blue >> 1) << 10) }
            Picture.new(shown: @core.chained_pixels(width * height).bytes.map { |entry| colors.fetch(entry) },
                        width: width, height: height, camera_x: 0, camera_y: 0)
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
