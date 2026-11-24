# frozen_string_literal: true

# A part of another game, for test/all/vblank/dsl/test_plain_ruby_writer_names.rb: a knob whose
# `level` has a writer, which nothing in this game changes.
class WriterNamesKnob
  attr_accessor :level

  def initialize
    @level = 5
  end
end
