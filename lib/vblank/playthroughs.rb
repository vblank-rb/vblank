# frozen_string_literal: true

# PLAYING A FINISHED CARTRIDGE WITH NOBODY AT THE CONTROLS: from a script that says what to
# press or a tape of the presses that were made, and two cartridges side by side to find the
# frame where they stop matching.
#
# It plays on the reader over a running cartridge, which is Diagnostics' (the Verifier). The
# line between the two is which way each one faces: Diagnostics reads a cartridge back, and
# what is here drives one.
require_relative "playthroughs/playthrough" # a game driven from a script
require_relative "playthroughs/lowered_game" # ...on a way of running a game other than the emulator
require_relative "playthroughs/unbuilt_game" # ......which needs the game checked, and no cartridge
require_relative "playthroughs/watched_game" # ...and shown in a window at the console's frame rate
require_relative "playthroughs/pass_stepped_game" # ...and counted in passes of the game loop and not frames
require_relative "playthroughs/tape" # ...and the presses it made, written down to play again
require_relative "playthroughs/tape_export" # ...and that tape written out for another emulator
require_relative "playthroughs/playthrough_picture_folder" # ...and the folder its pictures are written into
require_relative "playthroughs/comparison" # two cartridges played side by side on the same presses
require_relative "playthroughs/comparison_likeness" # ...and how alike two pictures have to be
require_relative "playthroughs/comparison_looked_at" # ...and which pixels of the screen it looks at, frame by frame
require_relative "playthroughs/comparison_ignored_frames" # ...and the stretches of the playing it does not look at
require_relative "playthroughs/comparison_torn_frames" # ...and the strict rule for a frame shown torn
require_relative "playthroughs/comparison_video_differences" # ...and which video memories differ where the two part
require_relative "playthroughs/comparison_readings" # ...and the numbers it reads off both and compares by name
require_relative "playthroughs/comparison_compared" # ...and the list of what it compares: the picture, the readings
require_relative "playthroughs/comparison_lined_up" # ...and the two lined up step by step, not frame by frame
require_relative "playthroughs/comparison_passes" # ......a step being a pass of the game's loop
require_relative "playthroughs/comparison_still_frames" # ......or a frame whose picture changed
require_relative "playthroughs/comparison_at_moments" # ...and the other way to compare: the same script on each
require_relative "playthroughs/comparison_screen_pair" # ...and the two screens of one frame, as pictures to look at
require_relative "playthroughs/comparison_picture_request" # ......one of which can be asked for by itself, for any frame
require_relative "playthroughs/comparison_report" # ...and the folder it writes for a drift it finds
require_relative "playthroughs/comparison_drift_report" # ......of a drift on a frame, on the same tape
require_relative "playthroughs/comparison_moment_report" # ......and of a drift at a moment, on the same script
require_relative "playthroughs/command_line" # what `vblank run` with a script or tape, and `vblank compare`, do
require_relative "playthroughs/probe" # any cartridge driven a frame at a time by hand, read by its memory's labels
