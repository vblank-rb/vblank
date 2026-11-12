# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        class Lowering
          # WHETHER TWO SPRITES' DRAWN PIXELS TOUCH (`pixels_overlap`), lowered for a PlayStation: a call into
          # Runtime::Collide, and each picture a sprite can show made into a mask of where it draws while the
          # program is built, as the Genesis's lowering makes them (Genesis::Lowering::Collision), a byte a
          # pixel here, since a byte is one load on the R3000 and a bit is three more instructions. Mixed into
          # Lowering.
          module Collision
            VALUE_KINDS = %i[pixels_overlap].freeze

            def value_of_collision_kind(node)
              case node.kind
              when :pixels_overlap then value_of_pixels_overlap(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # Reference#pixels_overlap?: 1 when they touch, 0 when they do not.
            def value_of_pixels_overlap(node)
              runtime_call("rt_pixels_overlap", [LabelAddress.new(mask_list_label(node.a_poses)), node.a_pose, node.a_x, node.a_y,
                                                 LabelAddress.new(mask_list_label(node.b_poses)), node.b_pose, node.b_x, node.b_y])
            end

            # Whether any pixels are asked about, which is when the program carries Runtime::Collide.
            def collides? = !masks.empty?

            # The tables Runtime::Collide reads, as sections for the Linker: each sprite's list of masks (how
            # many, then where each is), and each mask (Runtime::Collide::MASK_PIXELS).
            def collision_sections
              return [] unless collides?

              tables = R3000.new("collision tables", holds: TABLES_HOLDING)
              mask_lists.each do |poses, label|
                tables.label(label)
                tables.data_words(poses.length, *poses.map { |name| masks.fetch(name) })
              end
              masks.each do |name, label|
                image = @cache.image(picture_named(name))
                tables.label(label)
                tables.data_words(image.width, image.height)
                tables.data_bytes(Array.new(image.width * image.height) { |at| image.drawn_at?(at) ? 1 : 0 })
                tables.align
              end
              [tables.section]
            end

            private

            def masks = (@masks ||= {})
            def mask_lists = (@mask_lists ||= {})

            # The label of the list of masks for the pictures +poses+, made once.
            def mask_list_label(poses)
              poses.each { |name| masks[name] ||= "collision mask #{masks.length}" }
              mask_lists[poses] ||= "collision list #{mask_lists.length}"
            end
          end
        end
      end
    end
  end
end
