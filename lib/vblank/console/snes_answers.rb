# frozen_string_literal: true

module VBlank
  module Console
    # WHAT EVERY VERB DOES ON A SUPER NINTENDO (Console::Answers says what an answer is).
    #
    # The Super Nintendo came out a decade before the Advance and is in many ways the bigger machine:
    # a 256×224 screen, 128 sprites, backgrounds of up to sixteen colours a tile from eight lists,
    # 128K of work memory and a sound chip that plays recordings on eight voices. What it lacks is
    # the Advance's painted screen (every picture is tiles), a sprite that turns or resizes, more
    # than one layer that turns, and the Advance's square, wave and noise voices.
    #
    # A GAME NAMES WHICH CONSOLES IT IS FOR (`VBlank.game "PONG", consoles: %i[gba snes]`), and is
    # laid out from `screen_width` and `screen_height` rather than from 240 and 160, so the same
    # game fills each screen.
    #
    # An answer here is what the console's hardware does. What the Super Nintendo's build does not
    # make yet is the lowering's own list (Backends::SNES::Lowering::NOT_LOWERED_YET), which the
    # page shows under its own heading and the build refuses by name.
    module SNESAnswers
      extend Answers

      PAGE = ".claude/dsl/super-nintendo.md"

      PLAIN = "the same as on the Advance."

      ANSWERS = Ractor.make_shareable({
        # --- building, the screen and settings ---
        screen: works("`screen :tiled` and `screen :bitmap` work. A Super Nintendo has no painted " \
                      "screen, so a painted (bitmap) screen is made of tiles internally. " \
                      "`tear_free: true` keeps one picture, because the picture is copied to the " \
                      "console whole before it shows. `screen :rotozoom` is refused: the build does " \
                      "not use the one layer a Super Nintendo can turn. `pixel_size: 2` is refused: the " \
                      "build does not show a painted screen bigger yet."),
        setting: works,
        built_for_computer?: works("false on a cartridge."),
        built_for?: works("true when asked about :snes."),
        screen_width: works("256 on a Super Nintendo."),
        screen_height: works("224 on a Super Nintendo."),
        border: works("it does nothing on a Super Nintendo, which shows the game's screen whole."),
        wait_vblank: works("in a game loop, the sprites and scroll of a pass show on the frame after the wait. " \
                           "If a game writes the wait in a scene or an `if`, they show a frame later than that."),
        halt: works,
        debug_halt: works("the game stops there, as `halt` does; the cartridge is not cut short."),
        game_loop: works,
        once_a_frame: works,
        frames_since_power_on: works,
        each_pass: works,
        every: works,
        after: works,
        repeat: works,
        timer: works("a timer ticks by the frame, as the interpreter counts it."),

        # --- drawing on a painted screen ---
        pixel: works,
        fill_rect: works,
        dma_fill_rect: works,
        draw_rect_at: works,
        draw_column_at: works,
        place: works("a place is data in the cartridge. To draw it is refused: see `draw_place`."),
        viewer: works("a viewer is variables. To draw a place from it is refused: see `draw_place`."),
        change_picture: works("a slot is a number in a list. To draw the place is refused: see `draw_place`."),
        shading: works("a shading is data in the cartridge. To draw a place with it is refused: see `draw_place`."),
        screen_spot: works("the console's own processor turns and projects the point."),
        draw_place: refused("Super Nintendo games drew places like this with a Super FX chip on the cartridge. " \
                            "This build does not draw a place on that chip or on the console's own processor yet."),
        clear_screen: works,
        inside: works,
        grid: works,
        camera: works("a painted screen is the size of the screen, so moving the view over it shows " \
                      "black past the picture's edge. To move over a bigger world, use a tiled " \
                      "background and `scroll_to`. On a tiled screen the camera moves the backgrounds " \
                      "and the sprites together."),
        keep_showing: works("a painted screen is always shown whole, so a picture kept showing never tears."),

        # --- fades, tints and screen effects ---
        fade: works("`fade` to black is the display's own brightness, in sixteen levels, and costs no time. " \
                    "`tint`, and `fade` to white, change the colours the console shows, not the picture. " \
                    "`inside:`, `outside:` and `under:` are refused: the build cannot fade part of the " \
                    "screen on a Super Nintendo."),
        tint: works,
        fade_in: works,
        fade_out: works,
        flash_screen: works,
        fade_level: works,
        shake_screen: works,
        pixelate: refused("a Super Nintendo's mosaic shows the backgrounds in blocks but not the " \
                          "sprites. Use `fade_out` and `fade_in` to go from one screen to the next."),
        pixelate_in: refused("see `pixelate`."),
        pixelate_out: refused("see `pixelate`."),
        pixelate_size: works,
        spotlight: refused("a light darkens everything outside a circle by degrees, and a Super Nintendo's " \
                           "colour maths only adds, subtracts or halves. Use `fade` to darken the whole screen."),
        iris_in: refused("the iris is the game's light closing (see `spotlight`). Use `fade_out` and `fade_in`."),
        iris_out: refused("see `iris_in`."),
        iris_shut?: refused("see `iris_in`."),
        pulse: refused("a Super Nintendo cannot resize a sprite. Draw the sprite's sizes as poses and " \
                       "`face` them in turn."),
        camera_follows: works,

        # --- pictures and sprites ---
        image: works("a sprite's picture holds fifteen colours and see-through, and a background's tiles " \
                     "sixteen colours, from lists of sixteen."),
        color: works,
        rgb: works,
        rgb8: works,
        colors: works("a list of colours holds sixteen places on a Super Nintendo, the first see-through " \
                      "on a sprite. The console holds eight lists for sprites and eight " \
                      "for backgrounds on each screen. If the sprites do not fit the 512 tiles of sprite " \
                      "memory with a copy of their pictures for each list they wear with `draw_with`, the " \
                      "build keeps one set of pictures for all those lists."),
        recolor: works("a list told to hold other colours keeps a palette to itself, so a game can change " \
                       "eight lists of backgrounds on each screen and eight of sprites."),
        color_walk: works,
        colors_in_use: works,
        mirror: works,
        upside_down: works,
        blit: works,
        sprite: works("a sprite is made of the console's pieces, 128 pieces at once and 34 pieces of 8×8 on " \
                      "any one row of the screen. A square of 16×16 in a picture is one piece, so a screen of " \
                      "big sprites fits. A picture given with `pieces:` is those pieces, one each, 16×16 " \
                      "pieces too, wherever they sit. Past 128 pieces, a sprite is not drawn and no error " \
                      "shows as the game runs. The build warns when the sprites one screen declares pass " \
                      "128, and when it gives up the squares of 16×16 to fit the tiles. It does not count " \
                      "pools or letters of text. `scale`, `face_angle` and `turn` are refused: a Super " \
                      "Nintendo cannot turn or resize a sprite. Draw the turns as poses. A sprite with " \
                      "`over_picture: true` on a painted screen is not made yet: the build refuses it and says " \
                      "so. That painted screen uses nearly all the video memory and all 256 colours, and the " \
                      "sprites need some of both."),
        draw_in_order: works,
        hide_sprites: works("on the next frame, no sprite shows. On the frame after, every sprite shows where it is."),
        picture_groups: works,
        pool: works("its sprites count towards the 128."),
        box: works,

        # --- backgrounds and layers ---
        tiles: works("tiles of sixteen colours each."),
        background: works("two backgrounds at a time, and a status bar beside them. Three backgrounds with no " \
                          "status bar among them are refused: this build does not make that yet. The backgrounds " \
                          "are scrolled and changed as on the Advance. `above_row:` " \
                          "keeps a background to the rows above that row, and takes no processor time as the " \
                          "screen is drawn. A game with it cannot have a status bar yet. `show_only_inside` is " \
                          "refused: this build does not make it yet. `rotate` and " \
                          "`scale` are refused: the build does not use the one layer a Super Nintendo can turn. " \
                          "A background can be drawn from 16×16 tiles, which the console draws itself, as well as 8×8. " \
                          "A cell of its map is then one 16×16 tile. A `scroll_each_row` block runs for all 224 rows " \
                          "each pass, so a block that reads a table can take more than a frame. If a block only " \
                          "compares the row with numbers, as `row >= 68 ? a : b` does, it runs once for each band of " \
                          "rows, and the game keeps up. A scene can bend a background of its own. The rows go straight " \
                          "when that scene leaves. A block with no statement and no `?` takes none of the frame " \
                          "while that scene is away. Any other block runs as usual, because it can change a number. " \
                          "`held: true` changes nothing: a Super Nintendo writes its video memory only between " \
                          "frames, so the cells a pass changes with `set_tile` already show together."),
        status_bar: works("beside one background, the bar is one of the two background layers. Beside two " \
                          "backgrounds, the bar is on the third layer, which has tiles of four colours. Then each " \
                          "tile of the bar must show 3 colours or fewer, and all its tiles together use 8 lists " \
                          "of 3 colours or fewer. The game then has room for 960 background tiles, not 1024. " \
                          "On the third layer, a bar drawn with other colours (`draw_with`), a bar of 16×16 tiles " \
                          "and a bar of tiles painted from a list are refused: this build does not make them yet. " \
                          "`set_tile` with `now: true` is refused: " \
                          "a Super Nintendo writes its video memory only between frames, so a change " \
                          "shows on the frame after the pass."),
        canvas: works,
        tile_pictures: works("pictures of 8×8 or 16×16, each change one copy from the cartridge, however many cells show " \
                             "the tile. A group must fit one bank of the cartridge."),
        sprite_tiles: works("a Super Nintendo can draw poses from tiles the game loads, but this build does not " \
                            "make it yet. A game with a pose drawn from sprite tiles is refused, and the build says " \
                            "so (see Not made yet)."),
        layers: works("a layer holds a background or sprites. A layer of backgrounds can be half " \
                      "see-through, over a background that covers the whole screen: `transparency:` " \
                      "from 50 to 56, or `shows: 50, shows_behind: 50`. It can also be added to what is " \
                      "behind it: `shows: 100, shows_behind: 100`, and there `shows_behind:` can be a " \
                      "number the game changes between 100 and 0, which turns the layer solid in one " \
                      "frame. A number between shows as 100. A Super Nintendo mixes one layer into " \
                      "another only by half or by adding, never by the Advance's sixteen steps, so other " \
                      "amounts are refused."),
        layer: works("see `layers`."),

        # --- text ---
        draw_text: works("painted on a painted screen; on a tiled one each letter is a sprite, so they " \
                         "count towards the 128, 34 pieces to a row."),
        draw_number: works("see `draw_text`."),
        font: works("a font of the game's own pictures (`pictures:` or `strip:`) draws each character as its " \
                    "picture: a `blit` on a painted screen, a sprite on a tiled one."),
        text_width: works,
        text_height: works,
        menu: works("see `draw_text` for what its rows are made of."),

        # --- numbers and logic ---
        var: works("a variable is the same 32-bit whole number as on the Advance."),
        save_var: works("kept in 32K of battery-backed RAM on the cartridge. A cartridge with a Super FX chip " \
                        "keeps it too, in RAM of its own beside the chip's."),
        save_data: works("kept in 32K of battery-backed RAM on the cartridge. A cartridge with a Super FX chip " \
                         "keeps it too, in RAM of its own beside the chip's."),
        part: works, start_over: works,
        clock: refused("a Super Nintendo cartridge built here has no clock chip. Ask the player for the time " \
                       "on a screen of the game's own, if the game needs it."),
        saves_keep_everything: works,
        set: works, add: works, add_var: works,
        sub: works, sub_var: works, copy: works,
        negate: works, negate!: works, flip: works, flip!: works, abs: works, abs!: works,
        negate_abs: works, negate_abs!: works, clamp: works, clamp!: works,
        approach: works, approach!: works,
        list: works,
        func: works("`fast:` means nothing on a Super Nintendo, which runs all of its code alike. `on_chip: true` " \
                    "runs the routine on a Super FX cartridge's chip (sums, fractions, `if`, loops, tables, lists " \
                    "and a copy from a table into one, and calls of other `on_chip` routines; any other step is refused)."),
        call: works,
        scene: works("see `func` for `fast:`."),
        case_var: works,
        uses: works("a pack's verbs are verbs of the game's own, and each one has its answer here."),
        data_pack: works("the cartridge holds what each slot holds, as if the game had written it."),
        dump_func: refused("it lists the ARM a routine was made into, and a Super Nintendo has no ARM " \
                           "processor to list it for."),
        entry: refused("`entry` is raw ARM for the Advance's processor, which a Super Nintendo does not have."),

        # --- input ---
        held: works("the ten buttons the Advance has, and `:x` and `:y`: a Super Nintendo controller has " \
                    "twelve. `player: 2` reads the second controller, and `player: :any` reads either. " \
                    "`player: 3` or more is refused, and `players:` more than 2 is refused too: this build reads two " \
                    "controllers, and does not read a Multitap yet."),
        pressed: works("see `held`."),
        most_players: works,
        drawing_for_local_player: works("the player is always 1: a cartridge is played by one person."),
        mark: works("the mark is one more of the console's sprites, shown over the sprite it marks."),
        players_connected: works("a build for a computer answers it. The cartridge build does not make it yet: " \
                                 "it refuses it and says so, because it cannot yet tell if the second controller " \
                                 "is connected. A controller that is not connected holds no buttons, so a " \
                                 "cartridge can wait for a button on it instead, like `pressed(:start, player: 2)`."),
        rumble: works("nothing is felt. A Super Nintendo cartridge has no rumble motor, so the game plays " \
                      "the same without it."),

        # --- randomness ---
        seed: works, randomize: works, roll: works, rand: works, chance: works, random_numbers: works,

        # --- sound and music ---
        enable_sound: works,
        define_sound: works("a Super Nintendo has no square voice: its sound chip plays recordings, so the " \
                            "square is played as a recording of one. The sound chip cannot make a note above " \
                            "16000 Hz, so a higher note plays at 16000 Hz."),
        beep: works("see `define_sound`."),
        noise: works("a hiss is played on the sound chip's own noise. The sound chip has no metallic noise, " \
                     "so a metallic hit is played as a recording of one. The sound chip's noise is at most " \
                     "32000 steps a second, so a :high hiss is lower than on the Game Boy Advance."),
        wave: works("a Super Nintendo has no wave voice: its sound chip plays recordings, so it plays each " \
                    "waveform as a recording. A note above 4000 Hz plays at 4000 Hz."),
        stop_wave: works,
        song: works("see `define_sound` for the square and wave voices."),
        play_song: works,
        stop_music: works,
        hold_music: works,
        release_music: works,
        music_volume: works,
        fade_music_in: works,
        fade_music_out: works,
        songs: works("see `song`. A recorded note with `glides: true` carries on the note sounding at a new " \
                     "pitch: it fades as it was, and the voice is not struck again."),
        sound_effects: works("see `song`."),
        sample: works("each recording plays on a voice of the sound chip. The sound chip has eight voices. Four " \
                      "always play recordings, and each of the other four does when the game never uses it for a " \
                      "beep, a wave, noise or a song's own part. If every one of those plays a recording, the next " \
                      "recording is not heard. It still ends or loops as on the Advance. A recording whose " \
                      "`envelope:` is the sound chip's own bytes (a `VBlank::Audio::SNESEnvelope`) has them " \
                      "written to its voice unchanged, and the sound chip shapes each note itself."),
        instrument: works("see `sample`.")
      })

      # WHAT .claude/dsl/super-nintendo.md SAYS: every answer, in the order ANSWERS gives them, and
      # what the Super Nintendo's build does not make yet — +not_yet+, the lowering's own list of the
      # program's kinds it refuses for now, by what they are part of (Kit#answers_page).
      def self.reference(not_yet: {})
        <<~MARKDOWN
          # The Super Nintendo — what every verb does there

          A game built for the Super Nintendo too (`VBlank.game "NAME", consoles: %i[gba snes]`, then
          `vblank build`, which makes a cartridge for each console, or `--console snes` for the Super
          Nintendo's alone) is the same game on another machine: a 256×224 screen (`screen_width`,
          `screen_height`), 128 sprites (34 pieces on a row of the screen), backgrounds of tiles, and
          lists of sixteen colours. Every verb has one of two answers there, decided once in
          `Console::SNESAnswers`:

          - **works** — the same game, played the same way. The Super Nintendo lowering's run of
            `rake test:all` holds the cartridge to the interpreter after every pass.
          - **refused** — the build stops before anything is made, naming the hardware the Super
            Nintendo lacks and what to use instead. Nothing is shown differently.

          This file is `Console::SNESAnswers.reference` written out (`ruby tools/console_answers.rb`),
          and a test fails when the two differ. The Advance's answers are in
          `.claude/dsl/game-boy-advance.md`.

          #{answer_lines.join("\n")}

          ## Not made yet

          #{not_yet_words(not_yet)}
        MARKDOWN
      end

      # What the page says of the steps the Super Nintendo's build does not make yet.
      def self.not_yet_words(not_yet)
        return "The build for the Super Nintendo makes every kind of step that the answers above do not refuse." if
          not_yet.empty?

        "An answer above is what the Super Nintendo does with a verb. The build for it is still growing,\n" \
          "and a game that reaches one of these steps is refused, naming the step, until it is made:\n\n" +
          not_yet.map { |part, kinds| "- #{part}: #{kinds.map { |kind| "`#{kind}`" }.join(', ')}" }.join("\n")
      end
    end
  end
end
