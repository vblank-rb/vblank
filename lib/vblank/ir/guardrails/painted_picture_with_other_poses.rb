# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A picture the game paints from a list is the whole of the sprite that shows it.
        #
        # The console keeps such a picture in one room of sprite memory, which the game's list
        # is copied into whenever the game marks it `changed`, and the sprite points at that room. A
        # sprite that switches between poses points at a different picture for each, laid out
        # one after another; a painted picture among them would need a room of its own inside
        # that run, and nothing lays one out there: without this rule the Advance's lowering fails
        # deep in laying out sprite memory, with no word of why.
        #
        # So the mix is refused, and like the count of sprites the rule lives here, so the build,
        # the interpreter (Reference#refuse_painted_picture_with_other_poses!) and every cartridge
        # lowering (GBA::ScreenLayout#prepare_objects, LoweringPlan#refuse_what_console_lacks!)
        # refuse the same programs in the same words. The interpreter alone would draw it, each
        # pose in turn, and a game's own tests play the program without the build's checks, so
        # without its refusal they pass for a game no console's build makes. Each asks this rule
        # before PosesWithDifferentColors: a painted picture beside a pose of another list breaks
        # both, and this is what is really wrong.
        class PaintedPictureWithOtherPoses
          NAME = :painted_picture_with_other_poses
          PLAIN_NAME = "a painted picture beside other poses"

          def detect(program)
            painted = program.walk.filter_map { |node| node.picture if node.kind == :tile_run }
            return [] if painted.empty?

            program.walk.filter_map do |node|
              next unless node.kind == :object

              poses = node.poses.uniq
              picture = poses.find { |pose| painted.include?(pose) }
              next unless picture && poses.size > 1

              Finding.new(check: NAME, severity: :error, message: message(node.declared || node.name, picture), node: node)
            end
          end

          # Why the first such sprite is refused, or nil when no sprite mixes a painted picture
          # with others.
          def refusal_message(program)
            detect(program).first&.message
          end

          private

          def message(sprite, picture)
            "The sprite :#{sprite} shows the picture :#{picture}, which the game paints from a list. It also " \
              "shows other pictures. A painted picture must be the only picture of its sprite. To fix this, " \
              "show :#{picture} on a sprite of its own. Then show one of the two sprites at a time."
          end
        end
      end
    end
  end
end
