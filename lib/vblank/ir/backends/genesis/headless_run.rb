# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # A Genesis cartridge played in the emulator with nobody watching, driven and read back through
        # the calls a test makes on Backends::Reference (CartridgeHeadlessRun says how a pass is read).
        # What is the Genesis's own: its work RAM read by address, high byte first; the picture a
        # frame late; and a run of no frames ending before the screen is on.
        #
        # THE PICTURE COMES A FRAME AFTER THE PASS THAT MADE IT. The emulator plays a whole frame at a
        # time, from the top line of the picture to the end of the blank, and the blank is where a
        # pass's changes are copied to the console (Runtime::Frame): so the picture the emulator hands
        # over at the end of the frame that showed pass N is still pass N-1's, drawn before the
        # copy, and pass N's is drawn in the frame after. A pass's numbers are read when the game is
        # found waiting at its end, as every console's are, and its picture one frame after the game
        # is found to have shown it (#play_passes).
        class HeadlessRun < CartridgeHeadlessRun
          # The buttons a Genesis pad has, as the emulator names them: the same names as a game's.
          PAD_BUTTONS = Console::GENESIS.buttons

          # No pass past the last one asked for: what finishing a halted game flushes against.
          NO_LAST_PASS = Float::INFINITY

          # A pass whose picture is still to come: the pass, what was read of the game when it was
          # found waiting (its variables, lists, sprites, sounds and camera), and the frame it was seen to be shown at.
          Shown = Data.define(:pass, :read, :seen_at)

          # A Genesis cartridge has no rumble motor, so it never runs (Reference#motor_on?).
          def motor_on? = false

          # Nothing sounds on a Genesis build yet: the sound log and the recordings sounding are empty.
          def audio = []
          def active_samples = []

          # The rest of what the interpreter answers, each refused by name.
          refuses :clock_at

          private

          def kit = Console.for(:genesis)

          def big_endian? = true

          def start_run(_program)
            @frames_played = 0
            @shown = []
            @frames_seen = 0
          end

          def power_on = set_buttons(@held)

          # The buttons a game names, on the pad's: the same names. A button a Genesis pad lacks is
          # one no cartridge for it can read, so it is not pressed.
          def set_buttons(buttons) = @core.set_buttons(buttons.map(&:to_sym) & PAD_BUTTONS)

          # A RUN OF NO FRAMES ends as the first pass does, before anything is shown: the screen is
          # still switched off. The interpreter says a display switched off as a plain white picture
          # (Reference::Framebuffer::HELD_OFF), so that is the picture the run ends on, and the game goes
          # no further.
          def ends_before_first_picture?(frames) = frames.zero?

          def end_before_first_picture(variables, lists, sprites, sounds, camera)
            hold_after_this_pass
            @sprites = sprites
            off = Array.new(@core.width * @core.height, Reference::Framebuffer::HELD_OFF)
            record_moment(:end, variables, lists, Picture.new(shown: off, width: @core.width, height: @core.height,
                                                              camera_x: camera[0], camera_y: camera[1]), sounds)
          end

          # FRAME 1 CAN BE READ BEFORE IT IS DECIDED. The blank's interrupt reads the controller, and a
          # first pass that ends late in a frame finds that frame's interrupt, frame 1's, taken before the
          # pass is seen to be over: frame 1 read the buttons held from power-on. Writing the right ones
          # into the game's memory afterwards would hide a fault in the very routine that reads them,
          # so the frame is found first: a copy of the game is played as far as the end of its first pass,
          # on a console of its own, and the real one is handed frame 1's buttons before that frame
          # runs. Only a game told its buttons a frame at a time needs the copy: any other holds the
          # same ones from power-on. The block saying them is asked for a frame's once, and only when
          # that frame comes, since a test's block can count from the first frame it is asked about.
          def play(frames)
            @frames_played = 0
            @frame_one_at = @input_script ? frame_first_pass_ended : nil
            super
          end

          # How many emulated frames the game takes to be found waiting at the end of its first pass.
          def frame_first_pass_ended
            Diagnostics::Emulator.with_cartridge(@rom, file_name: "game#{kit.description.extension}") do |core|
              @core = core
              power_on
              ended_at = (1..LONGEST_PASS_FRAMES).find do
                core.run_frame
                state != Runtime::Frame::RUNNING || (waiting? && passes >= 1)
              end
              ended_at if frame_one_read_early?
            ensure
              @core = nil
            end
          end

          # Has the blank that reads frame 1 come, with the first pass ended and nothing shown? A
          # game that takes several frames to set up has not read frame 1 yet at all.
          def frame_one_read_early? = read32(runtime_place(Runtime::Frame::FRAMES)) == 1 && shown_pass.zero?

          # Frame 1 was handed over in time, so it is not decided again.
          def first_pass_ended
            @decided = 1 if @deciding && frame_one_read_early?
          end

          # PASS BY PASS until +frames+ have ended or the game stops, as the base reads them, except for
          # the picture: a pass seen to be shown has its picture read after the next frame is played
          # (#flush_shown), while the passes after it are already being found waiting. The interpreter,
          # told to play +frames+ frames, plays one pass more and stops as that one ends: the run ends
          # on the picture of that pass.
          def play_passes(frames)
            pending = nil # what was read of the pass found waiting, not yet shown
            taken = 0
            waited = 0
            loop do
              play_frame
              waited += 1
              refuse_stuck_game! if waited > LONGEST_PASS_FRAMES
              return if flush_shown(frames)

              if pending && shown_pass >= pending.first
                @shown << Shown.new(pass: pending.first, read: pending, seen_at: @frames_played)
                pending = nil
              end
              case state
              when Runtime::Frame::HALTED then return finish_after_halt
              when Runtime::Frame::WENT_WRONG then raise_cartridge_fault!
              end
              next unless pending.nil? && waiting? && passes > taken

              taken = passes
              pending = [passes, read_variables, read_lists, read_sprites, read_sounds, read_camera]
              return end_before_first_picture(*pending.drop(1)) if ends_before_first_picture?(frames)

              note_frames_took(passes - 1) if passes > 1
              mark_last_pass_taken if passes == frames
              hold_after_this_pass if passes > frames
              waited = 0
              @deciding = passes <= frames
              first_pass_ended if passes == 1
            end
          end

          # The passes seen shown in an earlier frame, now that the frame that draws them has been
          # played: their moments, with the picture as it is now. True when the pass past the last asked
          # for is one of them, which ends the run.
          def flush_shown(frames)
            ready, @shown = @shown.partition { |shown| shown.seen_at < @frames_played }
            ready.each do |shown|
              pass, variables, lists, @sprites, sounds, camera = shown.read
              if pass > frames
                record_moment(:end, variables, lists, picture_now(camera), sounds)
                return true
              end

              record_moment(pass, variables, lists, picture_now(camera), sounds)
            end
            false
          end

          # The moment of +frame+ — a pass's number, or :end for the moment the run ended on.
          def record_moment(frame, variables, lists, picture, sounds)
            @vars = variables
            @lists = lists
            @screen = picture
            @moments << Moment.new(frame: frame, variables: variables, picture: RunComparison.picture_check(picture.shown),
                                   sounds: sounds, sprites: @sprites, collections: game_state.except(:vars), sounding: [])
            @on_vblank&.call(frame) unless frame == :end
          end

          # The game halted: the passes it showed are finished first, then its picture shown once more
          # (a painted screen is copied over several blanks, Runtime::Picture), and the moment is
          # the end of the run.
          def finish_after_halt
            (1..passes).last(Runtime::Frame::STEPS_KEPT).each { |pass| note_frames_took(pass) unless @frames_took.key?(pass) }
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > LONGEST_PASS_FRAMES
              play_frame
              frames += 1
            end
            play_frame
            flush_shown(NO_LAST_PASS)

            @sprites = read_sprites
            record_moment(:end, read_variables, read_lists, picture_now(read_camera), read_sounds)
          end

          def play_frame
            @frames_played += 1
            set_buttons(Array(@input_script.call(1))) if @frames_played == @frame_one_at
            decide_buttons
            @core.run_frame
          end

          # The emulator's picture, each pixel the 15-bit colour the console holds (the three bits of
          # each channel it keeps, widened), and where the camera put the view, [x, y], as the pass
          # left it.
          def picture_now(camera)
            shown = @core.colors.map { |color| COLORS.fetch(color) }
            Picture.new(shown: shown, width: @core.width, height: @core.height, camera_x: camera[0], camera_y: camera[1])
          end

          # The emulator's 9-bit colours (red in the low three bits, then green, then blue) as the
          # 15-bit colours of the rest of the library, each channel's three bits widened to five.
          COLORS = Ractor.make_shareable(Array.new(512) do |color|
            red = Console::GenesisHardware.widen(color & 7)
            green = Console::GenesisHardware.widen((color >> 3) & 7)
            blue = Console::GenesisHardware.widen((color >> 6) & 7)
            red | (green << 5) | (blue << 10)
          end)

          # Where a painted screen's camera puts the view; [0, 0] until a painted screen is made.
          def read_camera = [0, 0]

          # The sprites the game placed in its last pass, back to front: none until sprites are made.
          def read_sprites = []

          # The Genesis's work RAM, read and written by address.
          def byte(address) = @core.wram_read8(address)
          def half(address) = @core.wram_read16(address)
          def read32(address) = @core.wram_read32(address)
          def write32(address, value) = @core.wram_write32(address, value)

          def state = half(runtime_place(Runtime::Frame::STATE))
          def waiting? = half(runtime_place(Runtime::Frame::WAITING)) == 1

          # FAULT: what went wrong (a word), the list's place (a long), and two numbers that say how
          # (a long each).
          def read_fault
            at = runtime_place(Runtime::Frame::FAULT)
            [half(at), read32(at + Runtime::Frame::FAULT_LIST), word(at + Runtime::Frame::FAULT_FIRST),
             word(at + Runtime::Frame::FAULT_SECOND)]
          end

          def console_fault_message(code, _first, _second)
            return super unless code == CartridgeFaults::CPU_EXCEPTION

            raise CannotAnswer, "the Genesis cartridge stopped: the processor met something it cannot do (an odd " \
                                "address, a division it cannot make, or an instruction it does not know)"
          end
        end
      end
    end
  end
end
