# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # SAVE MEMORY, lowered for a Super Nintendo: each save step a call into Runtime::Saving,
          # with the places in save memory worked out by IR::SaveLayout, so the cartridge's
          # battery-backed RAM holds the bytes the interpreter's save memory holds. Mixed into
          # Lowering.
          module Saving
            STATEMENT_KINDS = %i[save_init save_store save_write save_erase save_load_list save_store_list].freeze

            def emit_saving_statement(node)
              case node.kind
              when :save_init then emit_save_init(node)
              when :save_store then emit_save_store(node)
              when :save_write then emit_save_write(node)
              when :save_erase then emit_save_erase(node)
              when :save_load_list, :save_store_list then emit_save_list_move(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end
            VALUE_KINDS = %i[save_read save_sum].freeze

            def value_of_saving_kind(node)
              case node.kind
              when :save_read then value_of_save_read(node)
              when :save_sum then value_of_save_sum(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # How many bytes of save memory a read or a write moves, by the width it names: the
            # interpreter's own table, so the two cannot count a width differently.
            SAVE_BYTES = Reference::SAVE_WIDTHS

            private

            # A Super Nintendo cartridge saves in 32K of battery-backed RAM (Runtime::Saving). A game
            # that names flash or an EEPROM lays its save memory out for that chip — its blocks, and
            # its save_vars kept in a record — which this RAM does not have. Every board keeps one:
            # where it is on a Super FX board is Cartridge::SNESROM::SUPER_FX's to set.
            def refuse_unsupported_save_memory!
              return unless SaveLayout.named_by?(@program)

              memory = SaveLayout.memory_of(@program)
              return if memory.battery?

              raise LoweringError, "This game saves in #{memory.kilobytes}K of #{memory.kind_words}, and a Super " \
                                   "Nintendo cartridge saves in 32K of battery-backed RAM. To fix this, leave " \
                                   "`save_memory:` out of the game."
            end

            # Reference#exec_save_init: every `save_var` takes its saved number when save memory
            # carries the game's marker, and the number it was declared with when it does not. Each
            # is written back, and the marker after them, in that order, so a power cut lands on the
            # byte it lands on in the interpreter.
            def emit_save_init(node)
              saved = keep_local(:saved)
              marker_at = Build.int(SaveLayout::SAVE_VAR_MARKER_AT)
              marker = Int32.wrap(node.magic)
              value(Build.binop(:==, Build.save_read(marker_at, width: :word), Build.int(marker)))
              store(saved)
              node.vars.each do |kept|
                at = Build.int(SaveLayout.save_var_at(kept.slot))
                declared = fresh("declared_number")
                chosen = fresh("number_chosen")
                jump_unless(Build.var_ref(saved), declared)
                value(Build.save_read(at, width: :word))
                @asm.brl(chosen)
                @asm.label(declared)
                load_constant(Int32.wrap(kept.default))
                @asm.label(chosen)
                store(kept.name)
                runtime_call("rt_save_write", [at, Build.var_ref(kept.name), Build.int(SAVE_BYTES.fetch(:word))])
              end
              runtime_call("rt_save_write", [marker_at, Build.int(marker), Build.int(SAVE_BYTES.fetch(:word))])
            end

            # Reference#exec_save_store: one `save_var`'s number into its place.
            def emit_save_store(node)
              at = Build.int(SaveLayout.save_var_at(node.slot))
              runtime_call("rt_save_write", [at, Build.var_ref(node.var), Build.int(SAVE_BYTES.fetch(:word))])
            end

            # Reference#exec_save_write: the place worked out first and the value after it, as the
            # interpreter does.
            def emit_save_write(node) = runtime_call("rt_save_write", [node.at, node.value, save_width(node)])

            # A whole list moved to or from save memory (Reference#exec_save_load_list,
            # #exec_save_store_list) as a block, by a routine of the runtime's (Runtime::Saving
            # #emit_list_moves), handed a count it can copy without looking (SaveListMoves#load_count).
            # The step's counter is left at nought, as every backend leaves it.
            def emit_save_list_move(node)
              if node.kind == :save_load_list
                capacity = @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is used and never declared" }[1]
                refusal = SaveListMoves.past_capacity_message(node, capacity)
                raise LoweringError, refusal if refusal

                list_call("rt_save_load_list", node, node.at, SaveListMoves.load_count(node))
              else
                list_call("rt_save_store_list", node, node.at)
              end
              emit_statement(Build.set(node.index, 0))
            end

            # Reference#exec_save_erase: battery-backed RAM needs no wiping, but the place is worked
            # out all the same, as the interpreter works it out.
            def emit_save_erase(node) = runtime_call("rt_save_erase", [node.at])

            def value_of_save_read(node) = runtime_call("rt_save_read", [node.at, save_width(node)])
            def value_of_save_sum(node) = runtime_call("rt_save_sum", [node.at, node.length])

            def save_width(node) = Build.int(SAVE_BYTES.fetch(node.width))
          end
        end
      end
    end
  end
end
