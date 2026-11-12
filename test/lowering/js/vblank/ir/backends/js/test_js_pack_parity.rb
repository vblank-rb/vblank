# frozen_string_literal: true

require "test_helper"
require "pack_parity_tests"

# EVERY REGISTERED PACK GAME, BUILT WITH ITS PACK LEFT OUT, HELD TO ITS ALL-IN-ONE BUILD, both
# played as JavaScript and checked against the interpreter on every frame (PackParityTests in
# test/pack_parity_tests.rb, which says why these are not in test/all/).
class TestJSPackParity < Minitest::Test
  include PackParityTests

  private def written_out(program) = VBlank::IR::Backends::JS.new.lower(program)

  def test_the_search_finds_the_packs_numbers_in_all_in_one_builds_written_as_javascript
    assert_search_finds_the_packs_numbers_all_in_one(*SEARCHED)
  end
end
