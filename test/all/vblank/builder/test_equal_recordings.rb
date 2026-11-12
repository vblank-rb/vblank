# frozen_string_literal: true

require "test_helper"
require "equal_recording_games"

# RECORDINGS WITH THE SAME SAMPLES UNDER SEVERAL NAMES are kept once by each build that can
# (each lowering's own test counts the copies). A game cannot tell: each still sounds under its own
# name, and stopping one leaves another sounding.
class TestEqualRecordings < Minitest::Test
  include EqualRecordingGames

  def test_a_recording_alike_two_others_sounds_under_its_own_name
    run = game_player.run(recordings_game(plays: [:second]), frames: 6)

    assert_equal [:second], run.active_samples
    assert_includes run.audio, [:sample, :second]
    refute_includes run.audio, [:sample, :first]
  end

  def test_stopping_a_recording_leaves_one_alike_it_sounding
    run = game_player.run(recordings_game(plays: [:second], stops: :first), frames: 8)

    assert_equal [:second], run.active_samples
  end

  def test_stopping_a_recording_stops_it_and_not_one_alike_it
    stopped = game_player.run(recordings_game(plays: [:second], stops: :second), frames: 8)

    assert_empty stopped.active_samples
  end
end
