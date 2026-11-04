# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Ruby
        # A GAME BUILT AS RUBY, IN THIS PROCESS, to be played live: the printed program and its
        # runtime made into a class of its own each time, so two games never share a thing, with
        # the live driver (runtime/rg_live.rb) as the machine it runs on.
        #
        # #play hands it whoever plays it, which is asked one thing at the end of every frame:
        #
        #   buttons_after(pixels, left, right)  the picture as the screen shows it, a 15-bit colour
        #                          a pixel, a row at a time, drawn over next frame, and the sound of
        #                          the frame just played, the left speaker's 16-bit samples and the
        #                          right's at #sound_rate; gives back the buttons held for the pass
        #                          that starts, a number for each connected player
        #                          (IR::Buttons.masks), or nil to stop the play
        class LiveGame
          def initialize(source)
            @game = Class.new { class_eval(source, "(the game, as Ruby)") }.new
          end

          # The size of the picture it shows.
          def width = @game.class::RG_SCREEN_WIDTH
          def height = @game.class::RG_SCREEN_HEIGHT

          # The samples a second its sound is made at.
          def sound_rate = @game.class::RG_SOUND_RATE

          # How long one of its console's frames lasts, in seconds.
          def frame_seconds = Rational(@game.class::RG_CONSOLE_TICKS_A_FRAME, @game.class::RG_CONSOLE_TICKS_A_SECOND)

          # Plays until +player+ says stop, or the game halts or ends, and gives back the picture a
          # game that stopped itself stopped on (nil when the player stopped it). A game that does
          # something the interpreter refuses stops with IR::ProgramError, in the same words.
          #
          # +match_seed+ is the seed a match shared by several machines gives the game's random
          # numbers (Network::Lockstep), mixed in once the game has set itself up; nil for a game
          # played alone. +local_player+ is which player the person at this machine is (from 1), which
          # the game may draw but never keep (Builder#drawing_for_local_player); 1 when played alone.
          def play(player, match_seed: nil, local_player: nil)
            @game.rg_live_main(player, match_seed, local_player)
          rescue @game.class::RgFault => e
            raise IR::ProgramError, e.message
          end
          # A short number (a CRC-32) standing for the whole of the game's state as it is now: every
          # variable and list it keeps, written out the way the windowless run prints them. Machines
          # that run the same game on the same buttons have the same number on the same pass.
          def state_crc = @game.rg_live_state_crc
        end
      end
    end
  end
end
