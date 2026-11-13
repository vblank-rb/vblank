# frozen_string_literal: true

require "made_up_original"
require "pack_at_start_tests"

# RECORDED SOUND FROM THE DATA PACK. A recording (`sample`, `instrument`) can take its samples from a
# slot of samples of the pack (`slots.samples`), where `pcm: pack[:bang]` is the whole slot and
# `pcm: pack[:bang].samples(first, count)` a stretch of it. Built all-in-one, the recording holds
# what the slot holds. With the pack left out, the program holds zeros of the recording's length and
# the runtime fills them from the start file as the game starts, so the shell of a port plays
# its sound. That each of these games sounds as its all-in-one build is the registry's
# (PackGames::Sounds, test/pack_games.rb); here is what is particular: settings held to the same
# numbers written by hand, what the program holds, and what a player's file may hold. Like
# PackAtStartTests, this is played by each run that reads a file as it starts: the interpreter
# and the game as C, JavaScript and Ruby, checked against it on every frame.
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

  # One byte of the copy's filler, 24: how many of the recording's 32 samples it plays, when a
  # game reads its length.
  LENGTH_AT = 0x1C9

  # One byte of the copy's filler, 255: every bit set, which a hold read from the pack takes to
  # mean the recording does not loop (IR::StartFile.no_hold?).
  NO_HOLD_AT = 0x1E4

  # A length of nought, the copy's first colour (see-through), and one of 255, past the slot (the
  # same byte as NO_HOLD_AT). A recording the player's copy does not have is nought long in the pack.
  NOUGHT_LENGTH_AT = PALETTE_AT
  PAST_LENGTH_AT = NO_HOLD_AT
  raise "the made-up copy has no length of nought at #{NOUGHT_LENGTH_AT}" unless COPY.getbyte(NOUGHT_LENGTH_AT).zero?
  raise "the made-up copy has no length past the slot at #{PAST_LENGTH_AT}" unless COPY.getbyte(PAST_LENGTH_AT) > SOUND_COUNT

  # A hold of 107, one byte of the copy's filler: past the slot, and not every bit set. A hold of
  # -16, a byte of filler read as a number that goes below zero: before the slot, and not -1. And a
  # rate of nought, two bytes of the copy's first colour (see-through).
  FAR_HOLD_AT = 0x1E0
  NEAR_HOLD_AT = 0x1C1
  NOUGHT_RATE_AT = PALETTE_AT
  unless COPY.getbyte(FAR_HOLD_AT).between?(SOUND_COUNT, 0xFE)
    raise "the made-up copy has no hold past the slot at #{FAR_HOLD_AT}"
  end
  raise "the made-up copy has no hold before the slot at #{NEAR_HOLD_AT}" unless COPY.getbyte(NEAR_HOLD_AT).between?(0x80, 0xFE)
  raise "the made-up copy has no rate of nought at #{NOUGHT_RATE_AT}" unless COPY.byteslice(NOUGHT_RATE_AT, 2).unpack1("v").zero?

  SETTINGS_SLOTS = [VBlank::Original::Slot.samples(:bang, at: SOUND_AT, count: SOUND_COUNT),
                    VBlank::Original::Slot.numbers(:tuning, at: SETTINGS_AT, count: 1, width: :half, signed: false),
                    VBlank::Original::Slot.numbers(:holds, at: HOLDS_AT, count: 1, width: :byte, signed: false),
                    VBlank::Original::Slot.numbers(:shapes, at: ENVELOPE_AT, count: 4, width: :byte, signed: false),
                    VBlank::Original::Slot.numbers(:lengths, at: LENGTH_AT, count: 1, width: :byte, signed: false),
                    VBlank::Original::Slot.numbers(:no_holds, at: NO_HOLD_AT, count: 1, width: :byte, signed: false),
                    VBlank::Original::Slot.numbers(:nought_lengths, at: NOUGHT_LENGTH_AT, count: 1, width: :byte, signed: false),
                    VBlank::Original::Slot.numbers(:past_lengths, at: PAST_LENGTH_AT, count: 1, width: :byte, signed: false),
                    VBlank::Original::Slot.numbers(:far_holds, at: FAR_HOLD_AT, count: 1, width: :byte, signed: false),
                    VBlank::Original::Slot.numbers(:near_holds, at: NEAR_HOLD_AT, count: 1, width: :byte, signed: true),
                    VBlank::Original::Slot.numbers(:nought_rates, at: NOUGHT_RATE_AT, count: 1, width: :half, signed: false)].freeze
  Ractor.make_shareable(SETTINGS_SLOTS)

  private def settings_pack_file
    VBlank::Original::Pack.holding(SETTINGS_SLOTS.to_h { |slot| [slot.name, slot.cut_from(COPY)] }, sha1: SHA1, build_version: "1").to_bytes
  end

  # A game whose instrument takes the settings +from_pack+ names from the pack and the rest as the
  # numbers the copy holds there. It sounds it four ways: a note the game plays (A), the recording
  # going round (B), a song's long note, which takes the recording's own shape (up), and a sound
  # effect's note with a shape of its part's (down).
  # +mix_rate+ is the rate the game names for its mix, or nil for none. +from_pack+ naming
  # :length reads each recording's length from the pack, and :written_length gives the same number.
  # :no_hold reads a hold of every bit set from the pack, which is none, and :written_no_hold
  # gives no hold at all. :nought_length reads a length of 0 from the pack and :past_length one of
  # 255, past the slot; :written_one gives what the first comes to, a length of 1 and the hold put
  # at its one sample, and writing no length is what the second comes to, all of the slot.
  # :far_hold reads a hold of 107 from the pack, past the slot, and :written_last_hold gives what it
  # comes to, the recording's last sample. :near_hold reads a hold of -16, and :written_first_hold
  # gives what it comes to, the first sample. :nought_rate reads a rate of 0 from the pack, and
  # :written_rate_one gives what it comes to, a rate of 1.
  private def settings_at_start_game(folder, from_pack:, options: VBlank::Cartridge::Options.new, mix_rate: nil)
    from = options.pack_at_start ? original_nowhere(folder) : original(folder)
    held_rate = from_pack.include?(:written_rate_one) ? 1 : COPY.byteslice(SETTINGS_AT, 2).unpack1("v")
    written_length = from_pack.include?(:written_length) ? COPY.getbyte(LENGTH_AT) : SOUND_COUNT
    held_from = if from_pack.include?(:written_one) || from_pack.include?(:written_first_hold) then 0
                elsif from_pack.include?(:written_last_hold) then written_length - 1
                elsif !from_pack.include?(:written_no_hold) then COPY.getbyte(HOLDS_AT)
                end
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
      enable_sound(mix_rate: mix_rate)
      pack = data_pack(from: from, version: "1") do |slots|
        slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT
        slots.numbers :tuning, at: SETTINGS_AT, count: 1, width: :half, signed: false
        slots.numbers :holds, at: HOLDS_AT, count: 1, width: :byte, signed: false
        slots.numbers :shapes, at: ENVELOPE_AT, count: 4, width: :byte, signed: false
        slots.numbers :lengths, at: LENGTH_AT, count: 1, width: :byte, signed: false
        slots.numbers :no_holds, at: NO_HOLD_AT, count: 1, width: :byte, signed: false
        slots.numbers :nought_lengths, at: NOUGHT_LENGTH_AT, count: 1, width: :byte, signed: false
        slots.numbers :past_lengths, at: PAST_LENGTH_AT, count: 1, width: :byte, signed: false
        slots.numbers :far_holds, at: FAR_HOLD_AT, count: 1, width: :byte, signed: false
        slots.numbers :near_holds, at: NEAR_HOLD_AT, count: 1, width: :byte, signed: true
        slots.numbers :nought_rates, at: NOUGHT_RATE_AT, count: 1, width: :half, signed: false
      end
      length = if from_pack.include?(:length) then pack[:lengths].number(0)
               elsif from_pack.include?(:nought_length) then pack[:nought_lengths].number(0)
               elsif from_pack.include?(:past_length) then pack[:past_lengths].number(0)
               elsif from_pack.include?(:written_length) then COPY.getbyte(LENGTH_AT)
               elsif from_pack.include?(:written_one) then 1
               end
      holds_from = if from_pack.include?(:holds_from) then pack[:holds].number(0)
                   elsif from_pack.include?(:no_hold) then pack[:no_holds].number(0)
                   elsif from_pack.include?(:far_hold) then pack[:far_holds].number(0)
                   elsif from_pack.include?(:near_hold) then pack[:near_holds].number(0)
                   else held_from
                   end
      rate = if from_pack.include?(:rate) then pack[:tuning].number(0)
             elsif from_pack.include?(:nought_rate) then pack[:nought_rates].number(0)
             else held_rate
             end
      instrument :tone, length: length, pcm: pack[:bang], note: :C4,
                        rate: rate,
                        holds_from: holds_from,
                        envelope: from_pack.include?(:envelope) ? pack[:shapes].envelope(0) : held_shape
      # A note the game plays itself is over inside a frame, before a shape has climbed, so the
      # one the A button plays has none.
      flat = instrument :flat, pcm: pack[:bang], note: :C4, length: length,
                               rate: rate,
                               holds_from: holds_from
      round = sample :round, pcm: pack[:bang], note: :C4, length: length,
                             rate: rate,
                             holds_from: holds_from,
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

  # A RECORDING'S LENGTH READ AS THE GAME STARTS: the slot holds the most a recording can be, and
  # the recording plays its own 24 samples, so one that loops reads back from its own end.
  def test_a_recordings_length_read_as_the_game_starts_sounds_as_the_same_length_given
    Dir.mktmpdir do |folder|
      return assert_console_refuses(settings_at_start_game(folder, from_pack: %i[holds_from length])) unless console_mixes_recordings?

      presses = ->(frame) { { 1 => [:a], 8 => [:b], 20 => [:up], 50 => [:down] }.fetch(frame, []) }
      wanted = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: %i[written_length]), frames: 80)
      whole = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: []), frames: 80)
      left_out = settings_at_start_game(folder, from_pack: %i[holds_from length], options: PACK_AT_START)
      heard = game_player.hand_file(settings_pack_file).input_each_frame(&presses).run(left_out, frames: 80)

      refute_equal whole.mixed_sound, wanted.mixed_sound, "24 of the 32 samples sound otherwise than all of them"
      assert_equal wanted.audio, heard.audio
      assert_equal wanted.mixed_sound, heard.mixed_sound
    end
  end

  # A LENGTH IN THE PACK OUTSIDE THE SLOT is the player's, so it does not stop the build: one of
  # nought plays as 1 (the hold the game wrote is put at that one sample), and one past the slot
  # plays all of it. Built all-in-one and with the pack left out, the recording sounds alike.
  def test_a_length_of_nought_or_past_the_slot_in_the_pack_sounds_as_the_length_it_comes_to
    Dir.mktmpdir do |folder|
      return assert_console_refuses(settings_at_start_game(folder, from_pack: %i[nought_length])) unless console_mixes_recordings?

      presses = ->(frame) { { 1 => [:a], 8 => [:b], 20 => [:up], 50 => [:down] }.fetch(frame, []) }
      whole_slot = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: []), frames: 80)
      { nought_length: %i[written_one], past_length: [] }.each do |read, written|
        wanted = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: written), frames: 80)
        whole = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: [read]), frames: 80)
        left_out = settings_at_start_game(folder, from_pack: [read], options: PACK_AT_START)
        heard = game_player.hand_file(settings_pack_file).input_each_frame(&presses).run(left_out, frames: 80)

        assert_equal [wanted.audio, wanted.mixed_sound], [whole.audio, whole.mixed_sound], "#{read} built all-in-one"
        assert_equal [wanted.audio, wanted.mixed_sound], [heard.audio, heard.mixed_sound], "#{read} with the pack left out"
      end
      one = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: %i[written_one]), frames: 80)
      refute_equal whole_slot.mixed_sound, one.mixed_sound, "one sample sounds otherwise than all of them"
    end
  end

  # ...where a hold the game writes itself outside the samples it gave stays a mistake in the game,
  # whatever length the pack gives, built all-in-one or with the pack left out.
  private def hold_past_the_slot_game(folder, options: VBlank::Cartridge::Options.new)
    from = options.pack_at_start ? original_nowhere(folder) : original(folder)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      enable_sound
      pack = data_pack(from: from, version: "1") do |slots|
        slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT
        slots.numbers :nought_lengths, at: NOUGHT_LENGTH_AT, count: 1, width: :byte, signed: false
      end
      sample :bang, pcm: pack[:bang], rate: SOUND_RATE, length: pack[:nought_lengths].number(0), holds_from: SOUND_COUNT
    end
  end

  def test_a_hold_written_past_the_slot_beside_a_length_from_the_pack_is_a_friendly_error
    Dir.mktmpdir do |folder|
      [VBlank::Cartridge::Options.new, PACK_AT_START].each do |options|
        error = assert_raises(ArgumentError) { hold_past_the_slot_game(folder, options: options) }
        assert_includes error.message, "#{SOUND_COUNT} samples long"
      end
    end
  end

  # A HOLD IN THE PACK OUTSIDE THE RECORDING is the player's, so it does not stop the build: a held
  # note past the end reads back to the recording's last sample, beside no length (the slot's last)
  # or a length the game wrote (that length's last), and one below nought to its first. Built
  # all-in-one and with the pack left out, it sounds alike.
  def test_a_hold_outside_the_recording_in_the_pack_sounds_as_its_first_or_last_sample
    Dir.mktmpdir do |folder|
      return assert_console_refuses(settings_at_start_game(folder, from_pack: %i[far_hold])) unless console_mixes_recordings?

      presses = ->(frame) { { 1 => [:a], 8 => [:b], 20 => [:up], 50 => [:down] }.fetch(frame, []) }
      held = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: []), frames: 80)
      { %i[far_hold] => %i[written_last_hold], %i[far_hold written_length] => %i[written_last_hold written_length],
        %i[near_hold] => %i[written_first_hold] }.each do |read, written|
        wanted = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: written), frames: 80)
        whole = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: read), frames: 80)
        left_out = settings_at_start_game(folder, from_pack: read, options: PACK_AT_START)
        heard = game_player.hand_file(settings_pack_file).input_each_frame(&presses).run(left_out, frames: 80)

        refute_equal held.mixed_sound, wanted.mixed_sound, "#{written} sounds otherwise than a hold from sample 8"
        assert_equal [wanted.audio, wanted.mixed_sound], [whole.audio, whole.mixed_sound], "#{read} built all-in-one"
        assert_equal [wanted.audio, wanted.mixed_sound], [heard.audio, heard.mixed_sound], "#{read} with the pack left out"
      end
    end
  end

  # A RATE IN THE PACK BELOW 1 is the player's too: it plays as 1, so the recording all but stands
  # still. The game names its mix rate, which a build that reads a rate as it starts needs.
  def test_a_rate_of_nought_in_the_pack_sounds_as_a_rate_of_one
    Dir.mktmpdir do |folder|
      return assert_console_refuses(settings_at_start_game(folder, from_pack: %i[nought_rate])) unless console_mixes_recordings?

      presses = ->(frame) { { 1 => [:a], 8 => [:b], 20 => [:up], 50 => [:down] }.fetch(frame, []) }
      tuned = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: [], mix_rate: 13_379), frames: 80)
      wanted = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: %i[written_rate_one], mix_rate: 13_379),
                                                          frames: 80)
      whole = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: %i[nought_rate], mix_rate: 13_379),
                                                         frames: 80)
      left_out = settings_at_start_game(folder, from_pack: %i[nought_rate], options: PACK_AT_START, mix_rate: 13_379)
      heard = game_player.hand_file(settings_pack_file).input_each_frame(&presses).run(left_out, frames: 80)

      refute_equal tuned.mixed_sound, wanted.mixed_sound, "a rate of 1 sounds otherwise than the copy's own rate"
      assert_equal [wanted.audio, wanted.mixed_sound], [whole.audio, whole.mixed_sound], "built all-in-one"
      assert_equal [wanted.audio, wanted.mixed_sound], [heard.audio, heard.mixed_sound], "with the pack left out"
    end
  end

  # A RECORDING THAT DOES NOT LOOP, SAID BY THE PACK: a hold of every bit set (255 in a byte) is
  # none, so the recording sounds as one written without `holds_from:`, all-in-one and with the
  # pack left out: a note plays once, and a play that goes round reads all of it again.
  def test_a_hold_of_every_bit_set_in_the_pack_sounds_as_no_hold_given
    Dir.mktmpdir do |folder|
      return assert_console_refuses(settings_at_start_game(folder, from_pack: %i[no_hold])) unless console_mixes_recordings?

      presses = ->(frame) { { 1 => [:a], 8 => [:b], 20 => [:up], 50 => [:down] }.fetch(frame, []) }
      wanted = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: %i[written_no_hold]), frames: 80)
      held = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: []), frames: 80)
      whole = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: %i[no_hold]), frames: 80)
      left_out = settings_at_start_game(folder, from_pack: %i[no_hold], options: PACK_AT_START)
      heard = game_player.hand_file(settings_pack_file).input_each_frame(&presses).run(left_out, frames: 80)

      refute_equal held.mixed_sound, wanted.mixed_sound, "a recording held from sample 8 sounds otherwise than one with no hold"
      assert_equal [wanted.audio, wanted.mixed_sound], [whole.audio, whole.mixed_sound], "built all-in-one"
      assert_equal [wanted.audio, wanted.mixed_sound], [heard.audio, heard.mixed_sound], "with the pack left out"
    end
  end

  # ...and with its length read from the pack too, which works out how far back each play reads
  # from the length and the hold together.
  def test_a_hold_of_every_bit_set_with_a_length_from_the_pack_sounds_as_no_hold_given
    Dir.mktmpdir do |folder|
      return assert_console_refuses(settings_at_start_game(folder, from_pack: %i[no_hold length])) unless console_mixes_recordings?

      presses = ->(frame) { { 1 => [:a], 8 => [:b], 20 => [:up], 50 => [:down] }.fetch(frame, []) }
      wanted = game_player.input_each_frame(&presses).run(settings_at_start_game(folder, from_pack: %i[written_no_hold written_length]),
                                                          frames: 80)
      left_out = settings_at_start_game(folder, from_pack: %i[no_hold length], options: PACK_AT_START)
      heard = game_player.hand_file(settings_pack_file).input_each_frame(&presses).run(left_out, frames: 80)

      assert_equal [wanted.audio, wanted.mixed_sound], [heard.audio, heard.mixed_sound]
    end
  end

  def test_a_hold_of_every_bit_set_read_as_the_game_starts_is_no_hold
    Dir.mktmpdir do |folder|
      left_out = settings_at_start_game(folder, from_pack: %i[no_hold], options: PACK_AT_START)
      filled = VBlank::IR::StartFile.filled(left_out, settings_pack_file).walk.find { |node| node.kind == :sample && node.name == :tone }

      assert_nil filled.holds_from
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
