# frozen_string_literal: true

require "made_up_original"
require "pack_at_start_tests"

# RECORDED SOUND FROM THE DATA PACK. A recording (`sample`, `instrument`) can take its samples from a
# slot of samples of the pack (`slots.samples`), where `pcm: pack[:bang]` is the whole slot and
# `pcm: pack[:bang].samples(first, count)` a stretch of it. Built all-in-one, the recording holds
# what the slot holds. With the pack left out, the program holds zeros of the recording's length and
# the runtime fills them from the start file as the game starts, so the shell of a port plays
# its sound. Like PackAtStartTests, this is played by each run that reads a file as it starts:
# the interpreter and the game as C, JavaScript and Ruby, checked against it on every frame.
module PackSoundTests
  include PackAtStartPictures

  # Where the recording is in the made-up copy (filler bytes, so every sample is a number the
  # interpreter and each runtime must read alike, below zero as well as above), and how long.
  SOUND_AT = 0x1C0
  SOUND_COUNT = 32
  SOUND_RATE = 8000

  # Whether this run's console has the `instrument` verb. One that does not (the Color, whose
  # songs play on its square, wave and noise voices only) refuses a game that writes one, even one
  # no song names.
  private def console_plays_instruments? = VBlank::Console.for(game_console).answers.answer(:instrument).works?

  # A game that plays a recording from the pack on the A button: the whole slot as a sample, and
  # on B the middle of it, as the keys of an instrument where the console has instruments and as a
  # second sample where it has none. +options+ are the build's.
  private def sound_game(folder, options: VBlank::Cartridge::Options.new)
    from = options.pack_at_start ? original_nowhere(folder) : original(folder)
    keyed = console_plays_instruments?
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = data_pack(from: from, version: "1") do |slots|
        slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT
      end
      bang = sample :bang, pcm: pack[:bang], rate: SOUND_RATE
      tone = if keyed
               instrument :tone, pcm: pack[:bang].samples(8, 16), rate: SOUND_RATE, note: :C4
             else
               sample :tone, pcm: pack[:bang].samples(8, 16), rate: SOUND_RATE
             end
      game_loop do
        wait_vblank
        bang.play if pressed(:a)
        if pressed(:b)
          keyed ? tone.play(:E4) : tone.play
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def sound_pack_file
    slot = VBlank::Original::Slot.samples(:bang, at: SOUND_AT, count: SOUND_COUNT)
    VBlank::Original::Pack.holding({ bang: slot.cut_from(COPY) }, sha1: SHA1, build_version: "1").to_bytes
  end

  private def heard_playing(button, program, file: nil)
    player = file ? game_player.hand_file(file) : game_player
    player.hold(button).run(program, frames: 6)
  end

  # A game whose instrument takes its samples from the pack and is played by a song (a long note on
  # a recording that reads back to its start, so it sounds well past its own length) or by a sound
  # effect; the block gets the song and the effects to play. +options+ are the build's.
  private def scored_sound_game(folder, options: VBlank::Cartridge::Options.new)
    from = options.pack_at_start ? original_nowhere(folder) : original(folder)
    score = VBlank::Audio::Score
    held = score.new(tempo: 150, length: 60, plays_once: true,
                     parts: [score::Part.new(plays: :tone, notes: [score::Note.new(at: 0, key: :C4, length: 48)])])
    blip = score.new(tempo: 150, length: 12, parts: [score::Part.new(plays: :tone, notes: [score::Note.new(at: 0, key: :E4)])])
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = data_pack(from: from, version: "1") { |slots| slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT }
      instrument :tone, pcm: pack[:bang].samples(8, 16), rate: SOUND_RATE, note: :C4, holds_from: 0
      music = songs :music, [held]
      effects = sound_effects :sfx, [blip]
      game_loop do
        wait_vblank
        music.play 0 if pressed(:a)
        effects.play 0 if pressed(:b)
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_recording_from_the_pack_plays_in_a_song_and_in_a_sound_effect
    Dir.mktmpdir do |folder|
      whole = scored_sound_game(folder)
      left_out = scored_sound_game(folder, options: PACK_AT_START)
      return assert_console_refuses(left_out, sound_pack_file) unless console_plays_instruments?

      %i[a b].each do |button|
        heard = game_player.hold(button).run(whole, frames: 30).mixed_sound
        assert heard.flatten.any? { |level| level != 0 }, "the all-in-one build sounds the recording on #{button}"
        assert_equal heard, game_player.hand_file(sound_pack_file).hold(button).run(left_out, frames: 30).mixed_sound,
                     "the game handed its pack sounds as the all-in-one build does on #{button}"
      end
    end
  end

  # Where an instrument's rate (a number of two bytes) and the sample it holds from (one byte) are
  # in the made-up copy: its filler bytes, read here as the answer key, at places where they make a
  # rate of 7929 and a hold from sample 8.
  SETTINGS_AT = 0x1D6
  HOLDS_AT = 0x1F9

  # A game playing an instrument from the pack on the A button, its rate and the sample it holds
  # from read from the pack when +from_pack+, or given by hand as the numbers the copy holds there.
  private def instrument_settings_game(folder, from_pack:)
    rate = COPY.byteslice(SETTINGS_AT, 2).unpack1("v")
    holds = COPY.getbyte(HOLDS_AT)
    from = original(folder)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = data_pack(from: from, version: "1") do |slots|
        slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT
        slots.numbers :tuning, at: SETTINGS_AT, count: 1, width: :half, signed: false
        slots.numbers :holds, at: HOLDS_AT, count: 1, width: :byte, signed: false
      end
      tone = if from_pack
               instrument :tone, pcm: pack[:bang], rate: pack[:tuning].number(0), holds_from: pack[:holds].number(0)
             else
               instrument :tone, pcm: pack[:bang], rate: rate, holds_from: holds
             end
      game_loop do
        wait_vblank
        tone.play(:E4) if pressed(:a)
      end
    end
    b.finalize_program
    b.program
  end

  def test_an_instruments_rate_and_hold_read_from_the_pack_sound_as_the_same_numbers_given
    Dir.mktmpdir do |folder|
      return assert_console_refuses(instrument_settings_game(folder, from_pack: true)) unless console_plays_instruments?

      wanted = game_player.hold(:a).run(instrument_settings_game(folder, from_pack: false), frames: 20).mixed_sound
      heard = game_player.hold(:a).run(instrument_settings_game(folder, from_pack: true), frames: 20).mixed_sound

      assert wanted.flatten.any? { |level| level != 0 }, "the instrument given its numbers sounds"
      assert_equal wanted, heard
    end
  end

  # AN INSTRUMENT'S SETTINGS READ AS THE GAME STARTS. With the pack left out the build knows where
  # each number is in the pack and not the number, so the step a voice reads the recording at, how
  # far back a held note reads and the shape's four numbers are written from the file at power-on.
  # Four bytes of the copy's filler are the envelope: a full attack, then a decay, a sustain and a
  # release that are none of them plain.
  ENVELOPE_AT = 0x1E4

  SETTINGS_SLOTS = [VBlank::Original::Slot.samples(:bang, at: SOUND_AT, count: SOUND_COUNT),
                    VBlank::Original::Slot.numbers(:tuning, at: SETTINGS_AT, count: 1, width: :half, signed: false),
                    VBlank::Original::Slot.numbers(:holds, at: HOLDS_AT, count: 1, width: :byte, signed: false),
                    VBlank::Original::Slot.numbers(:shapes, at: ENVELOPE_AT, count: 4, width: :byte, signed: false)].freeze
  Ractor.make_shareable(SETTINGS_SLOTS)

  private def settings_pack_file
    VBlank::Original::Pack.holding(SETTINGS_SLOTS.to_h { |slot| [slot.name, slot.cut_from(COPY)] }, sha1: SHA1, build_version: "1").to_bytes
  end

  # A game whose instrument takes the settings +from_pack+ names from the pack and the rest as the
  # numbers the copy holds there. It sounds it four ways: a note the game plays (A), the recording
  # going round (B), a song's long note, which takes the recording's own shape (up), and a sound
  # effect's note with a shape of its part's (down).
  private def settings_at_start_game(folder, from_pack:, options: VBlank::Cartridge::Options.new)
    from = options.pack_at_start ? original_nowhere(folder) : original(folder)
    held_rate = COPY.byteslice(SETTINGS_AT, 2).unpack1("v")
    held_from = COPY.getbyte(HOLDS_AT)
    held_shape = VBlank::Audio::Envelope.new(**%i[attack decay sustain release].zip(COPY.byteslice(ENVELOPE_AT, 4).bytes).to_h)
    score = VBlank::Audio::Score
    long = score.new(tempo: 150, length: 60, plays_once: true,
                     parts: [score::Part.new(plays: :tone, notes: [score::Note.new(at: 0, key: :C4, length: 30),
                                                                   score::Note.new(at: 36, key: :G4, length: 12)])])
    blip = score.new(tempo: 150, length: 24,
                     parts: [score::Part.new(plays: :tone, envelope: { release: 0.1 }, notes: [score::Note.new(at: 0, key: :E4, length: 12)])])
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = data_pack(from: from, version: "1") do |slots|
        slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT
        slots.numbers :tuning, at: SETTINGS_AT, count: 1, width: :half, signed: false
        slots.numbers :holds, at: HOLDS_AT, count: 1, width: :byte, signed: false
        slots.numbers :shapes, at: ENVELOPE_AT, count: 4, width: :byte, signed: false
      end
      instrument :tone, pcm: pack[:bang], note: :C4,
                        rate: from_pack.include?(:rate) ? pack[:tuning].number(0) : held_rate,
                        holds_from: from_pack.include?(:holds_from) ? pack[:holds].number(0) : held_from,
                        envelope: from_pack.include?(:envelope) ? pack[:shapes].envelope(0) : held_shape
      # A note the game plays itself is over inside a frame, before a shape has climbed, so the
      # one the A button plays has none.
      flat = instrument :flat, pcm: pack[:bang], note: :C4,
                               rate: from_pack.include?(:rate) ? pack[:tuning].number(0) : held_rate,
                               holds_from: from_pack.include?(:holds_from) ? pack[:holds].number(0) : held_from
      round = sample :round, pcm: pack[:bang], note: :C4,
                             rate: from_pack.include?(:rate) ? pack[:tuning].number(0) : held_rate,
                             holds_from: from_pack.include?(:holds_from) ? pack[:holds].number(0) : held_from,
                             envelope: from_pack.include?(:envelope) ? pack[:shapes].envelope(0) : held_shape
      music = songs :music, [long]
      effects = sound_effects :sfx, [blip]
      game_loop do
        wait_vblank
        flat.play(:E4) if pressed(:a)
        round.play(loop: true, pitch: :G4) if pressed(:b)
        music.play 0 if pressed(:up)
        effects.play 0 if pressed(:down)
      end
    end
    b.finalize_program
    b.program
  end

  # Whether this run's console adds recordings together and shapes them. One that does not (the
  # Color, the Genesis) refuses the settings game whichever way it is built.
  private def console_mixes_recordings? = VBlank::Console.described(game_console).mixes_recordings

  # The run's console refuses +program+ before it plays, handed +file+ where its pack is left out.
  private def assert_console_refuses(program, file = nil)
    player = file ? game_player.hand_file(file) : game_player
    assert_raises(VBlank::IR::Guardrails::ValidationError) { player.run(program, frames: 1) }
  end

  private def assert_settings_at_start_sound_alike(from_pack)
    Dir.mktmpdir do |folder|
      whole = settings_at_start_game(folder, from_pack: from_pack)
      left_out = settings_at_start_game(folder, from_pack: from_pack, options: PACK_AT_START)
      return assert_console_refuses(left_out, settings_pack_file) unless console_mixes_recordings?

      %i[a b up down].each do |button|
        once = ->(frame) { frame == 1 ? [button] : [] }
        heard = game_player.input_each_frame(&once).run(whole, frames: 40).mixed_sound
        assert heard.flatten.any? { |level| level != 0 }, "the all-in-one build sounds on #{button}"
        assert_equal heard, game_player.hand_file(settings_pack_file).input_each_frame(&once).run(left_out, frames: 40).mixed_sound,
                     "the game handed its pack sounds as the all-in-one build does on #{button}"
      end
    end
  end

  def test_an_instruments_hold_and_envelope_read_as_the_game_starts_sound_as_the_all_in_one_build_sounds
    assert_settings_at_start_sound_alike(%i[holds_from envelope])
  end

  # Whether this run lays its sound out from the rates of the game's recordings: a build for a
  # computer, playing as a console whose mix runs at the rate most recordings have. The
  # interpreter reads the file before it lays anything out.
  private def mix_rate_follows_recordings?
    VBlank::Testing.checked? && VBlank::Console.described(game_console).recording_voice_hz.nil?
  end

  def test_an_instruments_rate_read_as_the_game_starts_sounds_as_the_all_in_one_build_sounds
    unless mix_rate_follows_recordings? && console_mixes_recordings?
      return assert_settings_at_start_sound_alike(%i[rate holds_from envelope])
    end

    Dir.mktmpdir do |folder|
      left_out = settings_at_start_game(folder, from_pack: %i[rate], options: PACK_AT_START)
      error = assert_raises(VBlank::BuildError) { game_player.hand_file(settings_pack_file).run(left_out, frames: 1) }
      assert_match(/rate/, error.message)
    end
  end

  def test_a_game_reading_settings_as_it_starts_holds_none_of_them
    Dir.mktmpdir do |folder|
      program = settings_at_start_game(folder, from_pack: %i[rate holds_from envelope], options: PACK_AT_START)
      tone = program.walk.find { |node| node.kind == :sample && node.name == :tone }
      filled = VBlank::IR::StartFile.filled(program, settings_pack_file).walk.find { |node| node.kind == :sample && node.name == :tone }

      refute_equal COPY.byteslice(SETTINGS_AT, 2).unpack1("v"), tone.rate
      assert_equal [COPY.byteslice(SETTINGS_AT, 2).unpack1("v"), COPY.getbyte(HOLDS_AT), COPY.byteslice(ENVELOPE_AT, 4).bytes],
                   [filled.rate, filled.holds_from, filled.envelope.to_h.values]
    end
  end

  # The file is the player's, so numbers a build would refuse do not stop the game: a held note
  # that would read back past the recording reads back to its last sample.
  def test_a_hold_past_the_recording_in_the_players_file_plays_on
    Dir.mktmpdir do |folder|
      bytes = SETTINGS_SLOTS.to_h { |slot| [slot.name, slot.cut_from(COPY)] }
      file = VBlank::Original::Pack.holding(bytes.merge(holds: [200].pack("C")), sha1: SHA1, build_version: "1").to_bytes
      left_out = settings_at_start_game(folder, from_pack: %i[holds_from], options: PACK_AT_START)

      filled = VBlank::IR::StartFile.filled(left_out, file).walk.find { |node| node.kind == :sample && node.name == :tone }
      assert_equal SOUND_COUNT - 1, filled.holds_from
      return assert_console_refuses(left_out, file) unless console_mixes_recordings?

      heard = game_player.hand_file(file).input_each_frame { |frame| frame == 1 ? [:b] : [] }.run(left_out, frames: 20).mixed_sound
      assert heard.flatten.any? { |level| level != 0 }, "the recording sounds, going round its last sample"
    end
  end

  def test_a_chip_envelope_from_the_pack_is_refused_by_name_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      from = original_nowhere(folder)
      error = assert_raises(ArgumentError) do
        VBlank::Builder.new(options: PACK_AT_START).instance_eval do
          pack = data_pack(from: from, version: "1") do |slots|
            slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT
            slots.numbers :shapes, at: ENVELOPE_AT, count: 3, width: :byte, signed: false
          end
          instrument :tone, pcm: pack[:bang], rate: SOUND_RATE, envelope: pack[:shapes].snes_envelope(0)
        end
      end
      assert_match(/chip envelope/, error.message)
    end
  end

  # A slot whose recording is shorter than the slot: the game's unpacking writes eight samples and
  # the rest of the slot stays zero, so the recording ends in silence.
  SHORT_COUNT = 8

  private def short_recording_game(folder, options: VBlank::Cartridge::Options.new)
    from = options.pack_at_start ? original_nowhere(folder) : original(folder)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = data_pack(from: from, version: "1") do |slots|
        slots.samples :bang, count: SOUND_COUNT
        slots.fill_from_copy { |copy, into| copy.copy_bytes at: SOUND_AT, count: SHORT_COUNT, into: into[:bang], start: 0 }
      end
      bang = sample :bang, pcm: pack[:bang], rate: SOUND_RATE
      game_loop do
        wait_vblank
        bang.play if pressed(:a)
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_recording_shorter_than_its_slot_ends_in_silence
    Dir.mktmpdir do |folder|
      short = COPY.byteslice(SOUND_AT, SHORT_COUNT) + ("\0".b * (SOUND_COUNT - SHORT_COUNT))
      file = VBlank::Original::Pack.holding({ bang: short }, sha1: SHA1, build_version: "1").to_bytes
      left_out = short_recording_game(folder, options: PACK_AT_START)

      filled = VBlank::IR::StartFile.filled(left_out, file).walk.find { |node| node.kind == :sample }
      assert_equal short, filled.bytes, "the samples written are in the recording and the rest of the slot is zero"
      assert_equal "\0".b * (SOUND_COUNT - SHORT_COUNT), filled.bytes.byteslice(SHORT_COUNT, SOUND_COUNT)

      heard = game_player.hold(:a).run(short_recording_game(folder), frames: 6).mixed_sound
      assert_equal heard, game_player.hand_file(file).hold(:a).run(left_out, frames: 6).mixed_sound
    end
  end

  def test_a_cartridge_build_cannot_leave_the_pack_with_samples_out
    Dir.mktmpdir do |folder|
      from = original_nowhere(folder)
      error = assert_raises(ArgumentError) do
        VBlank::Builder.new(options: VBlank::Cartridge::Options.new(pack_at_start: true)).instance_eval do
          pack = data_pack(from: from, version: "1") { |slots| slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT }
          sample :bang, pcm: pack[:bang], rate: SOUND_RATE
        end
      end
      assert_match(/cartridge holds its own data/, error.message)
    end
  end

  def test_a_recording_from_the_pack_sounds_as_the_all_in_one_build_sounds
    Dir.mktmpdir do |folder|
      whole = sound_game(folder)
      left_out = sound_game(folder, options: PACK_AT_START)

      %i[a b].each do |button|
        heard = heard_playing(button, whole).mixed_sound
        assert heard.flatten.any? { |level| level != 0 }, "the all-in-one build sounds the recording on #{button}"
        assert_equal heard, heard_playing(button, left_out, file: sound_pack_file).mixed_sound,
                     "the game handed its pack sounds as the all-in-one build does on #{button}"
      end
    end
  end

  # Two recordings of one length from two stretches of the slot. With the pack left out the build
  # holds the same zeros for both, and they are still two: each is filled from its own place.
  private def two_stretches_game(folder, options: VBlank::Cartridge::Options.new)
    from = options.pack_at_start ? original_nowhere(folder) : original(folder)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = data_pack(from: from, version: "1") { |slots| slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT }
      early = sample :early, pcm: pack[:bang].samples(0, 16), rate: SOUND_RATE
      late = sample :late, pcm: pack[:bang].samples(16, 16), rate: SOUND_RATE
      game_loop do
        wait_vblank
        early.play if pressed(:a)
        late.play if pressed(:b)
      end
    end
    b.finalize_program
    b.program
  end

  def test_two_recordings_of_one_length_from_the_pack_each_sound_their_own_samples
    Dir.mktmpdir do |folder|
      whole = two_stretches_game(folder)
      left_out = two_stretches_game(folder, options: PACK_AT_START)
      early, late = %i[a b].map { |button| heard_playing(button, whole).mixed_sound }

      refute_equal early, late, "the two stretches hold different samples"
      assert_equal early, heard_playing(:a, left_out, file: sound_pack_file).mixed_sound
      assert_equal late, heard_playing(:b, left_out, file: sound_pack_file).mixed_sound
    end
  end

  def test_the_game_without_its_pack_holds_none_of_the_recordings_bytes
    Dir.mktmpdir do |folder|
      program = sound_game(folder, options: PACK_AT_START)
      samples = program.walk.select { |node| node.kind == :sample }

      assert_equal [SOUND_COUNT, 16], samples.map { |node| node.bytes.bytesize }
      assert(samples.all? { |node| node.bytes.each_byte.all?(&:zero?) }, "the program holds zeros, not the pack's samples")
    end
  end

  def test_a_recording_from_a_stretch_past_its_slot_is_a_friendly_error
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        from = original(folder)
        VBlank::Builder.new.instance_eval do
          pack = data_pack(from: from, version: "1") { |slots| slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT }
          sample :bang, pcm: pack[:bang].samples(30, 8), rate: SOUND_RATE
        end
      end
      assert_match(/Slot :bang holds 32 samples/, error.message)
    end
  end

  def test_a_recording_from_the_pack_names_its_rate
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        from = original(folder)
        VBlank::Builder.new.instance_eval do
          pack = data_pack(from: from, version: "1") { |slots| slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT }
          sample :bang, pcm: pack[:bang]
        end
      end
      assert_match(/rate:/, error.message)
    end
  end

  def test_a_recording_cannot_take_samples_from_a_slot_of_something_else
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        from = original(folder)
        VBlank::Builder.new.instance_eval do
          pack = data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: PALETTE_AT, count: 16 }
          sample :bang, pcm: pack[:palette], rate: SOUND_RATE
        end
      end
      assert_match(/slot of samples/, error.message)
    end
  end
end
