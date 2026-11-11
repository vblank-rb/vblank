# frozen_string_literal: true

require "test_helper"
require "stringio"

# EVERY VERB A CONSOLE'S TABLE MARKS REFUSED IS REFUSED, IN ITS OWN WORDS. An answer in a table refuses
# nothing by itself (Console::Answers): the build refuses a line where Console::Questions can tell which
# verb's answer it asks for. So for each console, and each verb its table refuses, the smallest game
# that writes the verb is built for that console, and the build must stop naming the verb the author
# wrote, in the words of that verb's own answer: not the words of another verb it happens to be built on
# (a `pulse` refused as a sprite that resizes, an iris as a light).
class TestRefusedVerbs < Minitest::Test
  # A sprite on a tiled screen, moved every pass, with one verb written beside it.
  private def tiled_game(&verb)
    proc do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(20) { "." * 30 }
      box = sprite :box, at: [20, 60]
      instance_exec(box, &verb)
      game_loop { box.x += 1 }
    end
  end

  # The smallest game that writes each verb some console refuses.
  private def game_writing(verb)
    case verb
    when :pulse then tiled_game { |box| pulse box, to: 1.3 }
    when :iris_out then tiled_game { iris_out }
    when :iris_in then tiled_game { iris_in }
    when :iris_shut? then tiled_game { once_a_frame { halt if iris_shut? } }
    when :pixelate then tiled_game { pixelate 4 }
    when :pixelate_out then tiled_game { pixelate_out }
    when :pixelate_in then tiled_game { pixelate_in }
    when :spotlight then tiled_game { spotlight at: [40, 40], radius: 20 }
    when :clock then proc { game_loop { halt if clock.hour == 3 } }
    when :entry then proc { entry { loop_forever } }
    when :dump_func
      proc do
        func(:listed) { nil }
        dump_func :listed
        game_loop { call :listed }
      end
    when :instrument
      proc do
        instrument :piano, pcm: Array.new(64) { |at| (at % 16) * 8 }, rate: 8000
        game_loop { nil }
      end
    when :draw_place
      proc do
        screen :bitmap, tear_free: true
        image :white, width: 8, height: 8, data: Array.new(64, 0x7FFF)
        place :wall do
          face point(-1.0, 1.0, 2.0), point(1.0, 1.0, 2.0), point(1.0, -1.0, 2.0), point(-1.0, -1.0, 2.0),
               picture: :white, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
        end
        eye = viewer :eye, at: [0.0, 0.0, 0.0]
        game_loop { draw_place :wall, seen_by: eye }
      end
    end
  end

  # Everything the build said: what it printed and what it raised, as one line.
  private def said_building(kit, game)
    err = StringIO.new
    error = assert_raises(VBlank::BuildError) do
      VBlank.build("REFUSED", console: kit.name, out: StringIO.new, err: err, &game)
    end
    "#{err.string} #{error.message}".gsub(/\s+/, " ")
  end

  def test_every_refused_verb_has_a_game_here
    refused = VBlank::Console.kits.flat_map { |kit| kit.answers::ANSWERS.select { |_, answer| answer.refused? }.keys }.uniq

    assert_empty(refused.reject { |verb| game_writing(verb) }, "a verb a console refuses needs its smallest game in game_writing")
  end

  def test_every_verb_a_console_refuses_is_refused_in_its_own_words
    VBlank::Console.kits.each do |kit|
      kit.answers::ANSWERS.each do |verb, answer|
        next unless answer.refused?

        said = said_building(kit, game_writing(verb))

        assert_includes said, "`#{verb}", "#{kit.title}: the refusal of #{verb} names the verb. It said: #{said}"
        assert_includes said, "cannot: #{kit.answers.words_of(verb).gsub(/\s+/, ' ')[0, 60]}",
                        "#{kit.title}: #{verb} is refused in the words of its own answer. It said: #{said}"
      end
    end
  end

  # A console lists a routine's code exactly where its answers say `dump_func` works: the answer
  # decides, and the kit names what does the listing.
  def test_a_console_lists_a_routine_exactly_where_its_answers_say_it_does
    VBlank::Console.kits.grep(VBlank::Console::CheckedKit).each do |kit|
      assert_equal kit.answers.answer(:dump_func).works?, !kit.routine_lister.nil?, kit.title
    end
  end

  # An answer that only points at another verb's is refused in that verb's words.
  def test_an_answer_that_points_at_another_is_said_in_that_ones_words
    answers = VBlank::Console::ColorAnswers

    assert_equal answers.answer(:pixelate).words, answers.words_of(:pixelate_in)
    assert_equal answers.answer(:iris_in).words, answers.words_of(:iris_shut?)
  end

  # A game that writes `pulse` hears about `pulse` once, not about the sprite it resizes as well.
  def test_a_refused_verb_is_said_once_and_not_again_as_the_verb_under_it
    said = said_building(VBlank::Console.for(:gbc), game_writing(:pulse))

    assert_match(/1 problem/, said)
    refute_match(/This sprite turns or resizes/, said)
  end

  # ...and the verbs the console does are not caught by a refusal meant for another.
  def test_a_verb_that_works_beside_a_refused_one_still_builds
    VBlank::Console.kits.each do |kit|
      # The PlayStation's answers say a sprite works, and its build does not make one yet.
      next unless kit.answers.answer(:sprite).works? && kit.name != :ps1

      VBlank.build("WORKS", console: kit.name, out: StringIO.new, err: StringIO.new, &tiled_game { nil })
    end
  end
end
