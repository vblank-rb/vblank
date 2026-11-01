# frozen_string_literal: true

# A GAME'S LISTS AND POOLS READ OFF A RUNNING CARTRIDGE, played by each console that has a cartridge.
# The game does its work in its first passes and then idles, so the cartridge and the interpreter
# hold the same numbers however their frames line up. Each including test says +console+.
module ListReadingTests
  private def rom
    VBlank.build("LISTREAD", console: console, out: nil, err: nil) do
      screen :tiled
      image(:dot, "#" => :white) { (["#" * 8] * 8).join("\n") }
      sprite :dot, at: [8, 8]
      queue = list :queue, capacity: 6, width: :byte
      words = list :words, capacity: 4
      nothing = list :nothing, capacity: 3
      guards = pool :guards, x: 0, speed: 0.0, capacity: 4
      step = 0
      game_loop do
        step += 1
        if step == 1
          [200, 7, -3, 9, 11].each { |number| queue.push number }
          3.times { queue.shift }
          [4, 5, 6].each { |number| queue.push number }
          words.push 100_000
          words.push -2
          guards.spawn(x: 3, speed: 1.5)
          guards.spawn(x: 4, speed: 0.25)
          guards.spawn(x: 5, speed: -2.5)
        end
        if step == 2
          guards.each { |guard| guard.remove if guard.x == 4 }
        end
        step = 9 if nothing.length == 1
      end
    end
  end

  private def cartridge(built = rom)
    VBlank::Diagnostics::Verifier.new(built, frames: 30, vars: built.var_addresses)
  end

  private def interpreter(built) = VBlank::IR::Backends::Reference.new.run(built.source_program, frames: 30)

  def test_a_list_reads_as_the_interpreter_reads_it
    built = rom
    want = interpreter(built)
    got = cartridge(built)

    assert_equal [9, 11, 4, 5, 6], got.list(:queue), "shifted past the end of its slots, oldest first"
    assert_equal want.list(:queue), got.list(:queue)
    assert_equal want.list(:words), got.list(:words)
    assert_equal [], got.list(:nothing), "a list's length is what the game has put in it"
  end

  def test_a_pool_reads_as_the_interpreter_reads_it
    built = rom
    want = interpreter(built)
    got = cartridge(built)

    assert_equal want.pool(:guards, :x), got.pool(:guards, :x)
    assert_equal want.pool(:guards, :speed), got.pool(:guards, :speed), "a fraction comes back as the interpreter gives it"
    assert_includes got.pool(:guards, :x), nil, "a free slot"
  end

  def test_a_name_the_game_does_not_have_says_what_it_has
    error = assert_raises(ArgumentError) { cartridge.list(:queues) }

    assert_match(/no list :queues/, error.message)
    assert_match(/:queue/, error.message)
  end

  def test_a_cartridge_file_has_no_names
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.cartridge")
      rom.write(path)
      file = VBlank::Diagnostics::CartridgeFile.new(path)
      error = assert_raises(ArgumentError) { VBlank::Diagnostics::Verifier.new(file, frames: 2).list(:queue) }

      assert_match(/where its lists are/, error.message)
    end
  end
end
