# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # THE RUNTIME'S FIELDS IN THE STATE IMAGE, in the order each runtime visits them
        # (runtime/rg_state.h). The game's own fields — every global the build wrote, every list —
        # the build finds for itself (Lowering#visit_state); these are what each runtime keeps in
        # its own variables, which the C, JavaScript and Ruby runtimes each name by hand. So they
        # are listed here once, and a test plays a game on each runtime and fails naming any field
        # that runtime writes that is not here, or that is here and it does not write: the three
        # cannot drift apart, and an image written by one reads on the others.
        #
        # +count+ is how many numbers the field holds, or :save_size for as many as the game has
        # bytes of save memory. +with_save_memory+ marks a field only a game that reaches save
        # memory keeps.
        module StateFields
          Field = Data.define(:name, :count, :with_save_memory) do
            def initialize(name:, count:, with_save_memory: false)
              super
            end
          end

          MOST_PLAYERS = IR::Buttons::MOST_PLAYERS
          MOST_TIMERS = 32
          TIMER_NUMBERS = 5 # started, running, its rate, its frames a second, how far it has ticked

          FIELDS = [
            Field.new(name: "runtime.buttons.held", count: MOST_PLAYERS),
            Field.new(name: "runtime.buttons.seen", count: MOST_PLAYERS),
            Field.new(name: "runtime.buttons.pressed", count: MOST_PLAYERS),
            Field.new(name: "runtime.players.connected", count: 1),
            Field.new(name: "runtime.timers", count: MOST_TIMERS * TIMER_NUMBERS),
            Field.new(name: "runtime.timers.order", count: MOST_TIMERS + 1),
            # present, set, moved by frames, the seconds, the ticks, and the days and seconds a game set
            Field.new(name: "runtime.clock", count: 7),
            Field.new(name: "runtime.motor", count: 3), # frames left, the pattern, whether it runs
            Field.new(name: "save.memory", count: :save_size, with_save_memory: true),
            Field.new(name: "save.wiping", count: 1, with_save_memory: true)
          ].freeze

          # The fields a game's state holds besides its own, in order: those of a game that reaches
          # save memory with +save_memory+, else the rest.
          def self.kept(save_memory:) = FIELDS.select { |field| save_memory || !field.with_save_memory }
        end
      end
    end
  end
end
