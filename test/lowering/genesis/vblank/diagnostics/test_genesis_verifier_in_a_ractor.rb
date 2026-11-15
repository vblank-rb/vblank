# frozen_string_literal: true

require "test_helper"
require "ractor_workers"

# A Genesis cartridge read inside a Ractor worker, as a game's suite under minitest-ractor reads one,
# gets what the same cartridge read on the main Ractor gets. The Genesis run plays its tests on the
# main Ractor, so the worker is started here by hand.
class TestGenesisVerifierInARactor < Minitest::Test
  include RactorWorkers

  # What one reading of the cartridge found: the picture, the sound, and the memories read by name
  # and whole.
  Reading = Data.define(:picture, :samples, :steps, :video_ram, :color_ram, :sound_registers)

  # A box moved by the right button over a blue field, a number counted up each pass, and a held
  # note: something in the picture, the sound and the work RAM at once. In a module, because a
  # Ractor's block cannot reach a test's methods.
  module BoxAndBeep
    module_function

    def reading
      rom = VBlank.build("RACTORS", console: :genesis, out: StringIO.new, err: StringIO.new) do
        screen :tiled
        enable_sound
        image(:box, "#" => :white) { "########\n" * 8 }
        image(:sea, "." => :blue) { "........\n" * 8 }
        tiles :set, "." => :sea
        background :field, tiles: :set, map: Array.new(32) { "." * 40 }
        hero = sprite :box, at: [30, 40]
        steps = var :steps, 7
        beep 440, decay: :none, volume: 15
        game_loop do
          steps += 1
          hero.x = 50 if held(:right)
        end
      end
      read(VBlank::Diagnostics::Verifier.new(rom, frames: 30, keys: VBlank::IR::Buttons.mask(:right)))
    end

    def read(reader)
      Reading.new(picture: reader.picture, samples: reader.audio_samples, steps: reader.raw_var(:steps),
                  video_ram: reader.video_ram, color_ram: reader.color_ram, sound_registers: reader.sound_registers)
    ensure
      reader&.close
    end
  end

  def test_a_worker_reads_the_picture_sound_and_memory_the_main_ractor_reads
    on_main = BoxAndBeep.reading
    in_worker = value_raising_its_cause(without_the_experimental_warning { Ractor.new { BoxAndBeep.reading } })

    assert_operator on_main.samples.count { |sample| sample != 0 }, :>, 0, "the note is heard"
    assert_operator on_main.steps, :>, 7, "the count went up"
    assert_equal on_main.picture, in_worker.picture, "the same picture"
    assert_equal on_main.samples, in_worker.samples, "the same sound"
    assert_equal on_main.steps, in_worker.steps, "the same number read by name"
    assert_equal on_main.video_ram, in_worker.video_ram, "the same video memory"
    assert_equal on_main.color_ram, in_worker.color_ram, "the same colour memory"
    assert_equal on_main.sound_registers, in_worker.sound_registers, "the same sound chip registers"
  end

  # Two consoles in two workers at once each keep to their own cartridge: the core's callbacks find
  # the console that called them, not whichever was made last.
  def test_two_workers_at_once_each_read_what_one_alone_reads
    alone = BoxAndBeep.reading
    together = without_the_experimental_warning { Array.new(2) { Ractor.new { BoxAndBeep.reading } } }
                 .map { |ractor| value_raising_its_cause(ractor) }

    together.each do |reading|
      assert_equal alone.picture, reading.picture
      assert_equal alone.samples, reading.samples
      assert_equal alone.steps, reading.steps
    end
  end
end
