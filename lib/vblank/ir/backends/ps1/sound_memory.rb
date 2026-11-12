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
        # Every sample of those is a four-bit level at shift 0, so each comes back exactly (ADPCM).
        #
        # - A RECORDING the game plays (`sample`, `play_sample`) is its own samples, encoded as near as the
        #   chip's filters bring them, once for each way it is played: once through, or round from where it
        #   holds (#recording_samples).
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
            @next_free = Console::PS1Hardware::SPU_FIRST_FREE
            @kept_as = {} # a recording's name and read-back -> the loop that holds its samples
            made(program).each { |name, samples| keep(name, ADPCM.encode(samples, loop: true)) }
            # RECORDINGS ALIKE ARE KEPT ONCE. What sound memory keeps of a recording is its samples and where
            # it reads back to; the rate it was made at, the note it plays and its shape are the voice's pitch
            # and loudness, set for each play (Runtime::Recordings' row). So recordings declared under several
            # names with the same samples, as one instrument's recording shaped several ways is, read one
            # copy, each still under its own name.
            recordings(program).each do |(name, back), (samples, loop_from)|
              kept = [:recording, samples, back]
              keep(kept, ADPCM.encode(samples, loop: back.positive?, loop_from: loop_from)) unless @loops.key?(kept)
              @kept_as[self.class.recording(name, back)] = kept
            end
          end

          # The name of recording +name+ played going +back+ samples at its end (nought for once through).
          def self.recording(name, back) = [:recording, name, back]

          # A LOOP MUST START ON A BLOCK, and a recording holds from wherever it was told to, so the part it
          # holds over is laid out again from the next block on: the samples up to that block go on as the
          # recording does, and the part held over follows, turned to start where they leave off, and
          # written as many times over as makes a whole number of blocks — at most 28, past a size it is
          # written once and filled out to a block from its own start, which the ear does not tell from it.
          # The chip then plays the same samples the recording holds, in the same order, for ever.
          MOST_LOOP_SAMPLES = 0x1_0000

          def self.recording_samples(data, back)
            return [data, 0] unless back.positive?

            from = data.size - back
            held = data[from..]
            aligned = from.ceildiv(ADPCM::SAMPLES_A_BLOCK) * ADPCM::SAMPLES_A_BLOCK
            lead = Array.new(aligned - from) { |i| held[i % back] }
            turned = held.rotate((aligned - from) % back)
            times = ADPCM::SAMPLES_A_BLOCK / back.gcd(ADPCM::SAMPLES_A_BLOCK)
            body = if back * times <= MOST_LOOP_SAMPLES
                     turned * times
                   else
                     turned + Array.new((-back) % ADPCM::SAMPLES_A_BLOCK) { |i| turned[i % back] }
                   end
            [data[0...from] + lead + body, aligned]
          end

          # Every loop's bytes, one after another, as they go into sound memory from its first free byte.
          def bytes = @loops.values.map(&:bytes).join

          # Where in sound memory the loop +name+ starts, in 8-byte steps.
          def start_of(name)
            @loops.fetch(@kept_as.fetch(name, name)) { raise LoweringError, "no sound #{name.inspect} is in sound memory" }.start
          end

          # Where recording +name+, played going +back+ samples at its end, starts, in 8-byte steps; nil
          # where the program never plays it that way.
          def recording_start(name, back)
            kept = @kept_as[self.class.recording(name, back)]
            kept && @loops.fetch(kept).start
          end

          def empty? = @loops.empty?

          # The name of the square loop of +duty+ (Audio::Sound::SQUARE_HIGH_EIGHTHS's names).
          def self.square(duty) = [:square, Audio::Sound::SQUARE_HIGH_EIGHTHS.fetch(duty)]

          # WHERE THE SQUARE OF +duty+ STARTS, in 8-byte steps: every game's sound memory starts with the
          # squares, in SQUARE_EIGHTHS's order, each the same size, so it is the same in every game.
          def self.square_start(duty)
            bytes = (SQUARE_SAMPLES / ADPCM::SAMPLES_A_BLOCK) * ADPCM::BLOCK_BYTES
            (Console::PS1Hardware::SPU_FIRST_FREE + (SQUARE_EIGHTHS.index(Audio::Sound::SQUARE_HIGH_EIGHTHS.fetch(duty)) * bytes)) / 8
          end

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

          def keep(name, bytes)
            if @next_free + bytes.bytesize > Console::PS1Hardware::SPU_RAM_BYTES
              raise LoweringError, "This game's sounds and recordings come to more than the PlayStation's sound chip holds " \
                                   "(#{(Console::PS1Hardware::SPU_RAM_BYTES - Console::PS1Hardware::SPU_FIRST_FREE) / 1024} KB). " \
                                   "To fix this, make its recordings shorter, or use fewer of them."
            end
            @loops[name] = Loop.new(name: name, start: @next_free / 8, bytes: bytes)
            @next_free += bytes.bytesize
          end

          # Each recording the program plays, by [its name, how far back it reads at its end], as the
          # samples sound memory keeps and where their loop starts (SoundMemory.recording_samples).
          def recordings(program)
            declared = program.walk.select { |node| node.kind == :sample }.to_h { |node| [node.name, node] }
            plays = program.walk.select { |node| node.kind == :play_sample }.filter_map do |node|
              sample = declared[node.name] or next
              info = Assets::Sample.of(sample)
              back = node.loop ? (info.loop_length.positive? ? info.loop_length : info.length) : 0
              [[node.name, back], nil]
            end
            # A song's recorded note reads back to where its recording holds from (SongTable, recorded_note_row).
            notes = IR::Tunes.declared_songs(program).flat_map(&:voices).select { |part| IR::Tunes.part_kind(part) == :recorded }.flat_map do |part|
              part.events.select { |event| event[1].positive? }.filter_map do |event|
                sample = declared[event[2] || part.instrument] or next
                [[sample.name, Assets::Sample.of(sample).loop_length], nil]
              end
            end
            (plays + notes).uniq.to_h do |(name, back), _|
              data = declared.fetch(name).bytes.unpack("c*").map { |sample| sample << 8 }
              [[name, back], self.class.recording_samples(data, back)]
            end
          end

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
