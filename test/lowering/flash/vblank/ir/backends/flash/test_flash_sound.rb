# frozen_string_literal: true

require "test_helper"
require "runtime_sounds"

# The sound the game as a Flash movie makes, sample for sample (see RuntimeSounds for what is played and why). The
# native runtime is the one every runtime is held to, and it needs zig; the JavaScript runtime is already held to
# it, so the movie is held to the JavaScript one here. What the movie's runtime does not have yet skips naming it.
class TestFlashSound < Minitest::Test
  include RuntimeSounds

  private def runtime_under_test = :flash

  private def assert_sounds_like_the_native_runtime(program, frames:, only: nil, buttons: {})
    played_as = program.console ? [program] : [program, program.copy.tap { |copy| copy.console = :ps1 }]
    played_as.each do |each_program|
      SIDES.each do |side|
        javascript, flash = %i[js flash].map do |on|
          VBlank::Diagnostics::SoundRecording.of(each_program, on: on, frames: frames, buttons: buttons, only: only, side: side)
        end

        refute javascript.samples.all?(&:zero?), "the JavaScript runtime made no sound on the #{side}, so there is nothing to compare"
        first = javascript.first_difference(flash)
        assert_nil first, "the movie's sound on the #{side} differs from the JavaScript runtime's first at sample #{first}"
      end
    end
  rescue VBlank::IR::Backends::Flash::RuntimeGap => e
    skip_on_flash("the runtime does not have #{e.part} yet")
  end
end
