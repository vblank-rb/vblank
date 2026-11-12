# frozen_string_literal: true

require "test_helper"
require "pack_scores_at_start_tests"

# SONGS WHOSE NOTES ARE IN THE PACK, ITS PACK LEFT OUT, played as C and checked against the
# interpreter on every frame (PackScoresAtStartTests in test/pack_scores_at_start_tests.rb, which
# says why these are not in test/all/). The C runtime makes each part's events from the file it is
# handed before the game's first statement (rg_music_fill_notes).
class TestNativePackScoresAtStart < Minitest::Test
  include PackScoresAtStartTests
end
