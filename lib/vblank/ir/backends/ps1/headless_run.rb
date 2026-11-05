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

          # HOW MANY LINES THE SCREEN HAD DRAWN since the last blank began when +pass+ went to sleep, by
          # the pass's number as #frames_took has it, read off the console's line timer
          # (Runtime::Frame::END_LINES). For a pass that took several frames a blank began while it ran,
          # so this is how many lines too late it went to sleep to take a frame fewer. Nothing the
          # interpreter can say: it has no screen drawing a line at a time.
          def lines_after_blank(pass) = @lines_after_blank.fetch(pass)

          private

          def note_frames_took(pass)
            super
            @lines_after_blank[pass] = half(runtime_place(Runtime::Frame::END_LINES) + ((pass % Runtime::Frame::STEPS_KEPT) * 2))
          end

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

          def end_before_first_picture(variables, lists, sprites, sounds, _camera)
            hold_after_this_pass
            @sprites = sprites
            off = Array.new(@core.width * @core.height, Reference::Framebuffer::HELD_OFF)
            record_moment(:end, variables, lists, Picture.new(shown: off, width: @core.width, height: @core.height,
                                                              camera_x: 0, camera_y: 0), sounds)
          end

          def start_run(_program)
            @frames_played = 0
            @lines_after_blank = {}
          end

          def next_screen_frame = screen_on? ? super : 1

          # A page of the screen in video RAM: its top line, and its pixels as they were read.
          PageRead = Data.define(:top_line, :colors)

          # THE PICTURE A PASS DREW IS READ AS THE GAME WAITS AT ITS END, from the page it drew into
          # (Runtime::Paint::PASS_PAGE_Y). The graphics chip draws into video RAM the moment it is told
          # to, and on a screen of one page that is the page shown: by the time the reader finds the pass
          # on the screen, the game has gone on into the next pass and drawn some of it there.
          def read_picture_drawn
            top = read32(runtime_place(Runtime::Paint::PASS_PAGE_Y))
            PageRead.new(top_line: top, colors: read_page_colors(top))
          end

          # ...AND IT COUNTS ONLY IF IT IS THE PAGE SHOWN. As the pass went on the screen the runtime kept
          # which page the chip was showing (Runtime::Paint::PASS_SHOWN_PAGE_Y); that has to be the page the
          # pass drew. And what the runtime keeps of the page it last told the chip to show
          # (Runtime::Paint::SHOWN_PAGE_Y) has to be what the chip's display start says now, so a command the
          # chip never took is seen too. The page shown is read at the pass's moment and not now, since the
          # next pass may already have changed it, as a screen becoming tear-free does. Where either does not
          # hold — a tear-free screen whose pages did not trade places — the picture is the one the chip
          # showed or shows, which the interpreter never drew.
          def picture_of_pass(_camera, drawn)
            state = @core.gpu_state
            told = read32(runtime_place(Runtime::Paint::SHOWN_PAGE_Y))
            return picture_now(nil) unless state.fetch(:display_x).zero? && state.fetch(:display_y) == told

            shown_top = read32(runtime_place(Runtime::Paint::PASS_SHOWN_PAGE_Y))
            picture_of_colors(shown_top == drawn.top_line ? drawn.colors : read_page_colors(shown_top))
          end

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
            # A game that halts shows the page it showed, not the page it was drawing into.
            record_moment(:end, read_variables, read_lists, picture_now(nil), read_sounds)
          end

          def play_frame
            @frames_played += 1
            decide_buttons unless @frames_played == 1
            @core.run_frame
          end

          def screen_on? = read32(runtime_place(Runtime::Frame::DISPLAY_ON)) == 1

          # The picture the chip shows now. The painted screen has no camera yet.
          def picture_now(_camera) = picture_of_colors(@core.colors)

          # +colors+ as a Picture: each pixel the 15-bit colour video RAM holds, which is the library's own
          # layout (red in the low five bits).
          def picture_of_colors(colors)
            Picture.new(shown: colors, width: @core.width, height: @core.height, camera_x: 0, camera_y: 0)
          end

          # The screen's page whose top line is +top+, read from video RAM: the picture's size from the
          # chip's display mode, at the left edge, the top bit of each pixel dropped as the chip shows it.
          def read_page_colors(top) = @core.colors_at(0, top, @core.width, @core.height)

          # The picture's check, worked out once for a picture shown frame after frame.
          def picture_check_of(shown)
            return @check_of_shown if shown == @shown_checked

            @shown_checked = shown
            @check_of_shown = RunComparison.picture_check(shown)
          end

          # The PlayStation's RAM and scratchpad, read and written by address.
          def byte(address) = Diagnostics::PS1Memory.read8(@core, address)
          def half(address) = Diagnostics::PS1Memory.read16(@core, address)
          def read32(address) = Diagnostics::PS1Memory.read32(@core, address)
          def write32(address, value) = Diagnostics::PS1Memory.write32(@core, address, value)

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
