# frozen_string_literal: true

require "test_helper"
require "build_once_tests"

# What a Super Nintendo build does once (BuildOnceTests).
class TestSNESBuildOnce < Minitest::Test
  include BuildOnceTests

  runs_on_the_main_ractor! # BuildOnceTests counts calls by prepending to the lowering's classes

  BACKEND = VBlank::IR::Backends::SNES
  CONSOLE = :snes
end
