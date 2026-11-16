# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "vblank/testing/cartridge_cache"

# A game that takes long to build keeps its cartridges in a Testing::CartridgeCache: built once for
# every test and every later run, and again only when what it is built from changes. The games here
# are one-pixel games built in the test.
class TestCartridgeCache < Minitest::Test
  private def dot_game(color)
    VBlank.game("DOT", consoles: %i[gba]) do
      screen :bitmap
      pixel setting(:floors, 1), 10, color
      halt
    end
  end

  # Whether asking +cache+ for +game+'s cartridge read it from disk (:hit) or built it (:miss), as the
  # report a game's run prints says. The report is read after every ask, which empties it, so it
  # counts this ask alone.
  private def ask(cache, game, **settings)
    cache.cartridge(game, console: :gba, **settings)
    said = StringIO.new
    cache.report(said)
    counted = said.string.match(/(\d+) hits, (\d+) misses/)&.captures&.map(&:to_i)
    flunk "expected one ask in the report, got: #{said.string.inspect}" unless counted&.sum == 1
    counted.first == 1 ? :hit : :miss
  end

  def test_a_cartridge_is_built_once_and_read_back_by_a_later_run
    Dir.mktmpdir do |folder|
      game = dot_game(:red)
      first = VBlank::Testing::CartridgeCache.new(folder)

      assert_equal :miss, ask(first, game)
      later = VBlank::Testing::CartridgeCache.new(folder)

      assert_equal :hit, ask(later, game)
      assert_equal first.cartridge(game, console: :gba).buffer, later.cartridge(game, console: :gba).buffer
    end
  end

  # Two games whose programs say the same thing, one holding a picture's rows as one shared object
  # and one as two equal copies, as the same game does on a process that has shared some of its
  # pieces with tests before it and one that has not. Marshal writes those differently, so a key
  # made from it rebuilt one cartridge on several processes.
  #
  # A game here is what the cache asks of one, around a program built by hand: one fill step in it
  # twice, or two equal fill steps.
  HandBuiltGame = Struct.new(:program_made, :title, :code, :maker, :options) do
    def program(**) = program_made
    def variant_for(_console) = nil
    def build_rom(**) = ROM.assemble(GBA.new.lower(program_made), title: title)
  end

  # The fill steps are made by IR::Build, mixed into a module of its own so its names stay out of this
  # class.
  module HandBuilt
    extend VBlank::IR::Build

    def self.two_fills(shared:)
      first = fill_rect(0, 0, 8, 8, :red)
      program(screen(:bitmap), first, shared ? first : fill_rect(0, 0, 8, 8, :red), halt, console: :gba)
    end
  end

  private def two_fills_game(shared:) = HandBuiltGame.new(HandBuilt.two_fills(shared: shared), "TWO", nil, nil, {})

  def test_a_game_is_known_by_what_its_program_says_not_by_which_pieces_it_shares
    Dir.mktmpdir do |folder|
      ask(VBlank::Testing::CartridgeCache.new(folder), two_fills_game(shared: true), variant: nil)
      # A cache made afresh, so the second ask reaches the disk rather than this Ractor's own copy.
      later = VBlank::Testing::CartridgeCache.new(folder)

      assert_equal :hit, ask(later, two_fills_game(shared: false), variant: nil), "the second program built again"
    end
  end

  def test_a_game_that_builds_something_else_is_built_again
    Dir.mktmpdir do |folder|
      cache = VBlank::Testing::CartridgeCache.new(folder)
      ask(cache, dot_game(:red))

      assert_equal :miss, ask(cache, dot_game(:blue))
      assert_equal :miss, ask(cache, dot_game(:red), settings: { floors: 2 })
    end
  end

  def test_a_changed_input_builds_the_game_again
    Dir.mktmpdir do |folder|
      input = File.join(folder, "copy.bin")
      File.write(input, "first")
      ask(VBlank::Testing::CartridgeCache.new(folder, inputs: [input]), dot_game(:red))
      File.write(input, "second")

      assert_equal :miss, ask(VBlank::Testing::CartridgeCache.new(folder, inputs: [input]), dot_game(:red))
    end
  end

  def test_a_fresh_run_builds_every_cartridge
    Dir.mktmpdir do |folder|
      ask(VBlank::Testing::CartridgeCache.new(folder), dot_game(:red))

      assert_equal :miss, ask(VBlank::Testing::CartridgeCache.new(folder, env: { "NO_BUILD_CACHE" => "1" }), dot_game(:red))
    end
  end

  def test_a_game_keyed_by_its_sources_is_built_again_when_one_changes
    Dir.mktmpdir do |folder|
      source = File.join(folder, "rocket.rb")
      File.write(source, "first")
      ask(VBlank::Testing::CartridgeCache.new(folder, sources: [source]), dot_game(:red))

      assert_equal :hit, ask(VBlank::Testing::CartridgeCache.new(folder, sources: [source]), dot_game(:blue))
      File.write(source, "second")
      assert_equal :miss, ask(VBlank::Testing::CartridgeCache.new(folder, sources: [source]), dot_game(:red))
    end
  end

  # "lib/**/*" matches the folders under lib as well as its files; a folder has no contents to key on.
  def test_sources_given_as_a_whole_tree_key_on_its_files_and_pass_over_its_folders
    Dir.mktmpdir do |folder|
      FileUtils.mkdir_p(File.join(folder, "lib", "rocket"))
      source = File.join(folder, "lib", "rocket", "ship.rb")
      File.write(source, "first")
      tree = File.join(folder, "lib", "**", "*")
      ask(VBlank::Testing::CartridgeCache.new(folder, sources: [tree]), dot_game(:red))

      assert_equal :hit, ask(VBlank::Testing::CartridgeCache.new(folder, sources: [tree]), dot_game(:blue))
      File.write(source, "second")
      assert_equal :miss, ask(VBlank::Testing::CartridgeCache.new(folder, sources: [tree]), dot_game(:red))
    end
  end

  def test_a_cartridge_is_written_as_a_file_for_an_emulator
    Dir.mktmpdir do |folder|
      cache = VBlank::Testing::CartridgeCache.new(folder)

      path = cache.cartridge_path(dot_game(:red), console: :gba)

      assert path.end_with?(".gba")
      assert_equal cache.cartridge(dot_game(:red), console: :gba).buffer, File.binread(path)
    end
  end

  # A run ends with what the cache did: built twice is one miss and one hit; with an input changed,
  # a miss that says so; and the report of a run is forgotten once written.
  def test_a_run_s_report_counts_hits_and_misses_and_says_why_each_missed
    Dir.mktmpdir do |folder|
      input = File.join(folder, "copy.bin").tap { File.write(it, "first") }
      game = dot_game(:red)
      2.times { VBlank::Testing::CartridgeCache.new(folder, inputs: [input]).cartridge(game, console: :gba) }
      File.write(input, "second")
      cache = VBlank::Testing::CartridgeCache.new(folder, inputs: [input])
      cache.cartridge(game, console: :gba)
      out = StringIO.new

      cache.report(out)

      assert_match(/Build cache: 1 hits, 2 misses \(keys \d+\.\d s\)/, out.string)
      assert_match(/miss +\d+\.\d s  not cached yet +DOT gba/, out.string)
      assert_match(/miss +\d+\.\d s  an extra input changed +DOT gba/, out.string)
      assert_match(/hits saved about \d+ s of building/, out.string)
      cache.report(out.reopen)
      assert_empty out.string
    end
  end

  # Two cartridges of one title, asked for under labels of their own, are two lines in the report,
  # and each miss is explained against its own label's last build, never the other's.
  def test_a_label_names_a_cartridge_in_the_report_and_keeps_its_last_build_apart
    Dir.mktmpdir do |folder|
      VBlank::Testing::CartridgeCache.new(folder).cartridge(dot_game(:red), console: :gba, label: "DOT red")
      cache = VBlank::Testing::CartridgeCache.new(folder)
      cache.cartridge(dot_game(:blue), console: :gba, label: "DOT blue")
      cache.cartridge(dot_game(:green), console: :gba, label: "DOT red")
      out = StringIO.new

      cache.report(out)

      assert_match(/not cached yet +DOT blue$/, out.string)
      assert_match(/the game changed +DOT red$/, out.string)
    end
  end

  def test_a_labelled_cartridge_is_written_as_a_file_too
    Dir.mktmpdir do |folder|
      path = VBlank::Testing::CartridgeCache.new(folder).cartridge_path(dot_game(:red), console: :gba, label: "DOT red")

      assert path.end_with?(".gba")
    end
  end

  # A log a stopped run left days ago is not this run's, and is deleted unread.
  def test_a_stopped_run_s_old_log_is_left_out_of_the_report
    Dir.mktmpdir do |folder|
      old = File.join(folder, "runs", "1-1.jsonl")
      FileUtils.mkdir_p(File.dirname(old))
      File.write(old, %({"label":"OLD","result":"miss","reason":"x","key_seconds":1,"build_seconds":9}\n))
      File.utime(Time.now - (3 * 86_400), Time.now - (3 * 86_400), old)
      out = StringIO.new

      VBlank::Testing::CartridgeCache.new(folder).report(out)

      assert_empty out.string
      refute_path_exists old
    end
  end

  # Tidying after a build reads the age of every file it finds, and another process can rename or
  # remove one between the finding and the reading. A link to nothing stands in for such a file:
  # found by name, gone when its age is read.
  def test_a_file_gone_before_the_tidying_reads_its_age_is_passed_over
    Dir.mktmpdir do |folder|
      ask(VBlank::Testing::CartridgeCache.new(folder), dot_game(:red))
      library_folder = Dir.glob(File.join(folder, "*")).find { File.basename(it).match?(/\A\h{16}\z/) }
      missing = File.join(folder, "missing")
      %w[gone.marshal gone.marshal.1.1].each { File.symlink(missing, File.join(library_folder, it)) }
      File.symlink(missing, File.join(folder, "last", "gone.json"))

      cartridge = VBlank::Testing::CartridgeCache.new(folder).cartridge(dot_game(:blue), console: :gba)

      assert_equal dot_game(:blue).build_rom(out: nil, err: nil, console: :gba).buffer, cartridge.buffer
    end
  end

  def test_a_cache_can_be_shared_with_every_ractor
    Dir.mktmpdir { |folder| assert Ractor.shareable?(VBlank::Testing::CartridgeCache.new(folder)) }
  end
end
