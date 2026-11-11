# frozen_string_literal: true

require "test_helper"

# A copy by the video chip while the sound processor reads a recording out of the cartridge
# (docs/genesis/dma-and-the-sound-processor.md). The emulator the suite plays in shows nothing wrong
# without the guard, so what is held here is the code the cartridge carries: the Z80 asked for its
# bus and waited for before the write that starts a copy, and let go after it, in a game that
# plays recordings and in no other; and that write a word read from work RAM, in every game.
class TestGenesisDmaGuard < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  # move.w #$0100,($A11100).l, then btst #0,($A11100).l
  BUS_ASKED_FOR = "33fc010000a11100" "0839000000a11100"
  # ...and a branch back to the test while it reads 1, as it is in a linked cartridge.
  BUS_TAKEN = "#{BUS_ASKED_FOR}6600fff6".freeze
  # clr.w ($A11100).l
  BUS_GIVEN_BACK = "427900a11100"

  # The command put on the stack, which is in work RAM (move.l d0,-(sp), or d1 for the tiles), and
  # each of its words written from there to the chip (move.w (sp)+,(a3), or (a2) for the tiles).
  SPRITES_COMMAND_KEPT = "2f00"
  SPRITES_WORD_WRITTEN = "369f"
  TILES_COMMAND_KEPT = "2f01"
  TILES_WORD_WRITTEN = "349f"

  def test_the_write_that_starts_a_copy_is_a_word_read_from_work_ram
    assert_equal SPRITES_COMMAND_KEPT + SPRITES_WORD_WRITTEN + SPRITES_WORD_WRITTEN, dma_started(samples: false)
  end

  def test_a_copy_stops_the_sound_processor_in_a_game_with_recordings
    guarded = dma_started(samples: true)

    assert guarded.start_with?(SPRITES_COMMAND_KEPT + SPRITES_WORD_WRITTEN + BUS_ASKED_FOR),
           "the bus is asked for and tested before the word that starts the copy, not #{guarded}"
    assert guarded.end_with?(SPRITES_WORD_WRITTEN + BUS_GIVEN_BACK), "the word that starts the copy, then the bus given back, not #{guarded}"
  end

  def test_a_game_with_no_recordings_carries_no_bus_request_at_its_copies
    with = code_of(sprites_game(recording: true))
    without = code_of(sprites_game(recording: false))

    assert with.include?(SPRITES_WORD_WRITTEN + BUS_TAKEN + SPRITES_WORD_WRITTEN + BUS_GIVEN_BACK),
           "the sprite table's copy has the Z80 stopped round it"
    assert without.include?(SPRITES_COMMAND_KEPT + SPRITES_WORD_WRITTEN + SPRITES_WORD_WRITTEN), "the game still copies its sprite table"
    refute without.include?(BUS_ASKED_FOR), "a game with no recordings waits for no bus"
  end

  def test_a_painted_screen_stops_the_sound_processor_for_its_tiles
    with = code_of(painted_game(recording: true))

    assert with.include?(TILES_COMMAND_KEPT + TILES_WORD_WRITTEN + BUS_TAKEN + TILES_WORD_WRITTEN + BUS_GIVEN_BACK),
           "a run of tiles' copy has the Z80 stopped round it"
    refute code_of(painted_game(recording: false)).include?(BUS_ASKED_FOR), "a game with no recordings waits for no bus"
  end

  def test_sprites_and_a_recording_play_alike_on_the_interpreter
    run = Genesis::CheckedRun.new.run(sprites_game(recording: true), frames: 30)

    assert_equal [:clip], run.active_samples
  end

  private

  def dma_started(samples:)
    asm = Genesis::M68000.new("copy")
    Genesis::Runtime::Picture.emit_dma_started(asm, asm.d(0), asm.ind(3), samples: samples)
    asm.section.bytes.unpack1("H*")
  end

  def code_of(program) = Genesis.new.build(program).bytes.unpack1("H*")

  CLIP = (([100] * 15) + ([-100] * 15)).freeze

  def sprites_game(recording:) = game(:tiled, recording)

  def painted_game(recording:) = game(:bitmap, recording)

  def game(kind, recording)
    clip = CLIP
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen kind
      image(:dot, "#" => :red) { "##\n##" }
      dots = Array.new(4) { |i| sprite :dot, at: [8 + (i * 16), 8] }
      if recording
        enable_sound
        sample(:clip, pcm: clip, rate: 13_000).play(loop: true)
      end
      game_loop do
        dots.each { |dot| dot.move :right, by: 1 }
        fill_rect 8, 40, 8, 8, :red if kind == :bitmap
      end
    end
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end
end
