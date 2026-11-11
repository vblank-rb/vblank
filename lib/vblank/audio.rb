# frozen_string_literal: true

# THE SOUND AND MUSIC MODEL BEHIND THE VERBS: what a beep or a note IS, what a tune is made of,
# how a note starts and ends, and how a recording is read. Every backend reads this, which is
# what keeps the console and the headless interpreter agreeing about what a game sounds like.

require_relative "audio/sound"        # Beeps and notes, and each voice's limits
require_relative "audio/note_fade"    # A voice's note fading or swelling by itself
require_relative "audio/pitch_slide"  # The first square voice's pitch sliding by itself
require_relative "audio/vibrato"      # The music player's pitch wobble
require_relative "audio/pan"          # Which speaker a note plays from
require_relative "audio/duty"         # A square note's tone shape, or the shapes it steps through
require_relative "audio/pitch_shift"  # A part played higher or lower than written
# Must load before ir/: the backends size their music player from Music.
require_relative "audio/music"        # Music written as a block
require_relative "audio/score"        # Music handed over as data
require_relative "audio/envelope"     # How a note starts and ends, so an edge is not a click
require_relative "audio/snes_envelope" # The Super Nintendo sound chip's own envelope bytes
require_relative "audio/wav"         # A recording read from a file
