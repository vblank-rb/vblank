# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # Save memory, lowered for a Genesis: each save step a call into Runtime::Saving, with the places in
          # save memory worked out by IR::SaveLayout, so the cartridge's battery-backed RAM holds the bytes the
          # interpreter's save memory holds. Mixed into Lowering.
          module Saving
            STATEMENT_KINDS = %i[save_init save_store save_write].freeze

            def emit_saving_statement(node)
              case node.kind
              when :save_init then emit_save_init(node)
              when :save_store then emit_save_store(node)
              when :save_write then emit_save_write(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            VALUE_KINDS = %i[save_read].freeze

            def value_of_saving_kind(node)
              case node.kind
              when :save_read then value_of_save_read(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # How many bytes of save memory a read or a write moves, by the width it names: the interpreter's
            # own table, so the two cannot count a width differently.
            SAVE_BYTES = Reference::SAVE_WIDTHS

            private

            # A Genesis cartridge saves in 32K of battery-backed RAM (Runtime::Saving). A game built for the
            # console is given that (Console::Description#save_memories). A program that names flash or an
            # EEPROM lays its save memory out for that chip, which this RAM does not have, and one that names
            # more than 32K has places past its end.
            def refuse_unsupported_save_memory!
              return unless SaveLayout.named_by?(@program)

              memory = SaveLayout.memory_of(@program)
              return if memory.battery? && memory.size <= Runtime::Saving::SIZE

              raise LoweringError, "This game saves in #{memory.kilobytes}K of #{memory.kind_words}. This Genesis " \
                                   "cartridge saves in #{Runtime::Saving::SIZE / 1024}K of battery-backed " \
                                   "RAM. To fix this, build the game for this console, and the build gives it " \
                                   "the save memory that the cartridge keeps."
            end

            # Reference#exec_save_init: every `save_var` takes its saved number when save memory carries the
            # game's marker, and the number it was declared with when it does not. Each is written back, and the
            # marker after them, in that order, so a power cut lands on the byte it lands on in the interpreter.
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
                jump(chosen)
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

            # Reference#exec_save_write: the place worked out first and the value after it, as the interpreter
            # does.
            def emit_save_write(node) = runtime_call("rt_save_write", [node.at, node.value, save_width(node)])

            def value_of_save_read(node) = runtime_call("rt_save_read", [node.at, save_width(node)])

            def save_width(node) = Build.int(SAVE_BYTES.fetch(node.width))
          end
        end
      end
    end
  end
end
