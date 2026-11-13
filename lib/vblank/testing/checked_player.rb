# frozen_string_literal: true

module VBlank
  module Testing
    # A checked run's disagreement with the interpreter reported as a failed test rather than as
    # an error, the way every other check in a suite fails.
    module DisagreementFailsTest
      def run(program, max_steps: nil, frames: nil)
        super
      rescue IR::Backends::RunComparison::Disagreement => e
        raise Minitest::Assertion, e.message
      end
    end

    # A GAME ITS CONSOLE'S BUILD REFUSES IS NOT PLAYED on a run that plays games built for another
    # machine. A build checks a game before it makes anything (VBlank.build, through
    # IR::ProgramChecks): a game number handed to a verb that takes only a written one, a sprite too
    # many on a row, more colour lists than the console holds, a recording looped on a console that
    # cannot loop one, a tiled screen with nothing on it. A checked run plays a test's program without
    # that build, so without this it would play, and pass, a game the console's own cartridge never
    # runs, or fail far down its lowering. The checks are the ones every build runs, from the same
    # place (IR::ProgramChecks, with Guardrails.default_checks), on the program as the run plays it,
    # so they ask the run's console, and a refusal is the build's own Guardrails::ValidationError in
    # the build's own words. What a build learns from running the game's block (a test that is never
    # used, an `estimate:`) is not in a program, so it is not asked.
    #
    # The interpreter's own run (InterpreterPlayer) asks only the first half, that the program is
    # one any build can be made from (::refuse_malformed!). The guardrails it does not ask: it is the
    # answer key for a game a console plays, and a game its console refuses is not one, so there is
    # nothing to compare.
    #
    # A PORT'S UNPACKING IS NOT CHECKED either (IR::Nodes::Program#for_unpacking). It runs only on a
    # computer, in a shell or as a build makes its pack, and no build checks it against the console's
    # limits: a shell builds it for the game's console, so its screen and clock are that console's,
    # but its pack can be bigger than a cartridge's work memory. Every shell plays it unchecked
    # (Original::Shell.build checks only the game), so a test plays it as a shell does.
    #
    # One more program is played without them: the conformance fixture, which holds every kind of step
    # the IR has in one program so that each lowering is seen to write every one. No build accepts
    # it (a light beside a painted screen, a fade held to a box beside a light), and it is no game,
    # so its test plays it inside ::without_checks.
    module BuildChecks
      LEFT_OUT = :vblank_build_checks_left_out

      def self.refuse_unbuildable!(program)
        return unless checked?(program)

        IR::ProgramChecks.findings_for!(program).raise_on_error!
      end

      # The proof alone, that +program+ is a tree any build can be made from.
      def self.refuse_malformed!(program)
        IR::ProgramChecks.refuse_malformed!(program) if checked?(program)
      end

      # Whether +program+ is a game a build checks, played outside ::without_checks.
      def self.checked?(program) = !Thread.current[LEFT_OUT] && program.kind == :program && !program.for_unpacking
      private_class_method :checked?

      # The block, with no program it plays checked as a build checks one.
      def self.without_checks
        Thread.current[LEFT_OUT] = true
        yield
      ensure
        Thread.current[LEFT_OUT] = nil
      end
    end

    # What a test's player is on the GBA lowering's run: the interpreter, refusing first a program
    # no build can be made from, as every other run's player does (BuildChecks::refuse_malformed!).
    # Without it a slip the build names in plain words would play on here unseen and fail only on
    # the other runs.
    class InterpreterPlayer < IR::Backends::Reference
      def run(program, max_steps: nil, frames: nil)
        BuildChecks.refuse_malformed!(program)
        super
      end
    end

    # A runtime's player plays a program that names no console as one for the run's console
    # (Testing.console): the Advance, or whichever CONSOLE names. The runtime is built for that
    # console's screen and clock, and the interpreter it is checked against reads the same one.
    module PlaysRunConsole
      def self.included(player) = player.extend(ClassMethods)

      module ClassMethods
        def program_played(program)
          return program unless program.kind == :program && program.console.nil?

          program.copy.tap { |copy| copy.console = Testing.console }
        end
      end

      def run(program, max_steps: nil, frames: nil)
        played = self.class.program_played(program)
        BuildChecks.refuse_unbuildable!(played)
        refuse_recordings_without_clock!(played)
        super(played, max_steps: max_steps, frames: frames)
      end

      private

      # A console with nothing yet to clock a recording by (Console::Description#sample_clock?) cannot
      # answer for a game that plays one, so neither can the interpreter it is checked against.
      def refuse_recordings_without_clock!(program)
        return unless program.kind == :program && IR::Mixing.mixes?(program)

        console = program.described_console
        raise MissingFeature, "#{console.title} build does not make yet: recordings" unless console.sample_clock?
      end
    end

    # A PORT'S UNPACKING PLAYED AS C IS ALSO PLAYED AS A BUILD PLAYS IT: optimised, to its end, with
    # nobody watching (Original::Unpacking#run_as_c, IR::Backends::Native::FinalStateRun), and what it
    # left is held to what the checked run ended on, every variable and every list, byte for byte. The
    # checked run holds the C to the interpreter frame by frame, so every unpacking a test plays on the
    # native run holds the build's fast C run to the interpreter too.
    #
    # Must be mixed into a Computer::HeadlessRun: it reads the run's #vars and its private
    # #list_items, the variables and lists the checked run ended on.
    module UnpackingPlayedToItsEnd
      def hand_file(bytes)
        @unpacking_copy = bytes
        super
      end

      def run(program, max_steps: nil, frames: nil)
        super.tap do
          refuse_final_state_mismatch!(self.class.program_played(program), frames) if program.kind == :program && program.for_unpacking
        end
      end

      private

      def refuse_final_state_mismatch!(program, frames)
        ended = IR::Backends::Native::FinalStateRun.new(stuck_after: Original::Unpacking::SECONDS_WITHOUT_FRAME)
                                                   .run(program, frames: frames || IR::Backends::Reference::DEFAULT_FRAMES,
                                                                 file: @unpacking_copy)
        played = Original::Unpacking::PackedRun.new(vars: ended.vars, lists: ended.lists, runner: :c)
        mismatch = variable_mismatch(played) || list_mismatch(played)
        return unless mismatch

        raise Minitest::Assertion, "The unpacking played to its end as a build plays it (Original::Unpacking#run_as_c) " \
                                   "did not end as the checked run did: #{mismatch}."
      end

      # The first variable +played+ ended on another number than the checked run, in words, or nil.
      def variable_mismatch(played)
        name, value = played.vars.find { |named, number| vars.fetch(named, 0) != number }
        name && "variable #{name} is #{value}, and the checked run ended with #{vars.fetch(name, 0)}"
      end

      # The first list +played+ ended holding other numbers than the checked run, in words, or nil.
      def list_mismatch(played)
        played.lists.each_key do |name|
          numbers = played.list(name)
          checked = list_items(name) || []
          next if numbers == checked

          at = (0...[numbers.length, checked.length].max).find { |place| numbers[place] != checked[place] }
          return "list #{name} holds #{numbers[at].inspect} at #{at}, and the checked run's holds #{checked[at].inspect}"
        end
        nil
      end
    end

    # What a test's player is on the native lowering's run: the game played as C and checked
    # against the interpreter on every frame (Computer::Check says what it compares).
    class CheckedPlayer < IR::Backends::Native::CheckedRun
      include DisagreementFailsTest
      include PlaysRunConsole
      include UnpackingPlayedToItsEnd
    end

    # The same, on the JavaScript lowering's run: the game played as JavaScript under node
    # (JS::CheckedRun), checked against the interpreter on every frame by the same check.
    class JSCheckedPlayer < IR::Backends::JS::CheckedRun
      include DisagreementFailsTest
      include PlaysRunConsole
    end

    # The same, on the Ruby lowering's run: the game played as Ruby (Ruby::CheckedRun), checked
    # against the interpreter on every frame by the same check. What its runtime cannot do yet is a
    # skip naming it, so the run's count of skips by reason says what is left to do.
    class RubyCheckedPlayer < IR::Backends::Ruby::CheckedRun
      include DisagreementFailsTest
      include PlaysRunConsole

      def run(program, max_steps: nil, frames: nil)
        super
      rescue IR::Backends::Ruby::RuntimeGap => e
        raise MissingFeature, gap_reason(e)
      end

      private

      def gap_reason(gap) = "Ruby's runtime does not have yet: #{gap.part}"
    end

    # The same, on the run of a console whose own cartridge is played — the Game Boy Color's, the
    # Super Nintendo's: the game built as that console's cartridge and played in the emulator (the
    # checked run its kit names, Console::CheckedKit#checked_run), checked against the interpreter
    # after every pass, each test's program played as a program for that console. One player
    # serves every such console, made from its kit (CartridgeCheckedPlayer.for).
    #
    # A test of what the console's hardware cannot do is not here to play at all: it lives with
    # the Advance's tests, which such a run never loads (test/console/gba in this
    # repository). What its build does not make yet is a skip naming the part (the picture, the
    # sound), when the lowering says so (IR::Backends::NotMadeYet), so the run's count of skips by
    # reason says what is left to make; any other refusal fails, since it is a fault. What the run
    # cannot answer of the cartridge is a skip too.
    module CartridgeCheckedPlayer
      include DisagreementFailsTest

      # The player class for the console named +console+, a subclass of its kit's checked run.
      def self.for(console) = PLAYERS.fetch(console)

      # What the class of a player answers: the console it plays a game as, and a program as it
      # plays it.
      module OfConsole
        attr_accessor :console

        # +program+ as this run plays it: one that names no console, as a program for this one.
        def program_played(program)
          return program unless program.kind == :program && program.console.nil?

          program.copy.tap { |copy| copy.console = console }
        end

        def inspect = "VBlank::Testing::CartridgeCheckedPlayer.for(#{console.inspect})"
        alias_method :to_s, :inspect
      end

      def run(program, max_steps: nil, frames: nil)
        program = self.class.program_played(program)
        BuildChecks.refuse_unbuildable!(program)
        super
      rescue IR::Backends::RunComparison::CannotAnswer => e
        raise MissingFeature, cannot_answer_reason(e.message)
      rescue IR::Backends::NotMadeYet => e
        raise MissingFeature, "#{kit.title} build does not make yet: #{e.part}"
      end

      private

      # The kit of the console this player plays as. A player's own, not its run's, since the
      # player says which console it is (OfConsole#console) whatever run it is made over.
      def kit = Console.for(self.class.console)

      # What the cartridge cannot answer yet, asked by a test before, during or after its run, a skip
      # too (CartridgeHeadlessRun#refuse_question!).
      def refuse_question!(message) = raise(MissingFeature, cannot_answer_reason(message))

      # The skip's reason for a refusal saying +message+: the question it names, or the whole message.
      def cannot_answer_reason(message) = "#{kit.title} cannot answer: #{message[/`(\w+\??)`/, 1] || message}"

      # One player class for each console whose kit names a checked run, made once as the library
      # loads.
      PLAYERS = Ractor.make_shareable(Console.kits.grep(Console::CheckedKit).to_h do |console_kit|
        player = Class.new(console_kit.checked_run) { include CartridgeCheckedPlayer }
        player.extend(OfConsole)
        player.console = console_kit.name
        [console_kit.name, player]
      end)
    end
  end
end
