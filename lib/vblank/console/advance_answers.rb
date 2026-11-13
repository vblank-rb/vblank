# frozen_string_literal: true

module VBlank
  module Console
    # WHAT EVERY VERB DOES ON A GAME BOY ADVANCE (Console::Answers says what an answer is).
    #
    # Every verb works: the verbs were written for the Advance first, and its hardware does all of
    # them. The table is written out all the same, so the Advance answers the same question every
    # console does, the build asks every console alike, and a verb added to the builder is decided
    # for the Advance as deliberately as for the others. What a verb does here is its group file's
    # to say (.claude/dsl/), so most answers say only that.
    module AdvanceAnswers
      extend Answers

      PAGE = ".claude/dsl/game-boy-advance.md"

      # What a verb with nothing more to say answers.
      PLAIN = "as its group file says."

      ANSWERS = Ractor.make_shareable({
        # --- building, the screen and settings ---
        screen: works("`screen :bitmap, pixel_size: 2` shows each pixel of the game's 120×80 picture as a " \
                      "square of four. The console draws the painted screen through a background that can " \
                      "resize. It shows that background bigger, and the build copies nothing. " \
                      "`shown_rows:` is refused: a Game Boy Advance can write its painted screen at any " \
                      "time, so rows that do not show give it no more time. To give up rows on a Super " \
                      "Nintendo only, write `shown_rows:` when `built_for?(:snes)` is true."),
        setting: works, built_for_computer?: works("false on a cartridge."),
        built_for?: works("true when asked about :gba."),
        screen_width: works("240 on a Game Boy Advance. 120 with `pixel_size: 2`. 160 on a game built with " \
                            "`variants: { gba: :color_screen }`, which is laid out for a Game Boy Color."),
        screen_height: works("160 on a Game Boy Advance. 80 with `pixel_size: 2`. 144 with " \
                             "`variants: { gba: :color_screen }`."),
        border: works("with `variants: { gba: :color_screen }`, the build shows the game's 160×144 screen at " \
                      "its own size in the middle of the screen, and the border fills the 40 columns at each " \
                      "side and the 8 rows above and below. Without `border`, the build draws a border of its " \
                      "own. A fade or a tint does not change the border. That build does not make a status " \
                      "bar, a light, a fade held to a rectangle or under a layer, a background bent row by " \
                      "row or one that turns, `pixelate`, `hide_sprites` or `read_scanline` yet, and refuses " \
                      "each. It gives the game 32 fewer sprites, which draw the border. Without the variant, " \
                      "`border` does nothing."),
        wait_vblank: works, halt: works, debug_halt: works,
        game_loop: works, once_a_frame: works, frames_since_power_on: works, each_pass: works,
        every: works, after: works, repeat: works, timer: works,

        # --- drawing on a painted screen ---
        pixel: works, fill_rect: works, dma_fill_rect: works, draw_rect_at: works, draw_column_at: works,
        clear_screen: works, inside: works, grid: works, camera: works, keep_showing: works,
        place: works, viewer: works, screen_spot: works, change_picture: works,
        draw_place: works("on `screen :bitmap, tear_free: true` only. The processor turns each point and " \
                          "fills each face a pixel at a time. Each `perspective:` setting is made."),
        shading: works("the processor finds each lit pixel's colour in a table the build makes from the " \
                       "shading, one load a pixel. Each pixel is the colour the shading gives, exactly."),

        # --- fades, tints and screen effects ---
        fade: works, tint: works, fade_in: works, fade_out: works, flash_screen: works, fade_level: works,
        shake_screen: works, pixelate: works, pixelate_in: works, pixelate_out: works, pixelate_size: works,
        spotlight: works, iris_in: works, iris_out: works, iris_shut?: works, pulse: works,
        camera_follows: works,

        # --- pictures and sprites ---
        image: works, color: works, rgb: works, rgb8: works, colors: works,
        recolor: works("a background that draws with more than one list the game changes has one group of 16 " \
                       "background colors for each of those lists. When a list changes, the build copies its colors " \
                       "into that group. A background that walks between areas is refused there: this build does " \
                       "not make it yet."),
        colors_in_use: works, colors_name_of: works, color_walk: works, mirror: works, upside_down: works, blit: works,
        sprite: works("a sprite with `over_picture: true` on a painted screen is the console's own sprite. The " \
                      "painted picture uses half of the sprites' memory, so their pictures have 16K, not 32K. " \
                      "A sprite whose poses are drawn from different lists of colors is refused: this build " \
                      "draws all the poses of one sprite from one list. Use one sprite for the poses of each list."),
        draw_in_order: works, hide_sprites: works, picture_groups: works, pool: works, box: works,

        # --- backgrounds and layers ---
        tiles: works, canvas: works, tile_pictures: works, sprite_tiles: works, layers: works, layer: works,
        background: works("`above_row:` is refused: this build does not make it yet. `show_only_inside` uses the " \
                          "display's second window. One background at a time can be held to a box. A game " \
                          "that holds one cannot also have a light, a status bar, a fade held to part of the " \
                          "screen, or a fade under a layer, because these need the same windows. With " \
                          "`held: true`, the cells a pass changes with `set_tile` wait in work memory and go " \
                          "into video memory together in the gap between frames, so they all show on the next " \
                          "frame. Up to 1024 changes wait. A pass that makes more writes the waiting ones at once."),
        status_bar: works("the bar takes one of the four background layers. A game with a bar cannot also " \
                          "have a light, a fade held to part of the screen, or a fade under a layer, because " \
                          "these need the same part of the display."),

        # --- text ---
        draw_text: works, draw_number: works, text_width: works, text_height: works,
        font: works("a font of the game's own pictures (`pictures:` or `strip:`) draws each character as its " \
                    "picture: a `blit` on a painted screen, a sprite on a tiled one."),
        menu: works,

        # --- numbers and logic ---
        var: works, save_var: works, save_data: works, clock: works, saves_keep_everything: works,
        part: works, start_over: works,
        set: works, add: works, add_var: works,
        sub: works, sub_var: works, copy: works,
        negate: works, negate!: works, flip: works, flip!: works, abs: works, abs!: works,
        negate_abs: works, negate_abs!: works, clamp: works, clamp!: works,
        approach: works, approach!: works,
        list: works,
        func: works, call: works, scene: works, case_var: works,
        uses: works("a pack's verbs are verbs of the game's own, and each one has its answer here."),
        data_pack: works("the cartridge holds what each slot holds, as if the game had written it."),
        shell_screen: works("the cartridge holds nothing of it. Only a build as a shell shows a first screen."),
        dump_func: works("it lists the ARM a routine was made into."),
        entry: works("raw ARM for the Advance's processor (`.claude/dsl/escape-hatch.md`)."),

        # --- input ---
        held: works("the ten buttons a Game Boy Advance has, the shoulder buttons `:l` and `:r` among them. " \
                    "`:x` and `:y` are refused: it has no X or Y button. " \
                    "`player: 2` or more is refused, and `players:` more than 1 is refused too: it has one controller. " \
                    "`player: :any` reads that one controller."),
        pressed: works("see `held`."),
        most_players: works,
        drawing_for_local_player: works("the player is always 1: a cartridge is played by one person."),
        mark: works("the mark is one more of the console's sprites, shown over the sprite it marks."),
        players_connected: works("always 1: a Game Boy Advance has one controller."),
        rumble: works("nothing is felt. A Game Boy Advance cartridge with a rumble motor is not made yet, " \
                      "so the game plays the same without it."),
        computer_keys: works(Answers::COMPUTER_ONLY), computer_gamepad: works(Answers::COMPUTER_ONLY),

        # --- randomness ---
        seed: works, randomize: works, roll: works, rand: works, chance: works, random_numbers: works,

        # --- sound and music ---
        enable_sound: works(Answers::MAIN_VOLUME_NOT_MADE_YET), define_sound: works, beep: works, noise: works, wave: works, stop_wave: works,
        song: works("#{Answers::PAN_LEAD} #{Answers::NEAREST_SIDE} #{Answers::RECORDINGS_FROM_BOTH}"),
        play_song: works, stop_music: works, hold_music: works, release_music: works,
        music_volume: works, fade_music_in: works, fade_music_out: works,
        songs: works("a recorded note with `glides: true` is refused: this build does not make it yet. #{Answers::NOTE_VOICES}"),
        sound_effects: works, sample: works, instrument: works
      })

      # WHAT .claude/dsl/game-boy-advance.md SAYS: the answers with words of their own, then every
      # other verb by name.
      def self.reference
        said, plain = ANSWERS.keys.partition { |verb| answer(verb).words != PLAIN }
        # The plain ones by name, in lines of about a hundred characters.
        names = "#{plain.map { |verb| "`#{verb}`" }.join(', ')}.".gsub(/(.{1,96})(?:\s+|\z)/, "\\1\n").chomp
        <<~MARKDOWN
          # The Game Boy Advance — what every verb does there

          A game built for the Advance (`VBlank.game "NAME", consoles: %i[gba]`, then
          `vblank build`) has a 240×160 screen (`screen_width`, `screen_height`), ten buttons,
          four backgrounds, 128 sprites and lists of sixteen colours. Every verb works there: the
          verbs were written for the Advance first. The answers are decided in
          `Console::AdvanceAnswers`, as every console's are, and the Game Boy Color's are in
          `.claude/dsl/game-boy-color.md`.

          This file is `Console::AdvanceAnswers.reference` written out (`ruby tools/console_answers.rb`),
          and a test fails when the two differ.

          #{answer_lines(said).join("\n")}

          These work as their group files say:

          #{names}
        MARKDOWN
      end
    end
  end
end
