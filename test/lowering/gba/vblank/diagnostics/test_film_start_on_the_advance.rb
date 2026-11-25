# frozen_string_literal: true

require "test_helper"
require "film_start_tests"

# A film's cartridge side and interpreter side of an Advance game show the same pass on the same frame,
# on a painted screen, a tiled one and a tiled one with more to set up.
class TestFilmStartOnTheAdvance < Minitest::Test
  include FilmStartTests

  private def console = :gba
end
