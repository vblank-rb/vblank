# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Flash
        # A game run as a Flash movie with no window (runtime/rg_headless.hx, played in the harness of
        # ruby-flash-player/), driven and read back through the calls a test makes on Backends::Reference.
        #
        # The movie prints exactly what the native program prints, line for line, so everything about reading
        # it — the variables, the lists, the picture file, the sprites — is Computer::HeadlessRun's, and only
        # the program it plays is this one's. Two things differ. The program is the harness, which is started
        # with the movie and answers the buttons it asks for. And the picture is written to its file only when
        # it is asked for (the harness is asked, between a frame's end and its buttons), since a movie
        # writing every frame's picture costs more than playing the frame.
        #
        # What the movie does not do yet (sound, saves, the clock, the state image and the start file) is
        # refused before the run starts, as a question the lowering cannot answer.
        class HeadlessRun < Computer::HeadlessRun
          # Raised for something a test asks that the Flash lowering cannot answer yet. The shared one's,
          # since both are asked the same questions.
          CannotAnswer = Computer::HeadlessRun::CannotAnswer

          def recording_sound(**) = refuse_unmade!("recording the sound it makes")
          def sounding_as_played = refuse_unmade!("sounding as it plays")
          def clock_at(*, **) = refuse_unmade!("the cartridge's clock")
          def hand_file(*) = refuse_unmade!("a file handed to the game as it starts")
          def writing_state_after(*) = refuse_unmade!("writing the state image")
          def starting_from_state(*) = refuse_unmade!("reading a state image")

          private

          def headless_program(program) = Flash.new.build_headless(program)

          # The movie is played by the harness, which is told to play it as a game built to be tested.
          def program_command(movie) = [{}, Diagnostics::FlashPlayer.harness_path, movie, "--headless"]

          def lowering_name = "the Flash lowering"
          def skip_helper_name = "skip_on_flash"

          def refuse_unmade!(what)
            raise CannotAnswer, "the Flash lowering cannot answer yet: #{what}. Its runtime does not make it."
          end

          # A game that keeps save memory calls a runtime the Flash build has not got, which refuses it by
          # name before it starts; this is for a save handed to a game that does not keep one.
          def save_options(_dir) = []

          # The program is waiting for its buttons from here until they are sent: the picture is asked for
          # of the harness then.
          def record_frame_and_send_buttons(stdin, frame, rows)
            @program_in = stdin
            @program_waiting = true
            super
          ensure
            @program_waiting = false
          end

          # The picture in the program's file now: the harness writes it first, if the program is waiting.
          def picture_now
            write_picture_file if @program_waiting
            super
          end

          def write_picture_file
            @program_in.puts("picture")
            @program_in.flush
            reply = @program_out.gets&.chomp
            return if reply == "picture-written"

            raise Computer::Error, "the Flash player did not write the picture when it was asked: it said #{reply.inspect}"
          end
        end
      end
    end
  end
end
