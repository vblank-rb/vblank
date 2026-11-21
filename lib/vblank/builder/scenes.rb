# frozen_string_literal: true

module VBlank
  class Builder
    # Routines and scenes
    #
    # A `func` is a named routine, and `call` runs it. A `scene` is a routine for one state of the
    # game, such as the title screen, the play and the game over, and `call` runs it too. Names
    # are resolved when the game is built, so a routine can be called before the line that
    # defines it.
    #
    # ```ruby
    # func(:reset_ball) { ball_x = 120; ball_y = 80 }
    # scene(:title) { draw_text "PRESS START", :center, 80, :white }
    # mode = var :mode, :title
    # game_loop do
    #   call mode
    #   call :reset_ball if pressed(:select)
    # end
    # ```
    #--
    # Deferred func bodies are emitted, and their call/case targets verified, by the
    # builder's finalize step (finalize_program). That orchestration crosses concerns, so it
    # stays in the core; these are the verbs that feed it. A concern of Builder, mixed in so
    # these stay flat DSL verbs.
    #++
    module Scenes
      # Defines a named routine that the game can call.
      #
      # The block is stored and built after the main block, so the order of `func` and `call`
      # lines does not matter.
      #
      # ```ruby
      # func(:add_score) { score += 10 }
      # call :add_score
      # ```
      #
      # * `name` - the routine's name, as a symbol.
      # * `fast:` - where the routine is kept. The console has a small amount of very quick memory
      #   and a much larger, slower cartridge, and code runs about two and a half times faster
      #   from the quick one. The framework picks the routines a frame spends the most time in,
      #   so you can leave this alone. Write `fast: true` to insist on a routine it did not pick,
      #   or `fast: false` to keep one out. `rom.profile` says what it chose.
      # * `on_chip:` - for a Super Nintendo cartridge with a Super FX (`variants: { snes:
      #   :superfx }`): `true` runs the routine on that chip, several times quicker, while the
      #   console waits for it. It can do sums, fractions, `if`, loops, tables, a list's items by
      #   index and calls of other `on_chip` routines. Anything else in it, such as a drawing or
      #   a scene change, stops the build and says so. On every other cartridge it changes nothing.
      #--
      # See VBlank.build's `fast_code:` to turn the choosing off altogether.
      #++
      def func(name, fast: nil, on_chip: nil, &block)
        declare_func(name, fast: fast, on_chip: on_chip, wrote: "func :#{name}", &block)
      end

      # The names of the routines declared so far, scenes' among them. Asked by the build of an
      # unpacking routine, to tell which routines each of its parts declared
      # (Original::PartPrograms).
      # Asked by the build of a data pack's unpacking, to tell which routines each part declared (Original::PartPrograms).
      def declared_function_names = @functions.keys  # :nodoc:

      # Runs a named routine, a `func` or a `scene`.
      #
      # The routine can be defined before or after this line. There are three ways to name it:
      #
      # * A name: `call :reset_ball`.
      # * A variable that holds a name, which runs the routine that name picks. The routines are
      #   the names that variable can hold.
      # * A list of names with `number:`, which runs the one that number picks, counting from 0.
      #   Use it where a number already decides what happens next, such as a script's
      #   instructions or the move an enemy picked. It goes straight to the routine, so a list of
      #   a hundred costs what a list of two does. A number below 0 or past the end calls nothing.
      #
      # ```ruby
      # mode = var :mode, :title        # a variable that holds one of a set of names
      # game_loop { call mode }         # runs :title, :playing or :over
      # mode = :playing if pressed(:start)
      #
      # HANDLERS = %i[op_end op_wait op_walk op_say]
      # scripts.each { |s| call HANDLERS, number: s.opcode }
      # ```
      #
      # * `name` - a routine's name, a list of names, or a variable that holds a name.
      # * `number:` - which of the list to call. Give it only with a list.
      #--
      # The target is resolved by name when the tree is lowered. Which names a variable can hold
      # is known only once the whole program is built, so that list is gathered at the end
      # rather than where `call` was written.
      #++
      def call(name, number: nil)
        return call_by_name(name, number) if name.is_a?(DSL::Value)
        return call_one_of(name, number) if name.is_a?(Array)

        unless number.nil?
          raise ArgumentError,
                "`call :#{name}` was given `number:`, but it calls one routine. `number:` picks one " \
                "routine from a list. To pick one, give a list: `call [:#{name}, :other], number: ...`."
        end
        record(Build.call(name))
      end

      # Asks for a listing of the machine code of a routine, printed after the game is built.
      #
      # Write it anywhere in the game. It works for both `func` and `scene` names, and is for
      # finding out what a routine costs or why it misbehaves.
      #
      # ```ruby
      # func(:update_cpu) { cpu_center = cpu_y + PADDLE_H / 2 }
      # dump_func :update_cpu
      # ```
      #
      # * `name` - the routine's or scene's name, as a symbol.
      def dump_func(name)
        @dump_requests << name
      end

      # Defines a scene: a named routine for one state of the game, such as the title, the play or
      # the game over.
      #
      # Run a scene with `call`. A scene has its own sprites, text and pictures, which are hidden
      # while it is not the one running.
      #
      # ```ruby
      # scene :title do
      #   draw_text "PRESS START", :center, 80, :white
      # end
      # ```
      #
      # * `name` - the scene's name, as a symbol.
      # * `fast:` - the same as for `func`. It also covers the routine the build makes to write
      #   the scene's moving sprites: `false` keeps both in the cartridge, `true` insists on both.
      # * `loads_first:` - `true` gives the scene the pass it takes over on to put its pictures
      #   up, which is its scenery and its sprites, and starts its own work on the pass after. A
      #   scene with a lot of art otherwise copies it on the same pass as its first pass of game,
      #   and the two can run past the end of the frame. It is always exactly one pass.
      # * `measure_holding:` - what a build that measures the game presses while it measures this
      #   scene, to choose what goes in the console's quick memory: buttons held down the whole
      #   time (`%i[up b]`), or a tape (`Playthroughs::Tape.read("fight.tape")`) whose presses are
      #   played round and round. Measured with nothing pressed, a scene stands still, and a
      #   routine that only a press runs, such as a fight or a shot, is left in the cartridge
      #   however much a real game runs it. Nothing the scene does changes.
      #--
      # Internally the routine is prefixed with `_scene_` to avoid clashing with func names.
      #++
      def scene(name, fast: nil, loads_first: false, measure_holding: nil, &block)
        refuse_scene_in_layer!
        unless [true, false].include?(loads_first)
          raise ArgumentError, "`scene :#{name}` was given `loads_first: #{loads_first.inspect}`. " \
                               "`loads_first:` must be true or false. To fix this, write " \
                               "`loads_first: true`, or remove it."
        end
        @scene_loads_first[:"_scene_#{name}"] = true if loads_first
        @scene_measure_holding[:"_scene_#{name}"] = measured_frames(name, measure_holding) unless measure_holding.nil?
        (@scene_routines ||= {})[:"_scene_#{name}"] = name # each scene's own size of screen is told by its routine (Drawing)
        declare_func(:"_scene_#{name}", fast: fast, &block)
      end

      # What +given+ to `measure_holding:` presses, as a list of frames, each the buttons down on
      # it: buttons held are one frame that goes round, and a tape is its frames. A build only
      # measures a game on the Game Boy Advance, so the buttons are the Advance's.
      private def measured_frames(name, given)
        return frames_of_tape(name, given) if given.is_a?(Playthroughs::Tape)

        buttons = Array(given)
        unless !buttons.empty? && buttons.all?(Symbol)
          raise ArgumentError, "`scene :#{name}` was given `measure_holding: #{given.inspect}`. " \
                               "`measure_holding:` must be a list of buttons, such as `%i[up b]`, or a tape. " \
                               "To fix this, write the buttons to hold, or a tape from " \
                               "`VBlank::Playthroughs::Tape.read`."
        end
        unknown = buttons - Console::ADVANCE.buttons
        unless unknown.empty?
          raise ArgumentError, "`scene :#{name}` was given `measure_holding:` with #{unknown.first.inspect}. " \
                               "A build measures the game on the Game Boy Advance, and its buttons are " \
                               "#{Console::ADVANCE.buttons.map(&:inspect).join(', ')}. To fix this, use those buttons."
        end
        [buttons.uniq]
      end

      private def frames_of_tape(name, tape)
        tape.refuse_seed_frame_by_frame!("measuring a scene")
        if tape.in_passes
          raise ArgumentError, "`scene :#{name}` was given `measure_holding:` with a tape that counts passes. " \
                               "The build measures a scene frame by frame. To fix this, give a tape that counts frames."
        end
        if tape.frames.zero?
          raise ArgumentError, "`scene :#{name}` was given `measure_holding:` with a tape of no frames. " \
                               "To fix this, give a tape that presses something."
        end
        tape.presses_within(1..tape.frames).flat_map { |stretch| Array.new(stretch.frames.size, stretch.buttons) }
      end

      # Runs the scene that matches the value of a variable.
      #
      # The block lists the matches with `when_val`, each a value and the name of a scene.
      #
      # ```ruby
      # case_var :state do
      #   when_val 0, :title
      #   when_val 1, :playing
      # end
      # ```
      #
      # * `var_name` - the variable that holds the state, as a symbol.
      #--
      # Evaluates the block in a CaseContext to collect the when_val clauses, then records one
      # case node dispatching on the variable. Its targets are the scene routines (each scene is
      # a func named _scene_<name>).
      #++
      def case_var(var_name, &block)
        ctx = CaseContext.new
        ctx.instance_eval(&block)

        ensure_var(var_name)
        clauses = ctx.cases.map { |value, raw_name| [value, :"_scene_#{raw_name}"] }
        record(Build.case_(var_name, clauses))
      end

      # Collector for case_var clauses.
      class CaseContext
        attr_reader :cases

        def initialize
          @cases = []
        end

        # Map a value to a scene/function name.
        def when_val(value, scene_name)
          @cases << [value, scene_name]
        end
      end

      private

      # Call the routine whose name +value+ holds. The routines are that value's own names, and
      # the last of them is not known yet — a name first used further down the program is one
      # of them too — so the dispatch is recorded now and its list filled in at finalize.
      def call_by_name(value, number)
        unless number.nil?
          raise ArgumentError,
                "`call` was given a value and `number:`. The value already says which routine " \
                "to call. To fix this, remove `number:`."
        end
        held = value.names or raise ArgumentError, no_names_message(value)

        node = Build.call_one_of([], which: value.node)
        @name_dispatches << [node, held]
        record(node)
      end

      # A value that holds plain numbers cannot name a routine. Say what to write instead,
      # which is the list form — the number is then a place in a list you give.
      def no_names_message(value)
        wrote = value.name ? "the variable :#{value.name}" : "a value"
        "`call` was given #{wrote}, which holds numbers, not names. A value names a routine " \
          "only when it was declared with a name, like `var :mode, :title`. To call one of " \
          "several routines by a number instead, give the list: `call [:first, :second], " \
          "number: ...`."
      end

      # Call whichever of +names+ the +number+ picks. A number written into the program
      # picks while building, so it is a plain call; one the game works out picks as it runs.
      def call_one_of(names, number)
        refuse_bad_routine_list!(names, number)
        fixed = DSL::Value.fixed_number(number)
        if fixed
          number_in_list!(names, fixed)
          return record(Build.call(names.fetch(fixed)))
        end

        record(Build.call_one_of(names, which: DSL::Value.node_for(number)))
        ensure_var(number)
      end

      def refuse_bad_routine_list!(names, number)
        raise ArgumentError, "`call` was given an empty list of routines. Name at least one routine." if names.empty?

        if number.nil?
          raise ArgumentError,
                "`call` was given a list of #{names.length} routines and no number to pick one. To fix " \
                "this, add `number:`, like `call [:#{names.first}, ...], number: which`."
        end
        stray = names.index { |name| !name.is_a?(Symbol) }
        if stray
          raise ArgumentError,
                "`call` was given #{names[stray].inspect} in its list of routines. Each item in the list " \
                "must be the name of a routine, like `:#{names.grep(Symbol).first || 'op_walk'}`."
        end
        return unless DSL::Fraction.bits_of(number)

        raise ArgumentError,
              "`call` picks a routine by a whole number, and the number given to `number:` holds a " \
              "fraction. To fix this, use `.to_i` to drop the fraction."
      end

      def number_in_list!(names, fixed)
        return if fixed.between?(0, names.length - 1)

        raise ArgumentError,
              "`call` was given `number: #{fixed}`, but the list has #{names.length} routines, numbered " \
              "0 to #{names.length - 1}. To fix this, give a number from 0 to #{names.length - 1}."
      end

      # Register a routine's body. Every routine goes through here — an author's `func`,
      # an author's `once_a_frame`, and the ones the framework declares for itself (an
      # effect's per-frame body, a hidden helper).
      #
      # A body is built later, at finalize, when the `layer` block it was written inside
      # has long since closed. So anything in it that wants a depth would quietly get
      # none, and this is where the layer in force is remembered so that can be refused
      # when it actually happens (see Layers#refuse_deferred_layer!). Remembering rather
      # than refusing here is what lets `pulse coin` be written on the line after the
      # coin, inside the layer block: a pack's per-frame body is behavior and declares
      # nothing with a depth, so it never trips the rule. +wrote+ is what the author
      # typed, for that message; the framework's own routines leave it alone and are
      # never the subject of one.
      def declare_func(name, fast: nil, on_chip: nil, wrote: nil, &block)
        raise ArgumentError, "The function :#{name} is already defined. Use a different name for each function." if @functions.key?(name)

        @functions[name] = block
        # A routine written while another's body is built (a `once_a_frame`, an `each_pass` or a
        # `func` inside a scene's block) is built later, on its own, and is laid out on the screen
        # the body it was written in was laid out on: a scene's own size (Drawing#apply_scene_screen_size!).
        (@routine_screens ||= {})[name] = @console if @building_routine
        @func_fast[name] = fast unless fast.nil?
        @func_on_chip[name] = true if on_chip
        @routine_layer[name] = [@current_layer, wrote] if @current_layer && wrote
        remember_part_owners_of_routine(name)
      end

      # Every routine a call can reach must be a defined function. Check that here, so
      # a missing target surfaces as a clear error at build time. Walking the whole
      # tree (not just statement children) reaches targets nested in else-branches.
      def verify_targets_defined!
        @program.walk { |node| node.callees.each { |target| check_target_defined!(target) } }
      end

      def check_target_defined!(name)
        return if @functions.key?(name)

        raise ArgumentError,
              "The function :#{name} is called but never defined. To fix this, define it with " \
              "`func :#{name} do ... end`. Or correct the name in the call."
      end
    end
  end
end
