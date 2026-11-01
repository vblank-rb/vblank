# frozen_string_literal: true

require "test_helper"

# EVERY EXAMPLE BUILDS AND PLAYS, on every run, as the console that run plays games as, for each
# game that names that console. A few frames only: the question is whether it still goes at all,
# and each example's own test says whether it plays right. It reads every example in, so it
# stays on the main Ractor.
class TestEveryExamplePlays < Minitest::Test
  runs_on_the_main_ractor!

  FRAMES = 4

  # Each example's games, by the file's name: a file declares them as it is loaded.
  def self.games_by_example
    Dir[VBlank.root.join("examples/*.rb").to_s].sort.to_h do |path|
      next [File.basename(path, ".rb"), []] unless File.read(path).match?(/VBlank\.game\b/)

      before = VBlank.registered_games.size
      require path
      [File.basename(path, ".rb"), VBlank.registered_games.drop(before)]
    end
  end

  games_by_example.each do |example, games|
    games.each_with_index do |game, number|
      define_method(:"test_#{example}_#{number}_plays") do
        console = VBlank::Testing.console
        next unless game.consoles.include?(console)

        assert game_player.run(game.program(console: console), frames: FRAMES)
      end
    end
  end
end
