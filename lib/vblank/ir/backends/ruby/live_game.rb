# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Ruby
        # A GAME BUILT AS RUBY, IN THIS PROCESS, to be played live: the printed program and its
        # runtime made into a class of its own each time, so two games never share a thing, with
        # the live driver (runtime/rg_live.rb) as the machine it runs on.
        #
        # #play hands it whoever plays it, which is asked three things at the end of every frame:
        #
        #   sound_wanted?          whether it wants the frame's sound; when not, the sound is not
        #                          mixed and +left+ and +right+ are nil
        #   picture_wanted?        whether it wants the picture; when not, it is not built and
        #                          +pixels+ is nil (a data pack's unpacking wants neither)
        #   buttons_after(pixels, left, right)  the picture as the screen shows it, a 15-bit colour
        #                          a pixel, a row at a time, drawn over next frame, and the sound of
        #                          the frame just played, the left speaker's 16-bit samples and the
        #                          right's at #sound_rate, both written over next frame too;
        #                          gives back the buttons held for the pass
        #                          that starts, a number for each connected player
        #                          (IR::Buttons.masks), or nil to stop the play
        class LiveGame
          # The program the game was written from, for reading its numbers back in its own units
          # (Program#fraction_vars); nil for a game made from its Ruby alone.
          attr_reader :program

          # +game_class+ is a class of the game's Ruby made already (LiveGame.shareable_class), or nil
          # to make one from +source+. Every part of a game's state is its own, set up as the
          # runtime makes each game, so games of one class share nothing but their methods.
          def initialize(source, program: nil, game_class: nil)
            @game = (game_class || Class.new { class_eval(source, "(the game, as Ruby)") }).new
            @program = program
          end

          # A CLASS OF THE GAME'S RUBY THAT GAMES IN SEVERAL RACTORS ARE EACH MADE FROM (#initialize's
          # +game_class+): made once, its constants made shareable, so a Ractor can read them.
          #
          # Why one class and not one in each Ractor: what YJIT compiles is kept for the class's
          # methods, and its room for compiled code is one for the whole process. A class made in
          # each of a dozen Ractors compiled the same big program a dozen times over, filled that
          # room, and YJIT then threw code away and compiled it again, stopping every Ractor each
          # time: a dozen workers played slower together than one alone. Made once, the methods are
          # compiled once for every Ractor that plays them (Live::WorkerUnpacking).
          #
          # One game is made of it here first, so every instance variable a game sets as it is made
          # has its place in Ruby's record of objects' layouts before any Ractor makes one. With
          # none made here, four Ractors that each made their first game of a class at once once
          # read one of its variables as nil; laying the class's variables out once, here, keeps
          # the Ractors from laying them out at the same time.
          def self.shareable_class(source)
            game_class = Class.new { class_eval(source, "(the game, as Ruby)") }
            game_class.constants.each { |name| Ractor.make_shareable(game_class.const_get(name)) }
            game_class.new
            game_class
          end

          # The size of the picture it shows: the whole screen, with the border round a game's screen
          # shown in one (rg_screen_framed).
          def width = @game.class::RG_WHOLE_WIDTH
          def height = @game.class::RG_WHOLE_HEIGHT

          # How many of the window's pixels across and down each of the picture's is shown as at a
          # scale of 1 (Live::SDL's +pixel_size+).
          def pixel_size = @game.class::RG_PIXEL_SIZE

          # The file the game reads as it starts (IR::StartFile), +bytes+ a String, handed over before
          # #play. A game that reads one and is handed none stops at its first statement, in the sentence
          # rg_start_file_refusal gives.
          def hand_file(bytes)
            @game.rg_start_file_hand(bytes)
            self
          end

          # The keys and gamepad buttons the game adds to the window's layout (Live::SDL's
          # +game_controls+).
          def controls = @game.rg_live_controls

          # The buttons its console has, by their names in IR::Buttons::NAMES (Live::SDL's +buttons+).
          def buttons
            IR::Buttons::NAMES.each_with_index.filter_map { |name, at| name if @game.class::RG_CONSOLE_BUTTONS[at] == 1 }
          end

          # The most players the build seats, 0 for a game that names none (Live::Seats.several_players?).
          def seats = @game.rg_live_seats

          # The samples a second its sound is made at.
          def sound_rate = @game.class::RG_SOUND_RATE

          # How long one of its console's frames lasts, in seconds.
          def frame_seconds = Rational(@game.class::RG_CONSOLE_TICKS_A_FRAME, @game.class::RG_CONSOLE_TICKS_A_SECOND)

          # Plays until +player+ asks to stop, or the game halts or ends, and gives back the picture a
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
          # THE GAME'S SAVE MEMORY, for whoever keeps it in a file (Live::Session): how many bytes it has
          # (none for a game with no save), the bytes as a String, and a file's bytes put in as the game starts.
          # +save_file_due?+ is asked once a frame, and +save_file_written+ says the file holds it now.
          def save_size = @game.rg_live_save_size
          def save_bytes = @game.rg_live_save_bytes
          def load_save(bytes) = @game.rg_live_load_save(bytes)
          def save_file_due? = @game.rg_save_file_is_due?
          def save_unwritten? = @game.rg_save_unwritten?
          def save_file_written = @game.rg_save_file_written

          # A short number (a CRC-32) standing for the whole of the game's state as it is now: every
          # variable and list it keeps, written out the way the windowless run prints them. Machines
          # that run the same game on the same buttons have the same number on the same pass.
          def state_crc = @game.rg_live_state_crc

          # Every variable and list of the game by name, as they stand now: the runtime's RgLiveState, whose
          # +vars+ (`{ "x" => 3 }`) and +lists+ are Hashes by the game's own names. With
          # +byte_lists_packed+, a list of bytes (`width: :byte`) is a binary String, a byte an item,
          # not an Array of numbers: a data pack's build reads hundreds of megabytes that way.
          def state(byte_lists_packed: false) = @game.rg_live_state(byte_lists_packed)

          # Every variable of the game by name (`{ "x" => 3 }`), as they stand now, and none of its
          # lists: #state's +vars+, cheaply enough to ask each frame of a game whose lists are large.
          def vars = @game.rg_live_vars

          # CALLS INTO THE RUNTIME, COUNTED FOR A TEST THAT ASKS. A test of how much work a pass does
          # counts it, since a count is the same on a busy machine as on an idle one where a time is
          # not: how often the runtime's routines +names+ (`:rg_set_pixel`) are called from now on,
          # read back by #call_counts. Each named routine is wrapped, on this game alone, in one that
          # adds to its count and calls it. A game nobody asked this of has no wrapper and pays
          # nothing: the runtime itself keeps no count.
          def count_calls(*names)
            counts = @call_counts ||= Hash.new(0)
            names.each { |name| counts[name] += 0 } # a routine never called is counted as nought, not left out
            counting = Module.new do
              names.each do |name|
                define_method(name) do |*args, **options, &block|
                  counts[name] += 1
                  super(*args, **options, &block)
                end
              end
            end
            @game.singleton_class.prepend(counting)
            self
          end

          # How often each routine #count_calls named has been called, by name; nil for a game whose
          # calls are not counted.
          def call_counts = @call_counts&.dup
        end
      end
    end
  end
end
