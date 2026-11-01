# frozen_string_literal: true

require "fade_watch"

# A long fade toward black on a dark picture, for a console that shows five bits of each channel. A
# console of three bits (the Genesis) shows a dark colour as black some frames before the fade is all
# the way down, so this is not a test of every console.
module DarkFadeTests
  include FadeWatch

  # Where the rounding shows: a channel of 4 a 256th of the way back from black is nothing if it keeps
  # its share and one if a share is taken away. The walk takes one away, as the console's documented
  # fade does, so it is black only while the fade is all the way down, and back on the first frame after.
  #
  # Not held to the display's own fade on a plain bitmap screen: that fade is worked out the way the
  # emulator works it out, at eight bits a channel, and there a dark colour reaches black a level early
  # — a step before the walk on the way down and a step after it on the way back.
  DUSK = VBlank::Graphics::Color.rgb(4, 6, 8)
  BLACK = 0

  def test_a_long_fade_to_black_is_black_only_while_it_is_all_the_way_down
    walked = long_fade(:tiled, toward: :black, color: DUSK)
    seen = watch(walked, 90) { |run| [run.screen.pixel(120, 80), run[:fade_level_seen]] }

    # The colours are walked in the gap before a frame, so the picture shows the level the
    # pass before it reached — one frame on from the variable read beside it.
    black = seen.each_index.select { |n| seen[n][0] == BLACK }
    down = seen.each_index.select { |n| seen[n][1] == 100 }.map(&:succ)
    refute_empty black
    assert_equal down, black
  end
end
