# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # A Genesis cartridge played in the emulator with nobody watching, driven and read back through
        # the calls a test makes on Backends::Reference (CartridgeHeadlessRun says how a pass is read).
        # What is the Genesis's own: its work RAM read by address, high byte first, and a run of no
        # frames ending before the screen is on.
        #
        # THE EMULATOR'S FRAME STARTS AT THE VERTICAL BLANK, where the cartridge copies a pass's changes
        # to the console, and goes on through the lines of the picture, which are drawn after the copy. So
        # a pass's picture is on the frame that shows it, as it is on the Super Nintendo's emulator, and the
        # base run reads it there.
        class HeadlessRun < CartridgeHeadlessRun
          # The buttons a Genesis pad has, as the emulator names them: the same names as a game's.
          PAD_BUTTONS = Console::GENESIS.buttons

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

          # THE BUTTONS ARE THE ONES HELD FROM POWER-ON for the first emulated frame, which is where the
          # cartridge reads them (Runtime::Boot), and from the second on each frame's own, decided before
          # the frame is played: the frames the runtime counts (Frame::FRAMES) start where the video
          # chip's interrupt is switched on, a few emulated frames in, and the interrupt of
          # the frame that starts them reads the buttons the script gave for it.
          def start_run(_program)
            @frames_played = 0
            @deciding = true
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

          # The game halted: its last picture is shown by the blank that says so, and the moment is the end
          # of the run.
          def finish_after_halt
            (1..passes).last(Runtime::Frame::STEPS_KEPT).each { |pass| note_frames_took(pass) unless @frames_took.key?(pass) }
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > LONGEST_PASS_FRAMES
              play_frame
              frames += 1
            end
            @sprites = read_sprites
            record_moment(:end, read_variables, read_lists, picture_now(read_camera), read_sounds)
          end

          def play_frame
            @frames_played += 1
            decide_buttons unless @frames_played == 1
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

          # The sprites the game placed in its last pass, back to front, as the interpreter says them
          # (Reference#sprites): the runtime keeps a row for each (Runtime::Tiles::DRAWN) — whose, which
          # picture, where — and SpriteNames turns the numbers back into names. A game with no
          # sprites keeps no such place.
          def read_sprites
            return [] unless @places.runtime.key?(Runtime::Tiles::DRAWN)

            at = runtime_place(Runtime::Tiles::DRAWN)
            signed = ->(value) { value >= 0x8000 ? value - 0x10000 : value }
            Array.new(half(at)) do |i|
              whose, picture, x, y = @core.wram_bytes(at + 2 + (i * Runtime::Tiles::DRAWN_BYTES), 8).unpack("n4")
              @drawn_sprites.row(signed.call(whose), @places.sprite_picture_names.fetch(picture, picture), signed.call(x),
                                 signed.call(y))
            end
          end

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
