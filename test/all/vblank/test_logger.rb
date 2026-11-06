# frozen_string_literal: true

require "test_helper"
require "stringio"

# VBlank.logger: what the library says it is doing, below a level left out unworked, written where a
# game or a test points it.
class TestLogger < Minitest::Test
  def test_a_line_at_or_above_the_level_is_written_with_its_part
    log = StringIO.new
    logger = VBlank::Logger.new(log, level: :info)

    logger.info("network") { "connected" }
    logger.warn { "slow" }

    assert_match(/INFO  \[network\] connected$/, log.string)
    assert_match(/WARN  slow$/, log.string)
  end

  def test_a_line_below_the_level_is_not_worked_out
    worked = false
    logger = VBlank::Logger.new(StringIO.new, level: :warn)

    logger.debug("network") { worked = true }

    refute worked
    refute logger.debug?
  end

  def test_a_level_it_does_not_know_is_said_in_plain_words
    error = assert_raises(ArgumentError) { VBlank::Logger.new(StringIO.new, level: :loud) }

    assert_match(/not a level.*debug, info, warn, error/, error.message)
  end

  def test_the_library_writes_through_the_logger_it_is_given
    VBlank.logger = VBlank::Logger.new(log = StringIO.new, level: :debug)

    VBlank.logger.debug("relay") { "hello" }

    assert_match(/\[relay\] hello/, log.string)
  ensure
    VBlank.logger = nil
  end
end
