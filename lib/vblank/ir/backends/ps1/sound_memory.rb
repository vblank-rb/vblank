# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # WHAT A GAME'S SOUND MEMORY HOLDS: the loops its voices play, each made while building, encoded
        # (ADPCM), placed from the first free byte of the chip's sound memory, and copied there as the
        # program starts (Runtime::Sound#emit_upload).
        #
        # The PlayStation's sound chip has no square voice, no voice of 32 steps and no noise a game can
        # pitch: its 24 voices each read a sound out of sound memory. So every sound VBlank names is a
        # short recording looped for ever, and the voice's pitch register sets how fast it is read:
        #
        # - A SQUARE is one wave of 56 samples, high for so many eighths of it (7 samples an eighth) and
        #   low for the rest, one loop for each width (`duty:`). Read at 56 samples a wave, a voice plays
        #   it at the note's pitch.
        # - A WAVEFORM is its 32 steps, seven times over: 224 samples, a whole number of blocks of 28.
        # - NOISE is the Advance's noise voice's row of bits, one sample a step, recorded: its 15-bit hiss
        #   (the 32760 steps that fill whole blocks, of its 32767 before it comes round) and its 7-bit
        #   rattle (127 steps, 28 times over). The chip does have a noise of its own (NON, 1F801D94h), but
        #   that noise steps at one rate for every voice, set in SPUCNT, from a ladder whose top is 44100
        #   steps a second (Beetle PSX, spu.c SPU_RunNoise), below the 131072 of a high hit; and it has no
        #   rattle. Read as a recording, the noise is the Advance's at any pitch, a voice's own.
        #
        # Every sample is a four-bit level at shift 0, so each comes back exactly (ADPCM).
        class SoundMemory
          SQUARE_SAMPLES = 56
          WAVE_SAMPLES = Audio::Sound::WAVE_SAMPLES * 7
          SAMPLES_AN_EIGHTH = SQUARE_SAMPLES / 8

          # The widths of a square, as the eighths of each wave it is high (Audio::Sound::SQUARE_HIGH_EIGHTHS).
          SQUARE_EIGHTHS = Audio::Sound::SQUARE_HIGH_EIGHTHS.values.uniq.sort.freeze

          # The levels a loop is made of: a square's and the noise's high and low, the top and bottom four
          # bits hold at shift 0.
          HIGH = 0x7000
          LOW = -0x7000

          HISS_STEPS = 32_760
          RATTLE_STEPS = 127 * ADPCM::SAMPLES_A_BLOCK

          # One loop in sound memory: its name, where it starts, in the 8-byte steps a voice's start
          # register counts in, and its bytes.
          Loop = Data.define(:name, :start, :bytes)

          attr_reader :loops

          # The loops +program+ plays: every square width, each waveform it or its songs name, and the noise
          # when it or a song makes any.
          def initialize(program)
            @loops = {}
            next_free = Console::PS1Hardware::SPU_FIRST_FREE
            made(program).each do |name, samples|
              bytes = ADPCM.encode(samples, loop: true)
              @loops[name] = Loop.new(name: name, start: next_free / 8, bytes: bytes)
              next_free += bytes.bytesize
            end
          end

          # Every loop's bytes, one after another, as they go into sound memory from its first free byte.
          def bytes = @loops.values.map(&:bytes).join

          # Where in sound memory the loop +name+ starts, in 8-byte steps.
          def start_of(name) = @loops.fetch(name) { raise LoweringError, "no sound #{name.inspect} is in sound memory" }.start

          def empty? = @loops.empty?

          # The name of the square loop of +duty+ (Audio::Sound::SQUARE_HIGH_EIGHTHS's names).
          def self.square(duty) = [:square, Audio::Sound::SQUARE_HIGH_EIGHTHS.fetch(duty)]

          # The name of the loop of the waveform +shape+ (a name, or its 32 steps).
          def self.wave(shape) = [:wave, Audio::Sound.wavetable(shape)]

          def self.noise(metallic) = metallic ? :rattle : :hiss

          # One wave of a square high for +eighths+.
          def self.square_samples(eighths) = Array.new(SQUARE_SAMPLES) { |i| i < eighths * SAMPLES_AN_EIGHTH ? HIGH : LOW }

          # A waveform's 32 steps of 0 to 15, seven times over, each as its four bits (step - 8).
          def self.wave_samples(steps) = (steps.map { |step| (step - 8) << 12 } * (WAVE_SAMPLES / steps.size))

          # THE ADVANCE'S NOISE VOICE, a step at a time: a row of 15 bits (7 for a rattle), all ones at the
          # start; each step the lowest two are told apart, the row moves down one, and the answer goes in
          # at the top (at bit 6 too for a rattle). The voice is high while the bit falling off is nought
          # (GBATEK, "Sound Channel 4 - Noise").
          def self.noise_samples(steps, metallic)
            bits = metallic ? 0x7F : 0x7FFF
            Array.new(steps) do
              high = bits.even?
              carry = (bits ^ (bits >> 1)) & 1
              bits = (bits >> 1) | (carry << 14)
              bits = (bits & ~0x40) | (carry << 6) if metallic
              bits &= metallic ? 0x7F : 0x7FFF
              high ? HIGH : LOW
            end
          end

          private

          def made(program)
            nodes = program.walk.to_a
            loops = SQUARE_EIGHTHS.map { |eighths| [[:square, eighths], self.class.square_samples(eighths)] }
            shapes = (nodes.select { |node| node.kind == :wave }.map(&:shape) + Music.waveforms(program))
                     .map { |shape| Audio::Sound.wavetable(shape) }.uniq
            loops += shapes.map { |steps| [[:wave, steps], self.class.wave_samples(steps)] }
            if nodes.any? { |node| node.kind == :noise } || Music.drums?(program)
              loops << [:hiss, self.class.noise_samples(HISS_STEPS, false)]
              loops << [:rattle, self.class.noise_samples(RATTLE_STEPS, true)]
            end
            loops
          end
        end
      end
    end
  end
end
