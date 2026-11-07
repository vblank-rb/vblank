# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # A GAME'S RULES AS FAST AS THE MACHINE CAN PLAY THEM, for a bot that plays one long run many
        # times: the program with nothing to see or hear (IR::RulesOnly), built as C with its
        # checks off, and read only as far as somebody asks.
        #
        # THE DRAWING WAS NOT MOST OF IT. A run read frame by frame has the program print every
        # variable and list every frame, and this side read them all back, which for a game with
        # long lists costs far more than drawing does. So here the program prints nothing, and a
        # number read is a question sent to it and an answer (`--asked`, runtime/rg_headless.c). A
        # script that reads three numbers a frame pays for three numbers.
        #
        # ITS FRAMES ARE NOT THE CONSOLE'S. A pass is a frame here, because nothing is late, so a tape
        # made here does not play on a cartridge. This finds tactics and seeds, and the tape that
        # counts is recorded on the cartridge.
        class RulesRun < HeadlessRun
          def run(program, max_steps: nil, frames: nil)
            super(RulesOnly.copy_of(program), max_steps: max_steps, frames: frames)
          end

          # There is no picture, so there is a screen of nothing: a playthrough takes one at each
          # moment it names, whether anybody keeps it or not.
          def screen
            pixels = Array.new(@console.screen_width * @console.screen_height, 0)
            HeadlessRun::Picture.new(shown: pixels, stored: pixels, width: @console.screen_width,
                                     height: @console.screen_height, camera_x: 0, camera_y: 0)
          end

          def raw_var(name) = @asking ? self.class.variables_in(rows_asked("? #{name}")).fetch(name, 0) : super

          # Every variable, at the frame it is asked at.
          def vars
            read_everything if @asking
            super
          end

          # What only drawing and sound would have answered, refused by name.
          def sprites(_name = nil) = refuse_nothing_drawn!(:sprites)
          def audio = refuse_nothing_drawn!(:audio)
          def recording_sound(**) = refuse_nothing_drawn!(:recording_sound)

          private

          def refuse_nothing_drawn!(name)
            raise CannotAnswer, "A game's rules alone draw nothing and sound nothing, so they cannot answer `#{name}`. " \
                                "To read it, play the game another way."
          end

          def headless_program(program) = Native.new.build_headless(program, mode: :fast)

          def frame_options(_picture_path) = ["--asked"]

          # The list +name+, asked for; or as the run left it.
          def list_items(name)
            return super unless @asking

            self.class.lists_in(rows_asked("? #{name}")).fetch(name) { super }
          end

          # The program is waiting for this frame's buttons, so it answers until it has them. A
          # playing that stops here reads where the game stood, and the program ends with it.
          def record_frame_and_send_buttons(stdin, frame, _rows)
            @stdin = stdin
            @asking = true
            buttons = @input_script ? @input_script.call(frame) : @held
            @on_vblank&.call(frame)
            sent = true
            @asking = false
            stdin.puts(@pass_buttons.headless_input_line(buttons))
            stdin.flush
            expect_next_frame
          ensure
            unless sent
              read_everything
              @asking = false
            end
          end

          def record_end(rows) = read_state_from(rows)

          def read_everything = read_state_from(rows_asked("*"))

          # The numbers are all there is of it: no camera, no sprites, no sound.
          def read_state_from(rows)
            @vars = self.class.variables_in(rows)
            @lists = self.class.lists_in(rows)
          end

          def rows_asked(question)
            @stdin.puts(question)
            @stdin.flush
            rows = []
            until rows.last == "."
              rows << (@program_out.gets or raise Zig::Error, "the program stopped when it was asked: #{question}").chomp
            end
            rows
          end
        end
      end
    end
  end
end
