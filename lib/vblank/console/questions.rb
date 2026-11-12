# frozen_string_literal: true

module VBlank
  module Console
    # WHAT A LINE OF A GAME ASKS OF THE CONSOLE IT RUNS ON: which verb's answer (Console::Answers)
    # has the words for it, what the line asks for in words of its own, and — for a verb that works
    # but has a part some consoles lack, the Color's `held` for a shoulder button it does not have —
    # whether this console has that part, read from its description.
    #
    # The question is the same for every console, so it is asked here once and every console's
    # answers read it: the build's checks before anything is made (Checks::ConsoleAnswers), and
    # each lowering, for a program handed to it straight, as a test's is (LoweringPlan). Nothing
    # else keeps a list of what a console refuses.
    #
    # It reads the steps of a program, which are the IR's, and is only asked once everything is
    # loaded, so the console module still needs nothing loaded before it.
    module Questions
      # +verb+ whose answer has the words, what the line asks for in +words+, and +can+: whether the
      # console has the part asked for, or nil where the verb's own answer decides.
      Question = Data.define(:verb, :words, :can)

      # A VERB WRITTEN IN OTHER VERBS leaves no step of its own: a `pulse` is a sprite's size walked
      # every frame, an iris is the game's light closing. The steps alone would have a console
      # answer for the verb underneath, in words about a sprite that resizes or a light, which is
      # not what the author wrote. So the program notes that the verb was written
      # (IR::Nodes::Program#verbs_written), and the question is asked of that verb's own answer.
      #
      # For each: what the game asks for in words, and the verb its steps are made of, whose
      # questions a refusal of this one stands in for (Answers#refusals).
      WrittenVerb = Data.define(:words, :made_of)
      WRITTEN_VERBS = Ractor.make_shareable({
        pulse: WrittenVerb.new("This game makes a sprite grow and shrink (`pulse`)", :sprite),
        iris_out: WrittenVerb.new("This game closes a circle on the screen (`iris_out`)", :spotlight),
        iris_in: WrittenVerb.new("This game opens a circle on the screen (`iris_in`)", :spotlight),
        iris_shut?: WrittenVerb.new("This game asks whether the circle has closed (`iris_shut?`)", :spotlight),
        pixelate_out: WrittenVerb.new("This game breaks the picture into blocks over time (`pixelate_out`)", :pixelate),
        pixelate_in: WrittenVerb.new("This game brings the picture back from blocks over time (`pixelate_in`)", :pixelate),
        instrument: WrittenVerb.new("This game has an instrument (`instrument`)", :sample)
      })

      module_function

      # The Question each verb +program+ (the program's own step) notes as written asks: of that
      # verb's own answer, which decides.
      def verb_questions(program)
        (program.verbs_written || []).filter_map do |verb|
          written = WRITTEN_VERBS[verb] or next
          Question.new(verb, written.words, nil)
        end
      end

      # The verb whose steps +verb+ is made of, or nil for a verb with steps of its own.
      def made_of(verb) = WRITTEN_VERBS[verb]&.made_of

      # The Question +node+ asks of +console+ (a Console::Description), or nil for a line that asks
      # for nothing a console could lack.
      def question_for(node, console)
        case node.kind
        when :raw then Question.new(:entry, "This line hands the Advance's processor raw instructions (`entry`)", nil)
        when :shade_outside then Question.new(:spotlight, "This game has a light (`spotlight`)", nil)
        when :sample, :play_sample then recording_question(node, console)
        when :pixelate then pixelate_question(node, console)
        when :clock then Question.new(:clock, "This line reads the clock (`clock`)", nil)
        when :draw_place then Question.new(:draw_place, "This line draws a place as a viewer sees it (`draw_place`)", nil)
        # ...and the fill under it, which a program built by hand can hold without a place
        when :fill_face then Question.new(:draw_place, "This line fills a face of a place (`draw_place`)", nil)
        when :set_clock then Question.new(:clock, "This line sets the clock (`clock.set_to`)", nil)
        # The layers' declaration, which every see-through layer is in: one whose amounts are
        # written in the program is told to the console once and has no step of its own. A
        # console that mixes only by half is asked no more here: its build says which amounts
        # it can show.
        when :layers
          unless node.see_through.empty?
            Question.new(:layers, "This game shows one layer through another (`transparency:`)",
                         console.blends || console.mixes_by_half)
          end
        # ...and the step that tells the console again how see-through a layer is, before each
        # frame, for an amount the game works out. Only a console that blends by any amount can.
        when :see_through
          Question.new(:layers, "This game changes how much one layer shows through another as the game runs",
                       console.blends || (console.mixes_by_half && node.added == true))
        when :set_tile
          if node.now
            Question.new(:status_bar, "This line shows a bar's cell on the frame being drawn (`now: true`)",
                         console.changes_cells_while_drawing)
          end
        when :held, :pressed then button_question(node, console)
        when :players_connected
          Question.new(:players_connected, "This line asks how many players are connected (`players_connected`)", nil)
        when :program
          most = node.most_players
          if most && most > 1
            Question.new(:held, "This game takes up to #{most} players (`players:`)", most <= console.controllers)
          end
        when :fade
          Question.new(:fade, "This line fades part of the screen", console.blends) if node.under || node.reaches
        when :background
          if node.above_row
            Question.new(:background, "This background shows only above a row (`above_row:`)", console.holds_background_above_row)
          end
        when :box_background
          Question.new(:background, "This line shows a background only inside a box (`show_only_inside`)",
                       !console.background_box.nil?)
        when :song
          if node.voices.any? { |part| part.events.any? { |event| IR::Tunes.glides?(event) } }
            Question.new(:songs, "This game has a recorded note that glides (`glides: true`)", console.glides_recordings)
          end
        when :affine_background
          Question.new(:background, "This line turns or resizes a background", console.turns_backgrounds?)
        when :screen
          if node.mode == :rotozoom
            Question.new(:screen, "This game has a turning screen (`screen :rotozoom`)", console.turns_backgrounds?)
          elsif node.pixel_size
            Question.new(:screen, "This game shows its pixels bigger (`pixel_size: #{node.pixel_size}`)",
                         console.shows_bigger_pixels)
          end
        when :object
          if turns?(node)
            Question.new(:sprite, "This sprite turns or resizes (`scale`, `face_angle`, `turn`, `pulse`)",
                         console.turning_sprites)
          end
        end
      end

      # A recording, and the part of playing one that only a console that mixes them can do
      # (Console::Description#mixes_recordings): one that plays them as recorded, a sample at a
      # time, has no way to shape one, since its loudness is all or nothing. Looping one, or
      # reading it at another note, it does by where and how fast it reads.
      def recording_question(node, console)
        if node.kind == :sample && node.envelope && !node.envelope.plain?
          Question.new(:sample, "This recording has a shape (`envelope:`)", console.mixes_recordings)
        else
          Question.new(:sample, "This game plays a recording", nil)
        end
      end

      # The screen in blocks, and the part of it a console whose blocks reach only its backgrounds
      # cannot do (Console::Description#sprites_in_blocks): the sprites in blocks too. A line that
      # leaves them as drawn (`sprites: false`) asks only what the verb's own answer decides.
      #
      # A line that puts a status bar in blocks too asks for blocks that start again at the bar's
      # top (Console::Description#blocks_start_at_split).
      def pixelate_question(node, console)
        if node.bar_in_blocks && console.blocks_start_at_split == false
          Question.new(:pixelate, "This line puts the status bar in blocks (`pixelate` with `status_bar: true`)", false)
        elsif node.keeps_sprites || console.sprites_in_blocks != false
          Question.new(:pixelate, "This line shows the screen in blocks (`pixelate`)", nil)
        else
          Question.new(:pixelate, "This line shows the sprites in blocks too (`pixelate` with no `sprites: false`)", false)
        end
      end

      # The button a line reads, and then the controller. `player: :any` asks nothing of a console
      # with one controller: that one is every controller it has, and every one connected.
      def button_question(node, console)
        has_button = button?(node.button, console)
        player = node.player
        if has_button && player.is_a?(Integer) && player > 1
          controller = player == 2 ? "the second controller" : "controller #{player}"
          return Question.new(:held, "This line reads #{controller} (`player: #{player}`)", player <= console.controllers)
        end

        Question.new(:held, "This line reads the #{node.button.inspect} button", has_button)
      end

      # Whether +console+ has the button +button+ names; any button at all, every console has.
      def button?(button, console) = button == IR::Buttons::ANY || console.buttons.include?(button)

      # A sprite turns or resizes when its angle or its size is anything but the one it is drawn
      # at: upright, as drawn (Build#object's defaults).
      def turns?(obj)
        !(obj.angle.kind == :int && obj.angle.value.zero? && obj.scale.kind == :int && obj.scale.value == IR::Build::SCALE_ONE)
      end
    end
  end
end
