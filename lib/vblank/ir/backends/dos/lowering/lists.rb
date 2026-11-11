# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        class Lowering
          # A GAME'S LISTS, AND THE FIELDS OF ITS POOLS, which are lists too (Runtime::Lists says how one is
          # kept). Mixed into Lowering.
          #
          # Every list a run can reach has its place in the data segment before any code is written, with how
          # many it can hold and how wide a slot is written into its header as the program starts. A step
          # names its list, so each becomes the list's place in BX, its numbers in the registers the
          # runtime's routine takes them in (Runtime::Lists), and a call. The one written out where it stands
          # is a copy from a table (`list.copy_from`), which reads the art segment and writes the data segment
          # at widths both known as the game is built.
          module Lists
            STATEMENT_KINDS = %i[list_new list_push list_drop list_set list_fill list_copy list_sort].freeze
            VALUE_KINDS = %i[list_get list_len].freeze

            # WHERE A LIST IS, and what a reader of the running program asks of it
            # (CartridgeHeadlessRun#read_lists takes each as #to_a): its place in the data segment, how many
            # it can hold, how many bytes a slot is, and its name in words.
            ListPlace = Data.define(:address, :capacity, :slot_bytes, :name) do
              def to_a = [address, capacity, slot_bytes, name]

              # How far a slot's number is shifted to get its place in bytes.
              def shift = slot_bytes.bit_length - 1

              # The register a slot's worth of EAX is in.
              def slot_register = { 1 => :al, 2 => :ax, 4 => :eax }.fetch(slot_bytes)
            end

            # Whether +program+ has any list, and so carries the runtime's routines for them; and whether it
            # puts one in order, which is a routine of its own.
            def self.used_in?(program) = program.walk.any? { |node| (STATEMENT_KINDS + VALUE_KINDS).include?(node.kind) }
            def self.sorted_in?(program) = program.walk.any? { |node| node.kind == :list_sort }

            # Where each list is, as a reader takes it: [place, capacity, bytes a slot, name].
            def lists = @lists.transform_values(&:to_a)

            private

            # A place for each list a run can reach, and the two numbers of its header that never change, set
            # as the program starts: how many it can hold and its shift. Each is set by a write of four bytes,
            # which is nought into the word beside it too: the first slot its items begin in (FRONT, after
            # CAPACITY), and how many it holds (LENGTH, before SHIFT).
            def reserve_lists
              @lists = {}
              @plan.declared_lists.each_value do |node|
                refuse_list_too_long!(node)
                width = LoweringPlan::SLOT_BYTES.fetch(node.width)
                address = @memory.reserve([:list, node.name], Runtime::Lists::HEADER + (node.capacity * width), what: "the list #{node.name.inspect}")
                list = ListPlace.new(address: address, capacity: node.capacity, slot_bytes: width, name: node.name.to_s)
                @lists[node.name] = list
                @starts << [address + Runtime::Lists::CAPACITY, node.capacity]
                @starts << [address + Runtime::Lists::LENGTH, list.shift << 16] unless list.shift.zero?
              end
            end

            def refuse_list_too_long!(node)
              return if node.capacity <= Runtime::Lists::MOST_ITEMS

              raise LoweringError, "The list #{node.name.inspect} holds #{node.capacity} items. A #{CONSOLE.title} list holds " \
                                   "#{Runtime::Lists::MOST_ITEMS} at most. To fix this, make the list shorter, or use two."
            end

            def list_at(name)
              @lists.fetch(name) { raise LoweringError, "the list #{name.inspect} is used and never declared (`list #{name.inspect}, capacity: N`)" }
            end

            def list_place(name) = list_at(name).address

            def emit_list_statement(node)
              case node.kind
              when :list_new then emit_list_new(node)
              when :list_push then emit_list_push(node)
              when :list_drop then emit_list_drop(node)
              when :list_set then emit_list_set(node)
              when :list_fill then emit_list_fill(node)
              when :list_copy then emit_list_copy(node)
              when :list_sort then emit_list_sort(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            def emit_list_value(node)
              case node.kind
              when :list_get then emit_list_get(node)
              when :list_len then emit_list_len(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            def emit_list_push(node) = emit_list_call("rt_list_push", node, edx: node.value)
            def emit_list_set(node) = emit_list_call("rt_list_set", node, eax: node.index, edx: node.value)
            def emit_list_get(node) = emit_list_call("rt_list_get", node, eax: node.index)
            def emit_list_len(node) = emit_list_call("rt_list_length", node)

            # Reference#exec_list_fill: a count of nought or less sets none and asks nothing else. Where it
            # starts or what with may be a sum that stops the game (a read outside another list), so with
            # either to work out, the count is asked first and they are worked out only for one above nought.
            def emit_list_fill(node)
              known = folded(node.count)
              asks_nothing_else = [node.from, node.value].all? { |operand| simple?(value_node(operand)) }
              return emit_list_call("rt_list_fill", node, eax: node.from, ecx: node.count, edx: node.value) if asks_nothing_else || known&.positive?

              none = fresh_label("fills_none")
              emit_value(node.count)
              @asm.cmp(:eax, 0)
              @asm.jle(none)
              emit_list_call("rt_list_fill", node, eax: node.from, ecx: node.count, edx: node.value)
              @asm.label(none)
            end

            # The runtime's +routine+ for the list +node+ names, with each of +numbers+ worked out into the
            # register it is keyed by, in the order written. Working one out can read another list, which
            # leaves that list's place in BX, so this list's place goes in last.
            def emit_list_call(routine, node, **numbers)
              emit_values_into(numbers.keys, numbers.values.map { |operand| value_node(operand) }) unless numbers.empty?
              @asm.mov(:bx, list_place(node.name))
              @asm.call(routine)
            end

            # Reference#exec_list_new: the list as it is declared, with no items, or full of one number.
            def emit_list_new(node)
              @asm.mov(:bx, list_place(node.name))
              return @asm.call("rt_list_empty") unless node.full_of

              @asm.call("rt_list_at_capacity")
              @asm.xor(:eax, :eax)
              @asm.mov(:ecx, node.capacity)
              @asm.mov(:edx, Int32.wrap(node.full_of))
              @asm.call("rt_list_fill")
            end

            def emit_list_drop(node)
              @asm.mov(:bx, list_place(node.name))
              @asm.mov(:al, node.from == :front ? 1 : 0)
              @asm.call("rt_list_drop")
            end

            def emit_list_sort(node)
              @asm.mov(:bx, list_place(node.name))
              @asm.mov(:di, list_place(node.by))
              @asm.mov(:dl, node.descending ? 1 : 0)
              @asm.call("rt_list_sort")
            end

            # Reference#exec_list_copy: the list made to hold a run of a table's entries, from the place asked
            # for held so that the whole run is inside the table. Each entry is read at the width and sign the
            # table keeps it at and written at the width of the list's slots, so a byte the table reads as 200
            # is -56 in a list of bytes. DS is the art segment while the run is copied, and the list is written
            # through SS, which is the data segment.
            def emit_list_copy(node)
              table = @plan.tables.fetch(node.table) { raise LoweringError, "the table #{node.table.inspect} is copied and never declared" }
              list = list_at(node.name)
              return if emit_copy_that_cannot_fit(node, table, list)

              entry_bytes, signed = @plan.table_keeping(table)
              emit_value(Build.clamped(value_node(node.at), Build.int(0), Build.int(table.values.length - node.count)))
              @asm.mov(:bx, list.address)
              @asm.mov(X86.mem(:bx, Runtime::Lists::FRONT, size: 16), 0)
              @asm.mov(X86.mem(:bx, Runtime::Lists::LENGTH, size: 16), node.count)
              return if node.count.zero?

              @asm.mov(:si, :ax)
              @asm.shl(:si, entry_bytes.bit_length - 1) if entry_bytes > 1
              @asm.add(:si, @art_places.fetch(table_key(table.name)))
              @asm.mov(:cx, node.count)
              @asm.xor(:di, :di)
              @asm.mov_segment(:ax, :art)
              @asm.push(:ds)
              @asm.mov(:ds, :ax)
              again = fresh_label("copy_entry")
              @asm.label(again)
              emit_table_entry_read(X86.mem(:si, 0, size: entry_bytes * 8), entry_bytes, signed)
              @asm.mov(X86.mem(:bx, Runtime::Lists::HEADER, index: :di, seg: :ss, size: list.slot_bytes * 8), list.slot_register)
              @asm.add(:si, entry_bytes)
              @asm.add(:di, list.slot_bytes)
              @asm.dec(:cx)
              @asm.jne(again)
              @asm.pop(:ds)
            end

            # A run longer than its table, or than the list, can never be copied, whatever place the game asks
            # for. It is known as the game is built, and the step is then one that stops the game where it is
            # reached, as every cartridge's does (CartridgeFaults): a game that never reaches it plays on. True
            # where the step was written as that.
            def emit_copy_that_cannot_fit(node, table, list)
              code, first, second = if node.count > table.values.length
                                      [CartridgeFaults::COPY_PAST_TABLE, node.count, table.values.length]
                                    elsif node.count > list.capacity
                                      [CartridgeFaults::COPY_TOO_LONG, node.count, list.capacity]
                                    end
              return false unless code

              fault = runtime_at(Runtime::Frame::FAULT).disp
              { 0 => code, Runtime::Frame::FAULT_LIST => list.address, Runtime::Frame::FAULT_FIRST => first,
                Runtime::Frame::FAULT_SECOND => second }.each { |part, number| @asm.mov(X86.mem(nil, fault + part, size: 32), number) }
              @asm.jmp("rt_fault")
              true
            end
          end
        end
      end
    end
  end
end
