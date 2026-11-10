# frozen_string_literal: true

require "test_helper"
require "vblank/live"
require "tmpdir"

# SAVE STATES IN A GAME PLAYED LIVE (Session, and the window's menu and keys that ask for them): a
# device asks to save the game's state or load one, and the game does it between two frames and
# plays on from there. The device here stands in for the window.
class TestSessionStates < Minitest::Test
  # The game is built as Ruby and its source evaluated here, which sets constants the whole process shares.
  runs_on_the_main_ractor!

  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless
  StateRequest = VBlank::Live::WindowMenu::StateRequest
  StateSlots = VBlank::Live::StateSlots

  # A headless device that is asked to save and load on the frame boundaries a script names (the
  # first boundary is number 1), and keeps what it is told about each.
  class AskingDevice < Headless
    attr_reader :said

    def initialize(asks:, slots:, **options)
      super(**options)
      @asks = asks
      @slots = slots
      @boundaries = 0
      @said = []
    end

    def take_state_request = @asks[(@boundaries += 1)]

    def state_saved(slot, text)
      @slots.write(slot, text)
      @said << "saved #{slot}"
    end

    def state_to_load(slot)
      @slots.read(slot).tap { |text| @said << "no state in #{slot}" if text.nil? }
    end

    def state_loaded(slot) = @said << "loaded #{slot}"
    def state_refused(words) = @said << words
  end

  # A game whose picture says how many passes it has counted: a red pixel at that column of the top row.
  private def counting_program
    builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    builder.instance_eval do
      n = var :n, 0
      game_loop do
        clear_screen :black
        n += 1
        draw_rect_at n, 0, 1, 1, :red
      end
    end
    builder.finalize_program
    builder.program
  end

  private def counted(device) = device.pictures.map { |picture| picture.pixels.first(picture.width).index(Color.resolve(:red)) }

  private def play(asks, frames:, folder:)
    device = AskingDevice.new(frames: frames, asks: asks, slots: StateSlots.new(folder: folder))
    Session.new(counting_program).play(device)
    device
  end

  # Saved after one pass, loaded after another: the game counts on from where it was saved, not from
  # where it had got to.
  def test_a_state_loaded_puts_the_game_back_where_it_was_saved
    Dir.mktmpdir do |folder|
      device = play({ 4 => StateRequest.new(action: :save, slot: 3), 8 => StateRequest.new(action: :load, slot: 3) },
                    frames: 12, folder: folder)

      assert_equal ["saved 3", "loaded 3"], device.said
      assert_equal [nil, 1, 2, 3, 4, 5, 6, 3, 4, 5, 6, 7], counted(device)
    end
  end

  # Slot 0 is the quick state, in a file of its own.
  def test_the_quick_state_keeps_to_its_own_file
    Dir.mktmpdir do |folder|
      play({ 3 => StateRequest.new(action: :save, slot: 0) }, frames: 5, folder: folder)

      assert_path_exists File.join(folder, "state-quick")
      assert_equal "Empty", StateSlots.new(folder: folder).text_for(1)
      assert_match(/\A\d{4}-\d\d-\d\d \d\d:\d\d\z/, StateSlots.new(folder: folder).text_for(0))
    end
  end

  def test_a_slot_with_no_state_loads_nothing_and_the_game_plays_on
    Dir.mktmpdir do |folder|
      device = play({ 3 => StateRequest.new(action: :load, slot: 5) }, frames: 6, folder: folder)

      assert_equal ["no state in 5"], device.said
      assert_equal [nil, 1, 2, 3, 4, 5], counted(device)
    end
  end

  # A state another build saved is refused in plain words, before anything changes.
  def test_a_state_from_another_build_is_refused_and_the_game_plays_on
    Dir.mktmpdir do |folder|
      File.write(File.join(folder, "state-2"), "vblank-state 1\nbuild gba 0123456789abcdef\n")
      device = play({ 3 => StateRequest.new(action: :load, slot: 2) }, frames: 6, folder: folder)

      assert_match(/another build/, device.said.first)
      assert_equal [nil, 1, 2, 3, 4, 5], counted(device)
    end
  end

  def test_the_folder_is_named_from_the_title_and_the_game_code
    assert_equal "Pong_ 1 HAB1", StateSlots.folder_name(title: "Pong: 1", code: "HAB1")
    assert_equal "Pong HAB1", StateSlots.folder_name(title: "Pong", code: "HAB1")
    refute_equal StateSlots.folder_name(title: "Pong", code: "HAB1"), StateSlots.folder_name(title: "Pong", code: "HAB2")
  end
end
