# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # Whether a name in a game block becomes a game variable, and why. A game is plain Ruby, and a
      # Ruby local, instance variable, slot or attribute holds what its line worked out while the
      # game is built. Where game code changes it, or a test the game makes as it plays changes it,
      # that is not enough: the name has to hold a game variable instead, a promotion. Every yes or
      # no about that is answered here, and only here.
      #
      # The answers come in two halves, because a promotion is decided twice.
      #
      # - While the block is rewritten, from its source (an instance, one per block): is this local
      #   a game variable, and how does its line make it (#local, #action_for); what does a test the
      #   game may make have to promote first (#before_test, #write_under_test); does a plain local
      #   keep a copy of what its line worked out (#kept_copy, #button_kept?).
      # - While the rewritten block runs and builds the game, from the values themselves (the class
      #   methods): only then is it known whether a test is the game's, what a place holds, and
      #   whether game code is being recorded.
      #
      # Each answer is an Answer naming the rule that decided it, its reason. The reasons are for
      # the tests of each rule and for a friendly error that wants to say why.
      #
      # The facts the rules read (which lines write a local, which read it, which loops and tests
      # stand around a write, what a call of game code can change) are LocalNames's, found by
      # reading the whole block first. Writes, the Rewriter, InstanceVariables and Steps do what an
      # answer asks, and keep no rule of their own.
      class Promotion
        # The reasons that promote: the name or place holds a game variable here, whoever made it, or
        # keeps a copy of its number in one, or the rule lets the promotion go on to the next check.
        PROMOTED = %i[
          made_by_var changed_in_game_code changed_in_game_block
          read_after_test read_next_round
          copies_numbers copies_game_variable
          changed_under_game_test named_instance_variable holds_plain_value slot_named_while_building
          changed_while_recording given_variable_it_does_not_own
          copy_of_variable_read_whole copy_of_number_in_ruby copy_of_changing_working_out copy_of_test_answer
        ].freeze

        # The reasons a local stays a plain Ruby name, which holds what its line gives it.
        PLAIN = %i[argument unchanged_in_game_code changed_from_unplaced_block read_outside_unplaced_block].freeze

        # What a plain local given a game value keeps (Steps.kept_answer's +copy+), by reason.
        COPIES = { copies_numbers: :numbers, copies_game_variable: :every_variable }.freeze

        # One decision and the rule that made it.
        Answer = Data.define(:reason) do
          def promoted? = PROMOTED.include?(reason)

          # Is this a local that stays a plain Ruby name? A node that is no local is neither.
          def plain? = PLAIN.include?(reason)

          # A local changed from a block only running can place: its line decides as it runs
          # (Promotion.unplaced_change).
          def decided_while_running? = reason == :changed_from_unplaced_block

          # nil, :numbers or :every_variable, for a #kept_copy answer.
          def copy = COPIES[reason]
        end

        # A plain local a test the game makes has to give a variable first, and whether every side of
        # that test writes it (one written on some sides only may stay nil).
        NamePromotion = Data.define(:name, :reason, :on_every_side)

        # An instance variable, slot or attribute a test the game makes has to give a variable first.
        # +keys+ are a slot's keys, nil for any other place.
        PlacePromotion = Data.define(:node, :keys)

        # What a test the game may make promotes before its sides run. +changes+ is whether the sides
        # change any plain name or place at all, promoted or not.
        Promotions = Data.define(:names, :places, :changes) do
          def changes? = changes
        end

        # What the console changes between passes, with no line of the game writing it: the buttons
        # and the players connected. A random draw is not one, since `rand` and `chance` each keep
        # their draw in a variable of their own, set on their line. `frames_since_power_on` is not
        # one either: it hands back a variable, which a game keeps as a handle and reads live
        # (Steps.kept_answer).
        CONSOLE_STATE_VERBS = %i[held pressed pulled players_connected].freeze

        # The verbs that read a button, which a game means to read where it uses the answer.
        BUTTON_VERBS = %i[held pressed pulled].freeze

        # What a `clock` and a `timer` read, which move on between passes too (`clock.hour`,
        # `countdown.ticks`).
        CONSOLE_STATE_READINGS = %i[hour minute second year month day weekday present? set? ticks].freeze

        # +names+ is the LocalNames that read the block.
        def initialize(names)
          @names = names
          @under_test = {}.compare_by_identity
        end

        # Is this local a game variable? Asked of a write or a read of a local, at that node.
        #
        # A name is a game variable if `var` made it (:made_by_var), or it is given a number and
        # also changed in game code (:changed_in_game_code), or it is worked out in game code and
        # changed inside a game verb's block below its line (:changed_in_game_block). Everything
        # else stays Ruby's: a method's argument is its own value, as in Ruby (:argument); a number
        # nothing in game code changes stays a plain number and costs nothing
        # (:unchanged_in_game_code); and a number changed from a block only running can place, a
        # pool's `each` or a Ruby list's, is decided as its line runs (:changed_from_unplaced_block).
        # A read of such a name from outside such a block reads it as Ruby holds it
        # (:read_outside_unplaced_block). A node that is no local's answers :not_a_local.
        def local(node)
          local = @names.local_of(node)
          return Answer.new(:not_a_local) if local.nil?

          reason = local_reason(local)
          if reason == :changed_from_unplaced_block && node.is_a?(Prism::LocalVariableReadNode) &&
             !@names.read_from_unplaced_block?(node)
            reason = :read_outside_unplaced_block
          end
          Answer.new(reason)
        end

        # What a rewritten `x = ...` does: nil to leave it, :declare for the line that makes a
        # variable while setting up, :start for one that makes it in game code and so sets it
        # every pass, :assign to change the variable. A method's argument is its own value, as in
        # Ruby, so a write to one changes nothing the caller holds.
        def action_for(write)
          local = @names.local_of(write)
          return if local.nil? || local.parameter?
          return first_write_action(local) if local.first_write_of?(write)
          return unless variable?(local)

          LocalNames.var_call?(write) ? nil : :assign
        end

        # What a test the game may make promotes first. A test the game makes runs both its sides
        # while building, so a plain name changed on a side would end up with the last side's value
        # whichever way the game goes. So before the sides run, a name changed in +sides+ is given a
        # variable, if the test turns out to be the game's (Promotion.value_under_test), wherever it
        # is read after +node+. A name read nowhere else needs nothing. It stops at a block, whose
        # writes are not in the same scope as the test.
        #
        # A loop's test and body are asked again on the next round, so a name a loop changes is
        # read after the change when it is read in the loop before that change: by the test
        # (`more = copy.word(at)` read by `while more != 0`), by a line above it, or by the change
        # itself (`at += 16`) (:read_next_round). Left plain, the game's loop would ask about the
        # number it held when the loop was recorded, and never end. A name written and then read
        # further down the same round only carries a working-out down the lines, as in any game
        # code, and stays plain.
        #
        # The same holds for a test inside a loop: `if differing == 0 then start = at else at += 17 end`
        # in a `while` whose test reads `at`. The loop around it may be Ruby's the first time round,
        # its test asking about plain numbers, and the game's from the second, once this test has
        # changed them. So the name is given its variable at whichever test the game makes first.
        #
        # An instance variable, a slot or an attribute any method can read, so nothing can show it
        # is not read afterwards: each changed in +sides+ is promoted, except a slot at a key Ruby
        # cannot read twice with nothing changing. If that one turns out to need following,
        # Writes.write stops the build.
        def before_test(node, sides)
          kept = sides.compact.flat_map { |side| plain_writes_in(side) }.select do |write|
            reason = reason_under_test(node, write)
            @under_test[write] = reason if reason
          end
          names = kept.group_by(&:name).map do |name, writes|
            NamePromotion.new(name, @under_test.fetch(writes.first), written_on_every_side?(name, sides))
          end
          places = sides.compact.flat_map { |side| places_in(side) }
          Promotions.new(names, places.filter_map { |place| place_promotion(place) }, !names.empty? || !places.empty?)
        end

        # Is this write one #before_test promoted, so that it goes to the name's variable under a
        # test the game makes?
        def write_under_test(write) = Answer.new(@under_test.fetch(write, :not_read_after_test))

        # Does a plain local keep a copy of its line's number? Asked of the line +write+.
        #
        # A Ruby local holds the number its line worked out. Here a local given a game value holds
        # a working-out, which the game works out again at each read, so it reads the number of
        # that read, not of its line. The two agree only where nothing the value reads can change
        # between the line and every read. So the local keeps its number in a copy
        # (:copies_numbers), and the copy is left out only where this proves that nothing can
        # change it (:unchanged_before_read): a missed proof costs a hidden variable, never a wrong
        # number. :copies_game_variable is the same for a local read whole from another this source
        # keeps as a game variable (#local_variable_read?).
        #
        # What can change it: a write the source shows to a name the value reads; a call of game
        # code that can write it (CallChanges), which counts from the start of the statement it
        # sits in, its own arguments included, since a method reads what it is handed where it
        # uses it; the same for the names the value reads through the calls in it and through
        # the plain locals it uses. A local set while setting up, or in a method, and read by game
        # code is read later than any line of the source, so there every change counts, wherever
        # it is written. A read in a loop above the line comes round after the line too.
        #
        # One thing is left out without a proof (:handed_whole_in_setup): a game variable set up in
        # a local that only hands it on, whole, to the parts it builds.
        def kept_copy(write)
          local = @names.local_of(write)
          return Answer.new(:not_a_plain_local) unless local && plain_name?(local) && write.is_a?(Prism::LocalVariableWriteNode)
          return Answer.new(:handed_whole_in_setup) if handed_whole_in_setup?(local, write)
          return Answer.new(:unchanged_before_read) unless changed_before_any_read?(local, write)

          Answer.new(local_variable_read?(write.value) ? :copies_game_variable : :copies_numbers)
        end

        # Is +write+ a line outside game code that sets its local from a button (`held`, `pressed`),
        # with the local read in game code? Its copy keeps the buttons as the game started, which
        # never changes (Guardrails::Checks::PressKeptFromSettingUp).
        def button_kept?(write)
          local = @names.local_of(write)
          return false unless local && write.is_a?(Prism::LocalVariableWriteNode) && read_later_in_game_code?(local, write)

          values_worked_out_from(write).any? { |value| reads_console_state?(value, verbs: BUTTON_VERBS) }
        end

        # Is +local+ a plain name that starts as a number written out? CallChanges asks: a routine
        # handed one takes its number, and cannot change the name.
        def plain_number?(local) = plain_name?(local) && !local.parameter? && starts_as_number?(local)

        class << self
          # The run-time half, asked as the rewritten block runs.

          # Does +value+, held by a plain name about to be changed under +test+, need a hidden
          # variable of its own (Writes.promote)? Not unless the test is the game's
          # (:test_decided_while_building). Tests already open around this one have seen to a
          # name read after them, in +outer+: a name still holding a variable one of them made for
          # it keeps it (:holds_own_variable). One holding a variable it was handed, or one made for
          # another name (`bend = out`), gets its own, or the sides would write somebody else's. A
          # value only Ruby can hold is no game's to keep (:not_kept_by_game).
          def value_under_test(value, test, *outer, name: nil)
            return Answer.new(:test_decided_while_building) unless test.game?
            if outer.any?(&:game?) && Steps.variable?(value) && !Writes.handed?(value) && Writes.owned_by?(value, name)
              return Answer.new(:holds_own_variable)
            end
            return Answer.new(:not_kept_by_game) unless Writes.number_kept?(value)

            Answer.new(:changed_under_game_test)
          end

          # Is +owner+'s instance variable +label+ one the game names (`game_variables`), changed
          # under a test the game makes (Writes.promote_place)? A named one uses its own game
          # variable (:named_instance_variable), and one still holding nil is left as it is
          # (:named_still_nil): the line that sets it may be one this build skips, under a test
          # decided while building, and then no game code reads or writes it. Only while game code
          # is recorded is any instance variable followed (:setting_up).
          def instance_variable(owner, current, label)
            uses = InstanceVariables.uses_while_recording(owner)
            return Answer.new(:setting_up) unless uses
            return Answer.new(:not_named) unless uses.named?(owner, label)

            Answer.new(current.nil? ? :named_still_nil : :named_instance_variable)
          end

          # Does a place holding +current+ need a variable before a test the game makes? A place
          # holding a game variable has one (:holds_variable), and one holding nothing has no number
          # to keep (:holds_nothing).
          def held(current)
            return Answer.new(:holds_nothing) if current.nil?
            return Answer.new(:holds_variable) if Steps.variable?(current)

            Answer.new(:holds_plain_value)
          end

          # Is the slot of +collection+ at +keys+ one a promotion can name? Only a Hash's or an
          # Array's (:not_a_ruby_collection), and only at keys known while building: a key the
          # game works out is not a slot Ruby can name (:key_worked_out).
          def slot(collection, keys)
            return Answer.new(:not_a_ruby_collection) unless collection.is_a?(Hash) || collection.is_a?(Array)
            return Answer.new(:key_worked_out) if keys.any?(Value)

            Answer.new(:slot_named_while_building)
          end

          # A number changed from a block that is a pool's `each` or a Ruby list's, which only running
          # it can tell apart (Promotion#local's :changed_from_unplaced_block). Changed while game code
          # is recorded, a plain number would change once, while building, and the game would never
          # see it, so it becomes a game variable (:changed_while_recording). While setting up it
          # stays Ruby's (:setting_up), so `names.each { count += 1 }` over a Ruby list counts in
          # Ruby. Only a whole number or a fraction is one (:not_a_number).
          def unplaced_change(value, recording)
            return Answer.new(:setting_up) unless recording
            return Answer.new(:not_a_number) unless value.is_a?(Integer) || value.is_a?(Float)

            Answer.new(:changed_while_recording)
          end

          # An instance variable game code gives another name (LocalNames#moved_in_game_code?)
          # keeps a variable of its own and copies each number into it, where it is given a game
          # variable it does not own (:given_variable_it_does_not_own).
          def moved_instance_variable(current, value, owner, label)
            return Answer.new(:not_given_variable) unless Steps.variable?(value)
            return Answer.new(:holds_own_variable) if Writes.own_variable?(current, owner, label)

            Answer.new(:given_variable_it_does_not_own)
          end

          # Does a plain local given +value+ keep it in a hidden variable of its own (Steps.kept_answer)?
          # +copy+ is Promotion#kept_copy's.
          #
          # Copied: a local read whole from another the game changes, whatever made its variable
          # (:copy_of_variable_read_whole); a game variable that is a name's number in Ruby (`hp = 10`,
          # `@seed` named by `game_variables`, a hidden one) (:copy_of_number_in_ruby); a working-out
          # of something that changes as the game plays (:copy_of_changing_working_out); a test's
          # answer (:copy_of_test_answer).
          #
          # Left as it is, as in Ruby: a handle the game holds as an object, a variable a `var` line
          # or a verb made (`routine_var(:floors)`, `frames_since_power_on`), which the game hands
          # about to change and to read live (:handle_read_live); a working-out of numbers the
          # cartridge holds fixed, which no line can change (:fixed_working_out); and a plain Ruby
          # value (:plain_ruby_value).
          def copy(value, copy)
            return Answer.new(:copy_of_variable_read_whole) if copy == :every_variable && Steps.variable?(value)
            return Answer.new(value.number_in_ruby? ? :copy_of_number_in_ruby : :handle_read_live) if Steps.variable?(value)
            return Answer.new(value.changes_as_game_plays? ? :copy_of_changing_working_out : :fixed_working_out) if value.is_a?(Value)
            return Answer.new(:copy_of_test_answer) if value.is_a?(Condition)

            Answer.new(:plain_ruby_value)
          end
        end

        private

        def local_reason(local)
          return changed_from_unplaced_block?(local) ? :changed_from_unplaced_block : :argument if local.parameter?
          return :made_by_var if made_by_var?(local)

          auto = auto_variable_reason(local)
          return auto if auto
          return :changed_from_unplaced_block if changed_from_unplaced_block?(local)

          :unchanged_in_game_code
        end

        # On any line: `glint = nil` can be filled in later by code that runs later.
        def made_by_var?(local) = local.unpacked_from_var || local.writes.any? { |write| LocalNames.var_call?(write.node) }

        def variable?(local) = !auto_variable_reason(local).nil? || made_by_var?(local)

        def plain_name?(local) = local.parameter? || !variable?(local)

        # Why a name nobody made with `var` is a game variable, or nil.
        def auto_variable_reason(local)
          return if local.parameter?
          return (:changed_in_game_code if local.writes.drop(1).any?(&:in_game_code)) if starts_variable?(local)

          :changed_in_game_block if changed_by_game_block_inside?(local)
        end

        # A name first given a working-out in game code, `back = made - distance`, and changed
        # inside a game verb's block below that line, `repeat(count) { back += 1 }`. The block is
        # recorded once and runs many times, so a working-out moved on in it would move on once,
        # while building, and every round would read the same number: the name is a variable
        # that its line sets each time it runs. A working-out only carried down the lines of one
        # block stays one, and costs nothing.
        def changed_by_game_block_inside?(local)
          LocalNames::WHOLE_WRITES.any? { |kind| local.first_write.node.is_a?(kind) } &&
            local.writes.drop(1).any?(&:from_game_block)
        end

        # A number changed from a block that may be a pool's `each`, which only running it can
        # tell from a Ruby list's: see Rewriter#guarded_write_text. A name only read here (one of a
        # block around, or Ruby's own) has no write to decide by.
        def changed_from_unplaced_block?(local)
          !local.writes.empty? && !variable?(local) && starts_as_number?(local) &&
            local.writes.drop(1).any?(&:from_unknown_block)
        end

        # A number or a yes or no written out. A name started as nil is often filled in later
        # with something no game can keep, a point of a place or a sprite.
        def starts_as_number?(local) = %i[other yes_or_no].include?(LocalNames.kind_written(local.first_write.node))

        # In setting up, whatever a name is given is looked at as the line runs, so any start
        # will do. In game code a worked-out start stays a working-out, which Ruby's arithmetic
        # carries down the lines and which costs no memory.
        def starts_variable?(local)
          return true if local.unpacked_from_value || LocalNames.starts_from_value?(local.first_write.node)

          LocalNames::WHOLE_WRITES.any? { |kind| local.first_write.node.is_a?(kind) } && !local.first_write.in_game_code
        end

        def first_write_action(local)
          return if made_by_var?(local) || auto_variable_reason(local).nil?

          local.first_write.in_game_code ? :start : :declare
        end

        # Why +write+ is promoted before the test +node+, or nil.
        def reason_under_test(node, write)
          local = @names.local_of(write)
          return :read_after_test if local.read_from?(node.location.end_offset)

          :read_next_round if loops_asked_again_around(node, write).any? { |each_loop| read_next_round?(local, each_loop, write) }
        end

        # The loops that ask +node+ again each time round and hold +write+: +node+ itself if it is
        # one, and each loop around it.
        def loops_asked_again_around(node, write)
          around = @names.loops_around(write).select do |each_loop|
            each_loop.location.start_offset <= node.location.start_offset && each_loop.location.end_offset >= node.location.end_offset
          end
          LocalNames::LOOPS.any? { |kind| node.is_a?(kind) } ? around | [node] : around
        end

        # Is +local+ read in +loop+ at or before +write+, or in its test, so the next round reads
        # what it wrote?
        def read_next_round?(local, loop, write)
          from = loop.location.start_offset
          to = write.location.start_offset
          local.reads.any? { |read| read.location.start_offset.between?(from, to) || in_loop_test?(read, loop) }
        end

        # Does each of +sides+ write +name+, so that it holds something whichever way the test goes?
        def written_on_every_side?(name, sides)
          sides.none?(&:nil?) && sides.length > 1 &&
            sides.all? { |side| plain_writes_in(side).any? { |write| write.name == name } }
        end

        # A block inside a side runs while building, on that side, so a name of the scope around it
        # that it changes is changed on that side: +blocks+ counts the blocks gone into, and a write
        # whose depth reaches past them is one. A method or a lambda runs when it is called, which
        # may be anywhere, so its writes are not: a lambda's change to a name around it comes from a
        # block only running can place, and is decided as it runs (:changed_from_unplaced_block).
        def plain_writes_in(node, blocks = 0)
          return plain_writes_in_children(node, blocks + 1) if node.is_a?(Prism::BlockNode)
          return [] if OWN_SCOPES.any? { |kind| node.is_a?(kind) }

          own = plain_write?(node) && LocalNames::CHANGES.any? { |kind| node.is_a?(kind) } && node.depth >= blocks ? [node] : []
          own + plain_writes_in_children(node, blocks)
        end

        def plain_writes_in_children(node, blocks) = node.compact_child_nodes.flat_map { |child| plain_writes_in(child, blocks) }

        def plain_write?(node)
          local = @names.local_of(node)
          !local.nil? && plain_name?(local)
        end

        # The instance variables, slots and attributes +node+ changes, each written on a plain name.
        def places_in(node)
          return [] if OWN_SCOPES.any? { |kind| node.is_a?(kind) }

          own = changed_place?(node) ? [node] : []
          own + node.compact_child_nodes.flat_map { |child| places_in(child) }
        end

        def changed_place?(node)
          case node
          when Prism::InstanceVariableWriteNode then !LocalNames.makes_variable?(node.value)
          when Prism::InstanceVariableOperatorWriteNode then true
          when Prism::IndexOperatorWriteNode, Prism::CallOperatorWriteNode then plain_receiver?(node.receiver)
          when Prism::CallNode then (node.name == :[]= || node.attribute_write?) && plain_receiver?(node.receiver)
          else false
          end
        end

        def plain_receiver?(receiver) = (LocalNames::NAMES + [Prism::SelfNode]).any? { |kind| receiver.is_a?(kind) }

        # The place promoted, or nil for a slot at a key Ruby cannot read twice alike.
        def place_promotion(place)
          keys = slot_keys(place)
          return PlacePromotion.new(place, nil) if keys.nil?

          PlacePromotion.new(place, keys) if keys.all? { |key| plain_key?(key) }
        end

        # The keys of the slot +place+ writes, or nil for an instance variable or an attribute.
        def slot_keys(place)
          case place
          when Prism::IndexOperatorWriteNode then place.arguments.arguments
          when Prism::CallNode then place.arguments.arguments[0...-1] if place.name == :[]=
          end
        end

        # A key Ruby can read a second time with nothing changing.
        def plain_key?(key)
          [Prism::SymbolNode, Prism::IntegerNode, Prism::StringNode, Prism::LocalVariableReadNode].any? { |kind| key.is_a?(kind) }
        end

        # `first = hp`, where `hp` is a local this source keeps as a game variable, made by `var`
        # too: `hp -= 1` gives the name a new number, as Ruby's `hp` would, so `first` keeps the
        # old one whatever made the variable.
        def local_variable_read?(value)
          return false unless value.is_a?(Prism::LocalVariableReadNode)

          local = @names.local_of(value)
          !local.nil? && variable?(local)
        end

        # Could anything change what the value +write+ gives +local+ before one of its reads?
        def changed_before_any_read?(local, write)
          return false if local.reads.empty?
          return true if read_later_in_game_code?(local, write) && reads_console_state_through_locals?(write)

          read_after_any?(local, write, @names.changes_of_value(write) + changes_read_through_locals(write))
        end

        # Does the value +write+ gives its local read what the console changes between passes
        # (CONSOLE_STATE_VERBS), itself or through the plain locals it works out from? A local set
        # outside game code and read in it is read a pass or more later, so its line's answer has
        # gone by then: `advance = pressed(:a)` while setting up keeps the press as the game
        # started, as Ruby's local does.
        def reads_console_state_through_locals?(write)
          values_worked_out_from(write).any? { |value| reads_console_state?(value) }
        end

        # The value +write+ gives its local, and the values of the plain locals it works out from.
        def values_worked_out_from(write)
          ([write.value] + locals_worked_out_in(write.value).flat_map { |local| @names.value_writes(local).map(&:value) }).compact
        end

        # Does +node+ call one of +verbs+, or read a clock or a timer where +verbs+ are every verb
        # the console changes?
        def reads_console_state?(node, verbs: CONSOLE_STATE_VERBS)
          return true if node.is_a?(Prism::CallNode) && console_state_call?(node, verbs)

          node.compact_child_nodes.any? { |child| reads_console_state?(child, verbs: verbs) }
        end

        # A button verb counts on anything too, for a game that asks its own button objects
        # (`ADVANCE.map { |button| button.pressed(self) }`).
        def console_state_call?(call, verbs)
          return true if BUTTON_VERBS.include?(call.name)
          return verbs.include?(call.name) unless LocalNames.called_on_something?(call)
          return false if verbs.equal?(BUTTON_VERBS)

          CONSOLE_STATE_READINGS.include?(call.name) && (call.name == :ticks || clock_call?(call.receiver))
        end

        def clock_call?(node) = node.is_a?(Prism::CallNode) && node.name == :clock && !LocalNames.called_on_something?(node)

        # Is +local+, which +write+ sets, read after any of +changes+? A local set outside game
        # code (setting up, or in a method) and read in game code is read after every change that
        # can run after its line: one below it, and one in a method or a game block anywhere,
        # which runs when it is called. A read in a loop that holds the line, above it, comes
        # after the changes in that loop.
        def read_after_any?(local, write, changes)
          after = changes.select { |change| change.after?(write) }
          return true if read_later_in_game_code?(local, write) && (!after.empty? || changes.any? { |change| run_later?(change, write) })

          reached = local.reads.any? do |read|
            after.any? { |change| change.reaches?(read) { |side| side_apart_holds?(write, side) } }
          end
          reached || local.reads.any? { |read| read_next_time_round?(read, write, changes) }
        end

        # A change on one side of an `if` never comes before a read on its other side in the same
        # round. That keeps the local's number only where +write+ sets it on every round before
        # the `if`: inside the region the `if` sits in, above it, and under no test the `if` is
        # not under. A local set on some rounds only is read on later ones.
        def side_apart_holds?(write, side)
          return false unless write.location.start_offset > side.region_start && write.location.end_offset <= side.test_start

          @names.tests_around(write).all? { |test| test.location.start_offset <= side.test_start && test.location.end_offset >= side.to }
        end

        # Is +change+ in a method, a lambda or a game block that does not hold +write+?
        def run_later?(change, write)
          @names.bodies_run_later.any? do |body|
            change.offset.between?(body.location.start_offset, body.location.end_offset) && !inside?(write, body)
          end
        end

        # Is every line giving +local+ a value one set outside game code and read by it, whose copy
        # counts every change that can run after the line (#read_after_any?)?
        def copy_counts_later_changes?(local)
          local.writes.map(&:node).all? do |each_write|
            each_write.is_a?(Prism::LocalVariableWriteNode) && read_later_in_game_code?(local, each_write) &&
              !handed_whole_in_setup?(local, each_write)
          end
        end

        def read_later_in_game_code?(local, write)
          !@names.written_in_game_code?(write) && local.reads.any? { |read| @names.read_in_game_code?(read) }
        end

        # Is +read+ above +write+ in a loop that holds both, or in that loop's test, with one of
        # +changes+ in that loop?
        def read_next_time_round?(read, write, changes)
          @names.loops_around(write).any? do |each_loop|
            above = read.location.start_offset < write.location.start_offset && inside?(read, each_loop)
            (above || in_loop_test?(read, each_loop)) &&
              changes.any? { |change| change.offset.between?(each_loop.location.start_offset, each_loop.location.end_offset) }
          end
        end

        def inside?(node, outer) = node.location.start_offset >= outer.location.start_offset && node.location.end_offset <= outer.location.end_offset

        # Is +read+ in the test of +loop+? A loop asks its test again after each round, wherever
        # the test is written: `line = read_scanline while line >= 160` has it after the line it
        # guards, and the next round still asks about the number that line wrote.
        def in_loop_test?(read, loop) = inside?(read, loop.predicate)

        # `sound_setting = menu_art && @sound_setting`, set while setting up and read only as a
        # whole argument (`Menus.new(sound_setting: sound_setting)`). Handing a game variable to a
        # part as it is made hands it the variable itself (`Ball.new(selection: menu.selection)`),
        # and a local in between does not change that: the parts it is handed to share it.
        def handed_whole_in_setup?(local, write)
          return false if @names.written_in_game_code?(write) || @names.written_in_method?(write) || local.reads.empty?
          return false unless names_read_straight?(write.value)

          local.reads.all? { |read| @names.whole_argument?(read) }
        end

        # Is +value+ a name read as it is (`@setting`), or one picked by `&&` or `||` from such?
        def names_read_straight?(value)
          case value
          when *LocalNames::NAMES then true
          when Prism::AndNode, Prism::OrNode then names_read_straight?(value.right)
          when Prism::ParenthesesNode then value.body.body.one? && names_read_straight?(value.body.body.first)
          else false
          end
        end

        # What can change what the value +write+ gives its local reads through the plain names it
        # uses: `envelope = @copy.byte(at + 1)` reads what `at = get(:drum, c)` reads, the list
        # behind `get`, since `at` is a working-out too and is worked out where `envelope` is read.
        #
        # A local whose own copy is decided for every read after its line (#copy_counts_later_changes?)
        # needs no following: either it keeps its number, or nothing changes what it reads after
        # its line, a later line's read included.
        def changes_read_through_locals(write)
          locals_worked_out_in(write.value).flat_map do |local|
            @names.value_writes(local).flat_map { |each_write| @names.changes_of_value(each_write) }
          end
        end

        # The plain names +node+ reads, and the plain names their values read, however deep: each
        # a working-out read where +node+ is (a game variable or an argument holds its own number).
        def locals_worked_out_in(node, found = {}.compare_by_identity)
          if node.is_a?(Prism::LocalVariableReadNode)
            local = @names.local_of(node)
            if local && plain_name?(local) && !local.parameter? && !found.key?(local) && !copy_counts_later_changes?(local)
              found[local] = true
              @names.value_writes(local).each { |each_write| locals_worked_out_in(each_write.value, found) }
            end
          end
          node.compact_child_nodes.each { |child| locals_worked_out_in(child, found) }
          found.keys
        end
      end
    end
  end
end
