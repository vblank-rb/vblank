# frozen_string_literal: true

require "test_helper"
require "stringio"
require "many_tiles"

# A sprite drawn with more lists of colours (`draw_with ..., showing:`) than a Genesis has palettes
# for, one each. A Genesis keeps four palettes of fifteen colours, and a sprite drawn in a list
# names one of them, so a palette for each list cannot fit. The colours of all the lists fit in one
# palette, though, and the build then makes the picture once for each list, each copy drawn from
# that palette at the places of its list's colours. Held to the interpreter, which draws the
# picture in the chosen list's colours, place for place (Reference's draw_with).
class TestGenesisRecolorManyLists < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  # Colours whose channels are multiples of four, so the console's three bits a channel keep them apart.
  def self.rgb4(red, green, blue) = VBlank::Graphics::Color.rgb(red * 4, green * 4, blue * 4)

  # The sprite's own colours, see-through first: a body and an eye.
  OWN = [:transparent, rgb4(4, 4, 4), rgb4(0, 0, 0)].freeze
  # Six lists, each a body colour of its own and the same eye.
  BODIES = Ractor.make_shareable((1..6).map { |n| rgb4(n, 7 - n, (n * 3) % 8) })
  # The meadow behind it: three colours of its own.
  MEADOW = Ractor.make_shareable([rgb4(1, 5, 1), rgb4(2, 6, 2), rgb4(7, 7, 0)])

  # Which list the sprite shows on each pass, counting from pass 1: below nought and past the last
  # draw the sprite in its own colours, as the interpreter does.
  SHOWING = Ractor.make_shareable([-1, 0, 1, 2, 3, 4, 5, 6, 2, -1, 0])

  # The picture: an 8x8 body with one eye.
  ART = <<~ART
    ..####..
    .######.
    .##o###.
    .######.
    .######.
    .######.
    ..#..#..
    ..#..#..
  ART

  def test_the_cartridge_draws_the_sprite_in_each_list_as_the_interpreter
    Genesis::CheckedRun.new.run(game(outfits), frames: SHOWING.length + 2)
  end

  # Fifteen colours a list, and no two lists alike: no palette can hold two of them, and there
  # are more lists than palettes. The refusal says so in plain words.
  def test_lists_whose_colours_do_not_fit_are_refused_in_plain_words
    lists = (0...5).map do |n|
      [:transparent, *(0...15).map { |k| TestGenesisRecolorManyLists.rgb4(n, k % 8, k / 8 * 4 + n % 4) }]
    end
    error = assert_raises(VBlank::BuildError) { Genesis.new.build(game(lists, full: true)) }

    assert_match(/sprite :walker/, error.message)
    assert_match(/lists of colours/, error.message)
    assert_match(/To fix this/, error.message)
  end

  # The budget is what a game spends drawing the same walkers itself: a picture of its own for each
  # list, all from one list of colours, and the walker facing the one it wants (`face ... showing:`),
  # as examples/wanderers.rb once did by hand. The sprite is then placed from the copies' table by
  # the same routine, every piece copied and none changed on the way, and finding the table is a few
  # instructions of the game's own, once a sprite.
  def test_a_walker_drawn_from_copies_is_placed_as_one_drawn_by_hand
    drawn_with, by_hand = [game(outfits), game(outfits, by_hand: true)].map do |program|
      Genesis.new.build(program).profile(out: StringIO.new, settle: 4, frames: 8)
    end
    placing = ->(result) { result.runtime.select { |spent| spent.routine.to_s.start_with?("rt_sprite_place") } }

    refute placing.(drawn_with).any? { |spent| spent.routine.to_s.include?("recolored") }, "no piece's palette is changed"
    assert_operator placing.(drawn_with).sum(&:share), :<=, placing.(by_hand).sum(&:share) * 1.05
  end

  # A walker of several poses and a pointer drawn in front, both drawn with the six lists: each pose's
  # copy in each list, and the pointer's copies with the priority bit set, against the interpreter.
  def test_sprites_of_several_poses_and_in_front_are_drawn_from_copies_as_the_interpreter
    program = posed_game do
      walker = sprite :walker, frames: TestGenesisRecolorManyLists.posed_pictures(self, :walker, 3, across: 2, down: 2, from: 0), rate: 2, at: [16, 8]
      pointer = sprite :pointer, frames: TestGenesisRecolorManyLists.posed_pictures(self, :pointer, 2, across: 1, down: 1, from: 20), rate: 3,
                                 at: [20, 12], in_front: true
      [walker, pointer]
    end
    Genesis::CheckedRun.new.run(program, frames: SHOWING.length + 4)
  end

  # Copies cost tiles, so a game drawn from them can still run out of video memory, and the build then
  # keeps a sprite to one pose at a time (PoseRooms). The walker's copies are most of the tiles, and
  # its six poses would give the most back measured alone, but a copied sprite cannot be kept so: the
  # boss is, and the game fits.
  #
  # Counted from what follows: the walker's 6 poses of 24 tiles and their 36 copies are 1008 tiles,
  # the boss's 2 poses of 100 are 200 more, and the ground 300, past the 1471 a Genesis holds; the
  # boss kept to one pose gives back 100 and the game fits.
  def test_a_game_of_copies_and_too_many_tiles_keeps_another_sprite_to_one_pose
    program = posed_game(ground: 300) do
      walker = sprite :walker, frames: TestGenesisRecolorManyLists.posed_pictures(self, :walker, 6, across: 6, down: 4, from: 0), rate: 1, at: [16, 8]
      sprite :boss, frames: ManyTiles.declare_sprite_pictures(self, :boss, 2, :green, from: 1000), rate: 2, at: [120, 40]
      [walker]
    end
    Genesis::CheckedRun.new.run(program, frames: 8)
  end

  private def outfits = BODIES.map { |body| [:transparent, body, OWN[2]] }

  # +count+ pictures named +prefix+ and a number, +across+ × +down+ tiles each, drawn by place in OWN
  # (its body where ManyTiles draws, its eye elsewhere), no two tiles alike from tile +from+ on.
  def self.posed_pictures(builder, prefix, count, across:, down:, from:)
    width = across * 8
    height = down * 8
    Array.new(count) do |which|
      first = from + (which * across * down)
      places = Array.new(width * height) do |at|
        x = at % width
        y = at / width
        ManyTiles.drawn?(first + ((y / 8) * across) + (x / 8), x % 8, y % 8) ? 1 : 2
      end
      builder.image(:"#{prefix}_#{which}", width: width, height: height, colors: OWN, places: places)
      :"#{prefix}_#{which}"
    end
  end


  # A meadow, or +ground+ tiles all different, and the sprites the block declares: each one it gives back drawn with
  # the six lists, showing the list SHOWING names each pass.
  private def posed_game(ground: nil, &sprites)
    test = self
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      if ground
        background :ground, tiles: :ground, map: ManyTiles.declare(self, :ground, ground, :red, from: 2000)
      else
        colors :meadow, [:transparent, *MEADOW]
        image :grass, width: 8, height: 8, data: Array.new(64) { |i| MEADOW[i % 3] }, colors: :meadow
        tiles :meadow_set, "g" => :grass
        background :meadow, tiles: :meadow_set, map: Array.new(4) { "g" * 8 }
      end
      names = test.outfits_declared(self)
      drawn = instance_exec(&sprites)
      showing = table :showing, SHOWING
      pass = var :pass, 0
      game_loop do
        drawn.first.draw_with names, showing: showing[pass]
        drawn.last.draw_with names, showing: showing[pass + 3] if drawn.length > 1
        pass += 1
      end
    end
    builder.finalize_program
    builder.program.copy.tap { |copy| copy.console = :genesis }
  end

  # The six lists declared in +builder+, called back from the game's block; their names.
  def outfits_declared(builder)
    outfits.each_with_index.map do |list, n|
      builder.colors(:"outfit#{n}", list)
      :"outfit#{n}"
    end
  end

  # The game: a meadow, and the walker drawn with +lists+, showing the list SHOWING names each pass.
  # +full+ draws the walker in fifteen colours of its own, one a pixel along its top rows. +by_hand+
  # draws the same walker as the game would without `draw_with`: a picture for each list, all of them
  # from one list of colours, and the walker facing the one SHOWING names, its own where it names none.
  private def game(lists, full: false, by_hand: false)
    return game_by_hand(lists) if by_hand

    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :meadow, [:transparent, *MEADOW]
      image :grass, width: 8, height: 8, data: Array.new(64) { |i| MEADOW[i % 3] }, colors: :meadow
      tiles :meadow_set, "g" => :grass
      background :meadow, tiles: :meadow_set, map: Array.new(4) { "g" * 8 }
      if full
        own = [:transparent, *(0...15).map { |k| TestGenesisRecolorManyLists.rgb4(7, k % 8, k / 8) }]
        image :walker, width: 8, height: 8, data: Array.new(64) { |i| own[(i % 15) + 1] }, colors: own
      else
        image :walker, "." => :transparent, "#" => OWN[1], "o" => OWN[2], colors: OWN do
          ART
        end
      end
      names = lists.each_with_index.map do |list, n|
        colors :"outfit#{n}", list
        :"outfit#{n}"
      end
      walker = sprite :walker, at: [16, 8]
      showing = table :showing, SHOWING
      pass = var :pass, 0
      game_loop do
        walker.draw_with names, showing: showing[pass]
        pass += 1
      end
    end
    builder.finalize_program
    builder.program.copy.tap { |copy| copy.console = :genesis }
  end

  private def game_by_hand(lists)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :meadow, [:transparent, *MEADOW]
      image :grass, width: 8, height: 8, data: Array.new(64) { |i| MEADOW[i % 3] }, colors: :meadow
      tiles :meadow_set, "g" => :grass
      background :meadow, tiles: :meadow_set, map: Array.new(4) { "g" * 8 }
      colors :walkers, [:transparent, *OWN.drop(1), *lists.map { |list| list[1] }]
      poses = [OWN, *lists].each_with_index.map do |list, n|
        image(:"walker#{n}", "." => :transparent, "#" => list[1], "o" => list[2], colors: :walkers) { ART }
        :"walker#{n}"
      end
      walker = sprite :walker, facing: poses.to_h { |pose| [pose, pose] }, at: [16, 8]
      showing = table :showing, SHOWING.map { |n| n.between?(0, lists.length - 1) ? n + 1 : 0 }
      pass = var :pass, 0
      game_loop do
        walker.face poses, showing: showing[pass]
        pass += 1
      end
    end
    builder.finalize_program
    builder.program.copy.tap { |copy| copy.console = :genesis }
  end
end
