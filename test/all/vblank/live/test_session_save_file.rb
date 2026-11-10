# frozen_string_literal: true

require "test_helper"
require "vblank/live"
require "tmpdir"

# THE SAVE FILE OF A GAME PLAYED LIVE (Session, Live::SaveFile): a game that keeps save memory has it
# read from a file as it starts, written soon after it changes and as the play ends, and a state loaded
# brings its save memory with it, so the file holds that. The device here stands in for the window.
class TestSessionSaveFile < Minitest::Test
  # The game is built as Ruby and its source evaluated here, which sets constants the whole process shares.
  runs_on_the_main_ractor!

  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless
  SaveFile = VBlank::Live::SaveFile
  StateRequest = VBlank::Live::WindowMenu::StateRequest
  StateSlots = VBlank::Live::StateSlots

  # A headless device with a save file, and states in the same folder, asked for on the boundaries a
  # script names (the first boundary is number 1).
  class SavingDevice < Headless
    attr_reader :save_file

    def initialize(folder:, asks: {}, **options)
      super(**options)
      @save_file = SaveFile.new(folder: folder)
      @slots = StateSlots.new(folder: folder)
      @asks = asks
      @boundaries = 0
    end

    def take_state_request = @asks[(@boundaries += 1)]
    def state_saved(slot, text) = @slots.write(slot, text)
    def state_to_load(slot) = @slots.read(slot)
    def state_loaded(_slot); end
    def state_refused(_words); end
  end

  # A game that adds one to a number in its save memory every pass, and shows it as a red pixel's column.
  private def counting_program
    builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    builder.instance_eval do
      best = save_var :best, 0
      game_loop do
        clear_screen :black
        best += 1
        draw_rect_at best, 0, 1, 1, :red
      end
    end
    builder.finalize_program
    builder.program
  end

  private def counted(device) = device.pictures.map { |picture| picture.pixels.first(picture.width).index(Color.resolve(:red)) }

  private def play(folder, frames:, asks: {})
    device = SavingDevice.new(folder: folder, frames: frames, asks: asks)
    Session.new(counting_program).play(device)
    device
  end

  def test_a_game_with_save_memory_starts_where_the_last_run_left_its_save
    Dir.mktmpdir do |folder|
      first = play(folder, frames: 6)
      assert_path_exists File.join(folder, "save.sav")
      second = play(folder, frames: 4)

      assert_equal [nil, 1, 2, 3, 4, 5], counted(first)
      assert_equal [nil, 6, 7, 8], counted(second)
    end
  end

  # A state loaded brings its save memory back, and the file is written again with it.
  def test_the_save_memory_of_a_loaded_state_reaches_the_file
    Dir.mktmpdir do |folder|
      play(folder, frames: 9, asks: { 3 => StateRequest.new(action: :save, slot: 1), 9 => StateRequest.new(action: :load, slot: 1) })
      resumed = play(folder, frames: 3)

      assert_equal [nil, 3, 4], counted(resumed), "the file holds the save memory the state held, not where the run got to"
    end
  end

  def test_a_file_that_is_not_the_size_of_the_save_stops_the_game_before_it_starts
    Dir.mktmpdir do |folder|
      File.binwrite(File.join(folder, "save.sav"), "x" * 5)
      error = assert_raises(SaveFile::NotThisGamesSave) { play(folder, frames: 3) }

      assert_match(/not a save of this game/, error.message)
      assert_equal "x" * 5, File.binread(File.join(folder, "save.sav"))
    end
  end

  def test_a_game_with_no_save_memory_keeps_no_file
    Dir.mktmpdir do |folder|
      builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
      builder.instance_eval { game_loop { clear_screen :black } }
      builder.finalize_program
      Session.new(builder.program).play(SavingDevice.new(folder: folder, frames: 4))

      refute_path_exists File.join(folder, "save.sav")
    end
  end
end
