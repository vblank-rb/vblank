# frozen_string_literal: true

require "test_helper"

# A GAME BUILT AS RUBY, PLAYED BY NOBODY WHO WATCHES OR LISTENS. A data pack's unpacking runs as Ruby
# with nobody at the window, so the picture and the sound the runtime would make at the end of each
# frame are work thrown away: in a long unpacking, about half of it. A player says each frame whether
# it wants the picture and the sound (picture_wanted?, sound_wanted?), and is handed nil for what it
# did not ask for, which the runtime then does not make. The game plays the same either way.
class TestLiveGameUnwatched < Minitest::Test
  # Asks for the picture and the sound when told to, and keeps what it is handed each frame.
  class KeepingPlayer
    attr_reader :handed

    def initialize(frames, picture:, sound:)
      @left = frames
      @picture = picture
      @sound = sound
      @handed = []
    end

    def take_state_request = nil
    def picture_wanted? = @picture
    def sound_wanted? = @sound

    def buttons_after(pixels, left, right)
      @handed << [pixels&.dup, left&.dup, right&.dup]
      (@left -= 1).positive? ? [0] : nil
    end
  end

  # A box that moves a pixel a frame and a beep each frame, so each frame has a picture and a sound.
  private def moving_box_with_beeps
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval do
      screen :bitmap
      enable_sound
      x = var :x, 0
      game_loop do
        clear_screen :black
        fill_rect x, 20, 8, 8, :green
        x += 1
        beep 440
      end
    end
    b.finalize_program
    b.program
  end

  private def played(player)
    game = VBlank::IR::Backends::Ruby.new.live_game(moving_box_with_beeps)
    game.play(player)
    game
  end

  def test_a_player_that_wants_no_picture_and_no_sound_is_handed_neither
    player = KeepingPlayer.new(12, picture: false, sound: false)
    played(player)

    assert_equal [[true, true, true]] * 12, player.handed.map { |handed| handed.map(&:nil?) }
  end

  def test_a_player_that_wants_both_is_handed_both
    player = KeepingPlayer.new(12, picture: true, sound: true)
    played(player)

    assert(player.handed.all? { |pixels, left, right| pixels.length == 240 * 160 && left.any? && right.any? })
    assert(player.handed.any? { |_pixels, left, _right| left.any?(&:nonzero?) }, "No frame had any sound")
  end

  def test_the_game_plays_the_same_unwatched
    watched = played(KeepingPlayer.new(12, picture: true, sound: true))
    unwatched = played(KeepingPlayer.new(12, picture: false, sound: false))

    assert_operator unwatched.state.vars.fetch("x"), :>, 10
    assert_equal watched.state.vars, unwatched.state.vars
  end

  def test_the_runtime_makes_no_picture_and_mixes_no_sound_for_a_player_that_wants_neither
    made = []
    watching = TracePoint.new(:call) do |call|
      made << call.method_id if %i[rg_screen_framed rg_sound_render_frame].include?(call.method_id)
    end
    watching.enable { played(KeepingPlayer.new(12, picture: false, sound: false)) }

    assert_empty made
  end

  # What +frames+ passes of a loop that only counts make, played unwatched.
  private def objects_made_counting(frames)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval do
      count = var :count, 0
      game_loop { count += 1 }
    end
    b.finalize_program
    game = VBlank::IR::Backends::Ruby.new.live_game(b.program)
    player = VBlank::Original::Unpacking::FrameLimitedPlayer.new(frames)
    before = GC.stat(:total_allocated_objects)
    game.play(player)
    GC.stat(:total_allocated_objects) - before
  end

  # A long unpacking plays hundreds of thousands of frames, so a frame boundary that makes objects
  # (the buttons read into new lists each frame did) keeps Ruby's garbage collector busy.
  def test_a_frame_played_unwatched_makes_no_objects
    assert_operator objects_made_counting(102) - objects_made_counting(2), :<, 100
  end

  def test_an_unpacking_wants_no_picture_and_no_sound
    player = VBlank::Original::Unpacking::FrameLimitedPlayer.new(2)

    refute player.picture_wanted?
    refute player.sound_wanted?
  end
end
