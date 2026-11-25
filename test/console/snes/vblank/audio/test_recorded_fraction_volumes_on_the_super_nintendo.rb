# frozen_string_literal: true

require "test_helper"
require "recorded_fraction_volume_tests"

# A recorded note whose volume holds a fraction, played as the Super Nintendo. The tests themselves
# are in test/recorded_fraction_volume_tests.rb.
class TestRecordedFractionVolumesOnTheSuperNintendo < Minitest::Test
  include RecordedFractionVolumeTests
end
