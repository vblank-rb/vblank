# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "sprite_picture_tests"
VBlank.require_game_file "../../../../twin_pictures_parts"

class TestSpritePictures < Minitest::Test
  include SpritePictureTests

  private def console = :gba

  # The console's table is read straight: what it holds on a frame is what the pass before placed.
  def test_a_row_of_the_table_names_its_picture
    reader = VBlank::Diagnostics::Verifier.new(picture_game, frames: 5)

    assert_equal [:walk1], reader.sprites(:hero).map(&:picture), "picked in the third pass, shown after the fourth"
  end

  # A hero with more poses than sprite memory holds keeps one in a room of its own, and the
  # cartridge marks that room empty as its scene takes over on the first pass, after the gap
  # before it had already copied the first pose in and drawn it. The console still shows that
  # pose, so the reader names it on the first pass as on every other.
  def test_a_pose_kept_in_a_room_is_named_on_the_scenes_first_pass
    built = scene_with_hero_kept_in_a_room

    assert_equal 1, built.built.streamed_sprite_pose_vars.size, "the hero keeps one pose at a time"
    want = (1..5).map do |frame|
      [frame, VBlank::IR::Backends::Reference.new.run(built.source_program, frames: frame).sprites(:hero)]
    end

    assert_equal want, cartridge(built, :hero).first(5)
  end

  private def scene_with_hero_kept_in_a_room
    canvas = 64
    clear = CLEAR
    ink = INK
    art = (0...40).to_h do |pose|
      left = pose % 10
      top = pose % 8
      data = (0...(canvas * canvas)).map do |at|
        x = at % canvas
        y = at / canvas
        x >= left && x < left + 50 && y >= top && y < top + 50 ? ink : clear
      end
      [:"pose#{pose}", data]
    end
    VBlank.build("ROOMPOSE", console: console, out: nil, err: nil) do
      screen :tiled
      art.each { |name, data| image name, width: canvas, height: canvas, data: data, transparent: clear }
      state = 1
      pass = 0
      scene(:title) { state = 1 }
      scene(:play) do
        hero = sprite :hero, at: [40, 40], facing: art.keys.to_h { |name| [name, name] }
        hero.face :pose1 if pass >= 3
      end
      game_loop do
        pass += 1
        case state
        when 0 then call :title
        when 1 then call :play
        end
      end
    end
  end

  # Two pictures that are the same block at places a tile apart on their canvas are trimmed to
  # the same stored tiles, so the console draws either one from the same row, a tile further
  # along for the second. The row alone cannot say which, but the numbers the pose is worked
  # out from can, as they stood when the row was drawn.
  def test_two_pictures_stored_as_one_are_told_apart_by_the_pose_picked
    built = twin_pictures_game(:face)

    assert_equal twin_rows_interpreted(built), cartridge(built, :hero).first(8)
  end

  def test_two_pictures_stored_as_one_are_told_apart_in_a_walk
    built = twin_pictures_game(:walk)

    assert_equal twin_rows_interpreted(built), cartridge(built, :hero).first(8)
  end

  def test_two_pictures_stored_as_one_are_told_apart_in_a_facing_and_a_walk
    built = twin_pictures_game(:facing_walk)

    assert_equal twin_rows_interpreted(built), cartridge(built, :hero).first(8)
  end

  def test_two_pictures_stored_as_one_are_told_apart_for_a_pools_thing
    built = twin_pictures_pool_game

    assert_equal twin_rows_interpreted(built), cartridge(built, :hero).first(8)
  end

  # ...and a reader stepped several frames at once tells them apart too.
  def test_two_pictures_stored_as_one_are_told_apart_after_a_long_step
    reader = VBlank::Diagnostics::Verifier.new(twin_pictures_game(:face), frames: 6)
    row = reader.sprites(:hero).first

    assert_equal [:far, 40, 40], [row.picture, row.x, row.y]
  end

  # The interpreter's rows for the hero over eight frames, which show both pictures.
  private def twin_rows_interpreted(built)
    rows = (1..8).map do |frame|
      [frame, VBlank::IR::Backends::Reference.new.run(built.source_program, frames: frame).sprites(:hero)]
    end
    assert_equal %i[far near], rows.flat_map { |_, shown| shown.map(&:picture) }.uniq.sort, "the hero shows both"
    rows
  end

  # The hero shows :near and then :far, picked as +picked+ says.
  private def twin_pictures_game(picked)
    near = lopsided(0, 0)
    far = lopsided(8, 0)
    clear = CLEAR
    VBlank.build("TWINPICTURES", console: console, out: nil, err: nil) do
      screen :tiled
      image :near, width: CANVAS, height: CANVAS, data: near, transparent: clear
      image :far, width: CANVAS, height: CANVAS, data: far, transparent: clear
      pass = 0
      case picked
      when :face
        hero = sprite :hero, at: [40, 40], facing: { near: :near, far: :far }
        game_loop do
          pass += 1
          hero.face :far if pass == 2
        end
      when :walk
        sprite :hero, at: [40, 40], frames: %i[near far], rate: 3
        game_loop {}
      when :facing_walk
        hero = sprite :hero, at: [40, 40], facing: { both: %i[near far], back: %i[far near] }, rate: 3
        game_loop do
          pass += 1
          hero.face :back if pass == 5
        end
      end
    end
  end

  # The same pictures on a pool's thing, which faces :far from the third pass.
  private def twin_pictures_pool_game
    near = lopsided(0, 0)
    far = lopsided(8, 0)
    clear = CLEAR
    VBlank.build("TWINPICTURES", console: console, out: nil, err: nil) do
      screen :tiled
      image :near, width: CANVAS, height: CANVAS, data: near, transparent: clear
      image :far, width: CANVAS, height: CANVAS, data: far, transparent: clear
      hero = Array.new(capacity: 1)
      pass = 0
      game_loop do
        pass += 1
        hero << TwinThing.new(40, 40) if pass == 1
        hero.each { |thing| thing.face :far } if pass == 3
      end
    end
  end

  def test_a_cartridge_file_has_no_names
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.gba")
      picture_game.write(path)
      reader = VBlank::Diagnostics::Verifier.new(VBlank::Diagnostics::CartridgeFile.new(path), frames: 2)

      assert_match(/not built here/, assert_raises(ArgumentError) { reader.watch_sprites }.message)
    end
  end
end
