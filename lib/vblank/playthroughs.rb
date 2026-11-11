# frozen_string_literal: true

# PLAYING A FINISHED CARTRIDGE WITH NOBODY AT THE CONTROLS: from a script that sets out what to
# press or a tape of the presses that were made, and two cartridges side by side to find the
# frame where they stop matching.
#
# It plays on the reader over a running cartridge, which is Diagnostics' (the Verifier). The
# line between the two is which way each one faces: Diagnostics reads a cartridge back, and
# what is here drives one.
require_relative "playthroughs/playthrough"                   # A game driven from a script
require_relative "playthroughs/lowered_game"                  # A way of running a game other than the emulator
require_relative "playthroughs/unbuilt_game"                  # A game that is checked but has no cartridge
require_relative "playthroughs/window_stepper"                # A game stepped in a window at the console's frame rate
require_relative "playthroughs/pass_stepper"                  # A game stepped in passes of its loop, not frames
require_relative "playthroughs/tape"                          # The presses a playthrough made, written down to play again
require_relative "playthroughs/tape_export"                   # A tape written out for another emulator
require_relative "playthroughs/playthrough_picture_folder"    # The folder a playthrough's pictures go in
require_relative "playthroughs/comparison"                    # Two cartridges played side by side on the same presses
require_relative "playthroughs/comparison_likeness"           # How alike two pictures have to be
require_relative "playthroughs/comparison_looked_at"          # Which screen pixels a comparison looks at, frame by frame
require_relative "playthroughs/comparison_ignored_frames"     # Stretches of play a comparison skips
require_relative "playthroughs/comparison_torn_frames"        # The strict rule for a frame shown torn
require_relative "playthroughs/comparison_video_differences"  # Which video memories differ where two runs part
require_relative "playthroughs/comparison_readings"           # Numbers read from both runs and compared by name
require_relative "playthroughs/comparison_compared"           # The list of what a comparison compares
require_relative "playthroughs/comparison_lined_up"           # Two runs lined up step by step, not frame by frame
require_relative "playthroughs/comparison_passes"             # A step as a pass of the game's loop
require_relative "playthroughs/comparison_still_frames"       # A step as a frame whose picture changed
require_relative "playthroughs/comparison_at_moments"         # The same script run on each cartridge
require_relative "playthroughs/comparison_screen_pair"        # The two screens of one frame, as pictures
require_relative "playthroughs/comparison_picture_request"    # A picture asked for by itself, for any frame
require_relative "playthroughs/comparison_report"             # The folder written for a drift
require_relative "playthroughs/comparison_drift_report"       # A drift on a frame, on the same tape
require_relative "playthroughs/comparison_moment_report"      # A drift at a moment, on the same script
require_relative "playthroughs/heard_sound"                   # How loud one cartridge was on each frame of a playing
require_relative "playthroughs/heard_comparison"              # Two cartridges' heard sound on the same presses
require_relative "playthroughs/command_line"                 # What `vblank run` with a script or tape, and `vblank compare`, do
require_relative "playthroughs/probe"                         # A cartridge driven a frame at a time by hand, read by memory label
