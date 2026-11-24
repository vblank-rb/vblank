# frozen_string_literal: true

require "test_helper"
require "ruby_answers"
require "fixtures/plain_file_structs"

VBlank.require_game_file "../../../fixtures/plain_file_struct_parts"

# Structs and Data classes written in a file loaded with plain `require`
# (test/fixtures/plain_file_structs.rb), which no rewrite reads, held to Ruby's answers in game code
# as the answers suite holds a game file's (RubyAnswers): made by game code, or handed to it by a
# method of that file, alone, in an Array, a Hash, another object, a block or a method's argument.
class TestPlainFileStructs < Minitest::Test
  include RubyAnswers

  FOLLOWED = VBlank::DSL::PlainRuby::InstanceVariables::FollowedFields

  def test_a_struct_made_from_a_changing_number_keeps_a_copy
    agrees("PlainFilePoint.new(score, 0), then score += 1", reads: %i[n], passes: 3) do
      score = 0
      point = PlainFilePoint.new(score, 0)
      n = 0
      game_loop do
        score += 1
        n = point.x
      end
    end
  end

  def test_a_struct_made_in_the_game_loop_from_a_number_changed_after
    agrees("fresh = PlainFileLoopPoint.new(px + 2, 0); px += 5", reads: %i[n], passes: 3) do
      px = n = 0
      game_loop do
        px += 1
        fresh = PlainFileLoopPoint.new(px + 2, 0)
        px += 5
        n = fresh.x
      end
    end
  end

  def test_a_field_changed_in_the_game_loop
    agrees("PlainFileStepPoint.new(1, 0); point.x += 1", reads: %i[n], passes: 3) do
      point = PlainFileStepPoint.new(1, 0)
      n = 0
      game_loop do
        point.x += 1
        n = point.x
      end
    end
  end

  def test_a_data_object_made_from_a_changing_number_keeps_a_copy
    agrees("PlainFileFixedPoint.new(x: score), then score += 1", reads: %i[n], passes: 3) do
      score = 0
      point = PlainFileFixedPoint.new(x: score, y: 0)
      n = 0
      game_loop do
        score += 1
        n = point.x
      end
    end
  end

  def test_a_struct_made_by_a_method_of_the_file
    agrees("point = PlainFilePoints.at(score), then score += 1", reads: %i[n], passes: 3) do
      score = 0
      point = PlainFilePoints.at(score)
      n = 0
      game_loop do
        score += 1
        n = point.x
      end
    end
  end

  def test_a_struct_handed_back_in_an_array
    agrees("pts = PlainFilePoints.many(score)", reads: %i[n], passes: 3) do
      score = 0
      pts = PlainFilePoints.many(score)
      n = 0
      game_loop do
        score += 1
        n = pts[0].x
      end
    end
  end

  def test_a_struct_handed_back_in_a_hash
    agrees("found = PlainFilePoints.keyed(score)", reads: %i[n], passes: 3) do
      score = 0
      found = PlainFilePoints.keyed(score)
      n = 0
      game_loop do
        score += 1
        n = found[:first].x
      end
    end
  end

  def test_a_struct_held_in_a_field_of_another
    agrees("pair = PlainFilePoints.pair(score); pair.inner.x", reads: %i[n], passes: 3) do
      score = 0
      pair = PlainFilePoints.pair(score)
      n = 0
      game_loop do
        score += 1
        n = pair.inner.x
      end
    end
  end

  def test_a_struct_handed_to_a_block_and_kept
    agrees("PlainFilePoints.each_at(score) { |point| @kept = point }", reads: %i[n], passes: 3) do
      score = 0
      PlainFilePoints.each_at(score) { |point| @kept = point }
      n = 0
      game_loop do
        score += 1
        n = @kept.x
      end
    end
  end

  def test_a_struct_made_through_a_local_holding_its_class
    agrees("kind = PlainFileLocalClassPoint; kind.new(score, 0)", reads: %i[n], passes: 3) do
      score = 0
      kind = PlainFileLocalClassPoint
      point = kind.new(score, 0)
      n = 0
      game_loop do
        score += 1
        n = point.x
      end
    end
  end

  def test_a_struct_handed_to_a_method_of_game_code
    agrees("tally.read_after_bump(tally.point_now)", reads: %i[n], passes: 3) do
      tally = PlainFileTally.new
      n = 0
      game_loop { n = tally.read_after_bump(tally.point_now) }
    end
  end

  # Both objects were made before game code named either, so before their class was followed.
  def test_two_structs_made_before_their_class_is_followed
    agrees("two = PlainFilePoints.two_at(score)", reads: %i[n m], passes: 3) do
      score = 0
      two = PlainFilePoints.two_at(score)
      n = m = 0
      game_loop do
        score += 1
        two[1].x += 10
        n = two[0].x
        m = two[1].x
      end
    end
  end

  # The objects are followed, one by one; their classes stay as the file wrote them.
  def test_objects_of_a_class_and_the_one_it_comes_from_leave_both_classes_alone
    agrees("child, then base", reads: %i[n m], passes: 3) do
      score = 0
      child = PlainFilePoints.child_at(score)
      base = PlainFilePoints.base_at(score)
      n = m = 0
      game_loop do
        score += 1
        child.x += 1
        n = child.x
        m = base.x
      end
    end
    refute_includes PlainFileChild.ancestors, FOLLOWED
    refute_includes PlainFileBase.ancestors, FOLLOWED
  end

  # A frozen class is not changed, so it works as any other.
  def test_a_frozen_class_keeps_a_copy
    agrees("PlainFileFrozenPoint.new(score, 0)", reads: %i[n], passes: 3) do
      score = 0
      point = PlainFileFrozenPoint.new(score, 0)
      n = 0
      game_loop do
        score += 1
        n = point.x
      end
    end
  end

  # A frozen object holding a number the game works out cannot be given its own copy.
  def test_a_frozen_object_made_from_a_game_number_is_refused
    refused("PlainFilePoints.frozen_at(score)", /frozen.*do not freeze it/m) do
      score = 0
      point = PlainFilePoints.frozen_at(score)
      n = 0
      game_loop do
        score += 1
        n = point.x
      end
    end
  end

  # Ruby's own Structs, a gem's and VBlank's are not the game's, and are never changed.
  def test_only_a_class_of_the_games_own_source_is_followed
    followed = VBlank::DSL::PlainRuby::InstanceVariables
    assert followed.game_source_class?(PlainFilePoint)
    refute followed.game_source_class?(Process::Tms), "Ruby's own, made in C"
    refute followed.game_source_class?(VBlank::DSL::Background::AreaTiles), "VBlank's own"
    refute followed.game_source_class?(Minitest::Expectation), "a gem's"
  end

  # Following an object leaves its class, and every other object of it, as the file wrote them.
  def test_a_followed_objects_class_is_left_as_written
    agrees("PlainFilePoints.at(score)", reads: %i[n], passes: 1) do
      score = 0
      point = PlainFilePoints.at(score)
      n = 0
      game_loop { n = point.x }
    end
    refute_includes PlainFileMadePoint.ancestors, FOLLOWED
    point = PlainFileMadePoint.new(1, 2)
    refute_kind_of FOLLOWED, point
    point.x += 1
    assert_equal [2, 2], point.to_a
  end
end
