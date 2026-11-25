# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # How many bytes one routine of the game's takes in a build, its parts together.
      RoutineSize = Data.define(:routine, :bytes)

      class RoutineSize
        # The size of each routine in +routines+ (records with +addresses+ and +routine+, one for each
        # part a big routine was cut into), biggest first, ties by name. The parts of a routine share
        # its name, so they are one entry.
        def self.summed(routines)
          sizes = routines.group_by(&:routine).map do |routine, parts|
            new(routine: routine, bytes: parts.sum { |part| part.addresses.size })
          end
          sizes.sort_by { |size| [-size.bytes, size.routine] }
        end
      end
    end
  end
end
