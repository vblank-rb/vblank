# frozen_string_literal: true

require "digest"

module VBlank
  module Original
    # A PORT'S WHOLE UNPACKING ROUTINE, BUILT WHEN FIRST ASKED FOR. Building a big port's routine
    # takes many seconds, and a build whose pack is kept (PackCache#pack_of_routine) never needs
    # it. So the build of the data pack holds one of these rather than the routine, and the
    # routine is built only when something asks for it: a pack that is not kept, a shell, a test.
    #
    #   whole = RoutineBuild.new(declaration:, copy_bytes:) do |names, uses, programs|
    #     unpacking_program(..., built_names: names, slot_uses: uses, part_programs: programs)
    #   end
    #   whole.unpacking   # built now, or the one built before
    #
    # The block builds the routine (an Unpacking), and fills the three records it is handed as it
    # goes: the names the build made (BuiltNames), the slots each part used (a Hash of SlotUses by
    # part) and what each part put in the program (PartPrograms).
    #
    # AS IT IS BUILT, the files it is built from are recorded (#files, a RoutineFiles): what the
    # block read, and the game's Ruby. The pack cache keeps them beside the pack.
    #
    # ONE BUILD PER PROCESS. A test suite builds the same game many times, each build declaring the
    # same routine. A routine built before in this Ractor, for the same declaration and copy, whose
    # files are unchanged, is handed out again with its records rather than built again. Each
    # Ractor keeps its own, the last MOST_KEPT of them.
    class RoutineBuild
      # Where each Ractor keeps the routines it built, by key.
      KEPT = :vblank_routine_builds
      MOST_KEPT = 4

      # One routine built: it, its three records and its files.
      Built = Data.define(:unpacking, :names, :uses, :programs, :files)

      # +declaration+ (a RoutineDeclaration) and +copy_bytes+ (the copy the routine is built for)
      # are what the routine is built from besides its files; the block builds it.
      def initialize(declaration:, copy_bytes:, &build)
        @declaration = declaration
        # Written out now, while the values the blocks can see are the ones they are built with.
        @source = declaration.source
        @copy_bytes = copy_bytes
        @build = build
        @built = nil
      end

      # +source+ is the declaration as text (RoutineDeclaration#source), as it was declared.
      attr_reader :declaration, :source, :copy_bytes

      # The routine (an Unpacking).
      def unpacking = built.unpacking

      # The names its build made (BuiltNames).
      def names = built.names

      # The slots each part used, by part name.
      def uses = built.uses

      # What each part put in its program (PartPrograms).
      def programs = built.programs

      # The files it was built from (RoutineFiles).
      def files = built.files

      # Forgets every routine this Ractor built, so the next build of each builds it again, as a
      # new process would. Asked by the pack cache's tests (test_pack_cache_routine_index.rb).
      def self.forget_built = Ractor.current[KEPT] = nil

      private

      def built
        @built ||= kept_build || build_now
      end

      def key = @key ||= Digest::SHA256.hexdigest("#{@source}\0#{Digest::SHA256.hexdigest(@copy_bytes.to_s)}")

      def kept = Ractor.current[KEPT] ||= {}

      def kept_build
        found = kept[key]
        found if found&.files&.unchanged?
      end

      def build_now
        names = BuiltNames.new
        uses = {}
        programs = PartPrograms.new
        read, unpacking = FilesRead.recording { @build.call(names, uses, programs) }
        files = RoutineFiles.recorded(read: read, blocks: @declaration.blocks)
        made = Built.new(unpacking: unpacking, names: names, uses: uses, programs: programs, files: files)
        kept.delete(key)
        kept[key] = made
        kept.delete(kept.keys.first) while kept.size > MOST_KEPT
        made
      end
    end
  end
end
