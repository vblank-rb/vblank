# frozen_string_literal: true

require "test_helper"

# The one reader over a running cartridge plays a Super Nintendo cartridge in bsnes and answers
# the questions it answers for the other consoles.
class TestSNESVerifier < Minitest::Test
  Verifier = VBlank::Diagnostics::Verifier

  private def rom
    VBlank.build("READER", console: :snes) do
      screen :tiled
      image(:dot, "#" => :red) { (["########"] * 8).join("\n") }
      hero = sprite :dot, at: [30, 40]
      steps = var :steps, 7
      background_color = var :seen, 0
      game_loop do
        wait_vblank
        background_color += 1
        if held(:right)
          steps += 1
          hero.x = 50
        end
      end
    end
  end

  def test_it_reads_the_picture_at_the_consoles_size
    reader = Verifier.new(rom, frames: 8)

    assert_equal 256, reader.screen_width
    assert_equal 224, reader.screen_height
    assert reader.pixel_is?(33, 43, :red), "the sprite is where the game put it"
    refute reader.pixel_is?(120, 120, :red), "and nowhere else"
  end

  def test_it_reads_a_variable_and_the_sprites_by_name
    built = rom
    reader = Verifier.new(built, frames: 8, vars: built.var_addresses)
    hero = reader.sprites.first

    assert_equal 7, reader.var(:steps)
    assert_equal [30, 40], [hero.x, hero.y]
  end

  def test_a_step_holds_buttons_as_the_other_consoles_do
    built = rom
    reader = Verifier.new(built, frames: 8, vars: built.var_addresses)
    reader.step(4, keys: VBlank::IR::Buttons.mask(:right))

    assert_operator reader.var(:steps), :>, 7
    assert_equal 50, reader.sprites.first.x
  end

  def test_it_counts_the_passes_the_console_finished
    shorter = Verifier.new(rom, frames: 8).passes
    longer = Verifier.new(rom, frames: 18).passes

    assert_equal 10, longer - shorter
  end

  def test_two_runs_of_one_cartridge_are_one_picture
    built = rom

    assert Verifier.new(built, frames: 8).same_picture_as?(Verifier.new(built, frames: 8))
  end

  def test_the_colour_table_has_the_consoles_shape
    reader = Verifier.new(rom, frames: 8)

    assert_equal 256, reader.palette.size
    assert_equal 128, reader.palette(:sprites).size
    assert_equal 16, reader.palette(:sprites, 0).size
  end

  # Its sound is checked by the lowering's own run; saying so beats answering that it is silent.
  def test_a_question_about_sound_says_where_to_ask
    error = assert_raises(ArgumentError) { Verifier.new(rom, frames: 2).silent? }

    assert_match(/HeadlessRun/, error.message)
  end
end
