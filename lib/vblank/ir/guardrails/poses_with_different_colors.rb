# frozen_string_literal: true

require VBlank.root.join("lib/vblank/ir/stacking").to_s

module VBlank
  module IR
    module Guardrails
      module Checks
        # ONE SPRITE, PICTURES GIVEN DIFFERENT LISTS OF COLORS, on a console whose build keeps one
        # list for a whole sprite.
        #
        # A sprite's pixels are not colors. Each is a small number, a place in a list of
        # sixteen colors, and which list that is gets named in the sprite's row of the table
        # the console composes from, beside the tile it draws. A console's own games write the
        # two together, so a sprite changes list with its pose for nothing, and a build that
        # does the same shows each pose in its own list's colors
        # (Console::Description#poses_keep_own_lists?). This check says nothing there.
        #
        # A build that sets the list once for the whole sprite draws every picture the sprite
        # can show from that one list, and pictures that each came with a list of their own
        # cannot all be shown by it: whichever list the row names, the others' pictures come
        # out in the wrong colors. So such a sprite is refused there, naming the console.
        #
        # A pool is the same thing many times over. Each of its places is a sprite, and any
        # of them can show any of the pool's pictures.
        #
        # Like the count of sprites, the rule lives here so the build, the interpreter and
        # the cartridge lowering refuse the same programs in the same words. The interpreter
        # has no table and no rows — it paints each picture in whatever colors it holds — so
        # without this a game's own tests were green there for a game that could not be built.
        class PosesWithDifferentColors
          NAME = :poses_with_different_colors
          PLAIN_NAME = "a sprite whose pictures have different lists of colors"

          # +as_built+ is the program before the file it is handed was read into it (StartFile.filled),
          # where +program+ is the filled one: it tells which poses are drawn in their frames' banks,
          # which the filled program no longer says (#sprites_following_lists).
          def detect(program, as_built: program)
            console = program.described_console
            return sprites_following_lists(program, console, as_built) if console.poses_keep_own_lists?

            pictures = program.walk.select { |node| node.kind == :bitmap }
            lists = pictures.to_h { |node| [node.name, colors_compared(node.colors, program.start_file)] }
            list_names = pictures.to_h { |node| [node.name, node.colors_name] }
            of_banks = pictures.select(&:bank_places).to_set(&:name)
            sprites = Stacking.objects_in_draw_order(program).uniq { |node| [node.declared || node.name, node.poses] }
            sprites.filter_map do |node|
              by_list = picture_for_each_list(node, lists)
              next if by_list.size < 2

              words = if by_list.values.any? { |picture| of_banks.include?(picture) }
                        banks_message(node, by_list, console)
                      else
                        message(node, by_list, list_names, console)
                      end
              Finding.new(check: NAME, severity: :error, node: node, message: words)
            end
          end

          # Why the sprites are refused, or nil when every one draws from one list.
          def refusal_message(program, as_built: program)
            detect(program, as_built: as_built).first&.message
          end

          private

          # ON A CONSOLE WHOSE BUILD SHOWS EACH POSE IN ITS OWN LIST'S COLORS, what is left to refuse
          # is a sprite told to follow those lists (Object#follows_each), where the build cannot
          # do that yet (Console::Description#pose_lists).
          #
          # A sprite of ONE picture following its list is a sprite drawn with that list, which every
          # console's build makes, so it is not refused. A build that reads its pack as the game
          # starts makes one of a pose whose list its frame picks (Builder::PackPoses
          # #follow_lists_chosen_at_start), where the build that holds the pack draws the sprite with
          # the list.
          #
          # A sprite of SEVERAL such poses, all of banks of one slot, is not refused either. Which
          # bank each frame names is in the player's file, read as the game starts, so the build
          # cannot tell. Where every frame names one bank, the build that holds the pack draws the
          # sprite with that bank's list, as above. Where they name two, which that build refuses, the
          # build for a computer follows each pose's list: the file is the player's, so nothing in it
          # stops the game, as with a frame whose pieces name two banks (#colors_compared).
          #
          # The poses are told apart in +as_built+, the program as the build made it: once the file
          # is read into it, such a pose is a picture of the one list its frame picked.
          def sprites_following_lists(program, console, as_built)
            return [] if console.poses_follow_lists?

            bank_lists_by_pose = as_built.walk.select { |node| node.kind == :bitmap }.to_h { |node| [node.name, frame_bank_lists(node)] }
            following = Stacking.objects_in_draw_order(program).select(&:follows_each)
            following.reject { |node| single_color_source?(node, bank_lists_by_pose) }.map do |node|
              Finding.new(check: NAME, severity: :error, node: node, message: following_message(node, console))
            end
          end

          # The lists of the banks a pose drawn in its frame's bank can be drawn from
          # (StartFile::Pose#bank_lists), or nil for any other picture.
          def frame_bank_lists(node)
            pose_in_file = node.from_file
            pose_in_file.bank_lists if pose_in_file.is_a?(StartFile::Pose)
          end

          # Whether the sprite +node+ takes its colours from one source: it shows one picture, or only
          # poses drawn in their frames' banks of one slot (+bank_lists_by_pose+ holds each picture's
          # bank lists, nil for any other).
          def single_color_source?(node, bank_lists_by_pose)
            poses = node.poses.uniq
            return true if poses.one?

            slots = poses.map { |pose| bank_lists_by_pose[pose] }.uniq
            slots.one? && !slots.first.nil?
          end

          def following_message(node, console)
            lists = node.follows_each.map { |name| "#{name}: :#{name}" }.join(", ")
            "#{SpriteWords.owner_capitalized(node)} shows pictures that have different `colors:` lists, and it " \
              "was told to follow them with `draw_with({ #{lists} })`. The #{console.title} build does not make " \
              "that yet. It draws each picture in the colors of its own list. To fix this, give all the pictures " \
              "of the #{SpriteWords.member_word(node)} the same `colors:` list. Then tell it to `draw_with` that list."
          end

          # A PICTURE'S LIST AS IT IS COMPARED WITH ANOTHER: +colors+ as they are, except where the
          # program reads its data pack as it starts (+start_file+) and a pose is drawn in the bank
          # its frame names. That pose's list is a marker for each place of "the bank frame N names"
          # (StartFile::ChosenColor), so two frames give two lists even where both name one bank,
          # which the build cannot tell: the bank is in the player's file. Nothing in that file may
          # stop the game, so such places are compared without the frame that picks the bank, and
          # poses of one slot's banks count as one list. Where the frames name one bank this is the
          # all-in-one build's answer; where they name two, which that build refuses, the build
          # for a computer draws each pose in its own frame's bank.
          def colors_compared(colors, start_file)
            return colors unless colors && start_file

            colors.map do |color|
              next color unless StartFile.marker?(color)

              source = start_file.colors.fetch(StartFile.entry_of(color))
              source.is_a?(StartFile::ChosenColor) ? source.with(choice: nil) : color
            end
          end

          # Each different list this sprite's pictures were given, with the first picture given
          # it. A picture given none is filed under nil. A pose naming no declared picture is
          # left out: that is a different mistake, with words of its own.
          def picture_for_each_list(node, lists)
            node.poses.uniq.select { |pose| lists.key?(pose) }.group_by { |pose| lists[pose] }.transform_values(&:first)
          end

          def message(node, by_list, list_names, console)
            "#{SpriteWords.owner_capitalized(node)} #{disagreement_sentence(by_list, list_names)} The #{console.title} " \
              "build draws all the pictures of one sprite from one list of colors.#{pool_note(node)} To fix this, give all " \
              "its pictures the same `colors:` list. Or give none of them a `colors:` list. Then the " \
              "framework makes the list. Or use one #{SpriteWords.member_word(node)} for the pictures of each list. " \
              "To change the colors of one #{SpriteWords.member_word(node)}, tell " \
              "it to `draw_with` a list that `colors` declares."
          end

          # A POSE OF SEVERAL BANKS (Nodes::Bitmap#bank_places, `banks:`) beside a pose of other banks:
          # their `colors:` may be the same slot, so "different lists" would send the author to a list
          # that is the same. The banks the poses name are what differ.
          def banks_message(node, by_list, console)
            named = by_list.values.first(3).map { |picture| ":#{picture}" }.join(" and ")
            "#{SpriteWords.owner_capitalized(node)} shows poses that name different banks of colors (#{named}). The " \
              "#{console.title} build draws all the pictures of one sprite from the same colors.#{pool_note(node)} To fix " \
              "this, give every pose of the #{SpriteWords.member_word(node)} the same banks:, the banks that all their " \
              "frames use. Or use one #{SpriteWords.member_word(node)} for the poses of each set of banks."
          end

          # A picture with a list beside one with none is given as that, since "different lists"
          # would send the author looking for a second list that is not there. Pictures whose
          # lists all have names are given with them, since the game may not have written the
          # name down: a pose from a data pack takes its list from the bank its frame names.
          def disagreement_sentence(by_list, list_names)
            bare = by_list[nil]
            listed = by_list.except(nil).values
            if bare
              return "shows a picture that has a `colors:` list (:#{listed.first}) and a picture that has " \
                     "none (:#{bare})."
            end

            shown = listed.first(3)
            named = shown.map { |picture| ":#{picture}" }.join(" and ")
            return "shows pictures that have different `colors:` lists (#{named})." unless shown.all? { |picture| list_names[picture] }

            drawn = shown.map { |picture| ":#{picture} is drawn from :#{list_names[picture]}" }.join(" and ")
            "shows pictures that have different `colors:` lists (#{named}): #{drawn}."
          end

          def pool_note(node)
            SpriteWords.pool?(node) ? " Each instance of a pool is one sprite." : ""
          end
        end
      end
    end
  end
end
