# frozen_string_literal: true

module VBlank
  class Builder
    # The game loop, repeats and timers
    #
    # A game is a loop: every pass reads the buttons, moves things and draws. `game_loop` is that
    # loop, and the framework waits for the screen to be ready at the top of every pass, so a pass
    # is one picture. Inside it, `every` and `after` run code on a beat or once after a delay,
    # `repeat` runs code a number of times, and `once_a_frame` keeps something going even when
    # the code that started it does not run.
    #
    # ```ruby
    # game_loop do
    #   every(30) { blink = 1 - blink }   # twice a second
    #   after(600) { mode = :attract }    # ten seconds in
    # end
    # ```
    #
    # A frame is one picture on screen, 60 a second. Wherever a verb takes a time, frames are the
    # default and `:seconds` is there for a person who thinks in time.
    #--
    # The hooks the Condition and Branch handles call back into
    # (record_conditional, record_else) are the builder's public seam and live in
    # the core, not here — these are just the verbs. A concern of Builder, mixed in so
    # these stay flat DSL verbs.
    #++
    module ControlFlow
      # Stops the game here: nothing after this line ever runs.
      #
      # Use it after drawing a picture that never changes.
      #
      # ```ruby
      # draw_text "THE END", :center, 80, :white
      # halt
      # ```
      def halt
        record(Build.halt)
      end

      # Stops building the game at this line, to find which line breaks the picture.
      #
      # Everything before it runs and everything after it is left out of the game. The build
      # prints a warning that it is there, so that it is not left in by mistake. Move it down
      # until the picture goes wrong.
      #
      # ```ruby
      # screen :bitmap
      # clear_screen :red       # does this show up?
      # debug_halt              # the game stops here
      # draw_text "HELLO"       # left out
      # game_loop { }           # left out
      # ```
      def debug_halt
        record(Build.halt) # the lowered ROM stops (branches to self) at this point
        @debug_halted = true
        throw :debug_halt
      end

      # True if debug_halt was called (used by VBlank.build to skip finalization steps).
      # Asked by VBlank.build to skip finalization after `debug_halt`; not a verb.
      def debug_halted?  # :nodoc:
        @debug_halted
      end

      # Waits until the screen is ready for the next picture.
      #
      # A `game_loop` already does this at the top of every pass, so you only write it outside
      # one, in a program that shows a picture on its own. Inside a `game_loop` it does nothing,
      # because two waits in a pass would run the game at half speed; the build tells you once
      # that it was left out.
      #--
      # Inside a game loop the wait records nothing: it is counted instead, and
      # Checks::DroppedFrameSync reports the count once. Outside a game loop nothing is pacing the
      # program, so the wait is emitted as written. Inside a normal Ruby `while` on a game test it
      # is emitted too: the loop's passes are not the game loop's, and the wait is what lets the
      # screen go on being drawn while it goes round.
      #++
      def wait_vblank
        return @dropped_syncs += 1 if @frame_sync == :auto && @has_paced_loop && !inside_game_while?

        emit_frame_boundary
      end

      # The frame boundary: wait for the vertical blank, then put this frame's picture
      # on screen. `game_loop` calls this at the top of every pass.
      #
      # The vertical blank is the one window each frame where changing the screen is
      # safe, so the repaint happens right after it. That's why a sprite needs no draw
      # call and why moving one is just changing its position — see {Sprite} and
      # Builder#sprite.
      #
      # The repaint is two passes over ALL sprites: erase every one from where it was,
      # THEN draw every one where it is now. If instead each sprite erased-and-drew
      # before the next, a sprite drawn first would capture the one behind it that
      # hadn't been erased yet — and smear a copy of it across the screen when it
      # later moved. Erasing everyone first means each captures clean background, so
      # sprites can overlap (a hero touching a coin) without leaving trails.
      #
      # THE TWO PASSES RUN IN OPPOSITE ORDERS, and that is not a detail. A sprite
      # remembers what was under it when it drew, so where two overlap the FRONT one's
      # memory holds the BACK one's pixels. Putting them back has to undo the drawing
      # exactly, front first — otherwise the front one's restore paints those borrowed
      # pixels over background the back one has already cleaned, and nothing repaints
      # them. The stale copy then sits there for the rest of the game.
      def emit_frame_boundary
        wait_node = record(Build.wait_vblank)
        # The two passes go straight after the wait, and are put there at finalize (see
        # Sprites#finalize_sprite_repaints): a sprite declared inside a scene is not known
        # yet, since a scene's body is built after this loop, and it has to take its place
        # in both passes among the ones that are. What IS settled here is which of the
        # sprites declared above the loop this boundary repaints — the ones declared by now.
        @sprite_repaints << [wait_node, @sprites.dup]
        # Hardware sprites need no erase pass — the console recomposites the whole
        # picture each frame — so it's one step: draw them all from their current
        # positions (later ones sit in front). Tiled-mode text/number glyphs are
        # hardware sprites too, drawn last so a HUD sits on top of the game.
        #
        # The list of objects to present is filled in at finalize (see
        # finalize_present_lists), not here: a scene declares its own sprites/HUD inside
        # its body, which is built after this loop, so they aren't in @hw_sprites/
        # @hud_objects yet. Presenting them all is safe because a scene-owned object is
        # hidden while its scene is inactive (its `active` gate); a program with no
        # objects drops this node at finalize.
        present_node = Build.present_objects([])
        record(present_node)
        @present_nodes << present_node
        # Every flipbook is stepped along its beat straight after this, so the next frame
        # shows the next picture. Which flipbooks there are isn't known yet either, for the
        # same reason, so those steps are put in at finalize too (see
        # #finalize_animation_steps).
        #
        # The scroll position of every background the game moves is written here too,
        # right after the wait. Which backgrounds those are isn't known yet, so this
        # only marks the spot (see Builder#finalize_background_scrolls).
        mark_frame_boundary(wait_node)
      end
      # Internal machinery, not something a game writes: `game_loop` calls it.
      private :emit_frame_boundary

      # Runs the block over and over for as long as the game is on: once for each picture shown.
      #
      # Put the game in it: read the buttons, move things, draw. At the top of every pass the
      # framework waits for the screen to be ready and shows the sprites and text where the game
      # left them, so a sprite needs no draw call; moving it is changing its position.
      #
      # ```ruby
      # game_loop do
      #   x += 1 if held(:right)
      #   draw_text "HELLO", x, 80, :white
      # end
      # ```
      #
      # Build the game with `frame_sync: :manual` to place `wait_vblank` yourself instead.
      #--
      # The block's statements become the loop body in the IR tree; the backend adds the jump back
      # to the top. The frame boundary is emit_frame_boundary: wait for the vertical blank, then
      # repaint every sprite in two passes (erase all, then draw all, in opposite orders so
      # overlapping sprites restore correctly) and write the scroll of every moving background.
      #++
      def game_loop(&block)
        # Remembered for the whole build, not just this block: a scene body is built
        # later (at finalize) and is still part of a paced program, so a wait written
        # inside a scene is redundant in the same way one written here is.
        @has_paced_loop = true if @frame_sync == :auto

        push_container(Build.loop_) do
          emit_frame_boundary if @frame_sync == :auto
          run_block(&block)
        end
      end

      # Runs a block a number of times, counting while the game runs.
      #
      # The block is given the turn it is on, from 0 up to one less than the count, so it can
      # drive a position or pick an item from a list.
      #
      # ```ruby
      # repeat(8) { |i| dma_fill_rect 119, i * 20 + 2, 2, 12, :gray }
      # ```
      #
      # It is the counterpart of Ruby's `8.times { |i| ... }`. Use `times` when the count is known
      # as you write the game. Use `repeat` when the game decides the count while it runs, such as
      # how many segments a snake has right now.
      #
      # * `count` - how many times to run the block: a number, a variable or a calculation.
      # * `stop_when:` - a test that ends the loop as soon as it holds, so `count` is the most
      #   turns it can take.
      # * `estimate:` - is not used any more. It changes nothing, and the build warns and names
      #   each line that still gives one.
      #--
      # `estimate:` is read by Builder#record_estimate_line.
      #++
      def repeat(count, stop_when: nil, estimate: nil, &block)
        raise ArgumentError, "repeat needs a block: repeat(n) { |i| ... }" unless block

        record_estimate_line(estimate)

        index = declare_loop_counter
        ensure_var(count)
        i = DSL::Value.new(self, Build.var_ref(index), name: index)
        # A Condition carries its own node; anything else is an ordinary value, where not-zero
        # means stop. Handing one here USES it, the same as branching on it with `if` — the
        # guardrail that catches a comparison nobody acted on must not call this one an orphan.
        leave =
          if stop_when.is_a?(DSL::Condition)
            consume_condition(stop_when)
            stop_when.node
          elsif !stop_when.nil?
            DSL::Value.node_for(stop_when)
          end
        # A test whose working out recorded statements (a read of the copy's check of its place)
        # runs them inside the loop, before it is asked on each round.
        test_statements = leave ? take_trailing_test_statements(leave) : []
        return repeat_rerunning_test_statements(count, index, i, leave, test_statements, &block) unless test_statements.empty?

        if leave
          inlined = inline_held_expressions(leave)
          # The test is now the copy, so the value given is used, not thrown away.
          forget_expression(stop_when) if stop_when.is_a?(DSL::Value) && !inlined.equal?(leave)
          leave = inlined
        end
        push_container(Build.repeat(DSL::Value.node_for(count), index, stop_when: leave)) do
          run_block(i, &block)
        end
      end

      # A hidden variable for a loop to count in, declared and named: a `repeat`'s, and the one a
      # step that stands for a loop is handed (IR save_load_list, save_store_list, list_pack).
      private def declare_loop_counter
        @repeat_seq += 1
        :"__repeat_#{@repeat_seq}".tap do |index|
          ensure_var(index)
          @unique_names << index
        end
      end

      # The console refreshes the screen ~59.73 times a second; like every game, we
      # count that as a round 60 frames per second. It's what lets a timer be given
      # in seconds — the unit a person actually thinks in — and turned into frames.
      FRAMES_PER_SECOND = 60  # :nodoc:

      # Runs the block again and again on a steady beat, such as a blinking prompt, a wave of
      # enemies or a repeating sound.
      #
      # The counter behind it is kept for you, so there is nothing to declare or reset. Write it
      # once inside your game loop.
      #
      # ```ruby
      # every(30) { blink = 1 }              # every 30 frames
      # every(0.5, :seconds) { blink = 1 }   # the same, given in seconds
      # ```
      #
      # * `n` - the time between runs. Frames must be a whole number; seconds can be a fraction.
      # * `unit` - `:frames` or `:seconds`.
      def every(n, unit = :frames, &block)
        counter = timer_counter!(:every, n, unit, block)
        # Build a first-class `every` node: the tree still reads "every N frames"
        # (which anything reading the tree reads directly), and each backend
        # turns it into the frame counter + compare. The counter itself is still
        # allocated and cleared at boot by timer_counter! above.
        push_container(Build.every(counter, to_frames(n, unit))) do
          run_block(&block)
        end
      end

      # Runs the block once after a delay, and never again.
      #
      # Use it for a timeout on a title screen, a "GO!" that clears itself or a scripted beat.
      # Write it inside your game loop.
      #
      # ```ruby
      # after(600) { state = 1 }             # 600 frames in
      # after(10, :seconds) { state = 1 }    # the same, given in seconds
      # ```
      #
      # * `n` - the delay. Frames must be a whole number; seconds can be a fraction.
      # * `unit` - `:frames` or `:seconds`.
      def after(n, unit = :frames, &block)
        counter = timer_counter!(:after, n, unit, block)
        # A first-class `after` node — the tree still reads "after N frames", and
        # each backend counts up only until the target so the body fires exactly
        # once. The counter is allocated and cleared at boot by timer_counter!.
        push_container(Build.after(counter, to_frames(n, unit))) do
          run_block(&block)
        end
      end

      # Runs a block once for every frame that passes, wherever the rest of the game's code goes.
      #
      # This differs from writing the code in your `game_loop` in two ways.
      #
      # The body of a game loop runs where you put it, so a branch can step over it and a scene
      # switch can run a different scene instead. A `once_a_frame` body always runs. That makes it
      # the home for an effect that keeps going after you set it off: a hit, a pickup or a lost
      # life starts it once, and it carries on every frame after that until it is finished.
      # `shake_screen` is built on this.
      #
      # ```ruby
      # fade = var :fade, 0
      # once_a_frame { fade -= 1 if fade > 0 }
      # ```
      #
      # It also keeps real time. A pass of the game loop is one frame when the game keeps up and
      # two when it does not, so code run once per pass slows down when the game does: a
      # half-second fade takes a second and a half. A `once_a_frame` body runs once for every frame
      # that really passed, so it takes as long as it is set to. Put movement in here and the
      # world keeps real time, and show it from the game loop:
      #
      # ```ruby
      # once_a_frame { hero.walk }   # the world, once per frame that really passed
      # game_loop    { draw_it_all } # showing it, once per pass
      # ```
      #
      # A program with no game loop has no frames, so nothing runs.
      #
      # * `name` - a name for the routine, if something has to find it later. It gets a hidden one
      #   if you give none.
      #
      # Returns the routine's name.
      #--
      # A very slow pass is capped, so a game can never be asked to catch up half a second inside
      # one already-late frame. These bodies run in the gap between frames, which on a screen the
      # display reads directly is also the only safe moment to DRAW. A body that only moves things
      # is fine there however long it takes; the risk belongs to drawing, and drawing too much for
      # that gap is already what the frame budget warns about wherever it is written. A game on the
      # tear-free screen has no deadline at all: it is writing to the page nobody is looking at.
      #++
      def once_a_frame(name = nil, &block)
        raise ArgumentError, "once_a_frame needs a block: once_a_frame { ... }" unless block

        @each_frame_seq += 1
        wrote = name ? "once_a_frame :#{name}" : "once_a_frame"
        name ||= :"__once_a_frame_body_#{@each_frame_seq}"
        declare_func(name, wrote: wrote, &block)
        @per_frame_routines << name
        name
      end

      # Reads how many frames the screen has shown since the power came on.
      #
      # The number can be read and not changed. It keeps real time the way `once_a_frame` does,
      # so a pass that took two frames adds two. Unlike anything the game loop counts, it also
      # counts the frames spent setting up before the first pass.
      #
      # That is what a screen held for an exact number of frames needs. Setting up takes longer
      # on some power-ons than others, so a hold counted in passes from the first one ends on a
      # different frame each time. Held until this reaches a number, it ends on that frame every
      # time.
      #
      # ```ruby
      # game_loop do
      #   show_title if frames_since_power_on >= 49
      # end
      # ```
      #
      # A game with no game loop shows no frames, so it reads 0.
      #--
      # Setting up takes longer when save memory never written is laid out from scratch the first
      # time, and longer in one build of a game than another.
      #++
      def frames_since_power_on
        ensure_var(IR::Frames::COUNT)
        DSL::Value.new(self, Build.var_ref(IR::Frames::COUNT))
      end

      # Makes a job that takes a step once every pass, from when the game starts it until the job
      # stops itself.
      #
      # The block is the step. It is given the job, so a step can stop its own job when it
      # arrives. Calling `each_pass :name` with no block gives back the job made under that name,
      # so that separate verbs can start and stop one job between them.
      #
      # ```ruby
      # each_pass(:closing) { |job| light.radius -= 4; job.stop if light.radius <= 0 }
      # each_pass(:closing).start
      # ```
      #
      # The steps after the first are taken straight after each gap between frames, once for the
      # pass about to run, however many frames the last one took.
      #
      # * `name` - the job's name, to ask for it again.
      #
      # Returns the job, which answers `start` and `stop`.
      def each_pass(name = nil, &block)
        return pass_job_named(name) unless block

        if name && @pass_jobs.key?(name)
          raise ArgumentError, "This game makes `each_pass :#{name}` twice. Each job has one step. To fix this, " \
                               "give the second job another name, or ask for the first with `each_pass :#{name}`."
        end

        number = @pass_jobs.size + 1
        routine = name ? :"__each_pass_#{name}" : :"__each_pass_#{number}"
        running = var(:"#{routine}_running", 0)
        stepping = var(:"#{routine}_stepping", 0)
        # A new game stops a job the last game left running.
        add_part_member(:var, running.name, framework: true)
        # Not saved: a load made half way through a step would start the job with its first step skipped.
        add_part_member(:var, stepping.name, framework: true, saved: false)
        job = DSL::PassJob.new(self, routine: routine, running: running, stepping: stepping)
        declare_func(routine, wrote: name ? "each_pass :#{name}" : "each_pass") do
          stepping = 1
          job.with_step_being_built { yield(job) }
          stepping = 0
        end
        declare_func(:"#{routine}_tick") { call routine if running == 1 }
        @per_pass_routines << :"#{routine}_tick"
        @pass_jobs[name || routine] = job
      end

      # Maps a comparison's name to the IR operator, for building an `if` node's condition (a
      # binop over the variable and the operand). The library's own code compares this way
      # (#emit_conditional); a game writes `if score > 5`.
      COND_TO_OP = {  # :nodoc:
        eq: :==, ne: :!=, gt: :>, lt: :<, ge: :>=, le: :<=,
      }.freeze

      # The low-level tests a game once wrote beside `if`, and the operator each stands for. Each
      # is kept private so that the refusal reaches a line in a game block, where it needs no
      # receiver, and says the plain `if` to write instead.
      LOW_LEVEL_TEST_OPERATORS = { if_eq: :==, if_ne: :!=, if_gt: :>, if_lt: :<, if_ge: :>=, if_le: :<=,  # :nodoc:
                                   if_gte: :>=, if_lte: :<= }.freeze

      # Written out as source rather than made from a block: a method made from a block carries
      # the block's surroundings with it, and Ruby will not let another Ractor call one. See
      # {IR::Node.operands}, which says the same thing at length.
      LOW_LEVEL_TEST_OPERATORS.each_key do |word|
        class_eval <<~REFUSAL, __FILE__, __LINE__ + 1
          def #{word}(var_name = nil, operand = nil, *, &)
            raise DSL::PlainRuby::Refused, low_level_test_message(:#{word}, var_name, operand)
          end
          private :#{word}
        REFUSAL
      end

      private

      # The refusal for `if_gt :score, 5`, naming `if score > 5`.
      def low_level_test_message(word, var_name, operand)
        sides = [var_name, operand].map { |side| DSL::ChangingWord.as_source_text(side) || "..." }
        DSL::ChangingWord.low_level_test_refusal(word, "if #{sides.join(" #{LOW_LEVEL_TEST_OPERATORS.fetch(word)} ")}",
                                                 at: Messages::AuthorSource.at_author_line)
      end

      # The job `each_pass :name` made, for `each_pass :name` with no block.
      def pass_job_named(name)
        raise ArgumentError, "`each_pass` needs a block, the step it takes once a pass: `each_pass(:walk) { ... }`." unless name

        @pass_jobs.fetch(name) do
          raise ArgumentError, "There is no `each_pass :#{name}` with a block in this game yet. To fix this, " \
                               "make the job with its step before you ask for it: `each_pass(:#{name}) { ... }`."
        end
      end

      # The statements that advance one flipbook a single frame: tick its hidden
      # counter, and once it reaches the sprite's rate, reset the counter and step to
      # the next frame, wrapping back to the first at the end. Plain counter + compare
      # logic, so every backend runs it and the animation is nothing but data.
      def advance_animation(anim)
        pose = anim[:pose]
        tick = anim[:tick]
        frames = anim_operand(anim[:frames]) # a fixed frame count, or a var (a named clip's length)
        rate = anim_operand(anim[:rate])     # a fixed rate, or a var (a named clip's rate)
        wrap = Build.if_(Build.binop(:>=, Build.var_ref(pose), frames),
                         Build.set(pose, Build.int(0)))
        step = Build.if_(Build.binop(:>=, Build.var_ref(tick), rate),
                         Build.set(tick, Build.int(0)),
                         Build.add(pose, Build.int(1)),
                         wrap)
        [Build.add(tick, Build.int(1)), step]
      end

      # One posed pool's beat: count the frame, and when the beat comes round put the
      # counter back and step every instance on. The step is a walk of the pool's slots,
      # set up where the pool was declared (Composition#register_pool_animation) and built
      # afresh for each place it goes, since a node belongs to one place in the tree.
      def advance_pool_animation(anim)
        step = Build.if_(Build.binop(:>=, Build.var_ref(anim[:tick]), Build.int(anim[:rate])),
                         Build.set(anim[:tick], Build.int(0)),
                         anim[:step].call)
        [Build.add(anim[:tick], Build.int(1)), step]
      end

      # STEP EVERY FLIPBOOK ALONG ITS BEAT, straight after each frame's sprites are drawn, so
      # the next frame shows the next picture: every animated sprite, and every posed pool —
      # which keeps one counter for the whole set and a frame per instance, so a frame that
      # is not a step costs one compare and a step walks the slots.
      #
      # IT HAS TO BE NOW rather than where the frame boundary was written. A scene declares
      # its own sprites and pools inside its body, and a scene's body is built after the game
      # loop that runs it — so stepped as the boundary was recorded, a flipbook declared in a
      # scene was not known yet and stood on its first picture for ever, with nothing to say
      # why. By here every body has been built.
      #
      # A flipbook is stepped whether or not its scene is up. It costs the same count and
      # compare either way, and one that kept time while nobody could see it is not a thing
      # a player can tell from one that did not.
      #
      # Called before #finalize_present_lists, which takes a frame's present node away when
      # the game has no sprites of the console's own to draw: that node is what marks where
      # in the frame this goes.
      def finalize_animation_steps
        return if @animations.empty? && @pool_animations.empty?

        @present_nodes.each do |present|
          container = present.parent
          at = container&.children&.index(present)
          next unless at

          steps = @animations.flat_map { |anim| advance_animation(anim) } +
                  @pool_animations.flat_map { |anim| advance_pool_animation(anim) }
          steps.each_with_index do |node, offset|
            container.children.insert(at + 1 + offset, node)
            node.parent = container
          end
        end
      end

      # An animation's frame-count or rate as a value node: a Symbol names a variable (a
      # named clip's runtime length, which `play` switches); an IR node is used as-is (a
      # per-frame duration looked up at run time); anything else is a fixed number.
      def anim_operand(value)
        case value
        when IR::Node then value
        when Symbol then Build.var_ref(value)
        else Build.int(value)
        end
      end

      # Record an `if` node comparing a variable against an operand, and gather the
      # block's statements into it.
      #
      # @param cond [Symbol] condition (:eq, :ne, :gt, :lt, :ge, :le)
      # @param var_name [Symbol] variable to compare
      # @param operand [Integer, Symbol] immediate value or variable name to compare against
      def emit_conditional(cond, var_name, operand, &block)
        condition = Build.binop(COND_TO_OP.fetch(cond), Build.var_ref(var_name), DSL::Value.node_for(operand))
        ensure_var(var_name)
        ensure_var(operand)

        push_container(Build.if_(condition)) do
          run_block(&block)
        end
      end

      # Validate a timer's interval, unit, and block, then allocate the hidden frame
      # counter it counts on. The counter is cleared at boot (console RAM isn't
      # reliably zero at power-on) so the first interval measures from frame zero.
      def timer_counter!(verb, n, unit, block)
        raise ArgumentError, "#{verb} needs a block: #{verb}(n) { ... }" unless block
        unless %i[frames seconds].include?(unit)
          raise ArgumentError, "#{verb}'s unit must be :frames or :seconds. You gave #{unit.inspect}."
        end
        # Frames are whole; seconds may be fractional (half a second is fine), but
        # either way the interval must come out to at least one frame.
        valid = unit == :frames ? n.is_a?(Integer) : n.is_a?(Numeric)
        refuse_game_number_for_timer!(verb, n, unit) unless valid
        unless valid && n.positive? && to_frames(n, unit).positive?
          raise ArgumentError, "#{verb} needs a positive number of #{unit}. You gave #{Messages::PlainWords.words_for_given(n)}."
        end

        @timer_seq += 1
        counter = :"__timer_#{@timer_seq}"
        ensure_var(counter)
        at_boot(Build.set(counter, Build.int(0)))
        add_part_member(:var, counter, framework: true) # a new game counts from nought again
        counter
      end

      # A timer's beat is counted while the game is built: its hidden counter is compared
      # against a number fixed in the cartridge. So a variable, or a number the game works out,
      # cannot be its beat, and the refusal names what the author wrote.
      def refuse_game_number_for_timer!(verb, n, unit)
        return unless Messages::PlainWords.game_number?(n)

        example = unit == :seconds ? "#{verb}(0.5, :seconds) { ... }" : "#{verb}(30) { ... }"
        raise ArgumentError,
              "#{verb} takes only a number of #{unit} that is written in the program, like `#{example}`. " \
              "You gave #{Messages::PlainWords.words_for_given(n)}. To fix this, write the number. " \
              "If the beat must change as the game runs, count the frames in a variable of your own."
      end

      # A timer interval in whole frames. Frames pass through; seconds convert at the
      # console's frame rate and round to the nearest whole frame.
      def to_frames(n, unit)
        unit == :seconds ? (n * FRAMES_PER_SECOND).round : n
      end
    end
  end
end
