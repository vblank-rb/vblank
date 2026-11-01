# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require_relative "../lib/vblank"

# The picture at the top of the README: six examples being played at once, three across and
# two down, as one GIF. Run it again when the games change enough for the old one to be a lie:
#
#   bundle exec ruby tools/readme_collage.rb
#
# It needs the emulator and ffmpeg. Each game runs on a real Advance cartridge in the emulator,
# which is the point: this is what somebody who builds the example gets.
#
# Nobody is at the controls, so each game has an AUTOPILOT: a few presses to get past its start
# screen, then a small block asked before every frame which buttons are down. The block is
# handed the running game and how many frames it has played, so it can follow the ball or just
# walk a route. A game whose variables or screens change can stop making sense to its
# autopilot; the GIF then shows a game played badly, so look at it before committing.
module ReadmeCollage
  ROOT = VBlank.root
  OUTPUT = ROOT.join("assets", "examples.gif")
  ADVANCE_SCREEN = "240x160"
  ADVANCE_FRAME_RATE = 60
  GIF_FRAME_RATE = 30
  CLIP_FRAMES = 8 * ADVANCE_FRAME_RATE
  ACROSS = 3
  GAP = 4

  Playthrough = VBlank::Playthroughs::Playthrough

  # +source+ is the example's file, +constant+ the module it defines, +opening+ the script that
  # reaches the first frame worth showing, and +buttons_for+ the autopilot.
  Clip = Data.define(:source, :constant, :opening, :buttons_for)

  # An autopilot that walks +start+ once and then +lap+ round and round. Each is a list of
  # [buttons, frames] legs.
  def self.route(start: [], lap:)
    start_length = start.sum { |_, frames| frames }
    lap_length = lap.sum { |_, frames| frames }
    lambda do |_game, frame|
      next buttons_on_leg(start, frame) if frame < start_length

      buttons_on_leg(lap, (frame - start_length) % lap_length)
    end
  end

  def self.buttons_on_leg(legs, frame)
    legs.each do |buttons, frames|
      return buttons if frame < frames

      frame -= frames
    end
    []
  end

  # Pac-Man starts in the middle, so one short leg up reaches the pellets' row and the route
  # then goes round them for good. He moves twice as fast as the ghost, so it rarely catches him.
  PACMAN_ROUTE = route(start: [[[:up], 16]],
                       lap: [[[:right], 36], [[:down], 36], [[:left], 68], [[:up], 36], [[:right], 32]])

  # Round the two inner walls of the maze, keeping to the middle of its corridors, so the view
  # always has corners in it. A walk of one cell is 11 frames and a quarter turn is 32. Walk
  # into a wall here and the panel is one flat colour, so check this one by eye.
  RAYCASTER_ROUTE = route(start: [[[:up], 11], [[:left], 32], [[:up], 22]],
                          lap: [[[:right], 32], [[:up], 22], [[:right], 32], [[:up], 55],
                                [[:right], 32], [[:up], 22], [[:right], 32], [[:up], 55]])

  HERO_ROUTE = route(lap: [[[:right], 120], [[:up], 50], [%i[right down], 60], [[:left], 90]])

  # Through the dark to the cave's mouth, which takes three and a half seconds at a pixel a
  # frame, then out into the daylight and a wander round the meadow.
  CAVE_ROUTE = route(start: [[[:right], 215]],
                     lap: [[[:right], 115], [[:up], 45], [[:right], 70], [[:down], 70]])

  # The paddle chases the ball, aiming a little to one side and then the other so the ball
  # leaves at different angles and works through the wall.
  AIM_SWING = 10
  AIM_SWING_FRAMES = 90

  def self.breakout_buttons(game, frame)
    aim = (frame / AIM_SWING_FRAMES).even? ? AIM_SWING : -AIM_SWING
    paddle_middle = game.var(:paddle_x) + (Breakout::PADDLE_W / 2)
    target = game.var(:ball_x) + aim
    return [:left] if target < paddle_middle - 2
    return [:right] if target > paddle_middle + 2

    []
  end

  # Sweep across the bottom of the screen with the trigger tapped, since a shot is fired on the
  # press and a button left down is only one press.
  SHMUP_SWEEP = 90
  SHMUP_TAP = 8

  def self.shmup_buttons(_game, frame)
    sweep = (frame / SHMUP_SWEEP).even? ? :right : :left
    frame % SHMUP_TAP < SHMUP_TAP / 2 ? [sweep, :a] : [sweep]
  end

  HERO_OPENING = proc do
    wait frames: 10
    press :down
    press :down
    press :a
    wait frames: 4
    press :a
    wait frames: 4
  end

  CLIPS = [
    Clip.new("pacman", :Pacman, proc { wait frames: 30 }, PACMAN_ROUTE),
    Clip.new("raycaster", :Raycaster, proc { wait frames: 10 }, RAYCASTER_ROUTE),
    Clip.new("hero", :Hero, HERO_OPENING, HERO_ROUTE),
    Clip.new("breakout", :Breakout, proc {
      wait frames: 30
      press :start
      wait frames: 4
    }, method(:breakout_buttons)),
    Clip.new("shmup", :Shmup, proc { wait frames: 30 }, method(:shmup_buttons)),
    Clip.new("cave", :Cave, proc { wait frames: 10 }, CAVE_ROUTE)
  ].freeze

  # The clip's game on a fresh cartridge, standing at the end of its opening.
  def self.game_past_opening(clip)
    require ROOT.join("examples", clip.source).to_s
    cartridge = Object.const_get(clip.constant).build_rom(out: StringIO.new, err: StringIO.new, profile: false)
    VBlank.playthrough("#{clip.source}: to the first frame shown", &clip.opening).play(cartridge).game
  end

  # Play +clip+ and write every frame to +path+, one after another: two bytes a pixel, which is
  # how the console itself keeps a colour and a raw format ffmpeg reads as it is.
  def self.record(clip, path)
    game = game_past_opening(clip)
    File.open(path, "wb") do |file|
      CLIP_FRAMES.times do |frame|
        game.step(1, keys: Playthrough.key_mask(clip.buttons_for.call(game, frame)))
        file.write(game.frame_colors)
      end
    end
  end

  # Each recording framed by a thin dark border, the panels stacked, then the colours boiled
  # down to the 256 a GIF may hold. Picked for the whole clip, and not dithered: speckle would
  # fight pixel art, and costs far more bytes than it saves.
  def self.collage_filter(count)
    framed = Array.new(count) { |n| "[#{n}:v]pad=iw+#{GAP}:ih+#{GAP}:#{GAP / 2}:#{GAP / 2}:color=0x101018[p#{n}]" }
    rows = (0...count).each_slice(ACROSS).with_index.map do |panels, row|
      "#{panels.map { |n| "[p#{n}]" }.join}hstack=inputs=#{panels.size}[r#{row}]"
    end
    row_labels = (0...rows.size).map { |row| "[r#{row}]" }.join
    stacked = "#{row_labels}vstack=inputs=#{rows.size},fps=#{GIF_FRAME_RATE},split[a][b]"
    (framed + rows + [stacked, "[a]palettegen=stats_mode=full[colors]", "[b][colors]paletteuse=dither=none"]).join(";")
  end

  def self.ffmpeg_command(recordings, output)
    inputs = recordings.flat_map do |path|
      ["-f", "rawvideo", "-pixel_format", "bgr555le", "-video_size", ADVANCE_SCREEN,
       "-framerate", ADVANCE_FRAME_RATE.to_s, "-i", path]
    end
    ["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", collage_filter(recordings.size),
     "-loop", "0", output.to_s]
  end

  def self.make(output = OUTPUT)
    Dir.mktmpdir("readme-collage") do |folder|
      recordings = CLIPS.map do |clip|
        puts "playing #{clip.source}"
        File.join(folder, "#{clip.source}.raw").tap { |path| record(clip, path) }
      end
      FileUtils.mkdir_p(File.dirname(output))
      system(*ffmpeg_command(recordings, output), exception: true)
    end
    puts "wrote #{output} (#{File.size(output) / 1024} KB)"
  end
end

ReadmeCollage.make(ARGV.first || ReadmeCollage::OUTPUT) if $PROGRAM_NAME == __FILE__
