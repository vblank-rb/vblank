# frozen_string_literal: true

require "test_helper"

# A copy by the video chip while the sound processor reads a recording out of the cartridge
# (docs/genesis/dma-and-the-sound-processor.md). The emulator the suite plays in shows nothing wrong
# without the guard, so what is held here is the code the cartridge carries: the Z80 asked for its
# bus and waited for before the write that starts a copy, and let go after it, in a game that
# plays recordings and in no other.
class TestGenesisDmaGuard < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  # move.w #$0100,($A11100).l, then btst #0,($A11100).l
  BUS_ASKED_FOR = "33fc010000a11100" "0839000000a11100"
  # ...and a branch back to the test while it reads 1, as it is in a linked cartridge.
  BUS_TAKEN = "#{BUS_ASKED_FOR}6600fff6".freeze
  # clr.w ($A11100).l
  BUS_GIVEN_BACK = "427900a11100"

  def test_a_copy_stops_the_sound_processor_in_a_game_with_recordings
    plain = dma_started(samples: false)
    guarded = dma_started(samples: true)

    assert guarded.start_with?(BUS_ASKED_FOR), "the bus is asked for and tested first, not #{guarded}"
    assert guarded.end_with?(plain + BUS_GIVEN_BACK), "the write that starts the copy, then the bus given back, not #{guarded}"
  end

  def test_a_game_with_no_recordings_carries_no_bus_request_at_its_copies
    with = code_of(sprites_game(recording: true))
    without = code_of(sprites_game(recording: false))

    assert with.include?(BUS_TAKEN + sprite_copy_started + BUS_GIVEN_BACK), "the sprite table's copy has the Z80 stopped round it"
    assert without.include?(sprite_copy_started), "the game still copies its sprite table"
    refute without.include?(BUS_ASKED_FOR), "a game with no recordings waits for no bus"
  end

  def test_a_painted_screen_stops_the_sound_processor_for_its_tiles
    with = code_of(painted_game(recording: true))

    assert with.include?(BUS_TAKEN + tile_copy_started + BUS_GIVEN_BACK), "a run of tiles' copy has the Z80 stopped round it"
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

  # The write that starts the sprite table's copy, and the one that starts a run of painted tiles.
  def sprite_copy_started = dma_started(samples: false)

  def tile_copy_started
    asm = Genesis::M68000.new("copy")
    Genesis::Runtime::Picture.emit_dma_started(asm, asm.d(1), asm.ind(2), samples: false)
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
