# frozen_string_literal: true

# READING A BUILT OR RUNNING CARTRIDGE BACK: taking a finished ROM apart, running one and
# looking at the pixels and the sound it really produced, and measuring where its frames went.
# All of it needs a cartridge to exist first — what a build says while there is not one yet is
# Messages.

require_relative "diagnostics/sprite_row" # one sprite read back, off the console or off the oracle
require_relative "diagnostics/sprite_box" # ...and one entry of a console's sprite table, as the box it draws
require_relative "diagnostics/video_memory" # how much room the pictures took, and what the storage saved
require_relative "diagnostics/inspector" # a finished ROM taken apart: header, and the code disassembled
require_relative "diagnostics/func_dumper"
require_relative "diagnostics/sm83_listing" # ...and a routine of a Game Boy Color cartridge
require_relative "diagnostics/emulator" # the one seam to the emulator backend; swap emulators here
require_relative "diagnostics/recorded_sound" # the sound of a run, the older part of it in a scratch file
require_relative "diagnostics/verifier" # ...and reading real pixels and real sound back through it
require_relative "diagnostics/film" # ...and a film of one running, or of two side by side, as an MP4
require_relative "diagnostics/film_cartridge" # ...one side of it, brought to its first frame with a save folder of its own
require_relative "diagnostics/film_script" # ...and a film written as a small file. Its rake task, film_tasks.rb, is a
# Rakefile's and is not required here: a Rakefile requires it alone, and it loads the library when it runs.
require_relative "diagnostics/sound_recording" # what a game sounds like on the cartridge, the desktop build or as Ruby
require_relative "diagnostics/counted_passes" # ...the passes of a console whose runtime counts them
require_relative "diagnostics/snes_memory" # ...its memory, work RAM and the Super FX chip's, by address
require_relative "diagnostics/snes_probe" # ...a running Super Nintendo cartridge, as the reader asks of one
require_relative "diagnostics/genesis_probe" # ...a running Genesis cartridge
require_relative "diagnostics/ps1_memory" # ...a PlayStation's memory, main RAM and the scratchpad, by address
require_relative "diagnostics/ps1_probe" # ...and a running PlayStation program
require_relative "diagnostics/runtime_lists" # ...a list as the Color's and the Super Nintendo's runtimes keep it
require_relative "diagnostics/advance_reading" # ...what an Advance cartridge keeps its own way
require_relative "diagnostics/color_reading" # ...and what a Game Boy Color cartridge does
require_relative "diagnostics/snes_reading" # ...and what a Super Nintendo cartridge does
require_relative "diagnostics/genesis_reading" # ...and what a Genesis cartridge does
require_relative "diagnostics/ps1_reading" # ...and what a PlayStation program does
require_relative "diagnostics/tearing"
require_relative "diagnostics/flicker"
require_relative "diagnostics/tick_rate"
require_relative "diagnostics/sound_drops"
require_relative "diagnostics/analyzer"
require_relative "diagnostics/build_report" # the exact half of a profile: what the build made
require_relative "diagnostics/full_collections" # every list and pool, and how to hold each one full
require_relative "diagnostics/save_starts" # a save started on each scene that saves, so it is measured saving
require_relative "diagnostics/split_hints" # which part of a routine too big for the quick memory to make a func of
require_relative "diagnostics/hidden_variables" # the variables normal Ruby needed that nobody declared
require_relative "diagnostics/profiler" # ...and the measured half: where the frames went
require_relative "diagnostics/time_by_routine" # a frame's time by routine, from an emulator that counts it by address
require_relative "diagnostics/tape_profile" # ...each frame of a tape read by itself, and which work held its picture. Its
# rake task, profile_tasks.rb, is a Rakefile's and is not required here, as film_tasks.rb is not.
require_relative "diagnostics/gbc_profiler" # ...and where a Game Boy Color cartridge's frames went
require_relative "diagnostics/snes_profiler" # ...and where a Super Nintendo cartridge's frames went
require_relative "diagnostics/genesis_profiler" # ...and where a Genesis cartridge's frames went
require_relative "diagnostics/ps1_profiler" # ...and where a PlayStation program's frames went
require_relative "diagnostics/hand_overs" # which scenes run late on the frame the game hands over to them
require_relative "diagnostics/routine_profile"
require_relative "diagnostics/cartridge_file" # a cartridge that is only its file, with no record of its build
require_relative "diagnostics/save_bytes" # ...and a save of a kind the framework has no model of, kept as its bytes
