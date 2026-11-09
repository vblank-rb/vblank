# frozen_string_literal: true

require "stringio"
require "test_helper"
require "fixtures/game_with_plain_helper/game"
require "fixtures/game_with_plain_data/game"
require "fixtures/game_behind_a_part/game"

# What a game block in normal Ruby cannot do, and the plain words an author gets instead.
class TestPlainRubyRefusals < Minitest::Test
  OWN_NUMBER = 7

  Refused = VBlank::DSL::PlainRuby::Refused

  # Read from each test's Ractor, as an example's game is.
  SHARED_GAME = VBlank.game("SHARED", consoles: %i[gba]) do
    hp = 3
    game_loop { hp -= 1 if hp > OWN_NUMBER - 7 }
  end

  private def built(allow: [], &block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block, allow: allow))
    builder.finalize_program
    builder
  end

  private def assert_refused(phrase, &block)
    error = assert_raises(Refused) { built(&block) }
    assert_includes error.message, phrase
  end

  def test_a_constant_from_outside_the_game_is_refused_and_points_above_the_block
    assert_refused("above the block") { game_loop { Net::HTTP.get("example.com", "/") } }
    assert_refused("`File`") { File.read("level.txt") }
    assert_refused("`Minitest`") { game_loop { Minitest::Test } }
  end

  def test_an_instance_variable_handed_a_variable_can_move_while_setting_up
    built do
      score = var :score, 0
      lives = var :lives, 3
      @shown = score
      @shown = lives
      game_loop { halt }
    end
  end

  def test_an_instance_variable_written_with_itself_in_game_code_is_left_alone
    built do
      score = var :score, 0
      @shown = score
      game_loop { @shown = @shown }
    end
  end

  def test_game_code_changing_a_local_from_outside_the_block_is_refused
    lives = 3

    assert_refused("`lives` is set outside") { game_loop { lives -= 1 if pressed(:a) } }
    assert_refused("`lives` is set outside") { scene(:play) { lives = 2 } }
  end

  def test_a_name_holding_an_object_changed_under_a_game_test_is_refused
    assert_refused("`label` holds") do
      hp = var :hp, 5
      label = "LOW"
      label = "HIGH" if hp > 3
      game_loop { draw_text label, 0, 0, :white }
    end
  end

  def test_case_in_with_a_pattern_a_game_cannot_answer_is_refused
    assert_refused("`case ... when`") do
      hp = 5
      game_loop do
        case hp
        in Integer => left if left > 3 then wait_vblank
        end
        hp -= 1
      end
    end
  end

  def test_for_up_to_a_number_the_game_keeps_is_refused
    assert_refused("`while`") do
      n = 3
      total = 0
      game_loop do
        for each_number in 0...n
          total += each_number
        end
        n += 1
      end
    end
  end

  def test_for_from_a_number_the_game_keeps_is_refused
    assert_refused("`while`") do
      n = 0
      game_loop do
        for each_number in n..3
          wait_vblank
        end
        n += 1
      end
    end
  end

  def test_for_over_a_list_the_game_keeps_is_refused
    assert_refused("`.each`") do
      things = list(:things, capacity: 4)
      total = 0
      game_loop do
        for thing in things
          total += thing
        end
      end
    end
  end

  def test_case_asking_what_a_game_cannot_answer_is_refused
    assert_refused("`when String`") do
      hp = var :hp, 5
      game_loop do
        case hp
        when String then wait_vblank
        end
      end
    end
  end

  Thing = Struct.new(:x)

  def test_an_object_name_changed_under_a_game_test_is_refused
    assert_refused("`marker` holds") do
      marker = Thing.new(1)
      other = Thing.new(2)
      game_loop { marker = other if pressed(:a) }
    end
  end

  def test_a_number_name_given_nil_from_a_method_is_refused
    assert_refused("start it with `n = nil`") do
      def nothing = nil
      n = 1
      game_loop { n = nothing }
    end
  end

  def test_an_object_kept_in_a_slot_and_changed_under_a_game_test_is_refused
    assert_refused("holds a Thing") do
      hp = var :hp, 5
      slots = { marker: Thing.new(1) }
      slots[:marker] = Thing.new(2) if hp > 3
      game_loop { wait_vblank }
    end
  end

  def test_a_new_slot_given_a_number_under_a_game_test_is_refused
    assert_refused("give it a number before the test") do
      hp = var :hp, 5
      slots = {}
      slots[:speed] = 2 if hp > 3
      game_loop { wait_vblank }
    end
  end

  def test_a_yes_or_no_given_a_number_from_another_name_is_refused
    assert_refused("started as `true` or `false`") do
      ok = true
      count = var :count, 0
      game_loop { ok = count }
    end
  end

  def test_game_code_can_read_a_local_from_outside_the_block
    lives = 3
    builder = built do
      shown = 0
      game_loop { shown = lives }
    end

    assert_kind_of Builder, builder
  end

  def test_a_gem_nobody_has_heard_of_is_refused_the_same_way
    assert_refused("`SomeGemNobodyListed`") { SomeGemNobodyListed.go }
  end

  def test_the_games_own_constants_and_ruby_basics_are_allowed
    builder = built do
      wall = Array.new(2, OWN_NUMBER)
      shown = 0
      game_loop { shown = wall.first + Math.sqrt(16).to_i }
    end

    assert_kind_of Builder, builder
  end

  def test_the_author_can_allow_a_library_at_their_own_risk
    builder = built(allow: %w[Minitest]) do
      Minitest::Test
      game_loop { wait_vblank }
    end

    assert_kind_of Builder, builder
  end

  def test_calls_that_reach_outside_the_game_are_refused
    assert_refused("`system`") { system("ls") }
    assert_refused("`require`") { require "json" }
    assert_refused("`eval`") { eval("1 + 1") }
    assert_refused("`send`") { 1.send(:+, 1) }
    assert_refused("Backticks") { `ls` }
  end

  # They reach around an object the way `send` does, and a game written in plain Ruby has no use for them.
  def test_calls_that_reach_into_an_object_are_refused
    assert_refused("`instance_variable_get`") { game_loop { instance_variable_get(:@hp) } }
    assert_refused("`instance_variable_set`") { game_loop { instance_variable_set(:@hp, 1) } }
    assert_refused("`method`") { game_loop { method(:halt) } }
    assert_refused("`method`") { 1.method(:+) }
  end

  def test_a_game_verb_named_like_one_of_rubys_outside_calls_is_allowed
    builder = built do
      sparks = pool(:spark, x: 0, capacity: 2)
      game_loop { sparks.spawn(x: 1) }
    end

    assert_kind_of Builder, builder
  end

  def test_a_warning_names_the_authors_own_line
    line = __LINE__ + 4
    said = warnings_of do
      n = 0
      game_loop do
        while n >= 0
          n += 1
        end
      end
    end

    assert_includes said, "test_plain_ruby_refusals.rb:#{line}"
  end

  def test_jumping_out_of_game_code_is_refused
    assert_refused("`break`") do
      n = 0
      game_loop { n += 1; while n > 0; break if n == 3; n -= 1; end }
    end
    assert_refused("`next`") do
      n = 0
      game_loop { if n == 3 then next end; n += 1 }
    end
    assert_refused("`return`") do
      n = 0
      game_loop { return if n == 3; n += 1 }
    end
  end

  def test_jumping_in_build_time_code_is_plain_ruby
    builder = built do
      wide = 0
      if wide == 0
        3.times { |each_time| next if each_time == 1; wide = each_time }
      end
      game_loop { wait_vblank }
    end

    assert_kind_of Builder, builder
  end

  def test_a_picked_value_must_be_a_number
    assert_refused("between numbers") do
      n = 0
      game_loop { x = n == 0 ? :left : :right; n += 1 }
    end
  end

  def test_a_picked_value_needs_an_else
    assert_refused("needs an `else`") do
      n = 0
      game_loop { x = if n == 0 then 1 end; n += 1 }
    end
  end

  def test_a_plain_number_counted_by_a_plain_ruby_block_is_left_alone
    builder = built do
      total = 0
      [1, 2, 3].each { |each_number| total += each_number }
      game_loop { pixel total, 0, :red }
    end

    assert_kind_of Builder, builder
  end

  def test_a_game_can_be_shared_between_ractors
    game = TestPlainRubyRefusals::SHARED_GAME

    assert_predicate game, :frozen?
    refute_empty game.program.children
  end

  private def warnings_of(&block)
    err = StringIO.new
    VBlank.build("PLAIN", console: :gba, out: StringIO.new, err: err, &VBlank::DSL::PlainRuby.rewrite(block))
    err.string
  end

  def test_a_misspelt_key_on_a_hash_of_game_variables_is_refused
    assert_refused("no key :hq") do
      ball = { hp: var(:hp, 5) }
      game_loop { ball[:hq] = 2 }
    end
  end

  def test_a_list_can_go_in_a_hash_of_game_variables
    built do
      state = { a: var(:a, 1) }
      state[:b] = list(:b, capacity: 4)
      game_loop { wait_vblank }
    end
  end

  def test_a_jump_after_or_on_a_game_test_is_refused
    assert_refused("`next` cannot leave") do
      hp = 3
      game_loop do
        (hp > 0) || next
        hp -= 1
      end
    end
  end

  def test_an_old_way_of_changing_a_variable_is_refused
    assert_refused("A game does not need `set!`") { game_loop { hp = var(:hp, 0); hp.set! 1 } }
    assert_refused("A game does not need `add!`") { game_loop { add! :hp, 1 } }
    assert_refused("A game does not need `copy!`") { game_loop { copy! :a, :b } }
  end

  def test_an_old_way_of_changing_a_variable_is_refused_in_a_part_too
    builder = Builder.new
    hp = builder.var(:hp, 5)

    error = assert_raises(Refused) { hp.sub!(1) }
    assert_includes error.message, "A game does not need `sub!`"
  end

  def test_the_librarys_own_branch_is_refused_in_a_game
    assert_refused("A game does not need `when_true`") { game_loop { held(:a).when_true { wait_vblank } } }
  end

  # The low-level tests a game once wrote beside `if` are refused naming the `if` to write.
  def test_a_low_level_test_is_refused_naming_the_plain_if
    assert_refused("write `if score > 5`") { game_loop { score = var(:score, 0); if_gt(:score, 5) { score -= 1 } } }
    assert_refused("write `if lives <= 0`") { game_loop { if_lte(:lives, 0) { wait_vblank } } }
    assert_refused("write `if state == 2`") { game_loop { if_eq(:state, 2) { wait_vblank } } }
    assert_refused("write `if y >= floor`") { game_loop { if_gte(:y, :floor) { wait_vblank } } }
    assert_refused("write `if held(:a)`") { game_loop { if_held(:a) { wait_vblank } } }
    assert_refused("write `if pressed(:start, player: 2)`") do
      game_loop { if_pressed(:start, player: 2) { wait_vblank } }
    end
  end

  # The calls the rewrite makes to record a branch step by step are the library's own. A game that
  # writes one is told to write `if`.
  def test_the_librarys_step_by_step_branch_is_refused_in_a_game
    assert_refused("A game does not need `record_branch`") { game_loop { held(:a).record_branch { wait_vblank } } }
    assert_refused("A game does not need `open_branch`") { game_loop { (var(:x, 0) > 3).open_branch } }
    assert_refused("write `if`") { game_loop { held(:b).open_repeat(4) } }
    assert_refused("`open_other_branch`") { game_loop { held(:a).open_other_branch(nil) } }
    assert_refused("`close_branch`") { game_loop { held(:a).close_branch } }
    assert_refused("`take_back_branch`") { game_loop { held(:a).take_back_branch(nil) } }
    assert_refused("`close_repeat`") { game_loop { held(:a).close_repeat } }
  end

  def test_a_game_made_by_eval_with_no_file_is_refused
    block = eval("proc { game_loop { wait_vblank } }") # rubocop:disable Security/Eval
    error = assert_raises(Refused) { VBlank::DSL::PlainRuby.game_block(block) }

    assert_includes error.message, "no file"
  end

  def test_game_code_behind_a_game_part_is_refused
    error = assert_raises(Refused) { VBlank::DSL::PlainRuby.rewrite(GameBehindAPart.block) }

    assert_includes error.message, "`walker.rb` holds game code"
  end

  def test_a_game_with_no_file_is_refused
    block = eval("proc { game_loop { wait_vblank } }", binding, "-", 1) # rubocop:disable Security/Eval
    error = assert_raises(Refused) { VBlank::DSL::PlainRuby.game_block(block) }

    assert_includes error.message, "no file"
  end

  def test_a_new_key_on_a_plain_hash_is_plain_ruby
    built do
      ball = { hp: 5 }
      ball[:mp] = 2
      game_loop { wait_vblank }
    end
  end

  def test_a_number_tested_alone_builds_with_every_check_on
    rom = VBlank.build("TRUTHY", console: :gba, out: StringIO.new, err: StringIO.new) do
      flags = 3
      game_loop do
        wait_vblank if flags & 4
        flags += 1
      end
    end

    assert rom, "the game builds"
  end

  def test_unless_on_a_yes_or_no_builds_with_every_check_on
    rom = VBlank.build("YESNO", console: :gba, out: StringIO.new, err: StringIO.new) do
      lit = true
      game_loop do
        wait_vblank unless lit
        lit = false
      end
    end

    assert rom, "the game builds"
  end

  def test_a_flag_on_a_vblank_handle_is_a_test
    built do
      game_loop do
        rows = menu(:main, at: [40, 40]) { |row| row.item("GO") { wait_vblank } }
        wait_vblank if rows.moved
      end
    end
  end

  def test_a_file_of_game_code_brought_in_with_require_relative_is_refused
    error = assert_raises(Refused) { VBlank::DSL::PlainRuby.rewrite(GameWithPlainHelper.block) }

    assert_includes error.message, "`walker.rb` holds game code"
    assert_includes error.message, 'VBlank.require_game_file "walker"'
    assert_includes error.message, "game.rb:4"
  end

  def test_a_file_of_plain_ruby_can_come_in_with_require_relative
    assert_kind_of Proc, VBlank::DSL::PlainRuby.rewrite(GameWithPlainData.block)
  end

  def test_vblank_game_builds_a_game_written_in_plain_ruby
    game = VBlank.game("PLAIN GAME", consoles: %i[gba]) do
      shown = 0
      game_loop { shown += 1 if shown < 3 }
    end

    refute_empty game.program.children
  end
end
