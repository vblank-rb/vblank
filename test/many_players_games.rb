# frozen_string_literal: true

# GAMES FOR MORE PLAYERS THAN A CONSOLE SEATS, played by every player that reads them all: the
# interpreter (test/interpreter/vblank/builder/test_many_players_interpreter.rb), the game as Ruby
# (test/lowering/ruby/vblank/ir/backends/ruby/test_ruby_many_players.rb) and the game as C
# (test/lowering/native/vblank/ir/backends/native/test_native_many_players.rb). The browser build
# reads two players and refuses the rest, so these games are not in test/all/.
module ManyPlayersGames
  # The rows the four markers of #four_markers are drawn on, by player.
  MARKER_ROWS = { 1 => 10, 2 => 30, 3 => 50, 4 => 70 }.freeze

  # Four people at one game: each moves a marker of their own to the right, anybody's left counts
  # in `anyone_left`, and `connected` is how many players are connected.
  private def four_markers
    b = VBlank::Builder.new
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
    b = VBlank::Builder.new
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
end
