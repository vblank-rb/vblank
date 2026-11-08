# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A CONSOLE'S OWN CARTRIDGE PLAYED IN THE EMULATOR, and then the same buttons, pass for pass,
      # played on the interpreter — stopping at the first pass the two disagree on, about any variable,
      # any list or pool, or any pixel. Every checked run makes the same comparison and says it in the
      # same words (RunComparison).
      #
      # A console's checked run is a kind of its headless run with this check included, so it takes
      # the interpreter's calls and answers every question the headless run answers, and a test written
      # against Reference.new can be handed one of these instead and play its game on the console with
      # nothing else changed:
      #
      #   run = VBlank::IR::Backends::Genesis::CheckedRun.new
      #   run.input_each_frame { |frame| frame < 30 ? [:right] : [] }.run(game.program, frames: 60)
      #   run[:x]
      #
      # The interpreter plays the program on the screen of the console it was built for, and the two
      # pictures are compared over that console's screen. What a console adds to the comparison is its
      # checked run's to give: #further_difference for its sound unit and save memory, #prepare_interpreter
      # for what the interpreter is told before it plays, #sounding_levels, #motor_of and #picture_check
      # for what a moment holds, and #moments_difference for what it says of them.
      module CartridgeCheck
        Moment = RunComparison::Moment

        # The cartridge and the interpreter disagreed. The message says the pass and everything that
        # differs there.
        Disagreement = RunComparison::Disagreement

        # What the class of a checked run answers: the comparisons, and what a difference calls the
        # cartridge's side.
        module Comparisons
          include RunComparison

          def lowered_side = "cartridge"
        end

        def self.included(run) = run.extend(Comparisons)

        def initialize(save: SaveImage.new)
          super
          @played = {}
        end

        def run(program, max_steps: nil, frames: nil)
          build_before_playing(program)
          frames ||= max_steps ? frames_within(program, max_steps) : Reference::DEFAULT_FRAMES
          refuse_endless_game_without_frames!(program)
          before = @save.dup # the interpreter starts from the save memory the cartridge started from
          super(program, frames: frames)
          width, height = screen.then { |picture| [picture.width, picture.height] }
          interpreted = play_on_interpreter(program, frames, width, height, before)
          difference = moments_difference(interpreted)
          difference ||= further_difference(program, before)
          raise Disagreement, "the #{kit.title} lowering and the interpreter disagree at #{difference}" if difference

          self
        end

        private

        # Each frame's buttons as they are sent, kept to play the same ones on the interpreter.
        def buttons_sent(frame) = (@played[frame] = super)

        # THE CARTRIDGE IS BUILT BEFORE THE INTERPRETER PLAYS A FRAME, so that what the build does not
        # make yet (NotMadeYet) is raised before a game it could never be held to is played. Any other
        # refusal is left for the cartridge's own run to make, after the interpreter has had its say:
        # a program the interpreter calls wrong is wrong in the interpreter's words.
        def build_before_playing(program)
          build(program)
        rescue NotMadeYet
          raise
        rescue StandardError
          nil
        end

        # The first moment the two sides differ at, in words, or nil.
        def moments_difference(interpreted) = self.class.first_difference(interpreted, moments)

        # What else the console's cartridge is held to the interpreter on, past the moments: the first
        # difference in words, or nil. +before+ is the save memory the run started from, and the
        # interpreter's log of sounds is @interpreter_sounds.
        def further_difference(_program, _before) = nil

        # What the interpreter is told before it plays, past what every console tells it.
        def prepare_interpreter(_interpreter) = nil

        # A game that never waits for the screen has no frames to count, so it is played on the
        # interpreter first, with the buttons held from power-on, to find whether it comes to an
        # end by itself: the cartridge keeps no count of its steps.
        def refuse_endless_game_without_frames!(program)
          return if program.walk.any? { |node| node.kind == :wait_vblank }
          return unless Reference.new(save: @save.dup).hold(*@held).run(program).stopped_at_budget?

          raise RunComparison::AsksTheInterpreter, "its step budget to stop a game that never waits for the screen"
        end

        # A step budget is played as the frames it covers: the interpreter plays the game first with the
        # test's buttons and stops at the frame boundary after the budget runs out, and the cartridge
        # then plays that many frames.
        def frames_within(program, max_steps)
          lead = Reference.new(save: @save.dup).hold(*@held).input_each_frame { |frame| scripted_buttons(frame) }
                          .run(program, max_steps: max_steps)
          return lead.frame unless lead.frame.zero? && lead.stopped_at_budget?

          raise RunComparison::AsksTheInterpreter, "its step budget to stop a game before it first waits for the screen"
        end

        # The interpreter is told how many frames each pass took on the cartridge, so whatever keeps
        # real time moves on by the same frames on both. It plays on +save+, which it leaves as the
        # save memory it ended with.
        def play_on_interpreter(program, frames, width, height, save)
          interpreter = Reference.new(save: save).hold(*@held)
          interpreted = []
          interpreter.frames_each_pass { |pass| frames_took(pass) }
          prepare_interpreter(interpreter)
          interpreter.input_each_frame { |frame| @played.fetch(frame, []) }
                     .each_vblank { |frame| interpreted << moment_of(interpreter, frame, width, height) }
                     .run(program, frames: frames)
          @interpreter_sounds = interpreter.audio.dup
          interpreted << moment_of(interpreter, :end, width, height)
        end

        def moment_of(interpreter, frame, width, height)
          Moment.new(frame: frame, variables: interpreter.vars.dup, picture: picture_check(interpreter.screen, width, height),
                     sounds: interpreter.audio.size, sprites: interpreter.sprites_by_depth,
                     collections: interpreter.game_state.except(:vars), sounding: sounding_levels(interpreter),
                     motor: motor_of(interpreter))
        end

        # The recordings sounding at a moment: none for a console whose build makes no sound.
        def sounding_levels(_run) = []

        # Whether the cartridge's motor runs at a moment: off on a console without one.
        def motor_of(_run) = false

        # The interpreter's picture over the cartridge's screen, as the cartridge's Moments hold it.
        def picture_check(screen, width, height) = RunComparison.picture_check(RunComparison.pixels_over(screen, width, height))
      end
    end
  end
end
