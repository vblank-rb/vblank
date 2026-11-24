# frozen_string_literal: true

require "test_helper"

# A looping recording (Direct Sound) restarts with the clip's own start, not with what the cartridge
# keeps after its end. The sound hardware's FIFO is fed from the mix's buffers and never from the
# clip (Mixer), and the mix reads the clip by a pointer it takes back before the next read, so the
# samples at a seam are the clip's own. The clip is a ramp and what follows it in the cartridge is a
# run of numbers no ramp holds, so any sample from past the clip's end is seen.
class TestLoopingRecordingSeam < Minitest::Test
  include EmulatorSupport

  CLIP = (0...100).map { |i| i - 50 }.freeze
  DECOY = 120
  FRAMES = 30

  private def looping_game
    clip = CLIP
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      ramp = sample :ramp, pcm: clip, rate: 15_768
      sample :after_it, pcm: Array.new(400, 120), rate: 15_768
      pass = 0
      game_loop do
        pass += 1
        ramp.play(loop: true) if pass == 3
      end
    end
    b.finalize_program
    b.program
  end

  # Every sample the mix made over FRAMES frames, in order, from the first sound on.
  private def mixed_samples
    console = assert_emulator_loads_rom(assemble_rom(looping_game, name: "SEAM"), frames: 1)
    stream = console.last_frame_mix
    (FRAMES - 1).times do
      console.step
      stream += console.last_frame_mix
    end
    stream.drop_while(&:zero?)
  end

  def test_the_samples_at_each_loop_point_are_the_clips_own_start
    samples = mixed_samples

    assert_empty samples.reject { |sample| CLIP.minmax.then { |low, high| sample.between?(low, high) } },
                 "every sample is one the clip holds, never one from past its end (#{DECOY})"
    seams = samples.each_cons(2).select { |before, after| after < before - CLIP.length / 2 }
    assert_operator seams.length, :>=, 3, "the clip came round at least three times in #{FRAMES} frames"
    seams.each do |before, after|
      assert_operator before, :>=, CLIP.last - 2, "the sample before a seam is the clip's last"
      assert_operator after, :<=, CLIP.first + 2, "the sample after it is the clip's first"
    end
  end
end
