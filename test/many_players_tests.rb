# frozen_string_literal: true

# MORE PLAYERS THAN A CONSOLE SEATS: four people at one game, each moving a marker of their own,
# and a crowd of sixteen, the most any build reads (IR::Buttons::MOST_PLAYERS). `:any` is every
# connected player, and the game asks how many are connected.
#
# Every build that plays on a computer reads sixteen players, and so does the interpreter, but no
# console's cartridge does: the Advance, the Color and the Genesis read one controller and the
# Super Nintendo two, and each refuses a game that reads more. So these tests are not in
# test/all/, which every cartridge run plays too, and not in test/console/, which a console's
# cartridge run plays. They are played through game_player by each run whose player reads them
# all: the interpreter (test/interpreter/vblank/builder/test_many_players_interpreter.rb), and the
# game as C, as JavaScript and as Ruby, checked against it on every frame
# (test/lowering/{native,js,ruby}/vblank/ir/backends/*/test_*_many_players.rb). Which console
# seats how many is test/all/vblank/builder/test_player_option.rb's.
module ManyPlayersTests
  # The games are built for a computer, as the runs that play them build them, so a run's build
  # checks read sixteen players and not the console's controllers.
  BUILT_FOR_COMPUTER = VBlank::Cartridge::Options.new(for_computer: true)

  # The rows the four markers of #four_markers are drawn on, by player.
  MARKER_ROWS = { 1 => 10, 2 => 30, 3 => 50, 4 => 70 }.freeze

  # Four people at one game: each moves a marker of their own to the right, anybody's left counts
  # in `anyone_left`, and `connected` is how many players are connected.
  private def four_markers
    b = VBlank::Builder.new(options: BUILT_FOR_COMPUTER)
    b.instance_eval do
      x1 = 10
      x2 = 10
      x3 = 10
      x4 = 10
      anyone_left = 0
      connected = 0
      game_loop do
        x1 += 1 if held(:right, player: 1)
        x2 += 1 if held(:right, player: 2)
        x3 += 1 if held(:right, player: 3)
        x4 += 1 if held(:right, player: 4)
        anyone_left += 1 if held(:left, player: :any)
        connected = players_connected
        clear_screen :black
        draw_rect_at x1, 10, 2, 2, :red
        draw_rect_at x2, 30, 2, 2, :red
        draw_rect_at x3, 50, 2, 2, :red
        draw_rect_at x4, 70, 2, 2, :red
      end
    end
    b.finalize_program
    b.program
  end

  # A crowd of +players+: player n moves `xn` on by n while holding right, `anyone` counts frames
  # anybody holds left, `taps` counts presses of A by anybody, and `connected` is how many players
  # are connected.
  private def crowd(players)
    b = VBlank::Builder.new(options: BUILT_FOR_COMPUTER)
    b.instance_eval do
      places = (1..players).map { |player| var(:"x#{player}", 0) }
      anyone = var(:anyone, 0)
      taps = var(:taps, 0)
      connected = var(:connected, 0)
      game_loop do
        places.each.with_index(1) { |x, player| x.increase!(player) if held(:right, player: player) }
        anyone.increase!(1) if held(:left, player: :any)
        taps.increase!(1) if pressed(:a, player: :any)
        connected.store!(players_connected)
      end
    end
    b.finalize_program
    b.program
  end

  # What a crowd of +players+ holds on +frame+: player n holds right on the frames n divides, the
  # last player taps A every third frame, and player nine holds left from frame 6. The buttons
  # change from frame to frame, so a mix-up between two players' buttons shows as a frame two runs
  # disagree on.
  private def crowd_buttons_on(frame, players)
    rights = (1..players).select { |player| (frame % player).zero? }.map { |player| VBlank::IR::Buttons.name_for(:right, player) }
    rights << VBlank::IR::Buttons.name_for(:a, players) if (frame % 3).zero?
    rights << :p9_left if frame >= 6 && players >= 9
    rights
  end

  # Players join one after another and press on different frames.
  private def four_players_on(frame)
    { 1 => %i[right], 2 => %i[p2_right], 3 => %i[p3_right p2_left], 4 => %i[p4_right], 5 => %i[p3_left p4_left],
      6 => %i[p4_right p2_right], 7 => [] }.fetch(frame, [])
  end

  private def marker_at(run, player)
    (0...240).find { |x| run.screen.pixel(x, MARKER_ROWS.fetch(player)) == VBlank::Testing.shown(:red) }
  end

  def test_each_of_four_players_moves_their_own_marker_on_the_same_pass
    run = game_player.hold(:p2_right, :p4_right).run(four_markers, frames: 5)

    assert_equal [10, 15, 10, 15], (1..4).map { |player| run[:"x#{player}"] }
    assert_equal [10, 15, 10, 15], (1..4).map { |player| marker_at(run, player) }
    assert_equal 4, run[:connected]
  end

  def test_buttons_held_from_power_on_reach_the_third_player_alone
    run = game_player.hold(:p3_right).run(four_markers, frames: 4)

    assert_equal [10, 10, 14, 10], (1..4).map { |player| run[:"x#{player}"] }
    assert_equal 3, run[:connected]
  end

  def test_players_joining_one_after_another_each_move_their_own_marker
    run = game_player.input_each_frame { |frame| four_players_on(frame) }.run(four_markers, frames: 8)

    assert_equal [11, 12, 11, 12], (1..4).map { |player| run[:"x#{player}"] }
    assert_equal 4, run[:connected]
    assert_equal 2, run[:anyone_left], "anybody's left: the second player's on frame 3, two players' on frame 5"
  end

  def test_any_player_is_every_connected_player
    lefts = { 1 => %i[left], 2 => %i[p2_left], 3 => %i[p3_left], 4 => %i[p4_left], 5 => %i[p4_right] }
    run = game_player.input_each_frame { |frame| lefts.fetch(frame, []) }.run(four_markers, frames: 6)

    assert_equal 4, run[:anyone_left], "each player's left once, and nobody's on frame 5"
  end

  def test_a_player_counts_as_connected_from_their_first_button_on
    run = game_player.input_each_frame { |frame| frame == 2 ? [:p3_a] : [] }.run(four_markers, frames: 5)

    assert_equal 3, run[:connected], "letting go is not unplugging"
  end

  def test_one_player_is_connected_while_only_the_first_players_buttons_are_held
    run = game_player.hold(:right).run(crowd(VBlank::IR::Buttons::MOST_PLAYERS), frames: 4)

    assert_equal 1, run[:connected]
    assert_equal 4, run[:x1]
  end

  def test_sixteen_players_each_move_their_own_place
    players = VBlank::IR::Buttons::MOST_PLAYERS
    run = game_player.input_each_frame { |frame| crowd_buttons_on(frame, players) }.run(crowd(players), frames: 32)

    assert_equal 16 * 2, run[:x16], "player sixteen moved on frames 16 and 32"
    assert_equal 9 * 3, run[:x9], "player nine moved on frames 9, 18 and 27"
    assert_equal players, run[:connected]
    assert_operator run[:anyone], :>, 0
    assert_operator run[:taps], :>, 0
  end
end
