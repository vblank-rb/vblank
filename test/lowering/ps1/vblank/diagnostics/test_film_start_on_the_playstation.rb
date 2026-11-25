# frozen_string_literal: true

require "test_helper"
require "film_start_tests"

# A film's program side and interpreter side of a PlayStation game show the same pass on the same frame,
# on a painted screen, a tiled one and a tiled one with more to set up.
class TestFilmStartOnThePlayStation < Minitest::Test
  include FilmStartTests

  private def console = :ps1
end
