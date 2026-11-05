# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A port takes its labels and asset places from a decompilation only after Original::Decompilation
# has built it at its pin and shown it is the player's copy byte for byte. The decompilation here
# is a made-up one: two files its "build" joins into a cartridge.
class TestDecompilation < Minitest::Test
  # It starts git and the build, child processes.
  runs_on_the_main_ractor!

  HEADER = "HEADER--"
  SHIP = "ship pixels"

  private def git(folder, *arguments) = system("git", "-C", folder, *arguments, exception: true, out: File::NULL, err: File::NULL)

  # A checkout of the made-up decompilation, committed, and its pin.
  private def checkout(folder)
    source = File.join(folder, "decomp")
    Dir.mkdir(source)
    File.write(File.join(source, "header.bin"), HEADER)
    File.write(File.join(source, "ship.bin"), SHIP)
    git(source, "init", "--quiet")
    git(source, "add", "header.bin", "ship.bin")
    git(source, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "--no-verify", "-m", "decomp")
    [source, IO.popen(["git", "-C", source, "rev-parse", "HEAD"], &:read).strip]
  end

  private def decompilation(source, pin, **how)
    VBlank::Original::Decompilation.new(checkout: source, pin: pin, command: ["sh", "-c", "cat header.bin ship.bin > rocket.bin"],
                                        output: "rocket.bin", **how)
  end

  private def copy(folder, bytes) = File.join(folder, "rocket.bin").tap { File.binwrite(it, bytes) }

  def test_a_build_that_is_the_copy_is_harvested
    Dir.mktmpdir do |folder|
      source, pin = checkout(folder)

      extent = decompilation(source, pin).harvest(copy(folder, HEADER + SHIP)) { |built| built.extent("ship.bin", at: HEADER.bytesize) }

      assert_equal VBlank::Original::Decompilation::Extent.new(source: "ship.bin", offset: 8, length: SHIP.bytesize,
                                                               sha1: Digest::SHA1.hexdigest(SHIP)), extent
      assert_equal %w[header.bin ship.bin], Dir.children(source).reject { it == ".git" }.sort
    end
  end

  # The checkout is found and the copy accepted the way a game names them (Original::Game), and the
  # accepted copy is what the build is held to.
  def test_a_game_s_named_checkout_and_accepted_copy_are_harvested
    Dir.mktmpdir do |folder|
      source, pin = checkout(folder)
      copy(folder, HEADER + SHIP)
      File.write(File.join(folder, "rocket.yml"), "rom: rocket.bin\ndisassembly: decomp\n")
      game = VBlank::Original::Game.new(title: "Rocket", setting: "ROCKET_ROM", settings_file: File.join(folder, "rocket.yml"), env: {},
                                        releases: { "US" => { "sha1" => Digest::SHA1.hexdigest(HEADER + SHIP) } },
                                        paths: { checkout: { setting: "ROCKET_DISASSEMBLY", key: "disassembly", folder: true,
                                                                       what: "a checkout of the decompilation" } })

      assert_equal source, game.path(:checkout)
      assert decompilation(game.path(:checkout), pin).harvest(game.copy) { |built| built.bytes == HEADER + SHIP }
    end
  end

  def test_a_build_that_is_not_the_copy_is_refused_before_the_harvest
    Dir.mktmpdir do |folder|
      source, pin = checkout(folder)
      harvested = false

      error = assert_raises(VBlank::Original::HarvestRefused) do
        decompilation(source, pin).harvest(copy(folder, "HEADER--shiP pixelz")) { harvested = true }
      end
      assert_match "2 bytes differ", error.message
      refute harvested
    end
  end

  def test_a_fix_is_made_to_the_build_before_it_is_compared
    Dir.mktmpdir do |folder|
      source, pin = checkout(folder)
      fixed = ->(bytes) { bytes.sub("HEADER--", "CHECKSUM") }

      assert decompilation(source, pin, fix: fixed).harvest(copy(folder, "CHECKSUM#{SHIP}")) { true }
    end
  end

  def test_a_checkout_off_its_pin_or_edited_is_refused
    Dir.mktmpdir do |folder|
      source, pin = checkout(folder)
      wanted = copy(folder, HEADER + SHIP)

      assert_match "pinned", assert_raises(VBlank::Original::HarvestRefused) { decompilation(source, "1234567").harvest(wanted) {} }.message
      File.write(File.join(source, "ship.bin"), "edited")
      assert_match "edited", assert_raises(VBlank::Original::HarvestRefused) { decompilation(source, pin).harvest(wanted) {} }.message
    end
  end

  def test_a_build_that_fails_or_makes_nothing_is_refused_saying_what_it_said
    Dir.mktmpdir do |folder|
      source, pin = checkout(folder)
      wanted = copy(folder, HEADER + SHIP)
      failing = VBlank::Original::Decompilation.new(checkout: source, pin: pin, command: ["sh", "-c", "echo no assembler; exit 3"],
                                                    output: "rocket.bin")
      silent = VBlank::Original::Decompilation.new(checkout: source, pin: pin, command: ["true"], output: "rocket.bin")

      assert_match "no assembler", assert_raises(VBlank::Original::HarvestRefused) { failing.harvest(wanted) {} }.message
      assert_match "made no rocket.bin", assert_raises(VBlank::Original::HarvestRefused) { silent.harvest(wanted) {} }.message
    end
  end

  # What the commit does not hold (a file git ignores) is copied in from the checkout, and the build
  # is handed the environment the game gives it.
  def test_files_the_commit_leaves_out_and_the_game_s_environment_reach_the_build
    Dir.mktmpdir do |folder|
      source, pin = checkout(folder)
      File.write(File.join(source, "base.bin"), "BASE")
      decomp = VBlank::Original::Decompilation.new(checkout: source, pin: pin, output: "rocket.bin", extra_files: ["base.bin"],
                                                   env: { "TAIL" => "!" }, command: ["sh", "-c", "cat base.bin ship.bin > rocket.bin; printf %s \"$TAIL\" >> rocket.bin"])

      assert decompilation_harvested?(decomp, copy(folder, "BASE#{SHIP}!"))
    end
  end

  def test_a_pin_too_short_to_name_one_commit_is_refused
    assert_raises(ArgumentError) { decompilation("/nowhere", "0a6f") }
  end

  private def decompilation_harvested?(decomp, wanted) = decomp.harvest(wanted) { true }

  def test_an_asset_that_is_not_where_the_harvest_says_is_refused
    Dir.mktmpdir do |folder|
      source, pin = checkout(folder)

      assert_raises(VBlank::Original::HarvestRefused) do
        decompilation(source, pin).harvest(copy(folder, HEADER + SHIP)) { |built| built.extent("ship.bin", at: 0) }
      end
    end
  end
end
