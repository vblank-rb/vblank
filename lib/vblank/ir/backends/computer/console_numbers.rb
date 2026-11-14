# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # THE CONSOLE THE C IS BUILT AS, written where the runtime reads it: rg_console_numbers.h,
        # beside game.c, which runtime/rg_console.h includes. Its screen is the size of the
        # runtime's buffers, and its whole screen the size of its window: bigger where the game's
        # screen is shown in a border (Console::Description#bordered?), whose corner is RG_GAME_LEFT
        # and RG_GAME_TOP. RG_PIXEL_SIZE is how many of the window's pixels across and down each of
        # the picture's is shown as at a scale of 1 (Console::Description#pixel_size): a game of big
        # pixels plays a small screen and opens a window the console's size all the same. Its clock
        # sets how long a frame lasts. Everything else
        # the game does differently on one console than another is decided when the game is
        # lowered, from the same description.
        #
        # The JavaScript and Ruby runtimes are handed the same numbers by the same names
        # (JS#console_text, Ruby::Lowering#console_text), each from #values, so a new one is
        # added here once and reaches all three.
        module ConsoleNumbers
          FILE = "rg_console_numbers.h"

          module_function

          # What the runtimes are told of +console+ (a Console::Description), by the name each
          # reads it as: numbers, and true or false for what the console does or does not do.
          # +start_up+ false leaves the console's start-up out, for a program with no cartridge to
          # read it from (a shell's parts, Native#build_desktop_shell). The buttons a player's
          # number keeps are every console's, since a build refuses a button its console lacks
          # before there is a game to play.
          def values(console, start_up: true) = screen_values(console).merge(console_values(console, start_up), StartFileNumbers.names)

          # The screen's sizes and where the game's sits in it. Kept apart from the rest: one hash
          # literal of every pair is deep enough on Ruby's stack that YJIT (Ruby 4.0.9, arm64)
          # panicked compiling it, ending the process.
          def screen_values(console)
            whole = console.framed_screen_size
            left, top = console.border_corner
            { "RG_SCREEN_WIDTH" => console.screen_width, "RG_SCREEN_HEIGHT" => console.screen_height,
              "RG_WHOLE_WIDTH" => whole[0], "RG_WHOLE_HEIGHT" => whole[1], "RG_GAME_LEFT" => left, "RG_GAME_TOP" => top,
              "RG_PIXEL_SIZE" => console.pixel_size,
              "RG_SHOWN_FIRST_ROW" => console.shown_row_bounds[0], "RG_SHOWN_PAST_ROW" => console.shown_row_bounds[1] }
          end

          # The rest #values tells of +console+.
          def console_values(console, start_up)
            { "RG_CONSOLE_TICKS_A_SECOND" => console.cycles_a_second,
              "RG_CONSOLE_TICKS_A_FRAME" => console.cycles_a_frame,
              "RG_CONSOLE_BLENDS" => console.blends, "RG_CONSOLE_DIMS" => console.fades_by_brightness,
              "RG_CONSOLE_RUMBLES" => console.rumbles,
              "RG_SPRITE_PIECES_A_LINE" => console.sprite_pieces_drawn_a_line || 0,
              "RG_SPRITE_SLIVERS_A_LINE" => console.sprite_slivers_drawn_a_line || 0,
              "RG_SPRITE_PIXELS_A_LINE" => console.sprite_pixels_drawn_a_line || 0,
              "RG_SPRITE_PIECES_A_SCREEN" => console.sprite_pieces_drawn_a_screen || 0,
              "RG_SPRITE_TABLE_FROM_BACK" => console.sprite_table_filled_from == :back,
              "RG_CLOCK_KEEPS_DATE" => console.clock_keeps_date, "RG_COLOR_BITS" => console.color_bits,
              "RG_VOICES_READ_SOUND_MEMORY" => console.voices_read_sound_memory,
              "RG_CONSOLE_PLAYS_BIOS_START_UP" => start_up && console.plays_bios_start_up,
              "RG_ONE_PLAYERS_BUTTONS" => IR::Buttons::EVERY_BUTTON_MASK }
          end

          # +value+ as C and JavaScript write it: true and false as 1 and 0.
          def as_number(value) = { true => 1, false => 0 }.fetch(value, value)

          # The header for +console+, +start_up+ as #values takes it.
          def header(console, start_up: true)
            defines = values(console, start_up: start_up).map { |name, value| "#define #{name} #{as_number(value)}\n" }
            "/* Written by Computer::ConsoleNumbers: the #{console.title}. */\n#{defines.join}"
          end
        end
      end
    end
  end
end
