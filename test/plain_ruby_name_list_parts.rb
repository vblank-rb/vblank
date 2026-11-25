# frozen_string_literal: true

# A part with a game variable that keeps a list of Symbols it fills while it is set up, brought in
# by `VBlank.require_game_file` for test/all/vblank/dsl/test_plain_ruby_parts.rb. Game code never
# changes the list, so it stays Ruby's: a question on it is answered while the game is built.
class NameListRunner
  game_variables :count

  AIMS = %i[move_to].freeze
  RESTS = %i[sleep].freeze

  def initialize(scripts)
    @count = 0
    @used = []
    scripts.each { |names| @used |= names }
  end

  def reach
    @count += 1 if @used.intersect?(AIMS)
    @count += 10 if @used.intersect?(RESTS)
  end
end

# A scene asking the runner on every pass.
class NameListPlay
  def initialize(builder)
    @builder = builder
    @runner = NameListRunner.new([%i[walk move_to], %i[wait]])
    declare
  end

  def declare
    runner = @runner
    @builder.scene :name_list_play do
      runner.reach
    end
  end
end

def name_list_game(build)
  NameListPlay.new(build)
  mode = :name_list_play
  build.game_loop do
    mode = :name_list_play
    build.call mode
  end
end
