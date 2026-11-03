# frozen_string_literal: true

require "open3"
require "rbconfig"

# WHAT THE TESTS OF `vblank run` WITH A SCRIPT OR A TAPE, AND `vblank compare`, SHARE: the command run the way a
# person runs it, in a process of its own, and the files it is pointed at — a game, and
# scripts that play it.
#
#   include CLIPlaying
module CLIPlaying
  # Which Ruby to launch, asked once here. Asking reads Ruby's own table of how it was
  # built, which is not something a worker may touch — and these tests run in a pool.
  RUBY = RbConfig.ruby.freeze
  BIN = VBlank.root.join("bin/vblank").to_s.freeze

  # A white box on a blue ground, that walks while RIGHT is down and keeps the furthest it
  # has been in save memory. Two settings make a second game of it that differs in one
  # thing: how far it walks a frame, and the tick its ground turns red on.
  GAME = <<~RUBY
    require "vblank"

    VBlank.game "WALKER", consoles: %i[gba] do
      screen :bitmap
      speed = setting :speed, 2
      red_at = setting :red_at, 100_000
      ticks = var :ticks, 0
      x = var :x, 20
      best = save_var :best, 0
      game_loop do
        ticks += 1
        x += speed if held(:right)
        best = x if x > best
        if ticks >= red_at
          clear_screen :red
        else
          clear_screen :blue
        end
        draw_rect_at x, 60, 8, 8, :white
      end
    end
  RUBY

  # One playthrough: stand, walk right for twenty frames, stand.
  WALK = <<~RUBY
    VBlank.playthrough "walk" do
      wait frames: 10
      moment :standing
      hold :right, frames: 20
      moment :walked
      wait frames: 30
    end
  RUBY

  # Three playthroughs in one file: one to stand, one to walk until the box is somewhere,
  # and one to let a few frames go by before either.
  SEVERAL = <<~RUBY
    VBlank.playthrough "stand" do
      wait frames: 12
      moment :stood
    end

    VBlank.playthrough "walk to sixty" do
      wait frames: 10
      moment :standing
      hold_until("the box is at sixty", :right) { |game| game.var(:x) >= 60 }
      moment :arrived
    end

    VBlank.playthrough "five frames" do
      wait frames: 5
    end
  RUBY

  LIB = VBlank.root.join("lib").to_s.freeze

  # Run the command in +dir+, and hand back what it printed and how it ended.
  def cli(*args, dir:)
    Open3.capture2e(RUBY, BIN, *args, chdir: dir)
  end

  # Run the Ruby file +path+ in +dir+ with this checkout's library, for what the command line no
  # longer makes (a save, a tape played on the cartridge), and hand back the same.
  def ruby_file(path, dir:)
    Open3.capture2e(RUBY, "-I", LIB, path, chdir: dir)
  end

  # A folder holding the game and the scripts, handed to the block.
  def with_game_and_scripts
    Dir.mktmpdir("cli") do |dir|
      File.write(File.join(dir, "walker.rb"), GAME)
      File.write(File.join(dir, "walk.rb"), WALK)
      File.write(File.join(dir, "several.rb"), SEVERAL)
      yield dir
    end
  end
end
