# frozen_string_literal: true

# Recordings (`sample`, `instrument`) played together: the mixer that adds every sounding recording
# into one stream, a frame's slice at a time, for the game's own `play` and for the notes of songs.
# Joined into the sound runtime.
VBlank::IR::Backends::RuntimeFeatures.declare(
  name: :mix,
  needed_by: %i[sample play_sample stop_sample],
  hooks: %i[setup sound_frame sound_frame_ended mixed_slice moment_printed visit_sound_state],
  joins: :sound
)
