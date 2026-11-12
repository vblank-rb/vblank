# frozen_string_literal: true

require "test_helper"
require "differential"
require "console/gba/vblank/builder/test_placed_fade_across_scenes_on_the_advance"

# A fade placed in the stack kept across a change of scene, on the Advance's cartridge: the
# display's blend registers are the game's, and a scene that takes over leaves a fade in them
# where it is. Each game is held to the interpreter, every pixel, on the frames round the change.
# What those games show is in
# test/console/gba/vblank/builder/test_placed_fade_across_scenes_on_the_advance.rb.
class TestPlacedFadeAcrossScenesCartridge < Minitest::Test
  include Differential
  include PlacedFadeAcrossScenesGames

  def test_the_cartridge_keeps_the_fade_when_a_scene_with_no_sprite_takes_over
    assert_backends_agree(faded_title_then_room, frames: AROUND_THE_CHANGE, name: "FADEKEPT")
  end

  def test_the_cartridge_keeps_the_fade_with_a_sprite_on_screen
    assert_backends_agree(faded_title_then_room(with_sprite: true), frames: AROUND_THE_CHANGE, name: "FADEGUY")
  end

  def test_the_cartridge_shows_the_second_scenes_own_fade
    assert_backends_agree(room_fading_less, frames: AROUND_THE_CHANGE, name: "FADELESS")
  end

  def test_the_cartridge_shows_the_title_again_over_the_faded_room
    assert_backends_agree(faded_title_then_room(back_on: CHANGES_ON + 4), frames: AROUND_THE_CHANGE, name: "FADEBACK")
  end

  def test_the_cartridge_lifts_the_fade_where_the_second_scene_does
    assert_backends_agree(room_lifting_the_fade, frames: AROUND_THE_CHANGE, name: "FADELIFT")
  end

  def test_the_cartridge_fades_in_where_the_second_scene_does
    assert_backends_agree(room_fading_in, frames: (CHANGES_ON..(CHANGES_ON + 10)), name: "FADEIN")
  end

  def test_the_cartridge_keeps_a_whole_screen_fade_and_a_tint
    assert_backends_agree(title_fading_everything, frames: AROUND_THE_CHANGE, name: "FADEALL")
    assert_backends_agree(title_tinting_everything, frames: AROUND_THE_CHANGE, name: "TINTALL")
  end

  # A game with both kinds of screen has no one count of frames the console takes to start, so
  # each frame names the console's: two more, which is the painted screen's.
  def test_the_cartridge_shows_a_painted_scene_as_painted
    [CHANGES_ON + 2, SETTLED].each do |frames|
      assert_backends_agree(painted_room, frames: frames, console_frames: frames + 2, name: "FADEPAINT")
    end
  end

  def test_the_cartridge_holds_a_see_through_layer_solid_while_the_fade_stays
    assert_backends_agree(room_with_mist, frames: AROUND_THE_CHANGE, name: "FADEMIST")
    assert_backends_agree(room_with_mist(with_sprite: true), frames: AROUND_THE_CHANGE, name: "FADEMISTGUY")
  end
end
