# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # A PlayStation program played in the emulator with nobody watching, driven and read back through
        # the calls a test makes on Backends::Reference (CartridgeHeadlessRun says how a pass is read).
        # What is the PlayStation's own: its RAM read by address, low byte first; its picture read from
        # video RAM where the graphics chip is told to show it; its pad's buttons by the shared names; and
        # a run of no frames ending before the picture is on.
        #
        # THE PROGRAM STARTS ON THE EMULATOR'S FIRST FRAME. Beetle PSX runs OpenBIOS when no BIOS of Sony's
        # is in its system folder, and ruby-ps1-emulator's patch starts the program at power-on there, so
        # no frames go by in a BIOS first. The frames the runtime counts start as the picture comes on, at
        # the end of the first pass, as every cartridge console's do.
        class HeadlessRun < CartridgeHeadlessRun
          # The buttons a game names, as the emulator names the PlayStation pad's (Runtime::Pads says
          # which is which).
          PAD_BUTTONS = Ractor.make_shareable({ a: :cross, b: :circle, x: :triangle, y: :square, l: :l1, r: :r1,
                                                select: :select, start: :start, up: :up, down: :down, left: :left,
                                                right: :right })

          # The pad the build reads has no motor, so it never runs (Reference#motor_on?).
          def motor_on? = false

          # The build makes no sound yet, so the sound log is empty, as the interpreter's is for a game
          # whose sound the build refuses.
          def audio = []
          def audio_played = []

          # The rest of what the interpreter answers, each refused by name.
          refuses :clock_at, :mixed_sound, :active_samples

          private

          def kit = Console.for(:ps1)

          def power_on = set_buttons(@held)

          # The buttons a game names, on the pad's. One the pad lacks is one no program for it can read, so
          # it is not pressed.
          def set_buttons(buttons) = @core.set_buttons(buttons.filter_map { |button| PAD_BUTTONS[button.to_sym] })

          # A RUN OF NO FRAMES ends as the first pass does, before anything is shown: the picture is still
          # off. The interpreter says a display switched off as a plain white picture
          # (Reference::Framebuffer::HELD_OFF), so that is the picture the run ends on, and the game goes no
          # further.
          def ends_before_first_picture?(frames) = frames.zero?

          def end_before_first_picture(variables, lists, sprites, sounds, camera)
            hold_after_this_pass
            @sprites = sprites
            off = Array.new(@core.width * @core.height, Reference::Framebuffer::HELD_OFF)
            record_moment(:end, variables, lists, Picture.new(shown: off, width: @core.width, height: @core.height,
                                                              camera_x: camera[0], camera_y: camera[1]), sounds)
          end

          def start_run(_program) = @frames_played = 0

          def next_screen_frame = screen_on? ? super : 1

          def read_camera = [0, 0]
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

          # The game halted: its last picture is shown by the blank that says so, and the moment is the end
          # of the run.
          def finish_after_halt
            (1..passes).last(Runtime::Frame::STEPS_KEPT).each { |pass| note_frames_took(pass) unless @frames_took.key?(pass) }
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > LONGEST_PASS_FRAMES
              play_frame
              frames += 1
            end
            record_moment(:end, read_variables, read_lists, picture_now(read_camera), read_sounds)
          end

          def play_frame
            @frames_played += 1
            decide_buttons unless @frames_played == 1
            @core.run_frame
          end

          def screen_on? = read32(runtime_place(Runtime::Frame::DISPLAY_ON)) == 1

          # The picture shown, each pixel the 15-bit colour video RAM holds, which is the library's own
          # layout (red in the low five bits).
          def picture_now(camera)
            colors = @core.colors
            Picture.new(shown: colors, width: @core.width, height: @core.height, camera_x: camera[0], camera_y: camera[1])
          end

          # The picture's check, worked out once for a picture shown frame after frame.
          def picture_check_of(shown)
            return @check_of_shown if shown == @shown_checked

            @shown_checked = shown
            @check_of_shown = RunComparison.picture_check(shown)
          end

          # The PlayStation's RAM, read and written by address.
          def byte(address) = @core.ram_read8(address)
          def half(address) = @core.ram_read16(address)
          def read32(address) = @core.ram_read32(address)
          def write32(address, value) = @core.ram_write32(address, value)

          def state = read32(runtime_place(Runtime::Frame::STATE))
          def waiting? = read32(runtime_place(Runtime::Frame::WAITING)) == 1

          # FAULT: what went wrong, the list's place, and two numbers that say how, a word each.
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
