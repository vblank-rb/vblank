# frozen_string_literal: true

# Which picture each sprite of a running cartridge showed on each frame, and where, read off the
# cartridge by the names the game gave its pictures, the way the interpreter's sprites rows say
# them. Played by each console whose reader can say them. Each including test says +console+.
#
# The hero is told its picture by the game: a walk of three pictures, then the first mirrored in
# the same pass it moves, then back. The walker steps through its pictures on its own, one of them
# mirrored. Every picture is a block drawn at a different place on its canvas, so no two are the
# same stored picture and each is trimmed differently.
module SpritePictureTests
  # The frames the interpreter and the cartridge are held together over: past the last pass the
  # game changes anything on.
  FRAMES = 16

  CANVAS = 16
  INK = VBlank::Graphics::Color.rgb(31, 20, 0)
  EDGE = VBlank::Graphics::Color.rgb(0, 31, 10)
  CLEAR = VBlank::Graphics::Color.rgb(0, 0, 1)

  # A block at (+left+, +top+) whose left column is another colour, so it is not its own mirror.
  private def lopsided(left, top)
    (0...(CANVAS * CANVAS)).map do |at|
      x = at % CANVAS
      y = at / CANVAS
      next CLEAR unless x >= left && x < left + 6 && y >= top && y < top + 8

      x == left ? EDGE : INK
    end
  end

  private def picture_game
    canvas = CANVAS
    clear = CLEAR
    art = { walk0: lopsided(1, 2), walk1: lopsided(5, 3), walk2: lopsided(9, 6) }
    VBlank.build("SPRITENAMES", console: console, out: nil, err: nil) do
      screen :tiled
      art.each { |name, data| image name, width: canvas, height: canvas, data: data, transparent: clear }
      hero = sprite :hero, at: [40, 40], facing: { a: :walk0, b: :walk1, c: :walk2, back: mirror(:walk0) }
      sprite :walker, at: [100, 60], frames: [:walk0, :walk1, mirror(:walk1)], rate: 2
      pass = 0
      game_loop do
        pass += 1
        hero.face :b if pass == 3
        hero.face :c if pass == 5
        if pass == 7
          hero.face :back
          hero.move 4, 0
        end
        hero.face :a if pass == 10
        hero.move 0, 2 if pass == 12
      end
    end
  end

  # What the interpreter says of +built+ played for each count of frames: each sprite's row.
  private def interpreted(built)
    (1..FRAMES).map do |frame|
      [frame, VBlank::IR::Backends::Reference.new.run(built.source_program, frames: frame).sprites]
    end
  end

  # ...and what the cartridge says, played a frame past them, since the Advance shows a pass's
  # sprites as the gap after it ends.
  private def cartridge(built, name = nil)
    reader = VBlank::Diagnostics::Verifier.new(built, frames: FRAMES + 1)
    reader.watch_sprites
    reader.sprites_by_frame(name).map { |seen| [seen.frame, seen.sprites] }
  end

  def test_the_cartridge_shows_each_picture_on_the_frame_the_interpreter_does
    built = picture_game
    want = interpreted(built)

    assert_equal in_any_order(want), in_any_order(cartridge(built))
  end

  # Each frame's rows sorted, since the console's table keeps them in an order of its own.
  private def in_any_order(frames)
    frames.map { |frame, rows| [frame, rows.sort_by { |row| [row.name.to_s, row.x, row.y] }] }
  end

  # The game picks a picture in its pass, and the framework shows it once the next pass is placed.
  def test_the_hero_shows_each_picture_from_the_frame_after_the_pass_that_picked_it
    shown = cartridge(picture_game, :hero).to_h { |frame, rows| [frame, rows.map { |row| [row.x, row.picture] }] }

    assert_equal %i[walk0 walk0 walk0 walk1 walk1 walk2 walk2], (1..7).map { |frame| shown[frame].first.last }
    assert_equal [[[40, :walk2]], [[44, :walk0_mirrored]]], [shown[7], shown[8]], "mirrored, in the pass it moved"
    assert_equal [[44, :walk0]], shown[11]
  end
end
