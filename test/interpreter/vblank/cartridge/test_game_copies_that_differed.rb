# frozen_string_literal: true

require "test_helper"

# A plain local set from a game value keeps the number of its line, as Ruby's does, in a hidden
# copy. A game written while a local followed its variable can lean on the old live read without
# knowing it. Game#copies_that_differed plays the game on the interpreter and names each copy whose
# kept number was not what its source read at the moment the local was read: the line where the
# number was kept, the local, the variables it was worked out from, both numbers and the frame.
class TestGameCopiesThatDiffered < Minitest::Test
  # `kept` keeps @x's 5, and `bump` moves @x on to 6 before `kept` is read.
  private def changed_between
    VBlank.game "CHANGED", consoles: %i[gba] do
      game_variables :x
      @x = 5
      def bump = @x += 1
      seen = var :seen, 0
      game_loop do
        @x = 5
        kept = @x # changed_between's copy
        bump
        seen = kept
      end
    end
  end

  # `kept` is made a copy, since `bump` could be called before it is read, but `seen` is never
  # above 100, so nothing changes @x in between.
  private def unchanged_between
    VBlank.game "UNCHANGED", consoles: %i[gba] do
      game_variables :x
      @x = 5
      def bump = @x += 1
      seen = var :seen, 0
      game_loop do
        kept = @x
        bump if seen > 100
        seen = kept
      end
    end
  end

  # `over` keeps the answer of a test over two game variables; `go_inside` changes one of them
  # before `over` is read again. Ruby's `over` stays true.
  private def joined_test_across_a_call
    VBlank.game "JOINED", consoles: %i[gba] do
      game_variables :now, :moved_on
      @now = 1
      @moved_on = 1
      def go_inside = @moved_on = 0
      seen = var :seen, 0
      game_loop do
        @moved_on = 1
        over = (@now == 1) && (@moved_on == 1) # joined_test_across_a_call's copy
        go_inside
        seen = 1 if over
      end
    end
  end

  # A button a game keeps as an object, asked through a method the build cannot see into.
  Button = Data.define(:name) do
    def pressed_in(game) = game.pressed(name)
  end

  # `advance` is set from the buttons while setting up, outside the routine that reads it, so it
  # keeps the press of the moment the game started: none.
  private def press_kept_from_setting_up
    VBlank.game "PRESSED", consoles: %i[gba], allow: %w[TestGameCopiesThatDiffered::Button] do
      buttons = [Button.new(:a), Button.new(:b)]
      advance = buttons.map { |button| button.pressed_in(self) }.reduce(:|) # press_kept_from_setting_up's copy
      seen = var :seen, 0
      func :read_press do
        seen = 1 if advance
      end
      game_loop { call :read_press }
    end
  end

  def test_a_kept_test_whose_variable_a_call_changes_is_named
    differed = joined_test_across_a_call.copies_that_differed(frames: 3)

    assert_equal 1, differed.length, differed.map(&:described).join("\n")
    copy = differed.first
    assert_equal [copy_line("joined_test_across_a_call's copy"), :over, 1, 0],
                 [copy.source, copy.local, copy.kept, copy.live]
    assert_equal %i[moved_on now], copy.variables.sort
  end

  def test_a_press_kept_while_setting_up_and_read_in_a_routine_is_named
    differed = press_kept_from_setting_up.copies_that_differed(frames: 4) do |interpreter|
      interpreter.input_each_frame { |frame| frame == 3 ? [:a] : [] }
    end

    assert_equal 1, differed.length, differed.map(&:described).join("\n")
    copy = differed.first
    assert_equal [copy_line("press_kept_from_setting_up's copy"), :advance, 0, 1],
                 [copy.source, copy.local, copy.kept, copy.live]
  end

  private def copy_line(marker) = "#{__FILE__}:#{File.readlines(__FILE__).index { |line| line.include?(marker) } + 1}"

  def test_a_copy_whose_source_changed_before_the_read_is_named_with_its_line
    differed = changed_between.copies_that_differed(frames: 3)

    assert_equal 1, differed.length, differed.map(&:described).join("\n")
    copy = differed.first
    assert_equal [copy_line("changed_between's copy"), :kept, [:x], 5, 6],
                 [copy.source, copy.local, copy.variables, copy.kept, copy.live]
    assert_equal 1, copy.frame, "the game loop's first pass, counted as Reference#frame counts"
    assert_operator copy.times, :>=, 2, "it should count every read that differed"
    assert_includes copy.described, "kept"
  end

  def test_a_copy_whose_source_did_not_change_is_not_named
    game = unchanged_between
    refute_empty game_copies(game), "the game should keep a copy for `kept`"
    assert_empty game.copies_that_differed(frames: 3)
  end

  # The buttons a run is played with are set on the interpreter the block is handed.
  def test_the_block_is_handed_the_interpreter_before_it_plays
    handed = nil
    changed_between.copies_that_differed(frames: 1) { |interpreter| handed = interpreter }

    assert_kind_of Reference, handed
  end

  private def game_copies(game) = game.build_rom(out: nil, err: nil, profile: false).hidden_variables.select { |note| note.why == :copy }
end
