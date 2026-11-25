# frozen_string_literal: true

require "test_helper"

# A background tile drawn from colours alone, with no place numbers, shows the backdrop through
# its black pixels: a tile has no mark of its own for "nothing here", so black stands for it. On a
# game whose backdrop is not black that turns an outline black into holes in the colour of the
# backdrop, and nothing says so. This warns, naming the picture, and says how to keep black.
class TestBlackShowsBackdrop < Minitest::Test
  Guardrails = VBlank::IR::Guardrails
  Check = Guardrails::Checks::BlackShowsBackdrop

  private def findings_for(program)
    Guardrails::Validator.new(checks: [Check.new]).run(program, autofix: false).findings
  end

  # A tiled game whose backdrop is +backdrop+ (the colour's name; nil for none) and whose
  # background is made of +tile+, an image's art: black walls round a red middle. The block adds to
  # the game before its loop, to name the pictures it wants.
  private def game(backdrop: :white, tile: nil, &more)
    options = backdrop ? { backdrop: backdrop } : {}
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled, **options
      instance_exec(&more) if more
      tiles :stones, "#" => tile || :outline
      background :field, tiles: :stones, map: ["#" * 4] * 4
      game_loop { }
    end
    b.finalize_program
    b.program
  end

  private def outline = proc { image(:outline, "#" => :black, "o" => :red) { ("#oooooo#\n" * 8) } }

  def test_a_tile_with_black_pixels_over_a_backdrop_that_is_not_black_is_warned_about
    findings = findings_for(game(&outline))

    assert_equal 1, findings.size
    assert_predicate findings.first, :warning?
    assert_match(/picture :outline/, findings.first.message)
    assert_match(/black pixels show the backdrop/, findings.first.message)
    assert_match(/places:/, findings.first.message, "it says how to keep black")
    assert_equal :outline, findings.first.node.name, "at the picture's own line"
  end

  def test_a_black_backdrop_gives_no_warning
    assert_empty findings_for(game(backdrop: :black, &outline))
  end

  def test_no_backdrop_gives_no_warning
    assert_empty findings_for(game(backdrop: nil, &outline))
  end

  def test_a_tile_with_places_keeps_its_black_and_gives_no_warning
    placed = proc do
      image :outline, width: 8, height: 8, colors: %i[transparent black red],
                      places: Array.new(64) { |at| (at % 8).between?(1, 6) ? 2 : 1 }
    end

    assert_empty findings_for(game(&placed))
  end

  def test_a_picture_only_a_sprite_shows_gives_no_warning
    sprite_only = proc do
      image(:outline, "#" => :black, "o" => :red) { ("#oooooo#\n" * 8) }
      image(:plain, "o" => :green) { ("oooooooo\n" * 8) }
      sprite :outline, at: [8, 8]
    end

    assert_empty findings_for(game(tile: :plain, &sprite_only))
  end
end
