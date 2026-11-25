# frozen_string_literal: true

require "test_helper"
require "film_start_tests"

# A film's cartridge side and interpreter side of a Color game show the same pass on the same frame,
# on a painted screen and a tiled one.
class TestFilmStartOnTheColor < Minitest::Test
  include FilmStartTests

  private def console = :gbc
end
