# frozen_string_literal: true

require "test_helper"
require "fade_watch"

# The tests of vblank/effects/packs/test_screen_fade.rb that only the Game Boy Advance can play, kept apart so
# that the Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# The Advance's display fades a plain bitmap screen itself, in sixteenths. A Game Boy Color has no
# display blend, so every fade there walks the colours, in 256ths.
class TestScreenFadeOnTheAdvance < Minitest::Test
  include FadeWatch

  # The display's own fade counts in sixteenths, so a plain bitmap screen, which has no
  # colour table to walk, keeps the old steps. It is the yardstick for the finer steps a
  # screen drawn through a colour table takes (TestScreenFade).
  def test_a_long_fade_on_a_plain_bitmap_screen_keeps_seventeen_steps
    assert_equal 17, ramp(long_fade(:bitmap), 50).uniq.size
  end
end
