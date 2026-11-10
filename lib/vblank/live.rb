# frozen_string_literal: true

# A GAME PLAYED LIVE, IN RUBY: the game built as Ruby (IR::Backends::Ruby) runs in this process a
# pass at a time while a person watches and plays, its picture put on a screen, its buttons read
# from a keyboard or a pad.
#
# The playing is the session's; what it is shown on is a device, which shows a picture, reports
# which buttons are held and whether to stop, and keeps the time. The headless device is the
# one with no screen, for a test or a measurement.
#
# It is not part of `require "vblank"`, the way vblank/testing is not: the window (SDL) is reached
# through Fiddle, which a game that only builds cartridges never needs, and Fiddle is loaded only
# when a window is asked for.
require_relative "../vblank"
require_relative "live/lateness"       # Which passes ran longer than a frame, and how much was garbage collection
require_relative "live/rate"           # How fast play went: passes and frames a second
require_relative "live/session"        # The game played a pass at a time through a device
require_relative "live/headless"       # A device with no screen, whose clock a test moves
require_relative "live/bot_device"     # A device with no person, whose buttons a bot chooses
require_relative "live/recording"      # Any device, keeping the sound handed to its speaker
require_relative "live/window_menu"    # The window's menu written once: lines, keys and look
require_relative "live/menu"           # How the menu behaves and draws, with no window of its own
require_relative "live/settings"       # What the window keeps for a player
require_relative "live/state_slots"    # The places a game's save states are kept in, a file each
require_relative "live/save_file"      # The file a game's save memory is kept in between runs
require_relative "live/settings_file"  # Where those settings are kept, the same file as the desktop build's
require_relative "live/console_bios"   # The player's Game Boy Advance BIOS, found as the desktop build finds it
require_relative "live/shell"          # A port with no data: its menu, its unpacking and its kept pack
require_relative "live/shell_check"    # A port's shell played against its all-in-one build
require_relative "live/sdl"            # A window for a person: SDL3 through Fiddle, loaded when asked for
