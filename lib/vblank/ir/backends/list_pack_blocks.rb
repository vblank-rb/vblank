# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A LIST'S ITEMS WRITTEN INTO A LIST OF BYTES AS ONE COPY (IR list_pack), for a console whose
      # lowering has a routine that copies a run of a list's slots: what a save's snapshot is made of
      # (Builder::SaveJobs#save_job_snapshot).
      #
      # The step means the loop it stands for (IR::ListPacking.loops_for): a list_set of each byte in
      # turn, which stops the game at the first slot outside the list it writes into. So the copy is
      # taken only where the whole run is known, as the game runs, to fit: from slot nought or later,
      # and ending inside the list's length. A run that does not fit takes the loop, which stops the
      # game where the interpreter does; nothing a game that runs on does takes it. And only where the
      # build knows the slots are a copy's: the list read is kept at the width it declares, the list
      # written into is kept in bytes and never taken from its front, and neither is a pool's field
      # laid out at a stride (#list_pack_block?, the lowering's).
      #
      # WHAT THE LOWERING SUPPLIES, beside ControlFlow's hooks (fresh_label, place_label, jump,
      # jump_unless, statement):
      #
      #   list_pack_block?(node)        whether the build knows this step's slots are a copy's
      #   emit_list_pack_block(node)    the copy, for a run known to fit
      module ListPackBlocks
        # EVERY CARTRIDGE LOWERING THAT WRITES list_pack ITS OWN WAY, by the lowering's name, with why
        # its way is cheaper there: the ones that mix this module in, and the Advance's, which tests the
        # run in its own instructions (GBA::Lists#emit_list_pack). A lowering not named here takes the
        # loop (IR::ListPacking::Loops); test_list_pack_blocks.rb holds the five to this list, both
        # ways. The measurement behind each is in the commit that added it.
        OWN_WAYS = Ractor.make_shareable(
          {
            "GBA" => "The ARM keeps a number lowest byte first (GBATEK, \"ARM CPU Overview\"), so a plain array's " \
                     "slots are the stage's bytes already, and GBA::Lists#emit_list_pack hands the run to the " \
                     "copy engine, a word at a time, where the loop is a read, a shift and a list_set a byte.",
            "GBC" => "The runtime keeps a slot lowest byte first (Runtime::Lists, rt_list_write), " \
                     "so the slots are the stage's bytes already, and the runtime's " \
                     "rt_list_pack copies them with LD A,(DE) and LD (HL+),A, a few machine cycles a byte, where " \
                     "the loop is two runtime calls a byte, each taking its numbers and finding the slot again."
          }
        )

        def emit_list_pack(node)
          return emit_list_pack_loops(node) unless list_pack_block?(node)

          loops = fresh_label("list_pack_loops")
          done = fresh_label("list_pack_done")
          jump_unless(ListPacking.fit_test(node), loops)
          emit_list_pack_block(node)
          statement(Build.set(node.index, 0))
          jump(done)
          place_label(loops)
          emit_list_pack_loops(node)
          place_label(done)
        end

        def emit_list_pack_loops(node) = ListPacking.loops_for(node).each { |loop| statement(loop) }
      end
    end
  end
end
