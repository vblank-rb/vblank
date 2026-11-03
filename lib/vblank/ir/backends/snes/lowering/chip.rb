# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # ROUTINES THAT RUN ON THE SUPER FX, from the console's side. A routine marked `on_chip:
          # true`, on a cartridge with that chip, is made by ChipCode. Here it is still a routine like
          # any other: its label is 65816 code, which any call reaches. That code copies the
          # variables the chip needs into the chip's RAM, runs the chip until it stops, and copies
          # back the ones it can have changed. The console waits in between (Runtime::Chip).
          #
          # On any other cartridge there is no chip, the word means nothing, and the routine is made
          # as usual. A step the chip cannot do is refused here, in plain words, rather than run on the
          # console instead: the author asked for this routine to be quick, and would find it slow
          # with nothing to say why.
          module Chip
            # The kinds of IR a routine on the chip can hold besides what ChipCode makes, which say
            # nothing while the game runs.
            MADE = Ractor.make_shareable((ChipCode::STATEMENTS.keys + ChipCode::VALUES.keys + [:else]).to_h { |kind| [kind, true] })
            FRACTION_STEPS = %i[mul_fix div_fix shift_right].freeze
            # Where each 16-bit half of a variable is, for copying.
            HALVES = [0, 2].freeze

            private

            def prepare_chip(chip)
              @chip_routines = chip ? @called.select { |name| @funcs.fetch(name).on_chip } : []
              @chip_code = nil
            end

            def on_chip?(name) = @chip_routines.include?(name)

            # Every step a run of a chip routine reaches that the chip cannot do, the first of them
            # refused by name. A routine nothing calls never runs, and is not refused.
            def refuse_what_chip_cannot_run!
              @chip_routines.each do |name|
                Reach.statements_under(@funcs.fetch(name)).each do |node|
                  next if MADE[node.kind] && node.kind != :call
                  next if Nodes.of_role(:declaration).include?(node.kind)

                  refuse_chip_call!(name, node.target) if node.kind == :call && !on_chip?(node.target)
                  refuse_chip_step!(name, node) unless node.kind == :call
                end
              end
            end

            def refuse_chip_call!(name, target)
              raise LoweringError, "The routine #{name.inspect} runs on the Super FX chip. It calls the routine " \
                                   "#{target.inspect}, and that routine does not run on the chip. To fix this, add " \
                                   "on_chip: true to #{target.inspect}, or move the call out of #{name.inspect}."
            end

            def refuse_chip_step!(name, node)
              where = node.source ? " (#{node.source})" : ""
              raise LoweringError, "The routine #{name.inspect} runs on the Super FX chip. It has a step that the chip " \
                                   "cannot do: #{chip_step_words(node)}#{where}. To fix this, move the step out of " \
                                   "#{name.inspect}. Do the step before or after the call."
            end

            def chip_step_words(node)
              kind = node.kind
              return "a sum with fractions" if FRACTION_STEPS.include?(kind)
              return "a wait for the next frame" if kind == :wait_vblank
              return "a use of a list (#{kind})" if kind.start_with?("list_")
              return "a read of a table (#{kind})" if kind.start_with?("table_")
              return "a drawing step (#{kind})" if node.category == :draw
              return "a sound step (#{kind})" if node.category == :sound

              "the step #{kind}"
            end

            # The chip's code, as sections for the Linker: none for a game with nothing to run there.
            def chip_sections
              return [] if @chip_routines.empty?

              [@chip_code.section]
            end

            def make_chip_code
              return if @chip_routines.empty?

              @chip_code = ChipCode.new(routines: @chip_routines, funcs: @funcs, plan: @plan, holds: ROUTINES)
            end

            # The 65816 routine that stands for +name+.
            def chip_routine_section(name)
              routine_section(self.class.routine_label(name), [], routine: routine_said(name)) { emit_chip_run(name) }
            end

            def emit_chip_run(name)
              @chip_code.variables_sent(name).product(HALVES).each do |(variable, at), half|
                @asm.lda(at_place(place_of(variable) + half))
                @asm.sta(@asm.long(chip_ram_address(at) + half))
              end
              value(LongAddress.new(ChipCode.entry_label(name)))
              call_routine("rt_chip_run")
              @chip_code.variables_changed(name).product(HALVES).each do |(variable, at), half|
                @asm.lda(@asm.long(chip_ram_address(at) + half))
                @asm.sta(at_place(place_of(variable) + half))
              end
            end

            def chip_ram_address(at) = Runtime::ChipPaint::COPY | at
          end
        end
      end
    end
  end
end
