# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "pieced_original"

# A SHELL'S UNPACKING IN PIECES ON SEVERAL WORKERS (Live::WorkerUnpacking), a Ractor each: the
# pack is byte for byte the one a single worker makes, which plays the whole routine as one
# program, and the one the all-in-one build makes. The bar the window shows adds up every worker's
# work, so it is whole at the end.
class TestWorkerUnpacking < Minitest::Test
  include PiecedOriginal

  Headless = VBlank::Live::Headless
  # Enough frames for the made-up routine to end many times over.
  FRAMES = 100_000

  private def pack_on(workers, folder)
    shell = VBlank::Original::Shell.build(pieced_port(pieced_original_nowhere(folder)), err: nil)
    device = Headless.new(frames: FRAMES)
    pack = VBlank::Live::Shell.from(shell, workers: workers).pack_from_copy("made_up.gba", COPY, device)
    [pack, device.pictures.last]
  end

  def test_three_workers_make_the_pack_one_worker_and_the_all_in_one_build_make
    Dir.mktmpdir do |folder|
      one, = pack_on(1, folder)
      three, = pack_on(3, folder)
      all_in_one = Dir.mktmpdir { |elsewhere| pieced_port(pieced_original(elsewhere)).data_pack_file }

      assert_equal one, three
      assert_equal all_in_one, three
    end
  end

  def test_the_bar_of_several_workers_is_whole_once_they_end
    Dir.mktmpdir do |folder|
      _, last = pack_on(3, folder)
      bar = VBlank::Original::Shell.build(pieced_port(pieced_original_nowhere(folder)), err: nil).facts.bar
      row = (last.height - bar.height) / 2
      across = (bar.side...(last.width - bar.side)).map { |x| last.pixels.fetch((row * last.width) + x) }

      assert_equal [bar.filled], across.uniq
    end
  end
end
