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
      # * A Hash of numbers to names with `number:`, which runs the one whose key is that number.
      #   Build it in Ruby while the cartridge is made, where some routines are only in some
      #   builds or are made in a loop. A number that is no key calls nothing. Where every name
      #   is a scene, it picks the scene as a plain `case` on the number does. The number must
      #   then be a game variable. A scene can be picked by more than one key, and is up for
      #   each. The scenes can be declared above the `call` line or below it.
      #
      # ```ruby
      # mode = var :mode, :title        # a variable that holds one of a set of names
      # game_loop { call mode }         # runs :title, :playing or :over
      # mode = :playing if pressed(:start)
      #
      # HANDLERS = %i[op_end op_wait op_walk op_say]
      # scripts.each { |s| call HANDLERS, number: s.opcode }
      #
      # screens = { TITLE => :title, PLAY => :playing }
      # screens[LOGOS] = :logos if with_logos
      # game_loop { call screens, number: state }
      # ```
      #
      # * `name` - a routine's name, a list of names, a Hash of numbers to names, or a variable
      #   that holds a name.
      # * `number:` - which of the list or Hash to call. Give it only with a list or a Hash.
      #--
      # The target is resolved by name when the tree is lowered. Which names a variable can hold
      # is known only once the whole program is built, so that list is gathered at the end
      # rather than where `call` was written.
      #++
      def call(name, number: nil)
        return call_by_name(name, number) if name.is_a?(DSL::Value)
        return call_one_of(name, number) if name.is_a?(Array)
        return call_from_hash(name, number) if name.is_a?(Hash)

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

      private

      # Does a plain Ruby `case` pick scenes, so it can be the scene dispatch, one case node? The
      # rewrite of game code asks this of a `case` written as one (DSL::PlainRuby::Rewriter#
      # scene_dispatch_shape?), and builds the ordinary chain of tests where the answer is no.
      # +arms+ are `[[value, ...], name]`, one for each `when`.
      #
      # The subject must be a game variable that keeps a plain whole number, every value a whole
      # number, and every name a scene declared by now that no func shares. A working-out as the
      # subject stays a chain: the dispatch and everything that asks which scene is up (its
      # sprites, its scenery, what goes in the quick memory as it takes over) read one variable,
      # and a copy of the working-out made for it would be a second variable saying the same thing.
      # A `call` of a func stays a chain too: a routine named in a dispatch is taken for a scene.
      def scene_case?(subject, arms)
        return false unless scene_subject?(subject)

        arms.all? { |values, name| values.all?(Integer) && declared_scene?(name) }
      end

      # Can +subject+ pick a scene: a game variable's handle, the variable keeping a plain whole
      # number. A variable's name is not one: the Hash form looks the handle up first
      # (#scene_number_handle).
      def scene_subject?(subject)
        return false unless subject.is_a?(DSL::Value) && subject.node.kind == :var_ref

        !(subject.truth || subject.fraction? || subject.boolean? || subject.names)
      end

      # Records the dispatch for a `case` that #scene_case? said picks scenes. A value two arms
      # share runs the first, as in Ruby.
      def emit_scene_case(subject, arms)
        clauses = arms.flat_map { |values, name| values.map { |value| [value, name] } }.uniq(&:first)
        record(scene_case_node(subject.node.name, clauses, ScenePicker::CASE, Messages::AuthorSource.author_source))
        nil
      end

      # The case node picking the scenes of +clauses+ (`[value, scene name]`) by +variable+.
      # +picker+ and +source+ are what the author wrote and where, for a later message.
      def scene_case_node(variable, clauses, picker, source)
        ensure_var(variable)
        node = Build.case_(variable, clauses.map { |value, name| [value, :"_scene_#{name}"] })
        (@scene_case_sources ||= {}.compare_by_identity)[node] = [source, picker]
        node
      end

      # What picked the scenes of a dispatch, as an author's message names it: `the` for the
      # start of a sentence.
      ScenePicker = Data.define(:the)
      class ScenePicker
        CASE = new(the: "The `case`")
        HASH = new(the: "The Hash given to `call`")
      end

      #--
      # A plain `case` is made a scene dispatch when its line runs, and a Hash given to `call` when
      # its line runs or at the start of finalize, if every name it calls is a scene with no func
      # of that name then (#scene_case?, #resolve_hash_dispatches!). A func of one of those names
      # declared later would have been what `call` ran, so it is refused here, once every routine
      # is declared.
      #++
      def refuse_func_named_like_case_scene!
        (@scene_case_sources || {}).each do |node, (source, picker)|
          name = node.clauses.map { |_, target| target.to_s.delete_prefix("_scene_").to_sym }.find { |each| @functions.key?(each) }
          next unless name

          where = source ? " at #{source}" : ""
          raise ArgumentError, "#{picker.the}#{where} calls :#{name}, and :#{name} is both a scene and a func. " \
                               "It runs the scene, because the func is declared after it. To fix this, " \
                               "rename the func or the scene."
        end
      end

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

      # The most numbers a Hash given to `call` can span, first key to last: its table has a
      # slot for each, a word of the cartridge apiece on the Advance.
      MOST_HASH_SLOTS = 256

      # Call whichever of +routines+ (a Hash of whole numbers to names) the +number+ picks.
      # Where every name is a scene, it is the dispatch a plain `case` on the number records;
      # otherwise it is the call by number a list makes.
      #--
      # Which of the two it is waits for finalize (#resolve_hash_dispatches!) unless every name
      # is a scene already, since a scene or a func can be declared below the `call` line. The
      # placeholder recorded here is swapped for the real node then, in its place.
      #
      # The list is laid out as a table from the first key to the last, the gaps filled with a
      # routine that does nothing (#call_nothing_routine). Asked of the Advance, that dispatch is
      # the same few instructions however many keys there are (a load, a compare and a branch, a
      # load of the table and of its word, a call through it: Functions#emit_call_one_of), one
      # more to take the first key off where it is below 0, and a gap costs a word of the table.
      # Tests per key cost a load, a compare and a branch for each key on every call, and must
      # each be skipped once one has called, so a game picking among a dozen screens would ask a
      # dozen questions a pass. Keys from 0 up are read straight, so a Hash from 0 is the list.
      #++
      def call_from_hash(routines, number)
        refuse_bad_routine_hash!(routines, number)
        refuse_hash_number_past_keys!(routines, number)
        fixed = DSL::Value.fixed_number(number)
        return record(Build.call(routines.fetch(fixed))) if fixed

        ensure_var(number) unless number.is_a?(Symbol) # a name is looked up at finalize, once every variable is declared
        dispatch = HashDispatch.new(node: Build.call_one_of(routines.values, which: DSL::Value.node_for(number)),
                                    routines: routines.dup.freeze, number: number,
                                    source: Messages::AuthorSource.author_source)
        record(dispatch.node)
        all_scenes = !number.is_a?(Symbol) && routines.values.all? { |name| declared_scene?(name) }
        return resolve_hash_dispatch!(dispatch) if @hash_dispatches_resolved || all_scenes

        (@hash_dispatches ||= []) << dispatch
        nil
      end

      # A Hash given to `call` with a number the game works out, recorded as a placeholder
      # +node+ until it is known whether its names are scenes. +number+ is what `number:` was
      # given, a handle or a variable's name, and +source+ the line that wrote it.
      HashDispatch = Data.define(:node, :routines, :number, :source) do
        # " at file.rb:12", or nothing where the line is not known, for a message.
        def where = source ? " at #{source}" : ""
      end

      #--
      # Every routine the game declared outside a routine's body is declared by now, so each
      # Hash given to `call` is a scene dispatch or a call by number. A Hash written after this,
      # in a routine's body, is resolved as its line runs. Must run before the scene dispatches
      # are read (#scan_scene_gates).
      #++
      def resolve_hash_dispatches!
        @hash_dispatches_resolved = true
        (@hash_dispatches || []).each { |dispatch| resolve_hash_dispatch!(dispatch) }
        @hash_dispatches = []
      end

      # A placeholder taken back out of the tree after it was recorded (a test worked out again
      # by a game `while`, its first working out dropped) is left alone.
      def resolve_hash_dispatch!(dispatch)
        return nil unless dispatch.node.parent&.children&.any? { |child| child.equal?(dispatch.node) }

        names = dispatch.routines.values
        scenes = names.select { |name| declared_scene?(name) }
        handle = hash_number_handle(dispatch)
        replacement = if scenes.empty?
                        hash_table_call(dispatch, handle)
                      else
                        hash_scene_case(dispatch, handle, names.select { |name| @functions.key?(name) })
                      end
        swap_node(dispatch.node, replacement)
        nil
      end

      # A scene declared with no func of its name.
      def declared_scene?(name) = @functions.key?(:"_scene_#{name}") && !@functions.key?(name)

      # The handle of the variable `number:` named, where it was given a name: the same handle
      # `number: state` gives, so the same checks apply.
      def hash_number_handle(dispatch)
        number = dispatch.number
        return number unless number.is_a?(Symbol)

        unless @variables.include?(number)
          raise ArgumentError, "The Hash given to `call`#{dispatch.where} has `number: :#{number}`, and the game has " \
                               "no variable :#{number}. To fix this, give the name of a game variable, or the " \
                               "variable itself, like `number: state`."
        end
        value_handle_for(number)
      end

      # The case node for a Hash that names a scene. Every other name must be a scene too, or
      # one not declared yet, as a scene declared inside another scene's body is not: it is
      # declared as that body is built, after this. A name that never comes to be a scene is
      # refused when the targets are checked (#check_target_defined!). +funcs+ are the names
      # that are funcs.
      def hash_scene_case(dispatch, handle, funcs)
        unless funcs.empty?
          raise ArgumentError, "The Hash given to `call`#{dispatch.where} names scenes and other routines together. " \
                               ":#{funcs.first} is a func. A Hash picks scenes only, or other routines only. To " \
                               "fix this, give the scenes a Hash of their own."
        end
        refuse_scene_number!(dispatch, handle)
        scene_case_node(handle.node.name, dispatch.routines.to_a, ScenePicker::HASH, dispatch.source)
      end

      # The number that picks a scene is read by everything that asks which scene is up, so it
      # must be a game variable keeping a plain whole number (#scene_subject?).
      def refuse_scene_number!(dispatch, handle)
        if handle.is_a?(DSL::Value) && handle.names
          raise ArgumentError, "The Hash given to `call`#{dispatch.where} picks scenes by a variable that holds names, " \
                               "not numbers. To fix this, write `call` with that variable alone, which runs the " \
                               "scene it names."
        end
        refuse_hash_number_fraction!(dispatch, handle)
        return if scene_subject?(handle)

        raise ArgumentError, "The Hash given to `call`#{dispatch.where} picks scenes, so `number:` must be a game " \
                             "variable, like `number: state`. A working-out, a written number and a pool's field " \
                             "cannot pick a scene. To fix this, keep the number in a game variable and give that."
      end

      def refuse_hash_number_fraction!(dispatch, handle)
        return unless DSL::Fraction.bits_of(handle)

        raise ArgumentError, "The Hash given to `call`#{dispatch.where} picks a routine by a whole number, and the " \
                             "number given to `number:` holds a fraction. To fix this, use `.to_i` to drop the fraction."
      end

      # The call by number for a Hash of routines that are not scenes, picking by +handle+.
      def hash_table_call(dispatch, handle)
        routines = dispatch.routines
        refuse_hash_number_fraction!(dispatch, handle)
        refuse_hash_spread_out!(dispatch)
        first = hash_table_start(routines)
        names = (first..routines.keys.max).map { |key| routines.fetch(key) { call_nothing_routine } }
        which = DSL::Value.node_for(handle)
        which = Build.binop(:-, which, first) unless first.zero?
        node = Build.call_one_of(names, which: which)
        (@hash_table_sources ||= {}.compare_by_identity)[node] = dispatch
        node
      end

      #--
      # A Hash none of whose names was a scene when it was made a call by number (#resolve_hash_dispatch!)
      # cannot pick a scene declared later, inside a routine's body, so it is refused here, once
      # every routine is declared.
      #++
      def refuse_scene_declared_after_hash!
        (@hash_table_sources || {}).each_value do |dispatch|
          name = dispatch.routines.values.find { |each| declared_scene?(each) }
          next unless name

          raise ArgumentError, "The Hash given to `call`#{dispatch.where} names :#{name}, and :#{name} is a scene " \
                               "declared inside a routine's body. The Hash names no scene declared outside every " \
                               "routine, so it was made a call of routines before :#{name} was declared. To fix " \
                               "this, declare one of the Hash's scenes outside every routine."
        end
      end

      def refuse_bad_routine_hash!(routines, number)
        raise ArgumentError, "`call` was given an empty Hash of routines. Name at least one routine." if routines.empty?

        if number.nil?
          raise ArgumentError,
                "`call` was given a Hash of #{routines.size} routines and no number to pick one. To fix " \
                "this, add `number:`, like `call screens, number: state`."
        end
        key = routines.keys.find { |each| !each.is_a?(Integer) }
        unless key.nil?
          raise ArgumentError,
                "`call` was given a Hash with the key #{key.inspect}. Each key must be a whole number, " \
                "the number that picks its routine."
        end
        name = routines.values.find { |each| !each.is_a?(Symbol) }
        unless name.nil?
          raise ArgumentError,
                "`call` was given #{name.inspect} in its Hash of routines. Each value in the Hash must be " \
                "the name of a routine, like `:#{routines.values.grep(Symbol).first || 'title'}`."
        end
        refuse_bad_routine_list!(routines.values, number)
      end

      # The number a Hash's table starts at: 0, so the number is read as it is, unless a key is
      # below 0 or the table would then be too long, when it starts at the first key.
      def hash_table_start(routines)
        first, last = routines.keys.minmax
        first.negative? || last >= MOST_HASH_SLOTS ? first : 0
      end

      def refuse_hash_spread_out!(dispatch)
        first, last = dispatch.routines.keys.minmax
        return if last - first < MOST_HASH_SLOTS

        raise ArgumentError,
              "The Hash given to `call`#{dispatch.where} has keys from #{first} to #{last}. It is kept as a table with a slot " \
              "for each number between, and #{MOST_HASH_SLOTS} is the most. To fix this, number the routines " \
              "closer together."
      end

      def refuse_hash_number_past_keys!(routines, number)
        fixed = DSL::Value.fixed_number(number)
        return if fixed.nil? || routines.key?(fixed)

        raise ArgumentError,
              "`call` was given `number: #{fixed}`, and the Hash has no routine for #{fixed}. Its keys are " \
              "#{routines.keys.sort.join(', ')}. To fix this, give one of those numbers."
      end

      # A routine that does nothing, for the numbers between a Hash's keys.
      def call_nothing_routine
        declare_func(CALL_NOTHING) {} unless @functions.key?(CALL_NOTHING)
        CALL_NOTHING
      end

      CALL_NOTHING = :_call_nothing # A routine that does nothing

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
        raise ArgumentError, scene_called_by_name_message(name) if @functions.key?(:"_scene_#{name}")

        scene = name.to_s.delete_prefix("_scene_")
        if scene != name.to_s
          raise ArgumentError,
                "The scene :#{scene} is picked but never declared. To fix this, declare it with " \
                "`scene :#{scene} do ... end`. Or correct the name where it is picked."
        end
        raise ArgumentError,
              "The function :#{name} is called but never defined. To fix this, define it with " \
              "`func :#{name} do ... end`. Or correct the name in the call."
      end

      # `call :title` where :title is a scene, outside a dispatch that picks scenes (#scene_case?).
      def scene_called_by_name_message(name)
        "`call :#{name}` names a scene, and a scene runs only from a dispatch that picks scenes. " \
          "To fix this, put the call in a `case` on a game variable, after the `scene :#{name}` line: " \
          "`case state`, then `when 0 then call :#{name}`. A name is a game variable when game code changes " \
          "it, such as `state = 1` in a scene. Each `when` must be a whole number, and each must call one " \
          "scene. Or keep the scene's name in a variable, `mode = :#{name}`, and write `call mode`."
      end
    end
  end
end
