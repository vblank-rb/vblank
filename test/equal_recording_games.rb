# frozen_string_literal: true

# RECORDINGS DECLARED UNDER SEVERAL NAMES WITH THE SAME SAMPLES, as one instrument's recording
# shaped several ways is: small games of them, for the test every run plays
# (test/all/vblank/builder/test_equal_recordings.rb) and each lowering's test that its build keeps
# the samples once.
module EqualRecordingGames
  # A tone that rises as it goes, so no stretch of it is like another and a count of how many
  # times a build holds it cannot be fooled by a wave that repeats.
  def self.rising_tone(samples) = (0...samples).map { |i| (Math.sin(i * i / 9000.0) * 100).round }

  RECORDING = rising_tone(2000).freeze
  # The same but for one sample.
  NEARLY = RECORDING.dup.tap { |samples| samples[1000] = -samples[1000] - 1 }.freeze

  RATE = 8000

  # A game that declares :first, :second and :third, each with the samples and rate +declared+
  # gives it ({ pcm:, rate: }; RECORDING at RATE for one it leaves out), starts +plays+ going
  # round on its second pass, and on its fourth stops +stops+ (nothing, for nil). Built for
  # +console+, or for whichever console the run plays.
  private def recordings_game(plays:, stops: nil, declared: {}, console: nil)
    said = %i[first second third].to_h { |name| [name, { pcm: RECORDING, rate: RATE }.merge(declared.fetch(name, {}))] }
    b = console ? VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: console)) : VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      first = sample :first, **said[:first]
      second = sample :second, **said[:second]
      third = sample :third, **said[:third]
      count = 0
      game_loop do
        count += 1
        first.play(loop: true) if plays.include?(:first) && count == 2
        second.play(loop: true) if plays.include?(:second) && count == 2
        third.play(loop: true) if plays.include?(:third) && count == 2
        first.stop if stops == :first && count == 4
        second.stop if stops == :second && count == 4
      end
    end
    b.finalize_program
    b.program
  end

  # How many times +bytes+ holds +part+.
  private def copies_held(bytes, part)
    copies = 0
    at = -1
    copies += 1 while (at = bytes.b.index(part.b, at + 1))
    copies
  end
end
