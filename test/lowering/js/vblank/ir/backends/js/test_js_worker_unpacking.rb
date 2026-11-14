# frozen_string_literal: true

require "test_helper"
require "web_page"
require "pieced_original"
require "json"

# A WEB SHELL'S UNPACKING IN PIECES ON SEVERAL WORKERS (rg_shell_unpack_on_workers), a Web Worker
# each: the pack the page keeps is byte for byte the one it keeps on one worker, which plays the
# whole routine as one program, and the one the all-in-one build makes.
class TestJSWorkerUnpacking < Minitest::Test
  include WebPage
  include PiecedOriginal

  JS = VBlank::IR::Backends::JS
  # The menu's first line chosen with A (the page's X key), the copy picked, the unpacking played
  # and the game begun (TestJSShell's steps).
  CHOOSE_LOAD_ROM = ["settle", "play 3", "down KeyX", "play 3", "up KeyX", "play 12", "settle"].freeze
  UNPACK_AND_PLAY = ["play 2", "settle", "play 6", "picture"].freeze

  private def kept_pack_on(workers, folder)
    path = File.join(folder, "shell_#{workers}.html")
    JS.new.build_shell_page(pieced_port(pieced_original_nowhere(folder)), path, console: :gba, err: nil, unpack_workers: workers)
    copy = File.join(folder, "made_up.gba").tap { |at| File.binwrite(at, COPY) }
    store = File.join(folder, "idb_#{workers}.json")
    played_page([*CHOOSE_LOAD_ROM, "choose #{copy}", *UNPACK_AND_PLAY], html: File.read(path, encoding: Encoding::UTF_8),
                                                                       browser: ["idb:#{store}"])
    JSON.parse(File.read(store)).values.first.unpack1("m").b
  end

  def test_three_workers_keep_the_pack_one_worker_and_the_all_in_one_build_make
    Dir.mktmpdir do |folder|
      one = kept_pack_on(1, folder)
      three = kept_pack_on(3, folder)
      all_in_one = Dir.mktmpdir { |elsewhere| pieced_port(pieced_original(elsewhere)).data_pack_file }

      assert_equal one, three
      assert_equal all_in_one, three
    end
  end
end
