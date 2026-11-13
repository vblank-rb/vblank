# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # THE CONSOLE THE C IS BUILT AS, written where the runtime reads it: rg_console_numbers.h,
        # beside game.c, which runtime/rg_console.h includes. Its screen is the size of the
        # runtime's buffers and window, and its clock sets how long a frame lasts. Everything else
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
          # read it from (a shell's parts, Native#build_desktop_shell).
          def values(console, start_up: true)
            { "RG_SCREEN_WIDTH" => console.screen_width, "RG_SCREEN_HEIGHT" => console.screen_height,
              "RG_CONSOLE_TICKS_A_SECOND" => console.cycles_a_second,
              "RG_CONSOLE_TICKS_A_FRAME" => console.cycles_a_frame,
              "RG_CONSOLE_BLENDS" => console.blends, "RG_CONSOLE_DIMS" => console.fades_by_brightness,
              "RG_CONSOLE_RUMBLES" => console.rumbles,
              "RG_SPRITE_PIECES_A_LINE" => console.sprite_pieces_drawn_a_line || 0,
              "RG_CLOCK_KEEPS_DATE" => console.clock_keeps_date, "RG_COLOR_BITS" => console.color_bits,
              "RG_VOICES_READ_SOUND_MEMORY" => console.voices_read_sound_memory,
              "RG_CONSOLE_PLAYS_BIOS_START_UP" => start_up && console.plays_bios_start_up,
              "RG_SHOWN_FIRST_ROW" => console.shown_row_bounds[0], "RG_SHOWN_PAST_ROW" => console.shown_row_bounds[1] }
              .merge(StartFileNumbers.names)
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
