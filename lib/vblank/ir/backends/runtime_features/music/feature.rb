# frozen_string_literal: true

# `play_song`, `play_sound_effect` and the rest of the tune: the music player, the sound effects it
# walks, and the pitch wobble, swell and shape stepping that only notes do. Joined into the sound
# runtime, after the mix so the frame's slice is made before the tune plays.
VBlank::IR::Backends::RuntimeFeatures.declare(
  name: :music,
  needed_by: %i[play_song play_from_list play_sound_effect stop_music hold_music],
  hooks: %i[setup sound_frame voice_taken_by_game],
  after: %i[mix],
  joins: :sound
)
