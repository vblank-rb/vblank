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

  # A game that plays a recording from the pack on the A button: the whole slot as a sample, and
  # the middle of it as the keys of an instrument. +options+ are the build's.
  private def sound_game(folder, options: VBlank::Cartridge::Options.new)
    from = options.pack_at_start ? original_nowhere(folder) : original(folder)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = data_pack(from: from, version: "1") do |slots|
        slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT
      end
      bang = sample :bang, pcm: pack[:bang], rate: SOUND_RATE
      tone = instrument :tone, pcm: pack[:bang].samples(8, 16), rate: SOUND_RATE, note: :C4
      game_loop do
        wait_vblank
        bang.play if pressed(:a)
        tone.play(:E4) if pressed(:b)
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

      %i[a b].each do |button|
        heard = game_player.hold(button).run(whole, frames: 30).mixed_sound
        assert heard.flatten.any? { |level| level != 0 }, "the all-in-one build sounds the recording on #{button}"
        assert_equal heard, game_player.hand_file(sound_pack_file).hold(button).run(left_out, frames: 30).mixed_sound,
                     "the game handed its pack sounds as the all-in-one build does on #{button}"
      end
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
