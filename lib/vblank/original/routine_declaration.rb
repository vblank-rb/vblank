# frozen_string_literal: true

module VBlank
  module Original
    # WHAT A PORT'S UNPACKING ROUTINE IS DECLARED FROM, short of the files (RoutineFiles): the
    # slots, each part's name and pieces, the blocks the game wrote and where, the formats the copy
    # offers, the release it unpacks, and the console and screen the routine is built for. Written
    # out as text (#source), it is half of what the pack cache keys a routine it built before on
    # (PackCache#pack_of_routine), and what a routine built before in this process is found by
    # (RoutineBuild).
    #
    # A BLOCK IS NAMED BY WHERE IT IS WRITTEN AND THE PLAIN VALUES IT CAN SEE. One line of a game can
    # make many routines: a method that declares the pack with a number it is given, say. So each
    # block is written out with the local variables of the code around it, the ones whose values
    # are plain data (numbers, text, symbols, and lists, tables and Data records of them), and the
    # class of each other one. What an object holds is not written: a routine that reads an
    # object's state is told apart only by the files it was built from.
    RoutineDeclaration = Data.define(:declared_by, :slots, :routines, :platform, :formats, :release, :console, :variant,
                                     :screen_size)

    class RoutineDeclaration
      # How deep a list or a record inside another is written before it is named by its class alone.
      PLAIN_DEPTH = 4

      # The routine's declaration as text, the same for the same declaration in every process.
      def source
        [
          "declared by #{block_source(declared_by)}",
          *slots.map { |slot| "slot #{RoutineDeclaration.plain(slot)}" },
          *routines.map { |routine| "part #{routine.part.inspect} pieces #{routine.pieces.inspect} #{block_source(routine.block)}" },
          "platform #{platform.inspect}",
          "formats #{formats.map { |format| "#{format.name} #{format.format_name.inspect}" }.join(', ')}",
          "release #{release.name.inspect} #{release.size.inspect}",
          "console #{console.inspect} #{variant.inspect} screen #{RoutineDeclaration.plain(screen_size)}"
        ].join("\n")
      end

      # The blocks the game wrote for the routine: the pack's own and each part's.
      def blocks = [declared_by, *routines.map(&:block)].compact

      # +value+ written as text where it is plain data, else its class's name.
      def self.plain(value, depth = 0)
        return value.class.name if depth > PLAIN_DEPTH

        case value
        when Integer, Float, Symbol, String, true, false, nil then value.inspect
        when Range then "#{plain(value.begin, depth + 1)}..#{'.' if value.exclude_end?}#{plain(value.end, depth + 1)}"
        when Array then "[#{value.map { |item| plain(item, depth + 1) }.join(', ')}]"
        when Hash then "{#{value.map { |key, item| "#{plain(key, depth + 1)} => #{plain(item, depth + 1)}" }.join(', ')}}"
        when Data then "#{value.class.name}(#{value.to_h.map { |key, item| "#{key}: #{plain(item, depth + 1)}" }.join(', ')})"
        when Module then value.name || "an anonymous module"
        else value.class.name
        end
      end

      private

      # Where +block+ is written and the plain values it can see. A block Ruby cannot give the
      # variables of (one made from a method) is named for this process alone, so no build in
      # another process takes its routine for this one.
      def block_source(block)
        return "no block" unless block

        place = block.source_location&.join(":")
        seen = block.binding.then do |around|
          around.local_variables.sort.map { |name| "#{name}=#{RoutineDeclaration.plain(around.local_variable_get(name))}" }
        end
        "#{place} #{seen.join(' ')}"
      rescue ArgumentError
        "#{place} in process #{Process.pid} block #{block.object_id}"
      end
    end
  end
end
