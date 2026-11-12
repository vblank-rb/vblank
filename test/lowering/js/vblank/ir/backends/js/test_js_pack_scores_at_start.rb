# frozen_string_literal: true

require "test_helper"
require "pack_scores_at_start_tests"

# SONGS WHOSE NOTES ARE IN THE PACK, ITS PACK LEFT OUT, played as JavaScript and checked against
# the interpreter on every frame (PackScoresAtStartTests in test/pack_scores_at_start_tests.rb,
# which says why these are not in test/all/). The JavaScript runtime makes each part's events from
# the file it is handed, as the C runtime does.
class TestJSPackScoresAtStart < Minitest::Test
  include PackScoresAtStartTests
end
