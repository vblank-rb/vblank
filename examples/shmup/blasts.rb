# frozen_string_literal: true

# The shmup's blasts — the sound of something blowing up, as verbs of this game's own.
#
# A game that says the same few things in the same way in several places can give them a name.
# This is a pack: a plain Ruby module whose methods are written in VBlank's own verbs. The line
# `uses Blasts` in examples/shmup.rb makes each public method here a verb of this game, so the
# enemies' file says `build.play_enemy_blast` the way it says `build.rand`. The pack is this
# game's alone: another game built beside it does not get these verbs, and is free to have its own
# of the same names. And since it is made of ordinary verbs, it plays the same everywhere the game
# does, with nothing else to write.
#
# The sound is the console's noise voice, which hisses rather than playing a note: the hiss of a
# crash, a drum or an explosion. `noise` takes a ready-made one by name, or says how it sounds:
# how high the hiss sits, how fast it dies away and how loud it starts.
module Shmup
  module Blasts
    # An enemy shot down: a short crack.
    def play_enemy_blast = noise(:hit)

    # The ship lost: a low rumble at full loudness that takes its time to die away.
    def play_ship_blast = noise(pitch: :low, decay: :slow, volume: 15)
  end
end
