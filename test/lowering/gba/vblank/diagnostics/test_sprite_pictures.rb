# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "sprite_picture_tests"

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
  # along for the second. The row alone cannot say which picture it is, or where the canvas
  # starts, so the reader gives both readings rather than one of them.
  def test_two_pictures_stored_as_one_are_read_as_either
    reader = VBlank::Diagnostics::Verifier.new(twin_pictures_game, frames: 2)
    row = reader.sprites(:hero).first
    candidate = VBlank::Diagnostics::PictureCandidate

    assert_equal VBlank::Diagnostics::AmbiguousPicture.new(
      candidates: [candidate.new(picture: :near, x: 40, y: 40), candidate.new(picture: :far, x: 32, y: 40)]
    ), row.picture
    assert_nil row.x, "the canvas could start at either place"
    assert_nil row.y
    assert_equal 40, row.piece_x, "the console's own number is still read"
  end

  private def twin_pictures_game
    near = lopsided(0, 0)
    far = lopsided(8, 0)
    clear = CLEAR
    VBlank.build("TWINPICTURES", console: console, out: nil, err: nil) do
      screen :tiled
      image :near, width: CANVAS, height: CANVAS, data: near, transparent: clear
      image :far, width: CANVAS, height: CANVAS, data: far, transparent: clear
      sprite :hero, at: [40, 40], facing: { near: :near, far: :far }
      game_loop {}
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
