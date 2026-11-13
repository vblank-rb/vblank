# frozen_string_literal: true

# READING A BUILT OR RUNNING CARTRIDGE BACK: taking a finished ROM apart, running one and
# looking at the pixels and the sound it really produced, and measuring where its frames went.
# All of it needs a cartridge to exist first — what a build says while there is not one yet is
# Messages.

require_relative "diagnostics/sprite_row"        # One sprite read back, from the console or the oracle
require_relative "diagnostics/sprite_box"        # One entry of a console's sprite table, as the box it draws
require_relative "diagnostics/video_memory"      # How much room the pictures took, and what the storage saved
require_relative "diagnostics/inspector"         # A finished ROM taken apart: header and disassembled code
require_relative "diagnostics/func_dumper"
require_relative "diagnostics/sm83_listing"      # A routine of a Game Boy Color cartridge
require_relative "diagnostics/missing_emulator"  # Why the emulator would not load, and what to do about it
require_relative "diagnostics/emulator"          # The one seam to the emulator backend; swap emulators here
require_relative "diagnostics/frame_sound"       # One frame's samples and the loudest of them
require_relative "diagnostics/recorded_sound"    # The sound of a run, its older part in a scratch file
require_relative "diagnostics/verifier"          # Real pixels and real sound read back through the emulator
require_relative "diagnostics/film"              # A film of one cartridge running, or two side by side, as an MP4
require_relative "diagnostics/film_cartridge"    # One side of a film, brought to its first frame with a save folder of its own
require_relative "diagnostics/film_script"       # A film written as a small file
require_relative "diagnostics/film_shell"        # A port's shell filmed from its first start, as a side of a film
# Its rake task, film_tasks.rb, is a Rakefile's and is not required here: a Rakefile requires it alone,
# and it loads the library when it runs.
require_relative "diagnostics/sound_recording"   # What a game sounds like on the cartridge, the desktop build or as Ruby
require_relative "diagnostics/counted_passes"    # The passes of a console whose runtime counts them
require_relative "diagnostics/snes_memory"       # Super Nintendo memory, work RAM and the Super FX chip's, by address
require_relative "diagnostics/snes_probe"        # A running Super Nintendo cartridge, as the reader asks of one
require_relative "diagnostics/genesis_probe"     # A running Genesis cartridge
require_relative "diagnostics/ps1_memory"        # PlayStation memory, main RAM and the scratchpad, by address
require_relative "diagnostics/ps1_probe"         # A running PlayStation program
require_relative "diagnostics/runtime_lists"     # A list as the Color's and Super Nintendo's runtimes keep it
require_relative "diagnostics/advance_reading"   # What an Advance cartridge keeps its own way
require_relative "diagnostics/color_reading"     # What a Game Boy Color cartridge does
require_relative "diagnostics/snes_reading"      # What a Super Nintendo cartridge does
require_relative "diagnostics/genesis_reading"   # What a Genesis cartridge does
require_relative "diagnostics/ps1_reading"       # What a PlayStation program does
require_relative "diagnostics/tearing"
require_relative "diagnostics/flicker"
require_relative "diagnostics/tick_rate"
require_relative "diagnostics/sound_drops"
require_relative "diagnostics/analyzer"
require_relative "diagnostics/build_report"      # The exact half of a profile: what the build made
require_relative "diagnostics/full_collections"  # Every list and pool, and how to hold each one full
require_relative "diagnostics/save_starts"       # A save started on each scene that saves, so saving is measured
require_relative "diagnostics/split_hints"       # Which part of a routine too big for quick memory to make a func of
require_relative "diagnostics/hidden_variables"  # Variables normal Ruby needed that nobody declared
require_relative "diagnostics/profiler"          # The measured half: where the frames went
require_relative "diagnostics/time_by_routine"   # A frame's time by routine, from an emulator that counts by address
require_relative "diagnostics/tape_profile"      # Each frame of a tape read by itself, and which work held its picture
# Its rake task, profile_tasks.rb, is a Rakefile's and is not required here, as film_tasks.rb is not.
require_relative "diagnostics/gbc_profiler"      # Where a Game Boy Color cartridge's frames went
require_relative "diagnostics/snes_profiler"     # Where a Super Nintendo cartridge's frames went
require_relative "diagnostics/genesis_profiler"  # Where a Genesis cartridge's frames went
require_relative "diagnostics/ps1_profiler"      # Where a PlayStation program's frames went
require_relative "diagnostics/hand_overs"        # Which scenes run late on the frame the game hands over to them
require_relative "diagnostics/routine_profile"
require_relative "diagnostics/cartridge_file"    # A cartridge that is only its file, with no record of its build
require_relative "diagnostics/save_bytes"        # A save of a kind the framework has no model of, kept as bytes
