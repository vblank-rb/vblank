# frozen_string_literal: true

# Plain Ruby game code held to Ruby's own answers. A case is a block of game code: names set
# above `game_loop`, and the loop's body. It is run twice: once as plain Ruby, nothing rewritten,
# the body called once for each pass with no button down (RubyAnswers::Stage), and once as a game
# on the run's own player (`game_player`), for as many passes. The names the case reads are then
# compared, and a difference fails naming the case and each name.
#
# A name holding a number is read as the game's number; one holding an Array of numbers as the
# list of that name, and one holding an Array of Structs as the pool of that name, each thing as
# its fields, in no order (Ruby's order is asked for by a case that reads it into a number).
#
# Included by test/all/vblank/dsl/test_plain_ruby_answers.rb, which holds the cases.
module RubyAnswers
  # Ruby's own `Array.new` with VBlank's `capacity:` taken off, while Stage runs a case: plain
  # Ruby grows an Array, and the setting only says how much room the console sets aside.
  module CapacityIgnored
    def new(*given, capacity: nil, **settings, &)
      return super(*given, **settings, &) unless Thread.current[:ruby_answers_stage]

      super(*given, &)
    end
  end
  Array.singleton_class.prepend(CapacityIgnored)

  # The game's verbs a case may use, as plain Ruby has them with nothing on screen and no button
  # down: a button is never pressed, drawing does nothing, and `func` and `call` keep and run a
  # block. `game_loop` runs its body once for each pass and keeps where it was written, which is
  # where the names a case reads are found.
  class Stage
    def initialize(passes)
      @passes = passes
      @funcs = {}
    end

    def game_loop(&body)
      @body = body
      @passes.times { body.call }
    end

    # What +name+ held when the last pass ended.
    def read(name) = @body.binding.local_variable_get(name)

    def pressed(*) = false
    def held(*) = false
    def screen(*, **) = nil
    def clear_screen(*) = nil
    def draw_rect_at(*) = nil
    def draw_number(*, **) = nil
    def draw_text(*, **) = nil
    def func(name, &body) = @funcs[name] = body
    def call(name) = @funcs.fetch(name).call
  end

  # The case named +name+ answers as Ruby does after +passes+ passes, for each of +reads+.
  private def agrees(name, reads:, passes: 2, &game)
    ruby = ruby_answers(passes, reads, &game)
    played = played_game(passes, &game)
    differences = reads.filter_map do |read|
      got = game_answer(played, read, ruby.fetch(read))
      "#{read}: Ruby #{ruby.fetch(read).inspect}, the game #{got.inspect}" unless got == comparable(ruby.fetch(read))
    end
    assert_empty differences, "#{name}: the game does not answer as Ruby does"
  end

  # The case named +name+ is a known gap, written in +gap+ (what the open work on it is called):
  # today the game answers otherwise than Ruby, or stops. When it answers as Ruby does, the case
  # fails saying so, and it moves to #agrees.
  private def known_gap(name, gap:, reads:, passes: 2, &game)
    ruby = ruby_answers(passes, reads, &game)
    agree = begin
      played = played_game(passes, &game)
      reads.all? { |read| game_answer(played, read, ruby.fetch(read)) == comparable(ruby.fetch(read)) }
    rescue StandardError
      false
    end
    refute agree, "#{name}: the game now answers as Ruby does, so \"#{gap}\" is done for it. Make it an `agrees` case."
  end

  # The case named +name+ is refused while it builds, with a friendly error holding +phrase+,
  # never a raw Ruby error, and in words that name no verb plain Ruby never writes.
  private def refused(name, phrase, &game)
    error = assert_raises(StandardError, "#{name}: built, and it must be refused") { built_program(&game) }
    refute RAW_ERRORS.any? { |raw| error.is_a?(raw) }, "#{name}: stopped with a raw Ruby error: #{error.class}: #{error.message}"
    assert_match phrase, error.message, "#{name}: refused in other words"
    refute_match INTERNAL_VERBS, error.message, "#{name}: refused in words that name a verb plain Ruby never writes"
  end

  # The verbs plain Ruby is turned into, which its refusals never name.
  INTERNAL_VERBS = /\b(?:list|pool) :/

  # The case named +name+ builds, and stops the game as it plays with words holding +phrase+:
  # what Ruby would do there, the console cannot (an Array grown past its room).
  private def stops(name, phrase, passes: 2, &game)
    error = assert_raises(VBlank::IR::ProgramError, "#{name}: played on, and it must stop") { played_game(passes, &game) }
    assert_match phrase, error.message, "#{name}: stopped in other words"
  end

  # Errors Ruby raises by itself, which a friendly refusal never is.
  RAW_ERRORS = [NoMethodError, NameError, TypeError, ZeroDivisionError, FrozenError, KeyError, LocalJumpError].freeze

  private def ruby_answers(passes, reads, &game)
    stage = Stage.new(passes)
    Thread.current[:ruby_answers_stage] = true
    # Plain Ruby, with no game being built: a builder an earlier test made by hand on this thread
    # would take the parts' instance variables for game code's, and a part's Array is Ruby's.
    begin
      VBlank::Builder::Session.running_as_plain_ruby { stage.instance_eval(&game) }
    ensure
      Thread.current[:ruby_answers_stage] = nil
    end
    reads.to_h { |read| [read, stage.read(read)] }
  end

  # Built as a game is built (Cartridge::EvaluatedGame), which may build it again where game code
  # read an instance variable before changing it. A build also stops on a number worked out and
  # dropped, which only the build itself is told of (VBlank.build), so it is asked here too: a
  # case a test player plays and a real game file's build stops on would otherwise pass.
  private def built_program(&game)
    evaluated = VBlank::Cartridge::EvaluatedGame.new(VBlank::DSL::PlainRuby.rewrite(game, checked: false))
    program = evaluated.program
    dropped = VBlank::IR::Guardrails::Checks::OrphanedExpression.new(evaluated.expressions).detect(program)
    raise VBlank::BuildError, dropped.map(&:message).join("\n") unless dropped.empty?

    program
  end

  # The game played for +passes+ passes: the interpreter starts its first pass in the first frame.
  private def played_game(passes, &game)
    game_player.run(built_program(&game), frames: passes)
  end

  # What +player+ holds for the name +read+, whose Ruby answer is +ruby+.
  private def game_answer(player, read, ruby)
    case ruby
    when Array
      return player.list(read) unless ruby.first.is_a?(Struct)

      fields = ruby.first.members.map { |field| player.pool(read, field) }
      fields.transpose.reject { |thing| thing.first.nil? }.sort
    else player[read]
    end
  end

  # A Ruby answer as the game's is compared with it: an Array of Structs as each thing's fields, sorted.
  private def comparable(answer)
    return answer.map(&:to_a).sort if answer.is_a?(Array) && answer.first.is_a?(Struct)

    answer
  end
end
