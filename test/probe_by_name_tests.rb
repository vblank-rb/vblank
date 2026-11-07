# frozen_string_literal: true

require "tmpdir"

# A PROBE ON A CARTRIDGE VBLANK BUILT reads the game's variables, lists and pools by the names the
# game gave them, from the build's record, the way every other reader does: no address looked up,
# no width or sign put back by hand. Played by each console whose cartridge a probe opens. The game
# fills its list and pool on its first pass and then idles, so the frame the probe stops on does not
# matter. Each including test says +console+.
module ProbeByNameTests
  private def named_game
    VBlank.build("BYNAME", console: console, out: nil, err: nil) do
      var :hearts, 3
      var :lift, -3, width: :byte
      var :drop, -100_000
      var :pace, 2.5
      image(:dot, "#" => :white) { "####\n####\n####\n####" }
      sprite :dot, at: [30, 40], called: :spot
      trail = list :trail, capacity: 4
      guards = pool :guards, x: 0, capacity: 3
      step = var :step, 0
      game_loop do
        step += 1
        if step == 1
          trail.push 7
          trail.push 9
          guards.spawn(x: 5)
        end
      end
    end
  end

  # The probe on +cartridge+, played until the game's first pass is over.
  private def probe_on(cartridge)
    VBlank::Playthroughs::Probe.open(cartridge) do |probe|
      probe.step_until("the first pass over", within: 120) { probe.var(:step) > 1 }
      yield probe
    end
  end

  def test_a_probe_reads_the_games_variables_lists_and_pools_by_name
    built = named_game
    interpreter = VBlank::IR::Backends::Reference.new.run(built.source_program, frames: 10)
    probe_on(built) do |probe|
      assert_equal 3, probe.var(:hearts)
      assert_equal(-3, probe.var(:lift), "a byte-wide variable, its sign put back")
      assert_equal(-100_000, probe.var(:drop), "a signed word")
      assert_equal 2.5, probe.var(:pace), "a fraction, as the game wrote it"
      assert_equal 5 << 15, probe.raw_var(:pace), "and as it is kept"
      assert_equal [30, 40, true], [probe.sprite(:spot).x, probe.sprite(:spot).y, probe.sprite(:spot).shown?]
      assert_equal [7, 9], probe.list(:trail)
      assert_equal 1, probe.pool(:guards, :x).compact.size
      assert_equal interpreter.pool(:guards, :x), probe.pool(:guards, :x), "the slot the interpreter spawned into"
    end
  end

  def test_a_name_the_build_does_not_have_is_refused_in_plain_words
    probe_on(named_game) do |probe|
      error = assert_raises(ArgumentError) { probe.var(:lives) }

      assert_match "no variable :lives", error.message
      assert_match ":hearts", error.message
      refute_match "__", error.message, "the framework's own variables are not offered"
    end
  end

  def test_a_probe_on_the_bare_file_says_nothing_names_its_variables
    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "byname.#{console}").tap { |file| named_game.write(file) }
      VBlank::Playthroughs::Probe.open(path) do |probe|
        assert_match "not built here", assert_raises(ArgumentError) { probe.var(:hearts) }.message
        assert_match "not built here", assert_raises(ArgumentError) { probe.sprite(:spot) }.message
      end
    end
  end
end