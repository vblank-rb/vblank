# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # THE RUNTIMES' FEATURES. The native, JavaScript and Ruby lowerings each play a game on a runtime
      # written by hand in their language (native/runtime/, js/runtime/, ruby/runtime/). A drawing
      # feature only some games use is not part of those runtimes' screen files: it is a folder of its
      # own here, runtime_features/<name>/, holding its C (rg_<name>.c, and rg_<name>.h for what the
      # game calls), its JavaScript and its Ruby side by side, and a feature.rb that declares it: the
      # kinds of step that need it, the hooks it takes and the features it must come after.
      #
      # A game's build takes in only the features its steps need. Each language joins a feature into
      # the screen's own scope, so a feature reads the screen's state and painters as if it were written
      # there: JavaScript and Ruby join their runtime files into one script, and the C screen includes
      # the file the build writes for the game (#c_text) at its end.
      #
      # WHICH RUNTIME A FEATURE JOINS (+joins+). Screen features (the default) are joined into the
      # screen; sound features (+joins: :sound+) into the sound runtime. In C each is a translation
      # unit of its own, and so has an include point of its own, at its end, for the file the build
      # writes for it (#c_text); JavaScript and Ruby join every runtime file into one script, so
      # there the only difference is which hooks a feature may take.
      #
      # THE HOOKS are where a runtime calls whatever features take them, and it names no feature.
      # Each says which runtime calls it (+joins+) and how several takers are combined (+way+):
      # :each runs every taker in order; :claim
      # runs takers in order until one answers that it did the work; :all is true unless a taker
      # answers false; :one is at most one taker's answer, the hook's +default+ when none takes it.
      # A hook none of a game's features take does what the screen does with no feature at all,
      # which is written in each language once: rg_screen_hook_defaults.h and rg_sound_hook_defaults.h for C, and here for the two
      # whose dispatchers this writes whole.
      #
      # Must not be called once a pixel. A hook in JavaScript and Ruby is a real call, and a screen
      # does tens of thousands of pixels a frame. Where a feature changes what happens to each pixel,
      # the screen asks it once (a layer to paint into, a layer shown in front) and its loop reads
      # what it was handed (paint_onto_plain_layer, front_layer).
      module RuntimeFeatures
        ROOT = Ractor.make_shareable(File.expand_path("runtime_features", __dir__))
        LANGUAGES = Ractor.make_shareable(%i[c js ruby])
        WRITTEN_BY_C = "/* Written by VBlank's native backend: the game's runtime features. Do not edit. */\n"
        RUBY_MAGIC_COMMENT = "# frozen_string_literal: true\n" # The first line of a feature's Ruby, left out where it is joined

        # +params+ are the hook's arguments by name; +default+, for a :one hook, is the answer with no
        # taker: one of the params, a number, or :null. +languages+ are the runtimes that have the hook, and
        # +c_signature+ is the C one as rg_screen.c declares it (the compiler holds the two alike).
        # +joins+ is the C runtime that calls it, :screen or :sound.
        Hook = Data.define(:name, :way, :params, :default, :languages, :c_signature, :joins) do
          def initialize(name:, way:, params: [], default: nil, languages: LANGUAGES, c_signature: nil, joins: :screen)
            super
          end
        end

        HOOKS = Ractor.make_shareable([
          # Ruby keeps the runtime's state in instance variables set as it starts (rg_screen_setup).
          Hook.new(name: :setup, way: :each, languages: %i[ruby]),
          # A screen of a new kind is up (Reference#exec_screen).
          Hook.new(name: :screen_set, way: :each, c_signature: "static void rg_hook_screen_set(void)"),
          # That screen took the place of one of another kind, which went with what was up on it.
          Hook.new(name: :screen_crossed, way: :each, params: %i[new_kind],
                   c_signature: "static void rg_hook_screen_crossed(int32_t new_kind)"),
          # A frame boundary is reached, before the pages trade places (Reference#advance_frame).
          Hook.new(name: :frame_ended, way: :each, c_signature: "static void rg_hook_frame_ended(void)"),
          # A rebuild of the whole view is asked for (Reference#request_repaint).
          Hook.new(name: :repaint_requested, way: :each, c_signature: "static void rg_hook_repaint_requested(void)"),
          # An owed rebuild was painted, or none was owed (Reference#paint_owed_repaint).
          Hook.new(name: :rebuild_checked, way: :each, c_signature: "static void rg_hook_rebuild_checked(void)"),
          # The rebuild has cleared the picture to the backdrop, and paints nothing else yet.
          Hook.new(name: :repaint_began, way: :each, c_signature: "static void rg_hook_repaint_began(void)"),
          # The rebuild is at one level of the stack, before that level's sprites.
          Hook.new(name: :paint_level, way: :each, params: %i[level],
                   c_signature: "static void rg_hook_paint_level(int32_t level)"),
          # The rebuild has painted every level.
          Hook.new(name: :repaint_ending, way: :each, c_signature: "static void rg_hook_repaint_ending(void)"),
          # The scenery up, stamped onto the copy kept to put back under sprites (Reference#scene_framebuffer).
          Hook.new(name: :stamp_scenery, way: :each, c_signature: "static inline void rg_hook_stamp_scenery(void)"),
          # Whether any scenery is up, so a new backdrop has the picture built again rather than cleared.
          Hook.new(name: :scenery_up, way: :claim, c_signature: "static int32_t rg_hook_scenery_up(void)"),
          # Whether scenery showing now is in a see-through layer (Reference#layer_has_anything?).
          Hook.new(name: :layer_holds_scenery, way: :claim, params: %i[layer],
                   c_signature: "static int32_t rg_hook_layer_holds_scenery(int32_t layer)"),
          # A scene takes over; a taker that takes scenery down answers true (Reference#take_down_scenery).
          Hook.new(name: :scene_take_down, way: :claim, params: %i[brings_scenery],
                   c_signature: "static int32_t rg_hook_scene_take_down(int32_t brings_scenery)"),
          # The size of the blocks scenery and sprites are painted in, in pixels each way: 1 for no
          # blocks. Scenery or a sprite the game left as drawn ignores it.
          # Must be inline in C: only the tiled and sprites features ask it, and the compiler counts an
          # unasked inline function as no fault.
          Hook.new(name: :block_size, way: :one, default: 1,
                   c_signature: "static inline int32_t rg_hook_block_size(void)"),
          # How many sprites the game last put on screen, and the one at a place among them
          # (Reference#sprites): what the headless runners read, with or without sprites.
          Hook.new(name: :drawn_count, way: :one, default: 0, c_signature: "static int32_t rg_hook_drawn_count(void)"),
          Hook.new(name: :drawn_sprite, way: :one, params: %i[place], default: :null,
                   c_signature: "static rg_drawn_sprite rg_hook_drawn_sprite(int32_t place)"),
          # Whether any sprite is kept for the next rebuild (Reference#redraw_sprites_over_arrived_scenery).
          Hook.new(name: :any_sprite_kept, way: :claim, c_signature: "static int32_t rg_hook_any_sprite_kept(void)"),
          # The layer shown in front of the picture as it is read (sprites over a painted screen), a
          # screen's worth of cells holding RG_NOTHING_IN_FRONT where nothing is (nil in Ruby), or
          # null for no layer. Asked once a read.
          Hook.new(name: :front_layer, way: :one, default: :null,
                   c_signature: "static const uint16_t *rg_hook_front_layer(void)"),
          # Whether a painted screen can be read as it is stored, row for row. JavaScript reads it a
          # pixel at a time always, so has no such shortcut.
          Hook.new(name: :shown_plain, way: :all, languages: %i[c ruby], c_signature: "static int32_t rg_hook_shown_plain(void)"),
          # The stored column each screen column is read from, or null for its own.
          Hook.new(name: :shown_columns, way: :one, default: :null, c_signature: "static const int64_t *rg_hook_shown_columns(void)"),
          # The stored row a screen row is read from.
          Hook.new(name: :shown_row, way: :one, params: %i[y], default: :y, c_signature: "static int64_t rg_hook_shown_row(int64_t y)"),
          # The FILTER the finished picture is read through when a fade or tint changes a colour, or
          # null when none does (Framebuffer#faded). Asked once a read, after any owed rebuild. A
          # filter is plain data, so the loop that reads the picture asks nothing a pixel:
          #   table:      the colour shown for each value a cell holds, indexed by its sixteen bits;
          #   everywhere: whether it applies to every pixel;
          #   rows:       when not, for each screen row [from, to, inverted]: a pixel is changed
          #               when inverted XOR from <= x < to;
          #   remix:      whether a see-through mixed cell is mixed again from its two sides, each
          #               through the table (Framebuffer#shown_color).
          Hook.new(name: :fade_filter, way: :one, default: :null,
                   c_signature: "static const shown_filter *rg_hook_fade_filter(void)"),
          # The same for a light darkening the rest of each row (Framebuffer#shade_outside), applied
          # after the fade's. Asked once a read.
          Hook.new(name: :dim_filter, way: :one, default: :null,
                   c_signature: "static const shown_filter *rg_hook_dim_filter(void)"),
          # The colour table a thing is painted through while a fade placed in the stack reaches it
          # (Reference#set_blend_for), or null where it is left as drawn. +fade_place+ is how far
          # forward the thing's layer is. Asked once a thing painted, never once a pixel.
          Hook.new(name: :paint_fade_for, way: :one, params: %i[fade_place], default: :null,
                   c_signature: "static const uint16_t *rg_hook_paint_fade_for(int32_t fade_place)"),
          # Whether a fade holds the display's blend, so a see-through layer is solid
          # (Reference#fading?). Asked once a thing painted.
          Hook.new(name: :blend_held_by_fade, way: :claim,
                   c_signature: "static int32_t rg_hook_blend_held_by_fade(void)"),

          # --- the sound runtime's hooks (rg_sound.c) ---

          # The frame begins (Reference#advance_frame): every feature's work for the frame, in order.
          # The mixer's slice is made before the tune plays, so the music comes after the mix.
          Hook.new(name: :sound_frame, way: :each, joins: :sound, c_signature: "static void rg_hook_sound_frame(void)"),
          # The frame's sound work is done: what has to be moved on after the tune has played (the
          # mixer steps every sounding note's shape).
          Hook.new(name: :sound_frame_ended, way: :each, joins: :sound,
                   c_signature: "static void rg_hook_sound_frame_ended(void)"),
          # The game's own beep, wave or stop_wave took a console voice (Reference::Player#game_sound_on):
          # a tune's note there no longer wobbles or steps its shapes. Never asked for `noise`.
          Hook.new(name: :voice_taken_by_game, way: :each, params: %i[voice], joins: :sound,
                   c_signature: "static void rg_hook_voice_taken_by_game(int32_t voice)"),
          # The newest slice of mixed recordings, handed to the render of a frame: how many samples it
          # holds and, in +samples+, where they are; 0 for a game that mixes nothing. Asked once a
          # frame, never once a sample.
          Hook.new(name: :mixed_slice, way: :one, params: %i[samples], default: 0, joins: :sound,
                   c_signature: "static int32_t rg_hook_mixed_slice(const int32_t **samples)"),
          # A windowless run prints a moment (rg_headless.c and its twins): each feature prints the
          # lines of its own state. A game with none of them prints nothing here.
          Hook.new(name: :moment_printed, way: :each, joins: :sound,
                   c_signature: "static void rg_hook_moment_printed(void)")
        ])

        # +needed_by+ is the kinds of step that need the feature; +after+ the features whose hooks
        # must run before its own when a game has both; +joins+ the runtime it is joined into.
        Feature = Data.define(:name, :needed_by, :hooks, :after, :joins) do
          def initialize(name:, needed_by:, hooks:, after: [], joins: :screen)
            super
          end

          def folder = File.join(ROOT, name.to_s)
          def file(extension) = File.join(folder, "rg_#{name}.#{extension}")

          # The header a game that uses it includes, for the functions its steps call, if it has one.
          def c_header = File.exist?(file("h")) ? "#{name}/rg_#{name}.h" : nil

          # The text of its call for +hook+, with the hook's own arguments.
          def hook_call_text(hook) = "rg_#{name}_#{hook.name}(#{hook.params.join(', ')})"
        end

        # The features declared so far, filled while the feature files load and copied into ALL after.
        @declared = []

        class << self
          # Each feature.rb calls this as it is loaded, before ALL is set.
          def declare(name:, needed_by:, hooks:, after: [], joins: :screen)
            @declared << Feature.new(name: name, needed_by: needed_by, hooks: hooks, after: after, joins: joins)
          end

          attr_reader :declared

          # Every hook a feature names is one the runtimes have, and a :one hook has one taker at most.
          def refuse_wrong_hooks!(features)
            features.each do |feature|
              unknown = feature.hooks - HOOKS.map(&:name)
              raise ArgumentError, "runtime feature #{feature.name} takes hooks no runtime has: #{unknown.join(', ')}" if unknown.any?

              # A C hook is called by one runtime, so only a feature joined into it can take it.
              elsewhere = HOOKS.select { |hook| feature.hooks.include?(hook.name) && hook.languages.include?(:c) && hook.joins != feature.joins }
              next if elsewhere.empty?

              raise ArgumentError, "runtime feature #{feature.name} joins the #{feature.joins} runtime, and the " \
                                   "#{elsewhere.map(&:name).join(', ')} hooks are called by another"
            end
            HOOKS.select { |hook| hook.way == :one }.each do |hook|
              takers = features.select { |feature| feature.hooks.include?(hook.name) }
              next if takers.size <= 1

              raise ArgumentError, "the #{hook.name} hook has one taker at most, and #{takers.map(&:name).join(' and ')} each take it"
            end
          end

          # The features of +among+ that +steps+ (every step of the program) need, each after those it
          # names.
          def used_by(steps, among: ALL)
            kinds = steps.to_set(&:kind)
            in_order(among.select { |feature| feature.needed_by.any? { |kind| kinds.include?(kind) } })
          end

          # --- C: the file the screen, or the sound runtime, includes at its end ---

          # The file for the features that join +joins+: each is defined as RG_FEATURE_<NAME> (so a
          # feature can tell whether another is in the same file), then included, then the dispatcher
          # for each of that runtime's hooks that a feature takes.
          def c_text(features, joins: :screen)
            mine = features.select { |feature| feature.joins == joins }
            [WRITTEN_BY_C,
             *mine.map { |feature| "#define RG_FEATURE_#{feature.name.to_s.upcase}\n" },
             *mine.map { |feature| "#include \"#{feature.name}/rg_#{feature.name}.c\"\n" },
             *HOOKS.filter_map do |hook|
               c_dispatcher(hook, takers(hook, mine)) if hook.languages.include?(:c) && hook.joins == joins
             end].join
          end

          def c_headers(features) = features.filter_map(&:c_header)

          # --- JavaScript and Ruby: the features' files, and every hook's dispatcher ---

          def js_text(features)
            [*features.map { |feature| File.read(feature.file("js"), encoding: Encoding::UTF_8) },
             *HOOKS.filter_map { |hook| js_dispatcher(hook, takers(hook, features)) if hook.languages.include?(:js) }].join
          end

          def ruby_text(features)
            [*features.map { |feature| File.read(feature.file("rb"), encoding: Encoding::UTF_8).delete_prefix(RUBY_MAGIC_COMMENT) },
             *HOOKS.filter_map { |hook| ruby_dispatcher(hook, takers(hook, features)) if hook.languages.include?(:ruby) }].join
          end

          # Every runtime file a feature has in +extension+, for what reads all of a runtime's functions.
          def every_file(extension) = ALL.map { |feature| feature.file(extension) }

          private

          def takers(hook, features) = features.select { |feature| feature.hooks.include?(hook.name) }

          # Ordered so each comes after what it names, and otherwise by name, so a build is the same
          # whichever order the folders were found in.
          def in_order(features)
            placed = []
            pending = features.sort_by(&:name)
            until pending.empty?
              ready = pending.find { |feature| (feature.after & pending.map(&:name)).empty? }
              raise ArgumentError, "runtime features #{pending.map(&:name).join(', ')} each come after another" unless ready

              placed << ready
              pending.delete(ready)
            end
            placed
          end

          # C: only a taken hook is written, marked so the defaults leave it out.
          def c_dispatcher(hook, found)
            return nil if found.empty?

            calls = found.map { |feature| feature.hook_call_text(hook) }
            body = case hook.way
                   when :each then calls.map { |line| "  #{line};\n" }.join
                   when :claim then calls.map { |line| "  if (#{line}) return 1;\n" }.join + "  return 0;\n"
                   when :all then "  return #{calls.join(' && ')};\n"
                   when :one then "  return #{calls.first};\n"
                   end
            "#define RG_HOOK_#{hook.name.upcase}_TAKEN\n#{hook.c_signature} {\n#{body}}\n"
          end

          # The text a JavaScript or Ruby dispatcher answers with: the takers' calls combined by the
          # hook's way, or what the hook answers with no taker (+null+ is the language's null). For an
          # :each hook, the calls to make, one to a line.
          def answer_text(hook, found, null)
            calls = found.map { |feature| feature.hook_call_text(hook) }
            case hook.way
            when :each then calls
            when :claim then calls.empty? ? "false" : calls.join(" || ")
            when :all then calls.empty? ? "true" : calls.join(" && ")
            when :one then calls.first || (hook.default == :null ? null : hook.default.to_s)
            end
          end

          def js_dispatcher(hook, found)
            answer = answer_text(hook, found, "null")
            body = hook.way == :each ? answer.map { |line| "  #{line};\n" }.join : "  return #{answer};\n"
            "function rg_hook_#{hook.name}(#{hook.params.join(', ')}) {\n#{body}}\n"
          end

          def ruby_dispatcher(hook, found)
            answer = answer_text(hook, found, "nil")
            params = hook.params.empty? ? "" : "(#{hook.params.join(', ')})"
            body = hook.way == :each ? answer.map { |line| "  #{line}\n" }.join : "  #{answer}\n"
            "def rg_hook_#{hook.name}#{params}\n#{body}end\n"
          end
        end
      end
    end
  end
end

Dir.glob(File.join(VBlank::IR::Backends::RuntimeFeatures::ROOT, "*", "feature.rb")).sort.each { |file| require file }

module VBlank
  module IR
    module Backends
      module RuntimeFeatures
        refuse_wrong_hooks!(declared)
        ALL = Ractor.make_shareable(declared.dup)
      end
    end
  end
end
