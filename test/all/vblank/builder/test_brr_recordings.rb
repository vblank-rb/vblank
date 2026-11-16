# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "brr_recordings"

# A RECORDING GIVEN IN THE SUPER NINTENDO SOUND CHIP'S OWN FORMAT (Builder#sample's `brr:`), by hand
# or from a slot of the data pack, plays on every console as the samples the chip decodes from it,
# round the loop its last block names. The answer key is the same game given those samples by hand,
# as `pcm:` with `holds_from:`, decoded by fullsnes's arithmetic (BRRRecordings). The Super
# Nintendo plays the bytes themselves: test/lowering/snes/vblank/ir/backends/snes/test_snes_brr_as_given.rb.
class TestBRRRecordings < Minitest::Test
  RATE = 8000
  FRAMES = 8
  PACK_AT_START = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # A game that plays the recording :clip, declared by the block (given the builder), from its first
  # pass, going round it when +loop+.
  private def clip_game(loop:)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      clip = yield(self)
      clip.play(loop: loop)
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # The sound log and the recordings sounding after each frame.
  private def heard(program)
    Array.new(FRAMES) do |frame|
      run = game_player.run(program, frames: frame + 1)
      [run.audio, run.active_samples]
    end
  end

  # The same game given the answer key's samples, holding from the loop point's sample (sixteen to
  # each block of nine bytes) when it has one.
  private def by_hand(bytes, loop_at: nil, loop: false)
    held = loop_at / 9 * 16 if loop_at
    clip_game(loop: loop) { |b| b.sample :clip, pcm: BRRRecordings.chip_bytes(bytes, loop_at: loop_at || 0), rate: RATE, holds_from: held }
  end

  def test_a_recording_that_loops_goes_round_its_loop_as_the_chip_decodes_it
    wanted = heard(by_hand(BRRRecordings::QUIET, loop_at: BRRRecordings::QUIET_LOOP, loop: true))
    played = heard(clip_game(loop: true) { |b| b.sample :clip, brr: BRRRecordings::QUIET, brr_loop: BRRRecordings::QUIET_LOOP, rate: RATE })

    assert_equal [:clip], wanted.last.last, "it is still sounding"
    assert_equal wanted, played
  end

  def test_a_recording_that_ends_plays_once
    wanted = heard(by_hand(BRRRecordings::LOUD))
    played = heard(clip_game(loop: false) { |b| b.sample :clip, brr: BRRRecordings::LOUD, rate: RATE })

    assert_empty wanted.last.last, "80 samples at 8000 a second are over by the second frame"
    assert_equal wanted, played
  end

  def test_a_recording_that_ends_played_round_goes_round_the_whole_of_it
    wanted = heard(by_hand(BRRRecordings::LOUD, loop: true))

    assert_equal wanted, heard(clip_game(loop: true) { |b| b.sample :clip, brr: BRRRecordings::LOUD, rate: RATE })
  end

  def test_a_recording_that_loops_played_once_ends
    wanted = heard(by_hand(BRRRecordings::QUIET, loop_at: BRRRecordings::QUIET_LOOP))
    played = heard(clip_game(loop: false) { |b| b.sample :clip, brr: BRRRecordings::QUIET, brr_loop: BRRRecordings::QUIET_LOOP, rate: RATE })

    assert_empty wanted.last.last
    assert_equal wanted, played
  end

  def test_a_recording_and_its_loop_point_read_from_the_data_pack_play_as_the_same_given_by_hand
    Dir.mktmpdir do |folder|
      original = BRRRecordings.original_holding(folder)
      wanted = heard(by_hand(BRRRecordings::QUIET, loop_at: BRRRecordings::QUIET_LOOP, loop: true))
      played = heard(clip_game(loop: true) do |b|
        pack = b.data_pack(from: original, version: "1") { |slots| BRRRecordings.declare_slots(slots) }
        b.sample :clip, brr: pack[:clip], brr_loop: pack[:loops].number(0), rate: RATE
      end)

      assert_equal wanted, played
    end
  end

  def test_samples_given_beside_a_brr_recording_are_refused
    error = assert_raises(ArgumentError) do
      clip_game(loop: false) { |b| b.sample :clip, brr: BRRRecordings::LOUD, pcm: [1, 2, 3], rate: RATE }
    end

    assert_includes error.message, "brr: and pcm:"
  end

  def test_a_hold_given_beside_a_brr_recording_is_refused
    error = assert_raises(ArgumentError) do
      clip_game(loop: false) { |b| b.sample :clip, brr: BRRRecordings::QUIET, holds_from: 3, rate: RATE }
    end

    assert_includes error.message, "brr_loop:"
  end

  def test_a_loop_point_given_without_a_brr_recording_is_refused
    error = assert_raises(ArgumentError) { clip_game(loop: false) { |b| b.sample :clip, pcm: [1, 2, 3], brr_loop: 9 } }

    assert_includes error.message, "no brr:"
  end

  def test_a_broken_recording_is_refused_naming_the_sample
    error = assert_raises(ArgumentError) { clip_game(loop: false) { |b| b.sample :clip, brr: BRRRecordings::LOUD.first(40) } }

    assert_includes error.message, "sample :clip"
    assert_includes error.message, "blocks of 9 bytes"
  end

  # The slot's size and a loop point the game writes are the game's own words, so a build that
  # reads its pack as the game starts refuses them where they are not a recording's, as the build
  # that holds the pack does.
  def test_a_slot_of_part_of_a_block_is_refused_both_ways
    [VBlank::Cartridge::Options.new, PACK_AT_START].each do |options|
      Dir.mktmpdir do |folder|
        b = VBlank::Builder.new(options: options)
        pack = b.data_pack(from: BRRRecordings.original_holding(folder), version: "1") do |slots|
          slots.samples :clip, at: BRRRecordings::RECORDING_AT, count: 40
        end
        error = assert_raises(ArgumentError) { b.sample :clip, brr: pack[:clip], rate: RATE }

        assert_includes error.message, "sample :clip"
        assert_includes error.message, "blocks of 9 bytes"
      end
    end
  end

  def test_a_loop_point_written_inside_a_block_is_refused_both_ways
    [VBlank::Cartridge::Options.new, PACK_AT_START].each do |options|
      Dir.mktmpdir do |folder|
        b = VBlank::Builder.new(options: options)
        pack = b.data_pack(from: BRRRecordings.original_holding(folder), version: "1") { |slots| BRRRecordings.declare_slots(slots) }
        error = assert_raises(ArgumentError) { b.sample :clip, brr: pack[:clip], brr_loop: 20, rate: RATE }

        assert_includes error.message, "loop point is 20"
      end
    end
  end

  # Bytes the game wrote, with the loop point from the pack: the runtime would have no bytes to decode.
  def test_brr_written_with_a_loop_point_from_the_pack_left_out_is_refused
    Dir.mktmpdir do |folder|
      b = VBlank::Builder.new(options: PACK_AT_START)
      pack = b.data_pack(from: BRRRecordings.original_holding(folder), version: "1") { |slots| BRRRecordings.declare_slots(slots) }
      error = assert_raises(ArgumentError) { b.sample :clip, brr: BRRRecordings::QUIET, brr_loop: pack[:loops].number(0), rate: RATE }

      assert_includes error.message, "give brr: from the pack too"
    end
  end
end
