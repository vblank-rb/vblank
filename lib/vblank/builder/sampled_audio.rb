# frozen_string_literal: true

module VBlank
  class Builder
    # The sampled-audio verb: `sample` — define a recorded sound (8- or 16-bit PCM) and hand
    # back a {Sample} handle to play and stop it. A concern of {Builder}, mixed in so
    # `sample` stays a flat DSL verb.
    module SampledAudio
      # A sensible default rate for a hand-authored clip — how many samples play per
      # second when the caller doesn't give one.
      DEFAULT_SAMPLE_RATE = 8192

      # Define a named PCM sample, either from a `.wav` file or from raw samples:
      #
      #   sfx  = sample :zap,  from: "zap.wav"                    # a recorded clip (found beside your script)
      #   tone = sample :tone, pcm: [0, 100, 0, -100] * 20, rate: 8000  # hand-authored samples
      #
      # With `from:`, the file's own sample rate is used (any 8-/16-bit, mono/stereo PCM
      # WAV is converted for you); pass `rate:` only to override it. With `pcm:`, give the
      # samples as an Array of -128..127 (or a binary String) and the `rate:` they play at.
      # Returns a {Sample} handle — `play` it, `stop` it.
      #
      # +bits+ 16 takes `pcm:` as 16-bit samples, an Array of -32768..32767 or a String of two
      # bytes each, low byte first. A 16-bit WAV is 16-bit without it. A build for a computer
      # plays all sixteen bits; a console's build keeps what its sound hardware holds, made from
      # the high byte of each sample, as an 8-bit recording of those bytes would be.
      #
      # @param name [Symbol] the sample's name
      # @param pcm [Array<Integer>, String, nil] the signed PCM samples (or use from:)
      # @param from [String, nil] a .wav file to load (or use pcm:)
      # @param rate [Integer, nil] samples per second — defaults to the WAV's rate, or 8192 for pcm:
      # @param bits [Integer, nil] 8 or 16, how many bits each `pcm:` sample has (8 when not given)
      # @return [Sample]
      #
      # +length+ is how many of the samples the recording plays, from its first: for a recording
      # in a slot of the data pack that holds the most a recording can be, with the recording's own
      # length a number of the pack (`length: pack[:lengths].number(3)`), so one that reads back to
      # an earlier sample does so from its own end, not through the rest of the slot.
      #
      # +brr+ is a recording in the Super Nintendo sound chip's own format (Audio::SNESRecording), as
      # bytes or a slot of the data pack, and +brr_loop+ how many bytes into it its loop starts: the
      # Super Nintendo plays those bytes as they are, and every other build what the chip decodes.
      def sample(name, pcm: nil, from: nil, rate: nil, note: :C4, envelope: nil, holds_from: nil, length: nil,
                 brr: nil, brr_loop: 0, bits: nil)
        raise ArgumentError, "A sample name must be a Symbol. You gave #{name.inspect}." unless name.is_a?(Symbol)
        if VBlank::Audio::Music::CONSOLE_VOICE_NAMES.include?(name)
          raise ArgumentError, "The recording #{name.inspect} has the name of one of the console's own " \
                               "voices. A song part that says `plays: #{name.inspect}` plays that voice, " \
                               "not this recording. Give the recording a different name, for example " \
                               ":#{name}_tone."
        end

        refuse_brr_beside_samples!(name, pcm: pcm, from: from, holds_from: holds_from, length: length) if brr
        refuse_brr_loop_alone!(name, brr_loop) unless brr
        unless bits.nil?
          refuse_unknown_bits!(name, bits)
          refuse_bits_without_pcm!(name, pcm)
        end
        # A setting may be a number of the data pack, read here (PackScores), or, in a build that
        # leaves its pack out, read as the game starts: the recording then holds a stand-in for it.
        settings_from_file = recording_settings_in_start_file(rate: rate, holds_from: holds_from, envelope: envelope, length: length)
        # Must be worked out before pack_setting_value turns the pack's numbers into plain ones.
        # A length, a hold or a rate read here from the pack is the player's, held as the runtime
        # holds it as the game starts (#recording_length, #holds_point, #pack_rate_value), so the
        # build all-in-one plays what the build with the pack left out plays.
        length_from_pack = length.is_a?(DSL::PackNumber) && !pack_left_out?
        hold_from_pack = holds_from.is_a?(DSL::PackNumber)
        rate = pack_rate_value(rate, "sample :#{name}'s rate:")
        holds_from = pack_hold_value(holds_from, "sample :#{name}'s holds_from:")
        length = pack_setting_value(length, "sample :#{name}'s length:", nil)
        envelope = pack_envelope_value(envelope, "sample :#{name}'s envelope:")
        # The Super Nintendo's sound chip's own settings: its build writes them to the chip, and
        # every other build plays the ordinary envelope nearest them (Audio::SNESEnvelope).
        chip_envelope = envelope if envelope.is_a?(Audio::SNESEnvelope)
        envelope = chip_envelope.closest_envelope if chip_envelope
        # A recording in the Super Nintendo sound chip's format is played everywhere else as the
        # samples the chip decodes from it, round its own loop.
        chip_recording = snes_recording(name, brr, brr_loop) if brr
        full_samples = nil
        if chip_recording
          decoded = chip_recording.decoded
          bytes = decoded.pcm
          rate ||= DEFAULT_SAMPLE_RATE
          holds_from = decoded.holds_from
        else
          recording = sample_data(name, pcm, from, rate, bits)
          room = recording.bytes.bytesize
          recording = recording.first(recording_length(name, length, room, length_from_pack: length_from_pack)) if length
          bytes = recording.bytes
          full_samples = recording.full_samples
          rate = recording.rate
        end
        # Where a hold the game wrote can be: inside the samples given, where the pack gave the length.
        hold_room = length_from_pack ? room : bytes.bytesize
        start_file_offset = recording_start_file_offset(pcm)
        unless DSL::Whole.positive?(rate)
          raise ArgumentError, "sample :#{name} must have a positive rate. The rate is how many samples play in one second. You gave #{rate.inspect}."
        end
        raise ArgumentError, "sample :#{name} has no sound data. The samples or the .wav file are empty." if bytes.empty?
        DSL::Sample.validate_note!(note, "sample :#{name} note:")

        record(IR::Build.sample(name, bytes, rate, note: note,
                                                   envelope: Audio::Envelope.of(envelope, "sample :#{name}"),
                                                   holds_from: holds_point(name, holds_from, bytes.bytesize, rate, room: hold_room,
                                                                           from_pack: hold_from_pack),
                                                   from_file: start_file_offset, chip_envelope: chip_envelope,
                                                   settings_from_file: settings_from_file, chip_recording: chip_recording,
                                                   full_samples: full_samples))
        DSL::Sample.new(self, name)
      end

      # Define a playable instrument from a recorded sample — the same `pcm:`/`from:`/`rate:`
      # as `sample`, plus the note it was recorded at (`note:`, default :C4). You play notes
      # on the returned {Instrument}, and one recording covers the whole keyboard:
      #
      #   piano = instrument :piano, from: "piano_c4.wav", note: :C4
      #   piano.play(:E4)             # a note
      #   piano.play(:C4, :E4, :G4)   # ...or a chord
      #
      # @return [Instrument]
      def instrument(name, pcm: nil, from: nil, rate: nil, note: :C4, envelope: nil, holds_from: nil, length: nil,
                     brr: nil, brr_loop: 0, bits: nil)
        note_verb_written(:instrument)
        DSL::Instrument.new(self, sample(name, pcm: pcm, from: from, rate: rate, note: note, envelope: envelope,
                                               holds_from: holds_from, length: length, brr: brr, brr_loop: brr_loop,
                                               bits: bits))
      end

      private

      # `bits:` is how many bits each `pcm:` sample has: 8 or 16.
      def refuse_unknown_bits!(name, bits)
        return if [8, 16].include?(bits)

        raise ArgumentError, "sample :#{name} has bits: #{bits.inspect}. bits: is how many bits each pcm: sample has. " \
                             "To fix this, give bits: 8 or bits: 16."
      end

      # `bits:` says how deep the samples given as `pcm:` are, so it means nothing for any other
      # source: a WAV file and a BRR recording say their own, and a data pack's samples are bytes.
      def refuse_bits_without_pcm!(name, pcm)
        return if pcm && !pcm.is_a?(DSL::PackSlot)

        source = pcm ? "takes its samples from the data pack, which keeps 8 bits a sample" : "has no pcm:"
        raise ArgumentError, "sample :#{name} has bits: and #{source}. bits: is for samples given as pcm:. A WAV file " \
                             "says its own bits. To fix this, remove bits:."
      end

      # A BRR recording's samples and where it loops are its own bytes', so nothing else can give them.
      def refuse_brr_beside_samples!(name, pcm:, from:, holds_from:, length:)
        given = { pcm: pcm, from: from, holds_from: holds_from, length: length }.compact.keys
        return if given.empty?

        raise ArgumentError, "sample :#{name} has brr: and #{given.map { |word| "#{word}:" }.join(' and ')}. A BRR recording " \
                             "holds its own samples, and its last block says whether it loops, back to brr_loop:. To fix " \
                             "this, give brr: alone, or pcm: or from: without brr:."
      end

      # A loop point names a place in BRR bytes, so it means nothing without them.
      def refuse_brr_loop_alone!(name, brr_loop)
        return if brr_loop.is_a?(Integer) && brr_loop.zero?

        raise ArgumentError, "sample :#{name} has brr_loop: and no brr:. brr_loop: is where a BRR recording's loop starts. " \
                             "To fix this, give the recording as brr:, or use holds_from: for samples given as pcm: or from:."
      end

      # THE RECORDING +brr+ (bytes, or a slot of the data pack's samples) as an Audio::SNESRecording
      # that loops back +brr_loop+ bytes in (a number of the pack, or the game's own). The chip's
      # decoding is worked out here, as the game is built, from bytes a build that leaves its pack
      # out does not hold.
      def snes_recording(name, brr, brr_loop)
        if brr.is_a?(DSL::PackSlot)
          refuse_slot_from_elsewhere!(brr, "sample :#{name}'s brr:")
          refuse_slot_read_wrongly!(brr, :samples, "sample :#{name}'s brr:")
          refuse_brr_left_out!(name)
          brr = @data_pack_contents.bytes_of(brr.layout.name).byteslice(brr.first_pixel, brr.count)
        end
        refuse_brr_left_out!(name) if brr_loop.is_a?(DSL::PackNumber)
        loop_at = pack_setting_value(brr_loop, "sample :#{name}'s brr_loop:", nil)
        begin
          Audio::SNESRecording.new(bytes: brr, loop_at: loop_at)
        rescue ArgumentError => e
          raise ArgumentError, "sample :#{name}: #{e.message}"
        end
      end

      def refuse_brr_left_out!(name)
        return unless pack_left_out?

        raise ArgumentError, "sample :#{name} reads a BRR recording from the data pack, and this build reads its pack as the " \
                             "game starts. A BRR recording from the pack is not made that way yet. To fix this, build the " \
                             "game all-in-one."
      end

      # +holds_from+ as a sample number, read here where it is a number of the pack
      # (#pack_setting_value). A number of the pack with every bit set is no hold
      # (IR::StartFile.no_hold?): how a pack says a recording does not loop.
      def pack_hold_value(holds_from, subject)
        held = pack_setting_value(holds_from, subject, IR::StartFile::RECORDING_STAND_IN_HOLD)
        return held unless holds_from.is_a?(DSL::PackNumber) && !pack_left_out?

        IR::StartFile.no_hold?(held, holds_from.slot.layout.width) ? nil : held
      end

      # +rate+ as samples a second, read here where it is a number of the pack (#pack_setting_value)
      # and held as the runtime holds it (IR::StartFile.rate_held): one below 1 is 1. A rate the game
      # writes itself is not held, so #sample refuses one below 1.
      def pack_rate_value(rate, subject)
        read = pack_setting_value(rate, subject, IR::StartFile::RECORDING_STAND_IN_RATE)
        rate.is_a?(DSL::PackNumber) ? IR::StartFile.rate_held(read) : read
      end

      # How many samples +length+ keeps of a recording of +room+ samples. With the pack left out it
      # is a stand-in, all of them, which the runtime cuts as the game starts (IR::StartFile::RecordingSettings).
      #
      # A length read from the pack (+from_pack+) is the player's, so it is held by the rule the
      # runtime holds it to as the game starts (IR::StartFile.length_held): one below 1 is 1 and one
      # past the room is all of it. A pack whose copy has no such sound writes nought. Only a length
      # the game writes itself is a mistake to refuse.
      def recording_length(name, length, room, length_from_pack:)
        return room if length.nil?
        return IR::StartFile.length_held(length, room) if length_from_pack
        return length if length.is_a?(Integer) && length.between?(1, room)

        raise ArgumentError, "sample :#{name} has `length: #{length.inspect}`, and it holds #{room} samples. A length is " \
                             "how many of its samples it plays, a whole number from 1 to #{room}."
      end

      # WHERE A HELD NOTE READS BACK TO, as a sample number. A recording is finite and a note can
      # outlast it: a piano recorded for half a second, held for two. Without this the note ends
      # where the recording does, which is both too early and a click — the sound stops at
      # whatever the wave was doing.
      #
      # Given as a time in seconds (a Float) or as a sample number (a whole number), which is the
      # same Float-or-Integer rule the rest of the framework uses — and which matters here
      # because a recording taken out of another game arrives with a sample number and nothing
      # else.
      #
      # A hold the game wrote is refused outside +room+, the samples the game gave, and then held
      # inside +length+, the samples the recording plays. The two differ only where the length was
      # read from the pack: the recording can then be shorter than the hold the game wrote, and the
      # runtime holds from its last sample (IR::StartFile.hold_held), as this build does. A hold
      # read from the pack (+from_pack+) is the player's, so it is only held, never refused, whatever
      # gave the length: the runtime holds it the same way as the game starts (IR::StartFile.hold_in).
      def holds_point(name, holds_from, length, rate, room: length, from_pack: false)
        return nil if holds_from.nil?

        at = holds_from.is_a?(Float) ? (holds_from * rate).round : holds_from
        unless from_pack || (at.is_a?(Integer) && at >= 0 && at < room)
          raise ArgumentError, "sample :#{name} holds from #{holds_from.inspect}, and it is " \
                               "#{room} samples long (#{format('%.2f', room.fdiv(rate))} seconds). " \
                               "A held note reads back to a point inside the recording. Give a time " \
                               "in seconds, like 0.4, or a sample number."
        end

        IR::StartFile.hold_held(at, length)
      end

      # Resolve the sample's samples and rate (an Audio::Wav::Recording) from whichever source was
      # given — a WAV file (its own rate, unless overridden) or raw pcm: samples — insisting on
      # exactly one. Its bytes are the 8-bit samples every console's build plays; a 16-bit
      # recording's high byte of each sample, as a 16-bit WAV's have always been.
      def sample_data(name, pcm, from, rate, bits)
        recording = Audio::Wav::Recording
        if from
          raise ArgumentError, "You gave both pcm: and from: to sample :#{name}. Give pcm: or from:, not both." if pcm

          loaded = Audio::Wav.load(resolve_asset_path(from))
          rate ? loaded.with(rate: rate) : loaded
        elsif pcm.is_a?(DSL::PackSlot)
          recording.new(bytes: pack_recording_bytes(name, pcm, rate), full_samples: nil, rate: rate)
        elsif pcm && bits == 16
          full_samples = pack_pcm_16bit(name, pcm)
          recording.new(bytes: full_samples.unpack("s<*").map { |level| level >> 8 }.pack("c*"), full_samples: full_samples,
                        rate: rate || DEFAULT_SAMPLE_RATE)
        elsif pcm
          recording.new(bytes: pack_pcm(name, pcm), full_samples: nil, rate: rate || DEFAULT_SAMPLE_RATE)
        else
          raise ArgumentError, "sample :#{name} needs sound data. Give pcm: (raw samples) or from: (a .wav file)."
        end
      end

      # The samples of a recording that takes `pcm: pack[:slot]`. Built all-in-one they are what the
      # slot holds. With the pack left out they are zeros of the slot's count, which the runtime
      # fills from the start file as the game starts (see #recording_start_file_offset), so the build
      # never holds them. A sound runs at a speed its bytes do not say, so `rate:` is required.
      def pack_recording_bytes(name, handle, rate)
        raise ArgumentError, "sample :#{name} takes its samples from the data pack, so it needs rate:. The rate is how " \
                             "many samples play in one second. To fix this, add `rate: 7000` or the rate of the sound." if rate.nil?

        refuse_slot_from_elsewhere!(handle, "sample :#{name}'s pcm:")
        refuse_slot_read_wrongly!(handle, :samples, "sample :#{name}'s pcm:")
        return ("\0".b * handle.count) if pack_left_out?

        @data_pack_contents.bytes_of(handle.layout.name).byteslice(handle.first_pixel, handle.count)
      end

      # Where in the start file the recording's first sample is, for a recording that takes `pcm:` from
      # the pack with the pack left out; nil for every other recording.
      def recording_start_file_offset(pcm)
        return unless pcm.is_a?(DSL::PackSlot) && pack_left_out?

        @pack_slot_starts.fetch(pcm.layout.name) + pcm.first_pixel
      end

      # Pack the PCM into 8-bit signed bytes, whether it came as a byte string or an
      # array of sample values — with a friendly error for an out-of-range value.
      def pack_pcm(name, pcm)
        case pcm
        when String then pcm.b
        when Array
          bad = pcm.find { |s| !s.is_a?(Integer) || !s.between?(-128, 127) }
          raise ArgumentError, "sample :#{name} has a bad PCM value #{bad.inspect}. Each value must be -128..127." if bad
          raise ArgumentError, "sample :#{name} has no PCM data. Give it one or more samples." if pcm.empty?

          pcm.pack("c*")
        else
          raise ArgumentError, "sample :#{name} pcm: must be an Array of -128..127 or a byte String. You gave #{pcm.class}."
        end
      end

      # Pack 16-bit PCM into two bytes a sample, low byte first, from a String already in that
      # form or an Array of sample values.
      def pack_pcm_16bit(name, pcm)
        case pcm
        when String
          if pcm.bytesize.odd?
            raise ArgumentError, "sample :#{name} has bits: 16 and a pcm: String of #{pcm.bytesize} bytes. A 16-bit " \
                                 "sample is two bytes, low byte first, so the String must have an even length."
          end
          raise ArgumentError, "sample :#{name} has no PCM data. Give it one or more samples." if pcm.empty?

          pcm.b
        when Array
          bad = pcm.find { |s| !s.is_a?(Integer) || !s.between?(-32_768, 32_767) }
          raise ArgumentError, "sample :#{name} has a bad PCM value #{bad.inspect}. With bits: 16, each value must be -32768..32767." if bad
          raise ArgumentError, "sample :#{name} has no PCM data. Give it one or more samples." if pcm.empty?

          pcm.pack("s<*")
        else
          raise ArgumentError, "sample :#{name} pcm: must be an Array of -32768..32767 or a String of 16-bit samples. " \
                               "You gave #{pcm.class}."
        end
      end
    end
  end
end
