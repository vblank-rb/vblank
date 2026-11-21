# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # What a program reserves, against the memory there really is.
        #
        # The console has two work memories: 32K of quick on-chip RAM and 256K of roomier
        # RAM on a chip of its own. A collection can live in either — the framework puts
        # what a frame touches in the quick one and lets the rest fall into the roomy one
        # — so a program with a lot of state is no longer a build failure just because it
        # will not all fit near to hand.
        #
        # What cannot move is a variable. Every variable is reached by naming the base of
        # the quick memory and riding a distance inside the load instruction, which is what
        # makes a variable read two instructions instead of four; a variable in the roomy
        # memory would be neither quick nor near. Nor can a sprite's save-under buffer,
        # which the copying engine streams to and from every frame.
        #
        # That is the Advance's rule, not every console's. The Super Nintendo reaches any byte
        # of its work RAM with a long address, a byte and a cycle dearer than a near one, so
        # its lowering keeps the variables a game names most in the first 8K and lets the rest
        # go further on (Console::Description#variables_go_far). There a variable can move as
        # a list can, and only the whole is counted.
        #
        # So this checks three things, and all are real ceilings rather than budgets anybody
        # chose. What must be in the quick memory has to fit in it. What is kept out of it —
        # a collection marked cold, where the console's build keeps such a one in the roomier
        # memory whatever room the quick one has (Console::Kit#cold_collections_kept_roomier?)
        # — has to fit the roomier one alone. And everything the program declares, together,
        # has to fit in the two memories added up. Past any of them the build stops with a
        # plain-language error: how much is needed, how much there is, and the biggest users
        # so the fix is obvious.
        #
        # The roomier memory is not all the game's. The build keeps buffers of its own there
        # (the sound mixer's, the sound effects table, the save chip's), and the console's kit
        # says which, read off the program before it is lowered (Console::Kit#roomier_memory_reserved).
        # Both of the last two checks count against what is left. What the kit cannot read off
        # the program (the sprite drawing's records, which only laying out the sprites can size)
        # is not counted, and the lowering still refuses a game that runs out over those.
        #
        # The numbers are the console's (Console::Description#work_memory_bytes and the two
        # beside it), since a game for the Color is checked against the Color. That console has
        # one 8K work memory and nothing roomier beside it, so there everything the game keeps
        # is counted against the one memory and the second check has nothing to add. The
        # Color's build refuses a game that runs out where it lays it out too
        # (Backends::GBC::Memory::Full); this says it sooner, and names the biggest users.
        class IwramBudget
          NAME = :iwram_budget
          PLAIN_NAME = "the #{Messages::PlainWords::QUICK_MEMORY} budget".freeze

          # A variable or a list slot is a word: 4 bytes.
          WORD = 4

          # How many top users to name in the error — enough to point at the fix,
          # not so many the message becomes a memory dump.
          TOP_USERS = 3

          # How many names of variables made with no `var` line to give.
          NAMES_SHOWN = 6

          # How many lines of the game's that keep a copy of a name's number to give, most first.
          COPY_LINES_SHOWN = 5

          # How to write the Ruby so a name needs no copy, here and in the profile
          # (Diagnostics::HiddenVariables).
          COPY_ADVICE = "To need no copy, read the name before the line that changes the number. Or, after the " \
                        "call that changes it, read the number again."

          # +made_names+ are the variables that came from no line of the author's, names normal
          # Ruby made variables of, and +hidden_notes+ the hidden ones (Builder#hidden_variable_notes,
          # #told_of), each with the game's line that made it.
          def initialize(made_names: [], hidden_notes: [])
            @made_names = made_names
            @hidden_notes = hidden_notes
          end

          # The same check, knowing which variables came from no line of the author's. A game can
          # fill the memory with variables it never declared, and "2205 variables" would not help
          # it look. The class is named rather than asked of self (`self.class`), which crashed
          # Ruby once with several Ractors building at once (Validator#plain_name says why).
          def told_of(names, hidden_notes) = IwramBudget.new(made_names: names, hidden_notes: hidden_notes)

          # One thing the program keeps in memory, as the messages name it: its +label+ ("pool
          # :enemy", "120 variables"), its +bytes+, and the +node+ of the line that declared it
          # (nil for a sum over the whole program). +movable+ marks one that can go in the roomier
          # memory; +saved+ a save_data record's lists, whose fix is different (#save_record_advice);
          # +cold_bytes+ how much of it is in lists set `fast: false` (#cold_overflow_findings).
          MemoryUser = Data.define(:label, :bytes, :node, :movable, :saved, :cold_bytes) do
            def initialize(node: nil, saved: false, cold_bytes: 0, **rest) = super
          end

          def detect(program)
            console = program.described_console
            kit = Console.for(console.name)
            users = contributors(program, console, kit)
            pinned = users.reject(&:movable).sum(&:bytes)
            total = users.sum(&:bytes)
            if console.roomier_memory? && pinned > console.free_work_memory_bytes
              return pinned_overflow_findings(users, pinned, console)
            end

            reserved = kit.roomier_memory_reserved(program)
            roomier = console.roomier_memory_bytes - reserved.sum(&:bytes)
            if kit.cold_collections_kept_roomier?
              cold = users.select { |user| user.cold_bytes.positive? }.sort_by { |user| -user.cold_bytes }
              cold_bytes = cold.sum(&:cold_bytes)
              return cold_overflow_findings(cold, cold_bytes, roomier, reserved, console) if cold_bytes > roomier
            end
            return [] if total <= console.free_work_memory_bytes + roomier

            # Blame the biggest user, which is the capacity to shrink. The plain
            # variable count and the sprites' save-buffers are sums over the whole
            # program with no one declaration behind them, so a program whose biggest
            # user is one of those blames the program itself.
            [Finding.new(check: NAME, severity: :error, message: message(total, users, reserved, console),
                         node: users.first.node || :program)]
          end

          # The things that can only be in the quick memory are over it on their own, and
          # no other memory can take them.
          def pinned_overflow_findings(users, pinned, console)
            worst = users.reject(&:movable).first
            [Finding.new(check: NAME, severity: :error, node: worst&.node || :program,
                         message: pinned_message(pinned, users, console))]
          end

          private

          # The cold collections are over the roomier memory on their own. A collection marked
          # cold (`fast: false`, or a pool too big to share the quick memory, which the builder
          # marks so: Builder::Composition#pool) goes in the roomier memory whatever room the quick
          # one has, so the two memories added up are not what it has to fit: the roomier one is,
          # less what the build reserves there for itself. The biggest is blamed, at its own line.
          def cold_overflow_findings(cold, cold_bytes, roomier, reserved, console)
            [Finding.new(check: NAME, severity: :error, node: cold.first.node || :program,
                         message: cold_message(cold, cold_bytes, roomier, reserved, console))]
          end

          # Everything the program reserves IWRAM for, each a MemoryUser, largest first — so the
          # message can name the total and point at the biggest users, and the finding can send
          # the author to the biggest one's line.
          def contributors(program, console, kit)
            items = list_and_pool_items(program, kit)

            var_count = variable_names(program).size
            if var_count.positive?
              items << MemoryUser.new(label: pluralize(var_count, "variable"), bytes: var_count * WORD,
                                      movable: console.variables_go_far)
            end

            buffers = backing_bytes(program)
            items << MemoryUser.new(label: "sprite save-buffers", bytes: buffers, movable: false) if buffers.positive?

            items.sort_by { |item| -item.bytes }
          end

          # Lists as contributors — but the lists the build made up for one thing the author
          # declared collapse into that thing ("pool :name", "save_data :name": the author
          # declared one pool, not five lists), while a standalone list stays "list :name". The
          # node kept under a label is its first declaration, which is the line the author wrote.
          def list_and_pool_items(program, kit)
            grouped = {}
            list_declarations(program, kit).each do |name, (bytes, node)|
              label = Messages::MadeNames.collection_words(name)
              item = grouped[label] || MemoryUser.new(label: label, bytes: 0, node: node, movable: true,
                                                      saved: Messages::MadeNames.save_list?(name))
              grouped[label] = item.with(bytes: item.bytes + bytes,
                                         cold_bytes: item.cold_bytes + (node.fast == false ? bytes : 0))
            end
            grouped.values
          end

          # name => [bytes, node] for every list the program creates (deduped by name — a
          # list re-declared to reset it reserves its storage once). A list is its slots, at
          # its own element width, and its hidden bookkeeping words, as the console's build
          # lays it out (Console::Kit#list_bytes): a list the game shifts from can take more.
          def list_declarations(program, kit)
            rings = kit.ring_lists(program)
            declarations = {}
            program.walk do |node|
              next unless node.kind == :list_new

              bytes = kit.list_bytes(node.capacity, node.width || :word, ring: rings.include?(node.name))
              declarations[node.name] = [bytes, node]
            end
            declarations
          end

          # The kinds that name a variable, and which of their attributes hold the name(s).
          # Every variable that reserves a word is reached by one of these — a read
          # (var_ref), a write (set/add/…), or a loop/timer's hidden counter.
          VARIABLES_OF = Ractor.make_shareable({
            set: ->(n) { [n.var] }, add: ->(n) { [n.var] }, sub: ->(n) { [n.var] },
            negate: ->(n) { [n.var] }, abs: ->(n) { [n.var] }, negate_abs: ->(n) { [n.var] },
            clamp: ->(n) { [n.var] }, copy: ->(n) { [n.dest, n.src] },
            var_ref: ->(n) { [n.name] }, repeat: ->(n) { [n.index] },
            every: ->(n) { [n.counter] }, after: ->(n) { [n.counter] }
          })

          # The distinct variable names the program uses — each is one word of IWRAM.
          def variable_names(program)
            names = {}
            program.walk do |node|
              reader = VARIABLES_OF[node.kind] or next
              reader.call(node).each { |name| names[name] = true }
            end
            names.keys
          end

          # Total bytes for the save-under buffers moving sprites keep (a width x height
          # patch of 16-bit pixels, padded to a whole word), deduped by name.
          def backing_bytes(program)
            sizes = {}
            program.walk do |node|
              next unless node.kind == :backing_buffer

              sizes[node.name] = round_up_word(node.width * node.height * 2)
            end
            sizes.values.sum
          end

          def round_up_word(bytes) = (bytes + 3) & ~3

          def message(total, users, reserved, console)
            "This program reserves about #{human_size(total)} of memory for its data. But " \
              "#{memory_message(console)}#{reserved_message(reserved)} The biggest users are #{top_users(users)}. To fix this, use a " \
              "smaller capacity for a pool or a list. Or use fewer fields. Or use narrower items " \
              "(`width: :byte`).#{variables_advice(console)}#{save_record_advice(users)} Then it all " \
              "fits.#{made_variables_message}"
          end

          # What the author can look for, since no line of theirs writes `var` for these.
          def made_variables_message
            names = @made_names.to_a
            hidden = @hidden_notes.length
            return "" if names.empty? && hidden.zero?

            shown = names.first(NAMES_SHOWN).map { |name| "`#{name}`" }.join(", ")
            more = names.length > NAMES_SHOWN ? " and #{names.length - NAMES_SHOWN} more" : ""
            made = names.empty? ? "" : " These names are variables with no `var` line: #{shown}#{more}."
            kept = hidden.zero? ? "" : " The build also made #{pluralize(hidden, 'hidden variable')}."
            "#{made}#{kept}#{copies_message}"
          end

          # The copies plain Ruby takes (PlainRuby::Steps.kept_answer): a local given a game value
          # keeps the number of its line, as Ruby's does, in a hidden variable of its own wherever
          # the game can change that number before the local is read. Named by the game's own file
          # and line, with what each costs, and the change to the Ruby that needs none.
          def copies_message
            lines = @hidden_notes.select { |note| note.why == :copy }.group_by(&:source)
            return "" if lines.empty?

            count = lines.values.sum(&:length)
            shown = lines.sort_by { |_, copies| -copies.length }.first(COPY_LINES_SHOWN)
                         .map { |source, copies| "#{source ? File.basename(source) : 'the library'} (#{human_size(copies.length * WORD)})" }
            more = lines.length > COPY_LINES_SHOWN ? ", and #{lines.length - COPY_LINES_SHOWN} more lines" : ""
            " Of these, #{count} are copies (#{human_size(count * WORD)}): a name keeps the number it got on its line, " \
              "as in Ruby. #{shown.join(', ')}#{more}. The game can change that number before it reads the name. " \
              "#{COPY_ADVICE}"
          end

          # What memory the console has, said the way that console has it: two memories, or one.
          def memory_message(console)
            if console.roomier_memory?
              return "the console has only #{human_size(console.work_memory_bytes)} of " \
                     "#{Messages::PlainWords::QUICK_MEMORY} and #{human_size(console.roomier_memory_bytes)} of " \
                     "roomier memory, and both are full."
            end

            "the #{console.title} has only #{human_size(console.work_memory_bytes)} of work memory, and " \
              "about #{human_size(console.free_work_memory_bytes)} of that is free for your data. The rest " \
              "holds the call stack and the framework's own state."
          end

          # Where the variables share a memory with everything else, fewer of them makes room too.
          # (Where they are kept apart in the quick memory, too many has a message of its own.)
          def variables_advice(console)
            console.roomier_memory? && !console.variables_go_far ? "" : " Or use fewer variables."
          end

          # A save_data record has no capacity of its own: its buffers are as big as what it
          # keeps, so the fix for one among the biggest users is to keep less.
          def save_record_advice(users)
            record = top(users).find { |user| user.saved } or return ""

            " A save_data record holds a copy of everything it keeps, so for #{record.label}, " \
              "keep fewer variables and lists in it, or make its lists narrower."
          end

          def top(users) = users.first(TOP_USERS)

          # The variables and the sprites' save-buffers can only be in the quick memory, so
          # a program whose variables alone are over it cannot be helped by the other one.
          def pinned_message(pinned, users, console)
            "This program reserves about #{human_size(pinned)} of the console's #{Messages::PlainWords::QUICK_MEMORY} for " \
              "things that can only live there. But the console has only #{human_size(console.work_memory_bytes)} of it, " \
              "and about #{human_size(console.free_work_memory_bytes)} of that is free for your data — the rest holds the call stack " \
              "and the framework's own state. A list or a pool can move to the roomier memory; a variable " \
              "cannot, because a variable is reached by its distance from the start of the quick one. The " \
              "biggest users are #{top_users(users.reject { |u| u.movable })}. To fix this, use fewer " \
              "variables. Or keep the same numbers in a list, which can move.#{made_variables_message}"
          end

          # The lists and pools kept out of the quick memory, against the roomier memory alone.
          def cold_message(cold, cold_bytes, roomier, reserved, console)
            quick = Messages::PlainWords::QUICK_MEMORY
            biggest = top(cold).map { |user| "#{user.label} (#{human_size(user.cold_bytes)})" }.join(", ")
            "This program keeps about #{human_size(cold_bytes)} of lists and pools out of the #{quick}. These are " \
              "the lists and pools with `fast: false`, and the pools that are bigger than " \
              "#{human_size(VBlank::Builder::Composition::POOL_MAX_QUICK_BYTES)}. They can only go in the roomier memory. The " \
              "console has only #{human_size(console.roomier_memory_bytes)} of roomier memory.#{reserved_message(reserved)}" \
              "#{reserved.empty? ? '' : " So about #{human_size(roomier)} is free for these lists and pools."} " \
              "#{cold.one? ? 'It is' : 'The biggest of them are'} #{biggest}. " \
              "To fix this, use a smaller capacity for a pool or a list. Or use fewer fields. Or use narrower items " \
              "(`width: :byte`). If a list or a pool is small, remove `fast: false` from it. Then the build can put " \
              "it in the #{quick}."
          end

          # What the build reserves in the roomier memory for itself, where it reserves anything there.
          def reserved_message(reserved)
            return "" if reserved.empty?

            parts = reserved.map { |item| "#{item.label} (#{human_size(item.bytes)})" }.join(", ")
            " The build keeps about #{human_size(reserved.sum(&:bytes))} of the roomier memory for its own use: #{parts}."
          end

          def top_users(users)
            top(users).map { |user| "#{user.label} (#{human_size(user.bytes)})" }.join(", ")
          end

          # Bytes as a short human size: whole KB where it's exact, one decimal otherwise,
          # and plain bytes under 1KB (so tiny contributors don't all read "0KB").
          def human_size(bytes)
            return "#{bytes}B" if bytes < 1024

            kb = bytes / 1024.0
            kb == kb.round ? "#{kb.round}KB" : "#{format('%.1f', kb)}KB"
          end

          def pluralize(count, noun) = "#{count} #{noun}#{'s' unless count == 1}"
        end
      end
    end
  end
end
