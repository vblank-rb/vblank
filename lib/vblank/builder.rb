# frozen_string_literal: true

# DSL verbs grouped into concern modules, each mixed into Builder below. They keep
# the flat DSL surface (every verb a top-level method) while letting each area live
# in its own file. New concerns get required here and included in the class body.
#
# A concern with game code of its own comes in the way a part of a game does, since it is written
# in normal Ruby: a name that holds a variable is changed by assigning to it, and `if` on a test
# the game makes records that test.

# Must come before the concerns: a game file among them runs its `while` loops as it loads, and a
# loop asks which game is being built (PlainRuby::Steps::LoopTest).
require_relative "builder/session"

require_relative "builder/randomness"
require_relative "builder/sound"
VBlank.require_game_file "builder/music"
require_relative "builder/text"
require_relative "builder/picture_fonts"
require_relative "builder/images"
VBlank.require_game_file "builder/color_lists"
require_relative "builder/picture_groups"
require_relative "builder/table_groups"
VBlank.require_game_file "builder/sprites"
require_relative "builder/sprite_import"
require_relative "builder/input"
require_relative "builder/local_view"
require_relative "builder/drawing"
require_relative "builder/places"
VBlank.require_game_file "builder/spotlights"  # The circle a spotlight lights, a row at a time
require_relative "builder/variables"
VBlank.require_game_file "builder/control_flow"
require_relative "builder/scenes"
VBlank.require_game_file "builder/collision"
require_relative "builder/tiled"
require_relative "builder/tile_runs"
require_relative "builder/canvases"
require_relative "builder/tile_pictures"
require_relative "builder/sprite_tiles"
require_relative "builder/composition"
require_relative "builder/timers"
require_relative "builder/clocks"
require_relative "builder/sampled_audio"
require_relative "builder/layers"
require_relative "builder/draw_order"
require_relative "builder/settings"
require_relative "builder/features"
require_relative "builder/chosen_starts"
require_relative "builder/parts"
require_relative "builder/save_program"
require_relative "builder/save_records"
require_relative "builder/save_half"
require_relative "builder/save_places"
require_relative "builder/save_jobs"
require_relative "builder/save_var_record"
require_relative "builder/saves"               # All four save parts held as one object, behind the save_data verb
require_relative "builder/debug"               # The probe-only verbs, defined but deliberately not mixed in
require_relative "builder/game_effects"        # uses: a game's own effect packs, for its build alone
require_relative "builder/data_packs"          # data_pack: the original's data, read through the pack made from the copy
require_relative "builder/pack_backgrounds"    # background tiles: pack[...]: the original's own tiles, map and colours
require_relative "builder/pack_tile_pictures"  # tile_pictures tiles: { pack[...] => ... }: a pack's tile taking turns through pictures
require_relative "builder/pack_poses"          # image frame: pack[...]: a pose that is one of the original's frames
require_relative "builder/pack_scores"         # notes: pack[...]: the original's songs as notes, and its instruments' settings
require_relative "builder/pack_places"         # place, shading, viewer from pack[...]: a 3D level read from the copy
require_relative "builder/shell_screens"       # shell_screen: a shell's first screen, made the game's own

module VBlank
  # The verbs of a game
  #
  # Every verb a game block can write, such as `screen`, `sprite`, `game_loop` and `beep`, is a
  # method of Builder. Each one describes part of the game and returns, and the finished
  # description is turned into a cartridge once the block ends. Because the whole game is
  # described before any of it is built, a `call` can name a `func` that is written later in
  # the block.
  #
  # ```ruby picture=still
  # VBlank.game "PIXELS", consoles: %i[gba] do
  #   screen :bitmap
  #   clear_screen rgb(3, 4, 7)
  #   fill_rect 96, 56, 32, 32, :red
  #   amber = color("#FFA000")
  #   fill_rect 112, 72, 32, 32, amber
  #   pixel 120, 80, :white
  #   halt
  # end
  # ```
  #--
  # Each DSL method builds a node in an IR tree, an in-memory description of what the program
  # does, and returns. VBlank.build lowers the finished tree once the block ends.
  #++
  class Builder
    include Randomness # seed, randomize, roll, rand, chance
    include Sound      # enable_sound, define_sound, beep
    include Music      # song, play_song, stop_music
    include Text       # draw_text, draw_number
    include PictureFonts # font pictures: / strip:, and text drawn in the game's own pictures
    include Images     # image, blit, rgb, rgb8, color
    include ColorLists # recolor (a list of sprite colours that holds other colours as the game runs)
    include PictureGroups # picture_groups (a scene's sprite pictures by room, only some of them up at a time)
    include TableGroups # table_groups (a level's tables, one group of them loaded at a time)
    include Sprites    # sprite (software + hardware, facing/frames/clip animation, hitboxes)
    include SpriteImport # sprite art adapters (sheets, Aseprite) feeding the sprite builder
    include Input      # held, pressed, players_connected, rumble
    include LocalView  # drawing_for_local_player (what only this machine's person sees, in a networked match)
    include Drawing    # screen, pixel, fill_rect, clear_screen, draw_rect_at
    include Places     # place, viewer, draw_place (a first-person view of a place made of flat faces)
    include Variables  # set/var, add, sub, negate/flip, copy, abs, negate_abs, clamp, variables
    include ControlFlow # game_loop, wait_vblank, repeat, every, after, halt, debug_halt
    include Scenes     # func, call, scene, dump_func
    include Collision  # box (overlaps? lives on the shape — Box/Sprite via Bounds)
    include Tiled      # tiles, background (tiled-graphics surface; hardware lowering to follow)
    include TileRuns   # tiles from: a list — tiles the game paints as it runs
    include Canvases   # canvas — the same, drawn into with words
    include TilePictures # tile_pictures — tiles taking turns through pictures in the cartridge
    include SpriteTiles # sprite_tiles — sprite tiles the game loads, and poses drawn from them
    include Composition # pool (a component + a pool of instances, per-instance update)
    include Timers     # timer (a hardware counter running at a chosen rate)
    include Clocks     # clock (the date and time, from the clock a cartridge carries)
    include SampledAudio # sample (a recorded PCM sound, played via Direct Sound)
    include Layers     # layers, layer (a named place in the stack: what sits in front of what)
    include DrawOrder  # draw_in_order (sprites drawn in an order the game works out)
    include Settings   # setting (what this build was told: which floors, which screen it boots on)
    include Features   # feature? (whether this build has a part of the game a build can leave out)
    include ChosenStarts # the starts a build started in a chosen state gives variables and lists
    include SaveData   # save_data (records of the game's state, saved when the game asks for it; see Saves)
    include Parts      # part, start_over (a new game: a part of the game's state back as declared)
    include GameEffects # uses (a game's own effect packs, for its build alone)
    include DataPacks  # data_pack (the original's data, read through a pack made from the player's copy)
    include PackBackgrounds # background tiles: pack[...] (the original's own tiles, map and colours)
    include PackTilePictures # tile_pictures tiles: { pack[...] => ... } (a pack's tile taking turns through pictures)
    include PackPoses  # image frame: pack[...] (a pose that is one of the original's own frames)
    include PackScores # notes: pack[...] (the original's songs as notes, and its instruments' settings)
    include PackPlaces # place, shading, viewer from pack[...] (a 3D level read from the player's copy)
    include ShellScreens # shell_screen (a shell's first screen: its font, colours, picture, words and lines)

    # Shorthand for the IR node constructors, so DSL methods can build tree
    # nodes as terse Build.set(...) calls.
    Build = IR::Build

    # One variable the build added for the author: its name, the line that needed it, and why.
    # +local+ is the plain Ruby local it holds the number of (Value#owner_name), or nil.
    HiddenVariableNote = Data.define(:name, :source, :why, :local) do
      def initialize(name:, source:, why:, local: nil) = super
    end

    # A line of game code that gave a name a new number while it held a game variable.
    HandedNameWrite = Data.define(:name, :variable, :source)

    # A line outside game code that keeps a button's answer in +local+ for game code to read.
    KeptButton = Data.define(:local, :source)

    # @param options [Cartridge::Options] how the game is built; the Builder reads its frame
    #   pacing and the save memory it named
    # @param progress [VBlank::Messages::Progress] what a build says it is doing (see {#progress})
    # @param settings [Hash] what this build was told, read by the game with `setting` (see {Settings})
    # @param screen_as_asked [Boolean] whether this build gives the game the screen size it asks for
    #   (`screen :bitmap, size:`; see Drawing#apply_screen_size!): a computer's build that makes no
    #   cartridge. False for a console's, whose screen is fixed.
    # @param screen_size [Array, nil] a screen size already given, [width, height]: a program the
    #   library makes to show in a game's window (a shell's menu, its unpacking) takes the screen the
    #   game was given (Program#screen_size), so the window is never handed a picture of another size.
    def initialize(options: Cartridge::Options.new, progress: Messages::Progress.silent, settings: {},
                   screen_as_asked: false, screen_size: nil)
      @frame_sync = options.frame_sync
      @for_computer = options.for_computer
      @screen_as_asked = screen_as_asked
      @build_options = options # the console, variant and consoles `built_for?` answers from
      @save_memory = options.save_memory # kilobytes the game named, or nil to let its records decide
      @settings = settings.to_h.transform_keys(&:to_sym)
      @asked_settings = Set.new
      @progress = progress
      @has_paced_loop = false  # set once a game_loop is pacing the program
      @dropped_syncs = 0       # `wait_vblank` calls the game loop already covers
      @variables = Set.new     # every variable's name, in the order the game first named it
      @fraction_vars = {}      # name → fraction bits, for variables that hold a fraction (see Fraction)
      @fraction_lists = {}     # ...and the same for lists, from what `holds:` showed
      @name_vars = {}          # name → the NameSet, for variables that hold one of a set of names
      @var_declarations = {}   # name → what its first `var` started it at, and where (see Variables#var)
      @plain_locals = {}       # [source, local's name] → its PlainLocal (see #plain_local_variable)
      @list_owners = {}        # list name → the ListOwner that declared it (see #claim_list_name!)
      @collections_from_arrays = {} # list or pool name → the local of the Array that made it
      @name_dispatches = []    # [dispatch node, NameSet] — filled in at finalize, once every name is known
      @scene_name_sets = []    # the NameSet of each `call` that picks a scene, checked once every name is known
      @functions = {}          # name → deferred body block (evaluated at emit time)
      @view_statements = []    # the statements of each drawing_for_local_player block (see LocalView)
      @tile_runs = []          # runs of tiles painted from a list, in declaration order (see TileRuns)
      @painted_colors = {}     # picture painted from a list → the colours its places pick (see TileRuns)
      @painted_colors_names = {} # ...and the name those colours were declared under, where they were
      @inline_tile_copies = [] # their copies where `changed` was called, moved to the frame gap at finalize
      @sprite_tile_sets = {}   # sprite_tiles name → { count:, colors:, colors_name: } (see SpriteTiles)
      @tile_pose_sets = {}     # a pose drawn from sprite tiles → the set's name
      @func_fast = {}          # name → where the author insisted the routine live (func fast:)
      @func_on_chip = {}       # name → true for a routine to run on a cartridge's chip (func on_chip:)
      @scene_loads_first = {}  # scene routine → true where its work waits a pass (scene loads_first:)
      @scene_measure_holding = {} # scene routine → the frames of buttons it is measured holding (scene measure_holding:)
      @dump_requests = []      # function names to disassemble from the lowered ROM
      @songs = {}              # name → Music::SongContext or Score (for build-time validation)
      @song_lists = {}         # name → the songs a `songs` list holds, in order
      @sound_enabled = false
      @debug_halted = false
      @repeat_seq = 0          # counts repeat loops, to name each one's hidden index var
      @game_whiles = 0         # how many game `while` loops are open now
      @hidden_variables = 0    # counts the variables a picked value keeps its answer in
      @unique_names = Set.new  # variable names this build made unique (#unique_names)
      @hidden_variable_notes = []
      @placed_at_marks = {}.compare_by_identity # a statement #record_at put at an earlier place → that place
      @counted_loop_notes = []
      @step_variables = {}.compare_by_identity # routine body → why → its shared hidden variable (#step_variable)
      @held_expressions = {}   # variable name → the value node it was set to (#register_held_expression)
      @value_statements = {}.compare_by_identity # value node → the statements it needs (#register_statements_for_value)
      @open_repeat_container_counts = [] # containers each #open_repeat opened, for #close_repeat
      @handed_name_writes = []
      @kept_buttons = []
      @variables_with_no_var_line = []
      @unsaved_variables = Set.new # named `game_variables ..., saved: false` (Builder::SaveData)
      @instance_variable_uses = DSL::PlainRuby::InstanceVariables::Uses.new
      @boolean_variables = {}   # the variables started with `true` or `false`
      @timer_seq = 0           # counts every/after timers, to name each one's hidden counter var
      @rng_seq = 0             # counts anonymous random draws, to name each one's hidden var
      @approach_seq = 0        # counts approach calls, to name each one's hidden delta var
      @number_seq = 0          # counts draw_number calls, to name each one's hidden digit vars
      @sprite_seq = 0          # counts sprites, to name each one's hidden position/backing vars
      @images = {}             # image name → [width, height], so a sprite can size itself from its art
      @image_bounds = {}       # image name → [x, y, w, h] box around its visible (non-transparent) pixels, for collision
      @pictures = {}           # image name → its {IR::Assets::Image}, so `mirror` can turn one round
      @turned_images = {}      # [:mirrored or :upside_down, image name] → the turned picture's name, so turning one twice makes one picture
      @solid_black_images = {} # image name → its copy for a tileset that sets `black: :solid`
      @color_lists = {}        # `colors` name → its colours, see-through first, for a sprite told to draw with it
      @changing_color_lists = {} # `colors` name → what the build keeps about a list told to hold other colours (see ColorLists)
      @backdrop_list = nil     # the list the game's backdrop follows, or nil (see ColorLists#followed_backdrop_list)
      @picture_groups = {}     # `picture_groups` name → its declaration (see PictureGroups)
      @table_groups = {}       # `table_groups` name → its declaration (see TableGroups)
      @sprite_recolors = []    # every sprite's and pool's other colours, to find who draws with a changing list
      @lists_in_use = []       # each set of lists `colors_in_use` named, in the order the game counts them
      @lists_backgrounds_draw_with = {} # `colors` name → the backgrounds drawn with it, which follow it if it changes
      @tilesets = {}           # tileset name → its Tiled::Tileset
      @screen_mode = nil       # the current display mode (set by `screen`), so `sprite` picks its backend
      @sprites = []            # live software sprites, repainted after every wait_vblank
      @sprite_repaints = []    # [wait node, the software sprites declared by then], one per frame boundary
      @routine_sprites = []    # the software sprites declared inside a routine's body (see Sprites#sprite_painting_state)
      @building_routine = nil  # the routine whose body is being built, nil while the program block itself runs
      @scene_numbers = {}      # scene func name → the number that marks its body as the last scene to run
      @scene_screens = {}      # scene func name → the screen its body draws on
      @default_screen_mode = nil # the screen the program block left set, which every routine's body starts on
      @hw_sprites = []         # live hardware sprites, drawn (into the sprite table) after every wait_vblank
      @sprite_objects = []     # every sprite and pool slot object, in the order the game declared them
      @hud_objects = []        # tiled-mode text/number glyph sprites, drawn on top after every wait_vblank
      @glyph_images = {}       # [font, char, color] → a cached glyph image name (one 8x8 sprite tile per glyph)
      @picture_fonts = {}      # font name → Graphics::PictureFont, a font of the game's own pictures
      @pack_picture_options = {} # picture name → the image options of a picture made from a data pack's tiles
      @lettering_fonts = {}    # font name → PictureFonts::Lettering, a font of a pack's pixels with the pack left out
      @verb_owns_text = nil    # the verb drawing its own text right now (a menu's rows), rather than the author placing it
      @animations = []         # flipbook sprites, whose pose is advanced on a beat after every wait_vblank
      @pool_animations = []    # ...and posed pools, which step every instance on their own beat
      @prng_used = false       # whether the program draws random numbers (seeds the stream once)
      @boot_inits = []         # statements hoisted to program start (hidden state that must start known)
      @kept_widths = {}        # the variables kept a byte or two wide, and at which (see Builder::Variables#keep_narrow)
      @pending_conditions = [] # Conditions built but not yet used; leftovers are orphans
      @expressions = []        # every expression Value built; the unparented ones are orphans
      @present_nodes = []      # every frame's present-objects node, filled with the full object list at finalize
      @frame_boundaries = []   # each frame's wait node, the anchor the scroll writes are inserted after at finalize
      @backgrounds = {}          # name → a DeclaredBackground, everything the build learns about one (see Builder::Tiled)
      @background_handles = []   # every DSL::Background made, in the order declared
      @inline_scroll_nodes = []  # scroll nodes recorded at their call site, dropped once a frame boundary exists
      @inline_affine_nodes = []  # affine_background nodes recorded at their call site, moved to the frame boundary
      @inline_map_nodes = []     # show_map nodes recorded at their call site, dropped once a frame boundary exists
      @inline_color_nodes = []   # background_colors nodes, the same, for a layer drawn with other colours
      @inline_bar_nodes = []     # place_bar nodes, the same, for a status bar the game moves
      @inline_box_nodes = []     # box_background nodes, the same, for a background held to a box
      @bars_covering = {}        # the status bars the game tells to cover sprites, by name
      @per_frame_routines = []   # func names `once_a_frame` declared, called at every frame boundary
      @per_pass_routines = []    # func names the framework calls once a pass, after the frame boundary
      @pass_jobs = {}            # each_pass jobs by name (or their routine's, when unnamed)
      @each_frame_seq = 0        # counts once_a_frame bodies, to name each one's hidden routine
      @scene_gates = {}        # scene func name → [state_var, values] it's dispatched on (from the scene dispatch), for gating its presentation
      @current_scene_gate = nil # while a scene func's body is being built: the [state_var, values] its declarations belong to
      @building_scene = nil    # the scene func name currently being built (lets its presentation be declared inside it)
      @layer_stack = []        # the layers the program declared, back to front (see Builder::Layers)
      @shared_levels = []      # the neighbouring layers in it that share one level, each back to front
      @layers_node = nil       # ...and the node holding them, so a `layer` block can mark one see-through
      @current_layer = nil     # while a `layer` block runs: the layer its declarations belong to
      @routine_layer = {}      # routine name → [layer, what the author wrote] when it was declared inside one
      @deferred_layer = nil    # while such a routine's body is built: that pair, so a declaration in it can be refused
      @shell_screen = nil      # what the game gave for its shell's first screen (see ShellScreens)
      @shell_first_screen = false # whether this builder makes a shell's first screen, where no data pack slot may be used

      # The program the DSL builds: an IR tree of nodes that {VBlank.build}
      # lowers to a ROM. Each statement attaches to the container on top of the
      # stack — the program root, or an open control-flow block (a loop, an if, a
      # func body) while its block runs.
      # The program names the console the options name, and a Builder told none makes an unbound
      # program (see IR::Nodes::Program). The game is laid out on the screen
      # of the console the program names.
      @program = Build.program(console: options.console, variant: options.variant,
                               sprite_piece_sizes: options.sprite_piece_size.to_a,
                               players: Cartridge::Players.fewest_and_most_on_build(options.players,
                                                                                    console: options.console,
                                                                                    for_computer: options.for_computer),
                               for_computer: options.for_computer)
      @program.screen_size = screen_size if screen_size
      @console = @program.described_console
      @container_stack = [@program]
      @shown_while = []       # the conditions open right here, for a declaration that is only presented under them

      # Persisted variables (from `save_var`), in declaration order — each is
      # { name:, default:, slot: }, the slot being its place in save memory. Drives
      # the one boot-time save_init and the auto-save after each change.
      @persisted = []
      @saves = nil             # the save_data records and what saves them (see Saves), made with the first
      # Must come last: plain Ruby asks the session's builder whether it records game code, and a
      # builder whose making stopped part way could not answer. A builder made by hand is made
      # the thread's current game; one a build makes is its session's already (Session.building).
      Session.make_current(self)
    end

    # The IR tree built so far (the whole program). Lets tests assert the DSL
    # constructs the right tree without lowering it to a ROM.
    attr_reader :program

    # The Session this builder builds in, which says whether its game has ended
    # (Session#take sets it).
    attr_accessor :build_session # :nodoc:

    # The console this game is being built for (a Console::Description): the screen the DSL
    # lays things out on, clamps them to and checks them against.
    attr_reader :console

    # What this build says it is doing, for whoever is doing real work while it runs.
    #
    #   progress.step "reading the six episodes"
    #   floors.each_with_index { |floor, n| progress.report_count n + 1, floors.length, floor.name; ... }
    #
    # A build is already a run of named phases saying how far each has got (see
    # {VBlank::Messages::Progress}). Anything a game or an effect pack does while the block runs
    # happens inside one of those phases, and without this it happens namelessly — the
    # build stands there saying "reading the game" for a minute with no clue which minute
    # of it belongs to whom. This is the seam: a pack's verbs are mixed into this class,
    # and a game's block is evaluated on it, so `progress` resolves here for both, with no
    # plumbing to pass round. A game split across plain Ruby objects hands it on like any
    # other dependency.
    #
    # It is a noun, not a verb, and that distinction is deliberate. `blit` and `sprite` are
    # things a game does and belong on the teaching-facing verb surface; progress is a thing
    # the build has, and the surface a person learns should not grow a build-time member.
    #
    # The default says nothing, so nobody has to ask whether anybody is listening, and
    # nothing reported here may change what gets built: this is an observation. A pack that
    # behaved differently when somebody was watching would be a bug that only shows up in
    # the mode nobody tests.
    attr_reader :progress

    # Function names queued by dump_func, disassembled from the lowered ROM.
    attr_reader :dump_requests

    # --- Lists ---

    # Declares a list: a bounded, ordered collection whose length changes as the game runs, such as
    # a snake's body or a queue of shots. It returns a handle that you push onto, drop from, index
    # into and go through.
    #
    # ```ruby
    # body = list :body, capacity: 256
    # body.push head_cell
    # body.shift unless growing
    # ```
    #
    # `capacity` is the most it can ever hold. It is rounded up to a power of two, so that an index
    # wraps cheaply, and every build enforces that same ceiling, so a program overflows at the same
    # point everywhere.
    #
    # `holds:` sets what kind of number the list keeps, by showing one. Write a Float and the list
    # holds numbers with a fraction, exactly as writing one makes a variable hold them. A game with
    # many of something that moves in halves and quarters never has to pick a scale and carry it by
    # hand. The number is only an example, and a list still starts empty.
    #
    # `width:` sets how big one slot is, and it is the difference between a list that fits in the
    # console's fast memory and one that does not. A slot is a whole 32-bit number unless you set
    # another, and most lists do not hold anything like that much. `:byte` holds -128 to 127 and
    # `:half` holds -32768 to 32767, at a quarter and a half of the memory. A list of flags,
    # directions, which picture is showing, hit points or countdowns is a list of bytes.
    #
    # ```ruby
    # list :hurt, capacity: 64, width: :byte   # 64 bytes, not 256
    # list :speeds, capacity: 8, holds: 0.0    # numbers with a fraction
    # ```
    #
    # A narrow slot always goes below nothing, so a `:byte` holds -128 to 127 and a number that has
    # to reach past 127 asks for `:half`. A number too big for its slot keeps the low bits that fit,
    # exactly as the console does, so 200 in a `:byte` reads back as -56 on every build. Reading and
    # writing a narrow slot costs the same as a wide one. Only the memory differs.
    #
    # * `name` - the list's name, as a symbol.
    # * `capacity:` - the most items it can hold.
    # * `holds:` - an example of what it holds. A Float means it holds fractions.
    # * `width:` - how big one slot is: `:byte`, `:half` or `:word` (the default).
    # * `fast:` - where the list lives. The framework puts what a frame touches in the quick memory
    #   and lets the rest fall into the roomy one, so you almost never answer this. `false` on a
    #   list you know is cold, such as a world state read when a menu opens, gives the quick memory
    #   back to the things that are walked every frame, and `true` insists on a list the framework
    #   did not pick. It changes nothing the program does, only how long a read takes. It is the
    #   same word `func` uses for the same question about code.
    # * `full_of:` - start holding `capacity` items of this value, rather than none. It is one fill,
    #   done the moment the declaration runs, in place of a loop that pushes each item.
    #--
    # The build measures each scene with the list held at its capacity instead
    # (VBlank.warn_of_collections_that_fill). A narrow slot always goes below nothing because there
    # is no way to make it correctly: a countdown `wait -= 7` followed by `wait <= 0` really does
    # hold -4 while that test runs, and a slot that could not go below nothing would read -4 back
    # as 252 and the test would never fire. Nothing at build time can see that coming, since the
    # value is worked out as the game runs. `rom.profile` says where everything went.
    #++
    def list(name, capacity:, holds: nil, width: :word, fast: nil, full_of: nil)
      claim_list_name!(name, ListOwner.new(owner: :verb, at: Messages::AuthorSource.author_file_and_line))
      declare_list(name, capacity: capacity, holds: holds, width: width, fast: fast, full_of: full_of)
    end

    # Who declared a list's name, and where, as a message names a place (`game.rb:12`): the
    # `list` verb, or a plain Ruby Array (DSL::PlainRuby::Arrays) by what it belongs to.
    ListOwner = Data.define(:owner, :at)

    # Gives +name+ to +owner+, refusing a name another owner has: one list for each name, so a
    # `list :trail` and an Array `trail` would be one list, whichever line ran first.
    def claim_list_name!(name, owner)
      held = (@list_owners[name] ||= owner)
      return if held.owner == owner.owner

      raise ArgumentError, "The list name `#{name}` is used two times: at #{held.at} and at #{owner.at}. A game keeps " \
                           "one list for each name, so the two would be one list. To fix this, give one of them " \
                           "another name.#{Messages::AuthorSource.at_author_line}"
    end

    # The name of the list a plain Ruby Array is (DSL::PlainRuby::Arrays), given +name+ and
    # +owner+: +name+ itself for an Array a line of game code makes, which a line reached again
    # makes again, and the first free one of `name`, `name_2` ... for one an object holds, as an
    # object's variables are named.
    def plain_array_list_name(name, owner)
      return name.tap { claim_list_name!(name, owner) } unless owner.owner.first == :object

      free = [name, *(2..).lazy.map { |number| :"#{name}_#{number}" }.first(@list_owners.size + 1)]
                 .find { |each_name| [nil, owner.owner].include?(@list_owners[each_name]&.owner) }
      free.tap { claim_list_name!(free, owner) }
    end

    # Records that the list or pool +name+ is a plain Ruby Array the game wrote as the local
    # +local+ (DSL::PlainRuby::Arrays, DSL::StructArray), so a message names the Array.
    def record_collection_from_array(name, local) # :nodoc:
      @collections_from_arrays[name] = local
    end

    # Each list or pool a plain Ruby Array made, by name, with the local the game wrote, for the
    # checks that run once the program is made (IR::Guardrails::BuildFacts).
    def collections_from_arrays = @collections_from_arrays.dup.freeze # :nodoc:

    # How a message names the list or pool +name+ to the author: the Array the game wrote
    # (the Array `trail`), or the line of +verb+ that declared it (`list :trail`). +opening+ is
    # for the start of a sentence (The Array `trail`).
    def collection_words(name, verb: :list, opening: false) # :nodoc:
      local = @collections_from_arrays[name]
      return "`#{verb} :#{name}`" unless local

      "#{opening ? 'The' : 'the'} Array `#{local}`"
    end

    # ...and a call of +method+ on it: `trail.fill`, or `list :trail.fill` for a `list` line.
    def collection_call_words(name, method, verb: :list) # :nodoc:
      local = @collections_from_arrays[name]
      local ? "`#{local}.#{method}`" : "#{verb} :#{name}.#{method}"
    end

    # The list itself, for `list` and for what declares one in its place (a plain Ruby Array).
    def declare_list(name, capacity:, holds: nil, width: :word, fast: nil, full_of: nil) # :nodoc:
      width = kept_unsigned_halves({ name => width }) { name }.fetch(name)
      # A fraction given as what the list starts full of marks it as holding fractions, as `holds:` would.
      example = holds
      example = full_of if holds.nil? && full_of.is_a?(Numeric)
      bits = list_fraction_bits(name, example)
      refuse_unsigned_half_fractions!(name, bits)
      # A build started in a chosen state makes it empty and then holds the items given (Game#starting_with).
      chosen = chosen_list_pushes(name, capacity, bits) if chosen_start?(name)
      full_of = nil if chosen
      # A part made by game code makes its list once, as it fills it once (#once_for_part).
      note_made_in_part(name)
      once_for_part(name) do
        record(Build.list_new(name, capacity, width: width, fast: fast,
                                              full_of: list_starting_item(name, full_of, bits)))
        chosen&.each { |push| record(push.copy) }
      end
      @fraction_lists[name] = bits if bits
      add_part_member(:list, name)
      DSL::List.new(self, name, fraction_bits: bits)
    end

    # What `full_of:` gave, as the number each item holds: a fraction multiplied up the way the
    # list keeps its items. A fraction into a list `holds:` marks as whole is refused, as a push
    # of one would be.
    def list_starting_item(name, full_of, bits)
      return nil if full_of.nil?
      unless full_of.is_a?(Numeric)
        raise ArgumentError, "`full_of:` takes the number every item starts as, like `full_of: 0`. " \
                             "`list :#{name}` was given #{full_of.inspect}."
      end
      if bits.nil? && !full_of.is_a?(Integer)
        raise ArgumentError, "`list :#{name}` holds whole numbers, and `full_of:` gives #{full_of}. " \
                             "To start it with a fraction, write `holds: 0.0` too, or leave `holds:` out."
      end

      bits ? DSL::Fraction.scale(full_of, bits) : full_of.to_i
    end

    # What `holds:` gave, as a number of fraction bits. A whole number means the same as
    # giving nothing, so it is allowed and means what it looks like.
    def list_fraction_bits(name, holds)
      return nil if holds.nil?
      unless holds.is_a?(Numeric)
        raise ArgumentError,
              "`holds:` takes an example of what the list holds, like `holds: 0.0` for " \
              "numbers with a fraction. `list :#{name}` was given #{holds.inspect}."
      end

      DSL::Fraction.bits_of(holds)
    end

    # Ship a build-time array as a read-only ROM table, read at run time by a Value
    # index. The array is plain Ruby, evaluated as the program is built, so work the
    # console can't do cheaply every frame — sine, division — is precomputed once and
    # then just looked up:
    #
    #   sin = table :sin, (0...256).map { |a| (Math.sin(a * Math::PI / 128) * 256).round }, width: :half
    #   y = sin[angle]   # a plain lookup
    #
    # `width` is the element size: :byte (8-bit), :half (16-bit), or :word (32-bit).
    # `signed` is inferred from the values (any negative makes it signed) unless you
    # set it. An out-of-range index is made safe by the read — a power-of-two table
    # wraps it (what an angle wants), any other size clamps it — so a lookup never
    # reads past the table.
    #
    # A slot of numbers from the game's data pack is given in place of the array
    # (`table :speeds, pack[:speeds]`), and then its width and sign are the slot's, never
    # inferred from what the copy holds (see Builder::DataPacks). So can a DSL::StartFileEntries,
    # for a table read from the file the game is handed as it starts; its width and sign are then
    # the ones given (a half, not signed, unless given).
    #
    # @param name [Symbol] the table's name
    # @param values [Array<Integer>, DSL::PackSlot] the whole numbers to store, computed at build time
    # @param width [Symbol, nil] :byte, :half, or :word; nil is :half (or the slot's width)
    # @param signed [Boolean, nil] force signedness; nil infers it from the values
    # @return [Table] a handle to index with []
    def table(name, values, width: nil, signed: nil)
      return table_from_start_file(name, values, width: width || :half, signed: signed || false) if values.is_a?(DSL::StartFileEntries)

      if values.is_a?(DSL::PackSlot)
        refuse_table_unlike_slot!(name, values, width, signed)
        return table_from_pack_slot(name, values) if pack_left_out?

        width = values.layout.width
        signed = values.layout.signed
        values = pack_slot_values(values, :numbers, "table :#{name}")
      end
      values = validate_table_values!(name, values)
      bits = table_fraction_bits(values)
      # A table of numbers with a fraction is stored multiplied up, and a whole cell of
      # it no longer fits in a half — so it takes a word unless the program sets
      # another. Reads from it carry the fraction, so nothing downstream repeats it.
      width = :word if bits && (width.nil? || width == :half)
      width ||= :half
      values = values.map { |v| bits ? DSL::Fraction.scale(v, bits) : v }
      signed = values.any?(&:negative?) if signed.nil?
      check_table_values_fit!(name, values, width, signed)
      (@table_values ||= {})[name] = values
      record(Build.table(name, values, width: width, signed: signed))
      DSL::Table.new(self, name, values.length, fraction_bits: bits, width: width)
    end

    # A run of a table copied into a list at once (see List#copy_from). The loop it replaces —
    # `list[i] = table[start + i]` for each i — works out an address and makes a read and a
    # write for every entry, which is most of a frame for a few hundred of them. This is one
    # statement, so the console copies the run as a block. The list then holds exactly
    # +count+ entries; +at+ is held inside the table, so the run never reads past it.
    #
    # The two must keep their entries the same way, since a block copy moves bytes and does
    # not change one size of entry into another.
    def copy_table_run(list, table, at:, count:)
      made = declared_list_node(list.name)
      refuse_unfit_table_copy!(list, made, table, count, at)
      record(Build.list_copy(list.name, table: table.name, at: DSL::Value.node_for(at), count: count))
      ensure_var(at)
    end

    # A list set to one value in one step (see List#fill): the whole list as it is now, or
    # +count+ items from +from+. The loop it replaces sets an item at a time and works out an
    # address for each; the console sets the run a whole word at a time instead, and a byte
    # at a time only at its ends. On the console a run is held to the list's capacity; a run
    # written past that, or from before the first item, is refused here.
    def fill_list_run(list, value_node, from:, count:)
      what = collection_call_words(list.name, :fill)
      if from.nil? != count.nil?
        raise ArgumentError, "#{what} was given #{from.nil? ? 'count:' : 'from:'} alone. To fill a run, give both " \
                             "from: and count:. To fill all the items, give neither."
      end
      from, count = from.nil? ? [0, list.length] : [from, count]
      refuse_fill_outside_list!(what, declared_list_node(list.name), from, count)
      fill = Build.list_fill(list.name, from: DSL::Value.node_for(from), count: DSL::Value.node_for(count),
                                        value: value_node)
      record(guard_fill_with_count(fill))
      ensure_var(from)
      ensure_var(count)
    end

    # The interpreter works out a fill's count first and does nothing more when it is not above
    # nought (Reference#exec_list_fill), while each lowering works out the value first, so a value
    # that can stop the game, a list read out of range, would stop it on a console and not in the
    # interpreter. A fill whose value can do something and whose count is not a written number above
    # nought is recorded inside a test of its count. Returns +fill+ or the `if` around it.
    def guard_fill_with_count(fill)
      plain = ->(node) { !node.is_a?(IR::Node) || %i[int var_ref].include?(node.kind) }
      known = fill.count.is_a?(IR::Node) && fill.count.kind == :int && fill.count.value.positive?
      return fill if known || plain.call(fill.value)

      Build.if_(Build.binop(:>, fill.count.copy, Build.int(0)), fill)
    end
    private :guard_fill_with_count

    # A list the game shifts cannot be filled. Dropping the front item makes the list a ring
    # that wraps round its own memory, so a run of its items is not a run of memory to set in
    # one step. Refused once every routine is built, so a `shift` anywhere in the game is seen,
    # and both backends refuse it alike.
    def refuse_filled_shifted_lists!
      filled = @program.walk.filter_map { |node| node.name if node.kind == :list_fill }.uniq
      return if filled.empty?

      shifted = @program.walk.filter_map { |node| node.name if node.kind == :list_drop && node.from == :front }
      name = filled.find { |list| shifted.include?(list) } or return
      raise ArgumentError, "#{collection_words(name, opening: true)} is filled with `fill`, and the game also uses " \
                           "`shift` on it. A shift moves the first item, so the items are no longer one run in " \
                           "memory and `fill` cannot set them at once. To fix this, set the items one at a time " \
                           "with `[]=`, or do not use `shift` on #{collection_words(name)}."
    end

    def refuse_fill_outside_list!(what, made, from, count)
      start = DSL::Value.fixed_number(from)
      if start&.negative?
        raise ArgumentError, "#{what} was given from: #{start}. The items count from 0, so give from: 0 or more."
      end
      size = DSL::Value.fixed_number(count)
      return unless made && start && size && start + size > made.capacity

      raise ArgumentError, "#{what} sets items #{start} to #{start + size - 1}, and there is room for " \
                           "#{made.capacity} items. Give a run that ends inside that room, or give a bigger capacity."
    end

    def declared_list_node(name)
      (@program.walk.to_a + @boot_inits).find { |node| node.kind == :list_new && node.name == name }
    end

    def refuse_unfit_table_copy!(list, made, table, count, at)
      what = collection_call_words(list.name, :copy_from)
      unless made
        raise ArgumentError, "#{what} copies into a list that is not declared. Declare it first with " \
                             "`list :#{list.name}, capacity: ...`."
      end
      unless table.is_a?(DSL::Table)
        raise ArgumentError, "#{what} needs a table, made with `table`. It was given #{table.class.name.split("::").last}."
      end
      unless count.is_a?(Integer) && count.positive?
        raise ArgumentError, "#{what} needs `count:`, a whole number written in the program, 1 or more. " \
                             "It was given #{Messages::PlainWords.words_for_given(count)}."
      end
      if DSL::Fraction.bits_of(at)
        raise ArgumentError, "#{what} starts the run at an entry of the table, and the number given to " \
                             "`at:` holds a fraction. To fix this, use `.to_i` to drop the fraction."
      end
      if count > table.length
        raise ArgumentError, "#{what} copies #{count} entries, and table :#{table.name} has #{table.length}. " \
                             "Give a count of #{table.length} or less."
      end
      if count > made.capacity
        raise ArgumentError, "#{what} copies #{count} entries, and there is room for #{made.capacity}. " \
                             "Give a capacity of #{count} or more."
      end
      refuse_mismatched_table_copy!(what, list, made, table, count)
    end

    # The copying engine counts a run in at most 65535 halves, so a run is held to 64K.
    TABLE_COPY_MOST_BYTES = 65_536

    def refuse_mismatched_table_copy!(what, list, made, table, count)
      list_width = made.width || :word
      unless table.width == list_width
        raise ArgumentError, "#{what} copies from table :#{table.name}, which keeps each entry in a " \
                             "#{table.width}. #{collection_words(list.name, opening: true)} keeps each " \
                             "item in a #{list_width}. A copy moves " \
                             "the entries as they are, so give both the same `width:`."
      end
      bytes = count * Build::ELEMENT_BYTES.fetch(list_width)
      if bytes > TABLE_COPY_MOST_BYTES
        raise ArgumentError, "#{what} copies #{bytes} bytes. One copy can move #{TABLE_COPY_MOST_BYTES} bytes " \
                             "or less. Copy the run in parts, each with a count of its own."
      end
      return if table.fraction_bits == list.fraction_bits

      table_holds, list_holds = table.fraction_bits ? ["numbers with a fraction", "whole numbers"] : ["whole numbers", "numbers with a fraction"]
      raise ArgumentError, "#{what} copies from table :#{table.name}, which holds #{table_holds}. " \
                           "#{collection_words(list.name, opening: true)} holds #{list_holds}. A copy moves the numbers as they are, so give both the same kind of number."
    end
    # Defines an entry point of raw machine instructions, as an escape hatch for what the verbs
    # cannot say.
    #
    # The block collects the instructions you emit, and they are placed in the cartridge exactly as
    # written. They are the Game Boy Advance's own (ARM) instructions, so it is for people who know
    # that processor. The block offers `nop`, an instruction that does nothing, and
    # `loop_forever`, one that branches to itself.
    #
    # ```ruby
    # entry do
    #   nop
    #   loop_forever      # the processor stays here
    # end
    # ```
    #--
    # The block runs in an EntryContext that collects the emitted bytes into a raw IR node, which
    # the backend appends to the code verbatim.
    #++
    def entry(&block)
      ctx = EntryContext.new
      ctx.instance_eval(&block)
      record(Build.raw(ctx.bytes))
    end

    # --- Finalize (VBlank.build calls this once, after the DSL block) ---

    # Refuse a setting the build was given that the game never asked for (see {Settings}).
    def check_settings_were_asked!
      problem = unasked_setting_error
      raise ArgumentError, problem if problem
    end

    # Build the IR node for every deferred function body, then check that every
    # call and case target names a function that exists. Called automatically by
    # VBlank.build after the DSL block.
    def finalize_program
      resolve_hash_dispatches! # a Hash given to `call` is a scene dispatch or a call by number
      convert_scene_name_dispatches # `call mode` over scene names is a scene dispatch over them
      @scene_gates = scan_scene_gates # which state value each scene is shown for (from the scene dispatch)

      # The program's default display mode — whatever the top-level `screen` left set.
      # Each scene starts from this, so one scene's `screen` (a tiled game) can't leak
      # into the next (a bitmap title): a scene is bitmap or tiled by what it declares,
      # or the default, never by which scene happened to be built before it. That's what
      # lets `sprite`/`draw_text`/`draw_number` pick software vs hardware per scene.
      default_screen_mode = @screen_mode
      @default_screen_mode = default_screen_mode

      emitted = {}
      emit_bodies(emitted, default_screen_mode, holding_back: true)
      number_chosen_name_starts! # every name a variable is given is known, before start_over copies its start
      refuse_parts_named_like_scenes! # every scene is declared by now
      # Every routine the game wrote is built, so nothing more can be kept in a save_data
      # record: the records are laid out now, and the routines that read them built after —
      # with the ones held back until every line of the game was read (#build_last).
      @saves&.expand_kept_parts! # every part's members are known now
      check_saves_keep_everything!
      lay_out_save_records
      emit_bodies(emitted, default_screen_mode)
      refuse_scene_without_screen_line! # every scene's body is built by now
      refuse_starts_not_declared! # ...and so is every `var` and `list` a start can name
      # Every line of game code is recorded, so each plain flag's tests and changes are known.
      @instance_variable_uses.refuse_game_flags!
      drop_unwritten_handed_copies # ...and so is every line that gives a handed copy a number
      drop_unneeded_field_copies # ...and every timer's handler and bend that could change a field's number

      finalize_scene_sprite_handover # first: it settles what each sprite waits for before it is painted
      finalize_sprite_repaints
      finalize_sprite_clears
      finalize_animation_steps
      finalize_present_lists
      finalize_pool_stacking
      finalize_draw_orders # after the pools: a pool's numbers are copied with its things
      finalize_tiled_camera # before the scrolls: it makes a scroll write for every background it moves
      finalize_background_scrolls
      finalize_status_bars
      finalize_background_boxes
      finalize_background_maps
      finalize_held_tiles # after the maps, so its write comes before theirs in the gap
      refuse_shifted_tile_run_lists!
      refuse_filled_shifted_lists!
      refuse_set_tile_read_at_start!
      finalize_tile_copies
      link_backgrounds_to_changing_lists # before the colours: it sets what those backgrounds are drawn with
      finalize_background_colors
      finalize_backdrop_list # before the lists: a list only the backdrop shows is not one nobody draws with
      finalize_changing_color_lists
      finalize_picture_groups
      finalize_table_groups
      finalize_background_affine
      finalize_layer_blend
      finalize_light_switch
      finalize_per_frame_routines
      finalize_per_pass_routines
      refuse_non_scenes_in_scene_dispatch!
      refuse_func_named_like_case_scene!
      refuse_scene_declared_after_hash!
      finalize_name_dispatches
      finalize_pool_walks
      finalize_pool_colors
      verify_targets_defined!
      verify_instance_routines!
      refuse_unlayered_when_scenery_in_front!
      initialize_rng_stream
      register_save_init
      emit_boot_inits
      declare_save_memory
      resolve_save_data_peeks
      swap_save_stores_for_change_flags
      finalize_kept_widths
      finalize_unsigned_halves
      finalize_fractions
      finalize_sprite_readings
      finalize_background_readings
      refuse_local_player_outside_views!
      finalize_start_file_colors # last: a walk named in a routine built above makes colours too
      finalize_pack_frames
    end

    # A routine the framework writes whose body depends on every line of the game, built only
    # once all of them are (see #finalize_program).
    def build_last(name) = (@built_last ||= []) << name

    # Build every routine body not built yet (+emitted+ holds which are), each into a func
    # node of its own — but, +holding_back+, not the ones #build_last named.
    def emit_bodies(emitted, default_screen_mode, holding_back: false)
      held = holding_back ? (@built_last || []) : []
      # Drain rather than iterate: building one body can declare another routine — a
      # verb reached from inside a scene may declare a `once_a_frame` of its own — and
      # walking the hash directly would either miss it or raise for growing mid-loop.
      # Emitting until nothing new is pending covers however deep that goes.
      until (pending = @functions.reject { |name, _| emitted.key?(name) || held.include?(name) }).empty?
        pending.each do |name, block|
          emitted[name] = true
          # A scene's declarations belong to it: while its body is built, remember the
          # scene (so its HUD/sprites may be declared here) and the state gate that
          # scopes what it presents to when the scene is active.
          @building_scene = name if @scene_gates.key?(name)
          @current_scene_gate = @scene_gates[name]
          # ...and if this routine was written inside a `layer` block, remember which, so
          # anything it declares that wants a depth can be refused rather than quietly
          # getting none (see Layers#refuse_deferred_layer!).
          @deferred_layer = @routine_layer[name]
          @screen_mode = default_screen_mode
          @building_routine = name
          # Each routine is laid out on the game's screen until a scene's own screen line gives it
          # another (Drawing#apply_scene_screen_size!), and what one read of the size does not reach
          # the next: the game's lines have all run by now.
          laid_out = @console
          @console = @routine_screens[name] if @routine_screens&.key?(name)
          @screen_size_read = nil
          @scene_screen_line_written = false
          @scene_laid_out = @scene_routines&.[](name) # the scene this body is, by its name, or nil
          push_container(Build.func(name, fast: @func_fast[name], loads_first: @scene_loads_first[name],
                                          on_chip: @func_on_chip[name],
                                          measure_holding: @scene_measure_holding[name])) do
            with_part_owners_of_routine(name) { run_block(&block) }
          end
          @scene_screens[name] = @screen_mode if @building_scene
          (@scenes_without_screen_line ||= []) << @scene_laid_out if @scene_laid_out && !@scene_screen_line_written
        ensure
          @console = laid_out if laid_out
          @scene_laid_out = nil
          @building_scene = nil
          @current_scene_gate = nil
          @deferred_layer = nil
          @building_routine = nil
        end
      end
    end
    private :emit_bodies

    # How many `wait_vblank` calls the game loop already covered. Read by
    # VBlank.build so Checks::DroppedFrameSync can report them.
    attr_reader :dropped_syncs

    # The software sprites, in the order they were declared — which on a bitmap
    # screen is the order they are painted in. Read by VBlank.build so
    # Checks::StackNotHonored can compare that order against the declared stack; a
    # software sprite's layer lives on the handle rather than in the tree, so a check
    # walking the tree alone cannot see it.
    attr_reader :sprites

    # Remember that +name+ is scrolled, so its position is written once a frame in
    # the gap between frames rather than wherever the game happened to compute it.
    # +node+ is the write recorded at the call site, which finalize drops once it
    # knows there is a frame boundary to move it to. A {Background} calls this.
    def defer_scroll_write(name, x_var, y_var, node)
      declared_background(name).scroll_x = x_var
      declared_background(name).scroll_y = y_var
      @inline_scroll_nodes << node
    end

    # A status bar's place recorded where the game moved it (StatusBar#move_to), dropped once
    # there is a frame boundary to move it to, as a scroll's is (see #finalize_status_bars).
    def record_inline_bar_node(node)
      @inline_bar_nodes << node
    end

    # The variables a box the background +name+ IS HELD TO IS KEPT IN (Background#show_only_inside),
    # made the first time the game sets one: a background nobody holds to a box keeps none, and
    # its game builds as it did. All five start at 0, which is everywhere. +in_part+ is a box of
    # some size (`show_only_inside`), +whole+ one of nothing (`hide`).
    def hold_background_to_box(name, in_part: false, whole: false)
      declared = declared_background(name)
      declared.boxed_in_part = true if in_part
      declared.hidden_whole = true if whole
      declared.box ||= IR::Nodes::Background.box_vars(name).each do |var|
        at_boot(Build.set(var, Build.int(0)))
        ensure_var(var)
      end
    end

    # A box written where the game set it, dropped once there is a frame boundary to move it to,
    # as a scroll's is (see #finalize_background_boxes).
    def record_inline_box_node(node)
      @inline_box_nodes << node
    end

    # A cell change on a background declared `held: true`, kept until the frame boundary is
    # known (see #finalize_held_tiles).
    def note_held_tile_change(node)
      (@held_tile_changes ||= []) << node
    end

    # The variable that holds whether the status bar +name+ covers sprites, made the first time a
    # game sets it: a bar nobody tells keeps no such variable.
    def bar_covers_var(name)
      @bars_covering[name] ||= IR::Nodes::Background.bar_covers_var(name).tap { |var| ensure_var(var) }
    end

    # Remember that +name+ can be handed a whole different map, so the copy is made once a
    # frame in the gap between frames rather than wherever the game happened to name which
    # map it wants. +requested_var+ is what the game asked for; +applied_var+ is what is really
    # in the background's cells. A {Background} calls this from `show_map`.
    def defer_map_swap(name, requested_var, applied_var, node)
      declared_background(name).shown_map = requested_var
      declared_background(name).live_map = applied_var
      @inline_map_nodes << node
    end

    # A background that can be drawn with lists of colours other than the one its tiles were
    # drawn from. Hands back the statement that declared it, which is what carries those
    # lists to the backends — the same place an object carries its own. Called once, from the
    # first `draw_with`; a {Background} keeps the answer.
    # Two of its variables start out agreeing, both meaning "its own colours", so a
    # background that is told nothing on a frame writes nothing at all — which is also the
    # state the tiles are already in when the game starts. The third is a place for a backend
    # to keep whatever it needs to mark which list is showing; nought is "nothing has been
    # set yet", and what goes there otherwise is that backend's business alone.
    def make_background_recolorable(name)
      refuse_coloring_turning_background!(name)
      at_boot(Build.set(:"__bg_#{name}_colors", Build.int(IR::Build::NO_RECOLOR)))
      at_boot(Build.set(:"__bg_#{name}_live_colors", Build.int(IR::Build::NO_RECOLOR)))
      at_boot(Build.set(:"__bg_#{name}_colors_at", Build.int(0)))
      [:"__bg_#{name}_colors", :"__bg_#{name}_live_colors", :"__bg_#{name}_colors_at"].each { |v| ensure_var(v) }
      declared_background(name).node
    end

    # The colour counterpart to {#defer_map_swap}: remember that +name+ can be handed a
    # whole different list of colours, so the display's table is written once a frame in the
    # gap between frames rather than wherever the game happened to name which list it wants.
    # +requested_var+ is what the game asked for; +applied_var+ is what is really in the table.
    def defer_recolor_write(name, requested_var, applied_var, node)
      declared_background(name).shown_colors = requested_var
      declared_background(name).live_colors = applied_var
      @inline_color_nodes << node if node
    end

    # Undo {#defer_recolor_write}: +name+ has no colours of its own to write between frames. A
    # {Background} calls this once it is known to follow several lists the game changes, whose
    # own writes change its tiles (DSL::Background#follow_changing_lists!).
    def forget_recolor_write(name)
      declared_background(name).shown_colors = nil
      declared_background(name).live_colors = nil
    end

    # The affine counterpart to {#defer_scroll_write}: remember that +name+ turns or
    # resizes, so its matrix is written once a frame in the gap between frames rather
    # than wherever the game happened to change its angle or size. Called once, as soon
    # as a background is made affine (see Builder::Tiled#make_background_affine) — not
    # only from `rotate`/`scale` themselves — so the matrix stays live even for a
    # program that reaches into the angle/scale {Value}s directly (`bg.scale.approach!`)
    # rather than through those two verbs.
    #
    # Also captures the current scene gate (whatever scene this first `rotate`/`scale`/
    # `angle` call happens inside, if any — see #gated_by_scene), so a background declared
    # and turned only inside one scene writes its matrix only while that scene is
    # active. Without this, the write would land at every frame boundary in the whole
    # program regardless of which scene is running — and BG2's affine registers are
    # never inert the way a plain scroll's are: `screen :bitmap`'s Mode 3/4 framebuffer
    # is itself rendered through these same registers, so an untouched write from an
    # affine title screen would keep distorting a bitmap gameplay scene that never asked
    # for it.
    def defer_affine_write(name, angle_var, scale_var)
      background = declared_background(name)
      background.angle = angle_var
      background.scale = scale_var
      background.scene_gates = [@current_scene_gate]
    end

    # Does :+name+ turn and resize rather than scroll? True from the line that declares
    # it on `screen :rotozoom`, where that is the only kind of layer there is, and from
    # the first `.rotate!`/`.scale` anywhere else. A {Background} handle asks this rather
    # than keeping an answer of its own, because the fact is settled in two places at two
    # moments and a copy on the handle was a second answer to keep in step.
    def background_turns?(name)
      declared_background(name).node.affine
    end

    # An affine_background write recorded at its call site (by {Background#rotate} /
    # {Background#scale}) — kept so {#finalize_background_affine} can drop it once it
    # knows there's a frame boundary to move the write to instead, the same as
    # {#defer_scroll_write}'s inline scroll nodes.
    def record_inline_affine_node(node)
      @inline_affine_nodes << node
    end

    # The size or angle a background is declared at, which is a different thing from one
    # written each frame and has to run in a different place.
    #
    # `background(:sword, ...).scale(16.0)` sets how big the picture STARTS. At the top of
    # a program that is also where it runs, because the top of a program runs once — but a
    # scene's body is reached on every frame that scene is up, so the same line there put
    # the size back at the top of every frame and whatever was easing it got one step and
    # no more. So it goes to boot, which is the promise `var` already makes about the value
    # it is declared with, wherever it is declared.
    def set_at_boot(var, value)
      at_boot(Build.set(var, Build.int(value)))
    end

    # The point a background turns around, in screen pixels — kept with the background
    # rather than with one turn, because a picture turns around one point however many
    # times the game turns it (see {Background#turns_around}). Every write of that
    # background's matrix carries it, so there is nowhere for a second answer to live.
    #
    # +map_point+ is the point of the background's own map that sits there, or nil for a map
    # hung from the screen's corner, whose point there is the same two numbers.
    def set_background_pivot(name, x, y, map_point: nil)
      declared_background(name).pivot = [x, y]
      declared_background(name).pivot_map_point = map_point
    end

    # The last statement recorded into the block being built, or nil where nothing has been
    # recorded into it yet. What it answers is whether a call continues a declaration or
    # comes after it — `background(...).scale(16.0)` is one line and one declaration, where
    # a `scale` further down the same scene is a write that frame makes.
    def last_statement
      @container_stack.last.children.last
    end

    # Remember this frame boundary, so the per-frame scroll writes can be inserted
    # just after it at finalize. Which backgrounds scroll isn't known yet — one may
    # be scrolled further down the loop body, or inside a scene built later — so the
    # spot is marked now and filled at the end.
    #
    # The wait itself is the anchor, not a position: other statements around it come
    # and go before finalize is done (a program with no sprites has its present-
    # objects statement removed), and an index recorded now would no longer point
    # where it was meant to.
    def mark_frame_boundary(wait_node)
      @frame_boundaries << wait_node
    end

    # --- Handle hooks ---
    # The Value / Condition / Branch / List classes call these back into the
    # builder to record their statements at the current build point.

    # The hook behind Condition#record_branch: record an `if`
    # node from an already-built condition node and gather the block's statements
    # into it, returning the node so an `else` can attach to it. A {Condition}
    # calls this; a game writes `if`, not this.
    def record_conditional(cond_node, &block)
      if_node = Build.if_(cond_node)
      push_container(if_node) do
        run_block(&block)
      end
      if_node
    end

    # The hook a handle uses to append one of its own statement operations at the
    # current build point — a {List}'s push, a {Sprite} painting itself onto the screen
    # and taking itself off again — the counterpart to how a {Value}'s mutators record
    # through the builder's verbs.
    #
    # It skips the layer rules a flat DSL verb goes through, and that is the whole
    # difference between the two. A handle doing its own work is never a brushstroke
    # somebody wrote inside a `layer` block: a software sprite paints itself with the
    # same node an author's `blit` builds, and refusing the sprite for the sake of the
    # `blit` would refuse the very thing a layer is for.
    def record_statement(node)
      attach(node)
    end

    # The statement recorded last in the open container, for a handle that marks what it just
    # recorded through a verb (Pool#each marks its repeat as a walk). An internal hook, not a verb.
    def last_recorded_statement = @container_stack.last.children.last

    # Record a container node and run +block+ to fill its children — the hook a handle
    # reaches for to attach a body from outside the builder (e.g. Timer#on_tick). Lives
    # in the core, not a concern, so it isn't scanned as a DSL verb. Returns the node.
    def record_container(node, &block)
      push_container(node) { run_block(&block) }
      node
    end

    # A reusable hidden variable a handle can round-trip a read-modify-write through —
    # e.g. a {FieldRef} mutating a pool slot (load the slot, apply a Value mutator, store
    # it back). One is enough: such mutations are sequential statements, never nested.
    # An internal hook like #record_statement / #ensure_var, not a DSL verb.
    def field_scratch_var
      @field_scratch ||= begin
        name = :__field_scratch
        ensure_var(name)
        name
      end
    end

    # The table of sines a viewer turned by a worked-out angle reads (IR::ViewerMotion::SINES),
    # declared the first time one is, with the scratch variables +scratch+ that turn works in. It
    # goes at the top of the program wherever the turn is written, as a table a game declares
    # does, so a game whose viewers only turn by written angles carries neither. An internal hook
    # like #field_scratch_var, not a DSL verb.
    def declare_viewer_sines_with_scratch(scratch)
      scratch.each { |name| ensure_var(name) }
      @viewer_sines ||= begin
        name = Messages::MadeNames.make(:viewer_sines)
        values = IR::ViewerMotion::SINES
        (@table_values ||= {})[name] = values
        @program.add_child(Build.table(name, values, width: :word, signed: true))
        name
      end
    end

    # A {Condition} enters this "pending" set when it's built (Condition#initialize)
    # and leaves it when it's used (see #consume_condition). It's bookkeeping for
    # one guardrail only, never part of the program.
    def track_condition(condition)
      @pending_conditions << condition
    end

    # A {Condition} was used — branched on, or folded into another via
    # `&` / `|` — so peel it back out of the pending set.
    def consume_condition(condition)
      @pending_conditions.delete(condition)
    end

    # Every EXPRESSION Value built during this build — a number worked out, as opposed to
    # a handle naming a place that keeps one (see Value#handle?). Bookkeeping for one
    # guardrail only, never part of the program.
    #
    # There is no matching "consume" the way a Condition has one, and that is the whole
    # trick: an expression that gets used is written into another node, and a node wired
    # into the tree carries a parent. So the tree itself records what was used, and the
    # leftovers are the ones whose node never found a home.
    def track_expression(value)
      @expressions << value
    end

    def forget_expression(value)
      @expressions.delete_if { |each_value| each_value.equal?(value) }
    end

    # Runs the block, then forgets every expression it built. For a block of the game's that the
    # build calls once on stand-ins, only to read what it gives (the key of `sort_by!`, the
    # comparison of a Struct's `<=>`): what it works out is read and then left out of the program
    # on purpose, so it is not a number the author threw away.
    def with_expressions_untracked
      known = @expressions.to_set(&:object_id)
      yield
    ensure
      @expressions.select! { |value| known.include?(value.object_id) }
    end

    # The expressions built during this build, for the orphaned-expression guardrail.
    def expressions
      @expressions
    end

    # The Conditions still pending at build's end: built but never used. Each did
    # nothing, which almost always means it was handed to a native `if` (a Condition
    # is truthy to Ruby, so the `if` body ran unconditionally and the comparison was
    # silently ignored). The orphaned-Condition guardrail reports these.
    def pending_conditions
      @pending_conditions
    end

    # The hook behind Branch#else: gather the else block's statements
    # into an `else` node and attach it to the if node Condition#record_branch produced.
    def record_else(if_node, &block)
      else_node = Build.else_
      @container_stack.push(else_node)
      # The other side of the same test: what is declared here is shown when the `if`'s
      # condition is false. A copy of that condition, because a node belongs to one place
      # in the tree and this one already belongs to the `if`.
      @shown_while.push(Build.binop(:==, if_node.cond.copy, Build.int(0)))
      begin
        run_block(&block)
      ensure
        @shown_while.pop
        @container_stack.pop
      end
      if_node.else = else_node
    end

    # #record_conditional and #record_else with no block: normal Ruby's `if` keeps its sides
    # where they were written (see DSL::PlainRuby), so a side is opened, run, and closed. Each
    # open goes with one #close_branch.
    def open_branch(cond_node)
      if_node = Build.if_(cond_node)
      record(if_node)
      open_container(if_node, if_node.cond)
      if_node
    end

    def open_other_branch(if_node)
      if_node.else = Build.else_
      open_container(if_node.else, Build.binop(:==, if_node.cond.copy, Build.int(0)))
    end

    def close_branch
      @shown_while.pop
      @container_stack.pop
    end

    # A `break` (+word+ :break) or `next` in a loop the game runs (PlainRuby::Jumps), recorded as
    # the jump out of the innermost loop being recorded, or to its next round.
    def record_loop_jump(word) = record(word == :break ? Build.break_repeat : Build.next_repeat) # :nodoc:

    def take_back_branch(if_node)
      @container_stack.last.children.delete_at(-1) if @container_stack.last.children.last.equal?(if_node)
    end

    # Where the statement just recorded stands, to hand to #take_back_statement.
    def last_statement_place = [@container_stack.last, @container_stack.last.children.last]

    def take_back_statement(container, statement)
      container.children.delete_if { |each_statement| each_statement.equal?(statement) }
    end

    # Where the next statement will be recorded, for #take_statements_since: the open container
    # and the statement last recorded in it (nil for none), so a statement taken back before it
    # cannot move the place.
    StatementMark = Data.define(:container, :last)

    def statement_mark = StatementMark.new(container: @container_stack.last, last: @container_stack.last.children.last)

    # Has anything been recorded since +mark+, where it was made? Nothing is taken.
    def recorded_since?(mark)
      !mark.container.equal?(@container_stack.last) || !mark.container.children.last.equal?(mark.last)
    end

    # The statements recorded since +mark+, taken out of where they were recorded and handed back.
    def take_statements_since(mark)
      children = mark.container.children
      start = mark.last ? children.index { |statement| statement.equal?(mark.last) } : -1
      unless mark.container.equal?(@container_stack.last) && start
        raise IR::InvariantError, "statements were taken from a place that is no longer where the builder records"
      end

      children.slice!((start + 1)..)
    end

    # The statements recorded since +mark+, taken out as #take_statements_since takes them, but for
    # those #record_at put at +mark+ itself, which belong before it and stay (PlainRuby::Jumps: a
    # round of `loop do` taken back, whose field copies were placed where the field was given).
    def take_round_since(mark) # :nodoc:
      placed, round = take_statements_since(mark).partition do |statement|
        at = @placed_at_marks[statement]
        at && at.container.equal?(mark.container) && at.last.equal?(mark.last)
      end
      mark.container.children.push(*placed)
      round
    end

    # How many variables the build has named so far, for #forget_unnamed_variables_since.
    def variables_named = @variables.size # :nodoc:

    # The variables the build made for itself (`__...`) since it had named +count+, that no statement
    # names now: those of statements taken back (#take_round_since), which take no memory and are
    # not reported.
    def forget_unnamed_variables_since(count) # :nodoc:
      made = @variables.to_a.drop(count).select { |name| name.start_with?("__") }
      return if made.empty?

      named = Set.new
      @program.walk { |node| node.named_operands.each { |_field, held| named.merge(Array(held).flatten.grep(Symbol)) } }
      (made - named.to_a).each do |name|
        @hidden_variable_notes.reject! { |note| note.name == name }
        @variables.delete(name)
        @unique_names.delete(name)
        @fraction_vars.delete(name)
      end
    end

    # Records what the block records at +mark+, an earlier place, rather than where the builder
    # records now: just after the statement +mark+ names, in its container, however much was
    # recorded there since. Returns what the block returns.
    def record_at(mark) # :nodoc:
      now = statement_mark
      answer = yield
      made = take_statements_since(now)
      children = mark.container.children
      start = mark.last ? children.index { |statement| statement.equal?(mark.last) } : -1
      raise IR::InvariantError, "statements were put back at a place that is no longer recorded" unless start

      children.insert(start + 1, *made)
      made.each { |statement| @placed_at_marks[statement] = mark }
      answer
    end

    # A `repeat` with a stop test, likewise opened and closed rather than given a block.
    #
    # +test_statements+ are what working the test out recorded: a read's check of its place, the
    # answer of `a && b` whose right side does something, kept in a variable. The test reads what
    # they leave, so they must run again on every round, before the test is asked. Such a loop is
    #
    #   stopped = 0
    #   repeat most_passes, stop_when: stopped
    #     <test_statements>
    #     if <stop_node> then stopped = 1 else <body> end
    #
    # and the body goes in the `else`. A loop whose test records nothing is the plain repeat.
    def open_repeat(most_passes, stop_node, test_statements: [])
      @repeat_seq += 1
      index = :"__repeat_#{@repeat_seq}"
      ensure_var(index)
      @unique_names << index
      return open_repeat_rerunning_test_statements(most_passes, index, stop_node, test_statements) unless test_statements.empty?

      push_open_repeat(Build.repeat(DSL::Value.node_for(most_passes), index, stop_when: inline_held_expressions(stop_node)))
    end

    def close_repeat
      @game_whiles -= 1
      @open_repeat_container_counts.pop.times { @container_stack.pop }
    end

    # Is a `while` on a game test open, in normal Ruby? (see #wait_vblank)
    def inside_game_while? = @game_whiles.positive?

    # A variable of its own for a number the author never named: a value picked between two,
    # or a number kept (see PlainRuby::Steps). Nothing reads it before something has set it. +why+
    # is which line of Diagnostics::HiddenVariables tells the author about it. +like+ is a Value or
    # a Ruby Float to take the kind of number from: holding a fraction, it gives the same bits.
    def hidden_variable(why, like: nil)
      @hidden_variables += 1
      name = :"#{Build::KEPT_VARIABLE_PREFIX}#{@hidden_variables}"
      ensure_var(name)
      @unique_names << name
      bits = like.is_a?(Float) ? DSL::Fraction.bits_of(like) : (like.fraction_bits if like&.fraction?)
      @fraction_vars[name] = bits if bits
      @hidden_variable_notes << HiddenVariableNote.new(name:, source: Messages::AuthorSource.author_source, why:)
      value_handle_for(name)
    end

    # A hidden variable for a number one step stores and reads back before it ends, one for each
    # +why+ in the routine being recorded (outside every routine, the outermost body being recorded,
    # #recorded_routine_body), however many of its steps keep one (DSL::Value#step_copy). A step that
    # stores it reaches no other such step before its last read, so the steps of one routine can
    # share it, and a routine with hundreds of them keeps one word, not hundreds.
    #
    # Shared wider than the routine it would not be safe. A timer's handler runs whenever the timer
    # ticks: on the Advance from the timer's interrupt, which stops the game between any two
    # instructions (GBA::FrameBoundaryCalls). A step written in a handler could then store over a
    # number that a step of the routine it stopped had not read yet. A bend's steps are worked out
    # where the game wrote no call too, as the game wakes from a wait on the Advance, and a console
    # may work them out as the screen draws each row. So a step inside a handler or a bend keeps its
    # number apart from the routine it is written in, one for each handler and each bend. A routine
    # that a handler calls is no worse off than with a variable for each step: stopped part way
    # through one of its steps and run again by the handler, it would write over that step's own
    # variable too.
    def step_variable(why)
      owner = @container_stack.reverse_each.find { |node| UNCALLED_BODY_KINDS.include?(node.kind) } ||
              @container_stack[1] || @container_stack.first
      name = ((@step_variables[owner] ||= {})[why] ||= hidden_variable(why).name)
      value_handle_for(name)
    end

    # The bodies that run where the game wrote no call: a timer's handler and a bend's steps.
    UNCALLED_BODY_KINDS = %i[on_timer scroll_rows].freeze

    # Variable +name+ holds the value node +node+, set where it is written, so the text of a
    # program does not repeat the expression wherever its answer is used
    # (Original::Packing::BlockKitInternals holds a read's place this way). A loop's test must
    # still work the expression out afresh each time round, as it did written inline: the variable
    # is set once, before the loop, while a test is asked again on every round. So a loop's test
    # reads the expression in place of the variable (#inline_held_expressions). Public for
    # BlockKitInternals#emit_held_place, which holds those places.
    def register_held_expression(name, node) = @held_expressions[name] = node

    # The value the block gives back, with the statements recorded while working it out kept as
    # what that value needs run before each time it is read: a read of the copy's check of its place
    # against the copy's end, and the store of a held place (#register_held_expression). A loop's
    # test given as an argument (`repeat n, stop_when: copy.byte(at) == 0`) is worked out before
    # the loop is opened, so those statements are recorded before it, and would run once; #repeat
    # moves them into the loop, to run on every round before the test is asked
    # (#take_trailing_test_statements). Public for Original::Packing::BlockKitInternals, whose
    # reads of the copy are such values.
    def register_statements_for_value
      mark = statement_mark
      value = yield
      if value.is_a?(DSL::Value) && mark.container.equal?(@container_stack.last)
        children = mark.container.children
        start = mark.last ? children.index { |statement| statement.equal?(mark.last) } : -1
        recorded = start ? children[(start + 1)..] : []
        @value_statements[value.node] = recorded unless recorded.empty?
      end
      value
    end

    # +name+, or the first of name_2, name_3... that no variable has.
    def free_variable_name(name)
      return name unless @variables.include?(name)

      (2..).lazy.map { |number| :"#{name}_#{number}" }.find { |each_name| !@variables.include?(each_name) }
    end

    # #free_variable_name, for a variable about to be made under it: the name is one of
    # #unique_names from now on.
    def reserve_free_variable_name(name) = free_variable_name(name).tap { |free| @unique_names << free }

    # The variable names this build made unique, by a counter (a `repeat`'s index, a hidden copy, an
    # approach's step) or by taking a free name (#reserve_free_variable_name: a plain-Ruby local's
    # variable, an object's instance variable's). Another build of other code makes the same names
    # for variables of its own, so two builds that each made a name never mean one variable by it:
    # built together, the second would have been given another. Original::UnpackingParts asks, for
    # a part of an unpacking built alone.
    attr_reader :unique_names

    # Has a `var` line made +name+ already? PlainRuby::Writes asks, for a line that makes a variable
    # and is reached a second time.
    def variable_declared?(name) = @var_declarations.key?(name)

    # A local of plain Ruby that a game variable keeps: the variable's name, and the number the
    # local's first line started it at, which is the variable's start at power-on.
    PlainLocal = Data.define(:variable_name, :start)

    # The game variable for the local +name+ of +source+, one rewritten game block or game file
    # (PlainRuby::Writes.variable_with_no_var_line). As in Ruby, a local is its own whatever other
    # sources call theirs: the first source to use a name gets it, and each other takes name_2 and
    # on. The line that makes the variable can run again, in a method called twice or a loop
    # written out, with another start. The variable keeps the first as its power-on number, and
    # the line sets it to the other where it runs.
    def plain_local_variable(source, name, start)
      local = (@plain_locals[[source, name]] ||= PlainLocal.new(variable_name: reserve_free_variable_name(name), start: start))
      var(local.variable_name, local.start)
    end

    # Has the line of +source+ that makes the local +name+'s variable run already?
    def plain_local_made?(source, name) = @plain_locals.key?([source, name])

    # What the build added for the author that the author never wrote, for `rom.profile`.
    def hidden_variable_notes = @hidden_variable_notes

    # The hidden variable +name+ holds the number of the plain local +local+ (Value#owner_name=),
    # for Cartridge::Game#copies_that_differed to name it.
    def record_hidden_variable_local(name, local)
      at = @hidden_variable_notes.rindex { |note| note.name == name } or return # made just before, so near the end
      @hidden_variable_notes[at] = @hidden_variable_notes[at].with(local: local)
    end

    # Game code gave a new number to +name+, which held the game +variable+ it was handed, so the
    # variable stayed as it was (PlainRuby::Writes.note_handed_name_written). One warning for each
    # line, however many items a `each` around it recorded it for.
    def record_handed_name_write(name, variable)
      source = Messages::AuthorSource.author_source
      return if @handed_name_writes.any? { |write| write.name == name && write.source == source }

      @handed_name_writes << HandedNameWrite.new(name:, variable:, source:)
    end

    # The lines #record_handed_name_write kept, for the warning.
    attr_reader :handed_name_writes

    # A line outside game code kept a button's answer in +local+ for game code to read
    # (DSL::Value#record_kept_button). One warning for each line.
    def record_kept_button(local)
      source = Messages::AuthorSource.author_source
      return if @kept_buttons.any? { |kept| kept.source == source && kept.local == local }

      @kept_buttons << KeptButton.new(local:, source:)
    end

    # The lines #record_kept_button kept, for the warning.
    attr_reader :kept_buttons

    # The names normal Ruby made variables of with no `var` line.
    attr_reader :variables_with_no_var_line

    def note_variable_with_no_var_line(name) = @variables_with_no_var_line |= [name]

    def variable_with_no_var_line?(name) = @variables_with_no_var_line.include?(name)

    # An unsaved variable: scratch a part named with `game_variables ..., saved: false`, which a
    # save never keeps. `saves_keep_everything` passes it over, and a `save_data` record keeping
    # it is refused.
    def note_unsaved_variable(name) = @unsaved_variables << name

    def unsaved_variable?(name) = @unsaved_variables.include?(name)

    # A hidden variable that keeps the number a Struct's field was given
    # (PlainRuby::InstanceVariables#own_field_variable), noted so that #drop_unneeded_field_copies
    # can leave it out once the whole game is known.
    def field_copy_variable(like:)
      hidden_variable(:field, like: like).tap { |copy| (@field_copies ||= []) << copy.name }
    end

    # Each field copy whose number cannot change before its reads is left out, its reads given the
    # working-out it copied (IR::UnneededCopies). Run once every line of game code is recorded, so
    # every timer's handler and bend is known.
    def drop_unneeded_field_copies
      return if @field_copies.nil?

      outside = IR::UnneededCopies.names_outside_main_flow(@program)
      @field_copies.each { |name| forget_hidden_variable(name) if IR::UnneededCopies.drop!(@program, name, outside) }
    end

    # A hidden variable an instance variable keeps of its own, holding the number of the variable
    # +like+ it was handed (PlainRuby::Writes.handed_copy), noted so that
    # #drop_unwritten_handed_copies can leave it out where no line gives it a number.
    def handed_copy_variable(like:)
      hidden_variable(:handed_copy, like: like).tap { |copy| (@handed_copies ||= []) << copy.name }
    end

    # Each handed copy that only its first line writes is left out, its reads reading the variable
    # it copied (IR::UnneededCopies.drop_unwritten!). Run once every line of game code is recorded.
    def drop_unwritten_handed_copies
      return if @handed_copies.nil?

      IR::UnneededCopies.drop_unwritten!(@program, @handed_copies).each do |name|
        forget_hidden_variable(name)
        @unique_names.delete(name)
        @fraction_vars.delete(name)
      end
    end

    # A hidden variable nothing came to need, which then takes no memory and is not reported.
    def forget_hidden_variable(name)
      @variables.delete(name) if @hidden_variable_notes.reject! { |note| note.name == name }
    end

    # A hidden variable for a loop to count in, declared and named: a `repeat`'s, the one a step
    # that stands for a loop is handed (IR save_load_list, save_store_list, list_pack), and the one
    # a counted Ruby loop made a loop counts in (PlainRuby::Counts::KnownRounds).
    def declare_loop_counter
      @repeat_seq += 1
      :"__repeat_#{@repeat_seq}".tap do |index|
        ensure_var(index)
        @unique_names << index
      end
    end

    # A loop counter whose loop was dropped, which then takes no memory: the rounds after the first
    # of a counted Ruby loop the build made a loop (PlainRuby::Counts::KnownRounds).
    def forget_loop_counter(name) = @variables.delete(name)

    # One counted Ruby loop of game code whose count was known while building, and what the build
    # made of it (PlainRuby::Counts::KnownRounds): +rounds+ times round, +written_size+ the IR nodes
    # its rounds hold written out, +choice+ :written_out, :loop or :rounds_differ, and +worked_out+
    # how many numbers a loop works out from its count in each round.
    CountedLoopNote = Data.define(:source, :rounds, :written_size, :choice, :worked_out) do
      def initialize(source:, rounds:, written_size:, choice:, worked_out: 0) = super
    end

    # The counted loops of game code, for `rom.profile` (Diagnostics::CountedLoops).
    attr_reader :counted_loop_notes

    def record_counted_loop(note) = @counted_loop_notes << note

    # The notes of counted loops recorded after the first +count+, which were inside rounds of
    # a counted loop that the build dropped, making the first round a loop.
    def drop_counted_loops_after(count) = @counted_loop_notes.slice!(count..)

    # Is what is recorded now code the game runs as it plays, rather than setting up?
    def recording_game_code? = @container_stack.length > 1

    # The test, loop or routine body game code is being recorded into now: what runs on the same
    # passes as the line being recorded. DSL::PlainRuby::InstanceVariables notes where a Struct
    # is made with it.
    def recording_container = @container_stack.last # :nodoc:

    # Is +container+ (a #recording_container) open around what is recorded now, so a line recorded
    # now runs only on passes where +container+'s lines run too?
    def recording_inside?(container) = @container_stack.any? { |open| open.equal?(container) } # :nodoc:

    # Is what is recorded now game code under a test the game makes, inside the routine or loop
    # being recorded? Only some passes run it. DSL::PlainRuby::InstanceVariables::Uses asks, since a
    # number a method sets there is one Ruby cannot know after it.
    def recording_under_game_test? = @container_stack.drop(2).any? { |node| %i[if else].include?(node.kind) } # :nodoc:

    # Runs a part's `initialize` (PlainRuby's rewrite wraps each in a game file). A part game code
    # keeps (`@part ||= Part.new`, #keeping_part), in a scene or the game loop, is made the first
    # time the line runs, as its numbers start once
    # (InstanceVariables.first_number_set_where_reached?), though the line making it plays on
    # every pass: what it puts into its Arrays goes in on the first pass alone (#once_for_part).
    # Made while setting up, it runs once anyway, and nothing changes.
    def making_part # :nodoc:
      return yield unless recording_game_code?

      (@part_starts ||= []).push(PartStart.new(depth: @container_stack.length, made: Set.new, kept: keeping_parts?,
                                               keeper: @keeper_made_every_pass))
      keeper = @keeper_made_every_pass
      @keeper_made_every_pass = nil # what this part's `initialize` makes is kept, if at all, by this part
      begin
        yield
      ensure
        @keeper_made_every_pass = keeper
        close_part_start(@part_starts.pop)
      end
    end

    # Runs the block, a line of game code keeping a part with `||=` (#keeping_part) in a part of
    # the class named +keeper+, which is itself made again on every pass: in Ruby the part kept is
    # new on every pass too, so it is made every pass (#made_every_pass?), and the refusal of a
    # changing one names +keeper+ (#keeper_made_every_pass).
    def keeping_in_part_made_every_pass(keeper) # :nodoc:
      outer = @keeper_made_every_pass
      @keeper_made_every_pass = keeper
      yield
    ensure
      @keeper_made_every_pass = outer
    end

    # The class name of the part made every pass whose `||=` is making a part now, if one is.
    attr_reader :keeper_made_every_pass # :nodoc:

    # Runs the block, the right side of a line of game code that keeps what it gives with `||=`
    # (`@part ||= Part.new`, `@loads ||= Loads.fill(queue)`), so the parts it makes, and the parts
    # their `initialize` makes, are made one time (#made_every_pass?). Ruby runs the right side
    # once, so its straight-line code is set-up as a kept part's `initialize` is
    # (#recording_kept_part_start?), and a change it makes to a plain Ruby Array happens once.
    # Each such change is noted on +changes+, since a right side that gives nil or false runs
    # again on the next pass and its changes are then made every pass
    # (DSL::PlainRuby::InstanceVariables.keeping_part refuses them).
    def keeping_part(changes = []) # :nodoc:
      @keeping_parts = (@keeping_parts || 0) + 1
      (@kept_right_sides ||= []).push(KeptRightSide.new(depth: @container_stack.length,
                                                        part_starts: (@part_starts || []).length, changes: changes))
      yield
    ensure
      @kept_right_sides.pop
      @keeping_parts -= 1
    end

    # A right side of `||=` being run (#keeping_part): where its code records, how many parts were
    # being made around it, and the changes to plain Ruby Arrays it made.
    KeptRightSide = Data.define(:depth, :part_starts, :changes)

    # The changes to plain Ruby Arrays the right side of `||=` being run now has made, which a
    # change let through as set-up (#recording_kept_part_start?) is added to; nil where the
    # set-up is a kept part's `initialize`.
    def kept_right_side_changes = innermost_kept_right_side&.changes # :nodoc:

    # The right side of `||=` being run now, where no part started inside it is being made.
    def innermost_kept_right_side
      side = @kept_right_sides&.last
      side if side && (@part_starts || []).length == side.part_starts
    end
    private :innermost_kept_right_side

    def keeping_parts? = (@keeping_parts || 0).positive?
    private :keeping_parts?

    # Is a part made now made again on every pass in Ruby: made by game code, and not kept
    # (#keeping_part)? DSL::PlainRuby::InstanceVariables refuses one whose numbers change.
    def made_every_pass? = recording_game_code? && !keeping_parts? # :nodoc:

    # Runs the block with what it records (a list made and filled) set to run once at program
    # start (#at_boot), wherever the build is recording, and returns what the block returns. A
    # part's Array made the game's in game code (DSL::PlainRuby::InstanceVariables.indexed) is
    # made this way, since the game must make it once, not on every pass of the line.
    def recording_at_boot # :nodoc:
      holder = IR::Build.loop_
      @container_stack.push(holder)
      made = begin
        yield
      ensure
        @container_stack.pop
      end
      holder.children.dup.each { |node| at_boot(node) }
      made
    end

    # The part's things are in: its hidden number holds 1 from here on. Set inside the test the
    # last push recorded, where that ends the `initialize`, so a pass after the first sets nothing.
    def close_part_start(start)
      return unless start.started

      branch = start.branch
      return start.started.store!(1) unless branch && @container_stack.last.children.last.equal?(branch)

      open_container(branch, branch.cond)
      begin
        start.started.store!(1)
      ensure
        close_branch
      end
    end
    private :close_part_start

    # A part being made in game code (#making_part): where its `initialize` records, the Arrays it
    # made there, its hidden number, whether a #once_for_part is open, and the last test one made.
    PartStart = Struct.new(:depth, :made, :started, :once_open, :branch, :kept, :keeper, keyword_init: true)

    # The Array +name+ (a list, or the pool an Array of Structs is) is made while a part is being
    # made, so what that part's `initialize` puts into it goes in once (#once_for_part). Every part
    # being made takes note: one made inside another's `initialize` is made once with it, and an
    # object Ruby makes while the Array is declared opens a #making_part of its own.
    #
    # A part game code makes without keeping it (#keeping_part) is a new one on every pass in Ruby,
    # with its Arrays made and filled again, so making one there is refused.
    def note_made_in_part(name) # :nodoc:
      (@part_starts || []).each do |start|
        next unless part_start_code?(start)

        refuse_array_in_repeated_part!(name, start.keeper) unless start.kept
        start.made << name
      end
    end

    def refuse_array_in_repeated_part!(name, keeper)
      if keeper
        raise DSL::PlainRuby::Refused,
              "This line makes a new object and keeps it in a `#{keeper}`, and its `initialize` makes the Array " \
              "`#{name}`. But the `#{keeper}` is made in code that runs every frame, so in Ruby a new `#{keeper}` " \
              "is made on every pass, and it makes and fills a new Array. To fix this, make the `#{keeper}` " \
              "above the game loop, or keep it in an instance variable too, like `@part ||= #{keeper}.new(...)`." \
              "#{Messages::AuthorSource.at_author_line}"
      end
      raise DSL::PlainRuby::Refused,
            "This line makes a new object in code that runs every frame, and its `initialize` makes the Array " \
            "`#{name}`. In Ruby each new object makes and fills its Array again. To fix this, make the object " \
            "above the game loop, or keep it in an instance variable, like `@part ||= Part.new(...)`, so it is " \
            "made one time.#{Messages::AuthorSource.at_author_line}"
    end
    private :refuse_array_in_repeated_part!

    # Records what the block records (a push into the Array +name+, or its making) so it runs only
    # on the first pass of the part being made, where #making_part is open, the part made +name+
    # in its `initialize` (#note_made_in_part), and the block is in that `initialize`'s
    # straight-line code or a test there. A push into an Array handed in, and anything in a
    # routine, loop or timer the `initialize` opens, plays every time, as written.
    def once_for_part(name) # :nodoc:
      start = @part_starts&.last
      return yield unless start && start.made.include?(name) && !start.once_open && part_start_code?(start)

      start.started ||= hidden_variable(:part_started)
      (@part_started_by_array ||= {})[name] = start.started.name
      start.once_open = true
      # Pushes one after another (a Ruby loop filling the Array) share one test.
      if (branch = start.branch) && @container_stack.last.children.last.equal?(branch)
        open_container(branch, branch.cond)
      else
        start.branch = open_branch(Build.binop(:==, DSL::Value.node_for(start.started), Build.int(0)))
      end
      begin
        yield
      ensure
        close_branch
        start.once_open = false
      end
    end

    # The hidden number that keeps the Array +name+ (a list, or a pool's name) to one filling by its
    # part's `initialize` (#once_for_part), or nil. A save that keeps the Array keeps it too.
    def part_started_for(name) = @part_started_by_array&.fetch(name, nil) # :nodoc:

    # Is the builder recording the straight-line code of the `initialize` of a part game code keeps
    # (`@part ||= Part.new`, #keeping_part), or of a part that `initialize` makes? Ruby runs that
    # code once, so a change it makes to another object's plain Ruby Array happens once, while the
    # game is built, as in Ruby. Not under a test there: Ruby would run both sides of it while
    # building, where the game runs one. DSL::PlainRuby::InstanceVariables.refuse_unkept_change!
    # asks.
    #
    # So is the straight-line code of a right side of `||=` being run (#keeping_part), however
    # many calls down: Ruby runs it once too.
    def recording_kept_part_start? # :nodoc:
      side = innermost_kept_right_side
      return @container_stack.length == side.depth if side

      start = @part_starts&.last
      !start.nil? && start.kept && @container_stack.length == start.depth
    end

    # Is the builder recording in +start+'s `initialize` itself, under nothing but tests?
    def part_start_code?(start)
      @container_stack.length >= start.depth &&
        @container_stack.drop(start.depth).all? { |node| %i[if else].include?(node.kind) }
    end
    private :part_start_code?

    # Is the body being built now a routine's that is not a scene's? It runs wherever it is
    # called, inside a walk of a pool among them. DSL::StructArray#shift asks.
    def building_callable_routine? = !@building_routine.nil? && @building_scene.nil? # :nodoc:

    # The outermost body of game code being recorded now: the routine, scene or loop it is in,
    # nil while setting up. DSL::PlainRuby::InstanceVariables::Uses tells two routines apart by it.
    def recorded_routine_body = @container_stack[1]

    # The instance variables the game names as game variables, and what game code did to the
    # others (DSL::PlainRuby::InstanceVariables::Uses).
    attr_reader :instance_variable_uses

    private

    # #open_repeat's loop for a test that records statements. The statements were recorded where
    # the test was worked out, and move into the loop here. Two containers are opened, the loop
    # and the `else` the body goes in, and #close_repeat closes both.
    #
    # The test is not given #inline_held_expressions: a held place's store is one of the
    # statements, so it is set afresh each round before the test reads it. Nor does the `else`
    # gate what is declared in the body (no #open_container), as the plain repeat's body is not.
    def open_repeat_rerunning_test_statements(most_passes, index, stop_node, test_statements)
      stopped = declare_stop_flag(index)
      push_open_repeat(Build.repeat(DSL::Value.node_for(most_passes), index, stop_when: Build.var_ref(stopped)))
      @container_stack.push(emit_test_asking(stopped, stop_node, test_statements))
      @open_repeat_container_counts[-1] += 1
    end

    # #repeat's loop for a `stop_when:` whose working out recorded +test_statements+
    # (#take_trailing_test_statements): the loop #open_repeat_rerunning_test_statements makes,
    # given a block for its body, which is handed +index_value+.
    def repeat_rerunning_test_statements(count, index, index_value, stop_node, test_statements, &block)
      stopped = declare_stop_flag(index)
      push_container(Build.repeat(DSL::Value.node_for(count), index, stop_when: Build.var_ref(stopped))) do
        @container_stack.push(emit_test_asking(stopped, stop_node, test_statements))
        begin
          run_block(index_value, &block)
        ensure
          @container_stack.pop
        end
      end
    end

    # The loop's stop flag, a variable of its own, set to 0 here before the loop.
    def declare_stop_flag(index)
      stopped = :"#{index}_stopped"
      ensure_var(stopped)
      @unique_names << stopped
      record(Build.set(stopped, 0))
      stopped
    end

    # Inside the loop: +test_statements+, then an `if` on +stop_node+ that sets +stopped+, whose
    # `else` is given back for the body.
    def emit_test_asking(stopped, stop_node, test_statements)
      test_statements.each { |statement| attach(statement) }
      ask = Build.if_(stop_node, Build.set(stopped, 1))
      ask.else = Build.else_
      record(ask)
      ask.else
    end

    # The statements +node+ (a loop's test, worked out before the loop) needs run before each time
    # it is read (#register_statements_for_value), and those the statements themselves need, taken
    # out of the open container. They are taken only when they are the last statements recorded
    # there, so nothing written between them and the loop reads what they set; otherwise none are,
    # and the test reads them once, before the loop.
    def take_trailing_test_statements(node)
      return [] if @value_statements.empty?

      children = @container_stack.last.children
      needed = {}.compare_by_identity
      waiting = [node]
      until waiting.empty?
        waiting.pop.walk.each do |part|
          @value_statements.fetch(part, []).each do |statement|
            next if needed.key?(statement)

            needed[statement] = true
            waiting << statement
          end
        end
      end
      here = children.select { |statement| needed.key?(statement) }
      return [] if here.empty? || !children.last(here.size).each_with_index.all? { |statement, at| statement.equal?(here[at]) }

      children.pop(here.size)
    end

    # Records +node+, a game `while`'s repeat, and opens it until #close_repeat.
    def push_open_repeat(node)
      record(node)
      @container_stack.push(node)
      @open_repeat_container_counts.push(1)
      @game_whiles += 1
    end

    # +node+ (a loop's test), with every read of a variable #register_held_expression named
    # replaced by the expression it holds, and those inside it in turn; +node+ itself where it
    # reads none. A copy, so the expression stays as it is where it was written.
    def inline_held_expressions(node)
      return node if @held_expressions.empty? || !reads_held_expression?(node)
      return inline_held_expressions(@held_expressions.fetch(node.name).copy) if held_expression_read?(node)

      fresh = node.copy
      replace_held_expression_reads!(fresh)
      fresh
    end

    def held_expression_read?(node) = node.is_a?(IR::Nodes::VarRef) && @held_expressions.key?(node.name)

    def reads_held_expression?(node)
      node.is_a?(IR::Node) && (held_expression_read?(node) || node.operand_nodes.any? { |part| reads_held_expression?(part) })
    end

    # Each read of a held variable among +node+'s operands, however deep, replaced by what it holds.
    # A read held in a list of nodes cannot be replaced, and raises rather than read a stale place.
    def replace_held_expression_reads!(node)
      node.operand_nodes.each do |part|
        if held_expression_read?(part)
          replaced = node.replace_operand(part, inline_held_expressions(@held_expressions.fetch(part.name).copy))
          raise IR::InvariantError, "#{node.kind} holds a read of #{part.name} in a list, which a loop's test cannot inline" unless replaced
        else
          replace_held_expression_reads!(part)
        end
      end
    end

    def open_container(node, shown_while)
      @container_stack.push(node)
      @shown_while.push(shown_while)
    end

    # --- Boot-time initialization ---

    # Register a statement to run once at program start, before anything else. It's
    # for hidden state that must begin from a known value because console RAM isn't
    # zero at power-on — the random seed, a timer's frame counter. #emit_boot_inits
    # hoists these to the very front at finalize, so they can be recorded from deep
    # inside a loop or scene yet still run once, up front.
    def at_boot(node)
      @boot_inits << node
    end

    # Hoist every registered boot statement to the front of the program, keeping
    # the order they were registered in, so all hidden state is set before the
    # game starts.
    def emit_boot_inits
      @boot_inits.reverse_each { |node| prepend_to_program(node) }
    end

    # Put +node+ first in the program, owned by it.
    def prepend_to_program(node)
      @program.children.unshift(node)
      node.parent = @program
    end

    # A fixed marker written alongside the saved variables so a fresh cartridge
    # (whose save memory holds random power-on garbage) is told apart from one that
    # already holds real saved data. Any stable, unlikely value does; this spells
    # "SAV1" in bytes.
    SAVE_MAGIC = 0x53415631

    # If the program declared any `save_var`s, add the one boot step that loads them
    # (or writes their defaults on a fresh cartridge). Registered at boot like the
    # other hidden-state setup, so it runs once before the game starts. On flash they are kept
    # in a record of their own, which loads them itself (see SaveVarRecord).
    def register_save_init
      return if @persisted.empty? || @saves&.save_vars_in_record?

      at_boot(Build.save_init(vars: @persisted, magic: SAVE_MAGIC))
    end

    # Record a mirror-to-save-memory right after a persisted variable changed, so
    # what's saved always matches what the game just did. A no-op for an ordinary
    # variable, so every mutation verb can call it without checking first.
    def mirror_save(name)
      entry = @persisted.find { |v| v.name == name }
      record(Build.save_store(name, entry.slot)) if entry
    end

    # Whether +name+ is a persisted variable (declared with `save_var`).
    def persisted?(name)
      @persisted.any? { |v| v.name == name }
    end

    # Which scenes are shown for which state, read from the scene dispatch (case nodes):
    # a scene func named as a case target is presented only while the dispatched
    # variable holds a value of a clause naming it. Maps a scene func name → [state_var,
    # values], so a sprite/HUD declared inside that scene can be gated to when the scene is
    # live. A scene picked by several values (`when 1, 2 then call :over`) is up for each.
    def scan_scene_gates
      values = Hash.new { |hash, target| hash[target] = [] }
      vars = {}
      @program.walk do |node|
        next unless node.kind == :case

        node.clauses.each do |value, target|
          vars[target] ||= node.var
          values[target] |= [value] if vars[target] == node.var
        end
      end
      vars.to_h { |target, var| [target, [var, values[target].freeze].freeze] }
    end

    # Gate an object's visibility to its scene: a scene-owned object is shown only when
    # both its own shown-flag is set AND its scene is the active one. Rides the object's
    # existing per-frame `active` value, so presentation stays automatic — nothing new to
    # call, and no per-draw flag in game code. Outside a scene, visibility is unchanged.
    # Which game state a declaration belongs to, or nil where it belongs to none and is
    # always there. The gate above gives the same thing as a run-time test; this gives it
    # as a name, which is what something deciding what has to be in memory at once needs.
    def declaring_scene = @building_scene

    # A scene's body that no dispatch picks, whose lines never run.
    def body_of_unpicked_scene? = !@scene_laid_out.nil? && @current_scene_gate.nil?

    def gated_by_scene(active_node)
      return active_node unless @current_scene_gate

      Build.binop(:*, active_node, scene_up(@current_scene_gate))
    end

    # "The scene +gate+ names is the one up": the variable the game picks its scenes with holds
    # a value that picks it. A gate is that variable and those values.
    def scene_up((state_var, values))
      values.map { |value| Build.binop(:==, Build.var_ref(state_var), Build.int(value)) }
            .reduce { |either, other| Build.binop(:or, either, other) }
    end

    # +node+, run only while the scene +gate+ names is up — or as it is, for a nil gate: a
    # thing declared outside every scene is there in all of them.
    def while_scene_up(gate, node) = gate ? Build.if_(scene_up(gate), node) : node

    # +node+, run while any scene of +gates+ is up: a background of one name declared in
    # several scenes is written for while any of them is. A nil among them is a declaration
    # outside every scene, which is there in all of them.
    def while_any_scene_up(gates, node)
      # A background declared only in scenes never picked has no gates, and is written as one
      # outside every scene is.
      return node if gates.empty? || gates.include?(nil)

      Build.if_(gates.map { |gate| scene_up(gate) }.reduce { |either, other| Build.binop(:or, either, other) }, node)
    end

    # Gate a declaration's visibility on the conditions it was written under, so a
    # blinking prompt is the plain thing an author would write:
    #
    #   draw_text "PRESS START", 76, 100, :gray if blink == 1
    #
    # Text on a tiled screen is not painted where the call sits — it becomes little glyph
    # sprites the console composites every frame, from a list settled once at build time.
    # So the `if` around the call would otherwise decide nothing at all: the glyphs are
    # declared inside it, and then shown on every frame regardless, which reads as a
    # prompt that never blinks. Carrying the condition onto the glyph itself is what makes
    # the two agree — it is shown exactly while the test holds, which is what the line asks for.
    #
    # A condition is 0 or 1, so several nested ones multiply together, the same way
    # #gated_by_scene folds in "and this scene is the live one". Each is copied because a node
    # belongs to one place in the tree, and these already belong to their `if`.
    def gated_by_open_conditions(active_node)
      @shown_while.reduce(active_node) { |node, cond| Build.binop(:*, node, cond.copy) }
    end

    # Fill every frame's present-objects node with the complete object list once all
    # scenes are built — a scene declares its sprites/HUD inside its own body (built after
    # the game loop), so the list isn't known when wait_vblank records the node. A frame
    # that ends up with no objects drops the node, so an object-free program is unchanged.
    #
    # Sprites and a pool's slots are listed together, in the order the game declared them,
    # so a pool takes its place among the sprites by the same rule two sprites follow: the
    # one declared later is in front. The HUD comes last, over all of them.
    def finalize_present_lists
      names = move_front_sprites_last(arrange_draw_orders(in_stack_order(@sprite_objects + @hud_objects)))
      @present_nodes.each do |node|
        if names.empty?
          node.parent&.children&.delete(node)
        else
          node.names = names
          node.orders = draw_order_runs(names)
        end
      end
    end

    # +names+ with every sprite marked in front (IR::Nodes::Object#in_front) moved after the rest,
    # each keeping its order: a console that keeps a priority bit in each sprite shows the front
    # sprite's pixel and only then asks its priority, so a sprite in front must be in front of
    # every sprite not in front, or one of those over it would put it behind a cell in front.
    def move_front_sprites_last(names)
      front = @program.walk.select { |node| node.kind == :object && node.in_front }.map(&:name)
      return names if front.empty?

      ahead, behind = names.partition { |name| front.include?(name) }
      behind + ahead
    end

    # The objects to draw, arranged the way the declared layers ask for. This is the
    # one place a frame's drawing order is settled: the list every backend is handed
    # already sets what goes in front of what, so no backend works it out for itself
    # and two of them cannot come to different answers.
    #
    # The layer is read back off the objects in the tree rather than kept beside them
    # here, because the tree is where a backend will read it too — one fact, one place.
    def in_stack_order(names)
      layer_of = @program.walk.each_with_object({}) do |node, found|
        found[node.name] = node.layer if node.kind == :object
      end
      IR::Stacking.order_by_stack(names, @layer_stack) { |name| layer_of[name] }
    end

    # Move every background's scroll write to the frame boundary.
    #
    # The display re-reads a background's scroll position for every line it draws, so
    # writing it while the picture is being drawn shifts only the lines below that
    # point and the screen tears in half. Writing it in the gap between frames
    # instead means a game can work out where its camera goes anywhere in the frame,
    # take as long as it likes, and never tear.
    #
    # The writes are placed here rather than where scroll was called because which
    # backgrounds scroll is only known now: a scene's body is built after the loop
    # that dispatches to it. Each boundary gets fresh nodes, so no node is shared
    # between two places in the tree.
    #
    # A program with no frame boundary (no game loop) keeps the writes where they
    # were called — nothing is pacing it, so there is no gap to move them to.
    #
    # Each write is gated to its owning scene, the same as a scene-owned sprite, HUD glyph
    # or turning background (see #finalize_background_affine). Where a background sits is a
    # property of the layer rather than of the background, and scenes take turns with the
    # layers — so two backgrounds that share one both write its position every frame, and
    # the one declared later wins wherever they disagree. A title screen of drifting
    # scenery handing over to a game that starts at the top of its map was pinned still by
    # the game's nought, on a screen the game was not even on.
    def finalize_background_scrolls
      write_between_frames(@inline_scroll_nodes, backgrounds_that(&:scrolls?)) do |name, background|
        scroll_write_node(name, background)
      end
    end

    # Show where each status bar's top is, in the gap between frames, gated to its scene, for
    # the reason a scroll is written there: the display reads where the bar starts as it draws
    # each line, so a bar moved while it draws would split the picture. Every bar has one, moved
    # or not, since its top is a variable (see Tiled#status_bar).
    def finalize_status_bars
      write_between_frames(@inline_bar_nodes, backgrounds_that { |background| background.node.bar? }) do |name, background|
        covers = @bars_covering[name]
        while_any_scene_up(background.scene_gates,
                           Build.place_bar(name, top: Build.var_ref(IR::Nodes::Background.bar_top_var(name)),
                                                 covers: covers && Build.var_ref(covers)))
      end
    end

    # Show the box each background is held to, in the gap between frames, gated to its scene, for
    # the reason a scroll is written there: the display reads which layers show where as it draws
    # each line, so a box moved while it draws would show two boxes on one picture. Every
    # declaration of the name carries the variable that holds whether it is held, which goes back to
    # everywhere as its scene takes over (IR::SceneHandover). A background the game hides
    # (`hide`) and never holds to a box of some size has every write marked whole
    # (Nodes::BoxBackground), the ones left where the game set them in a program with no frame
    # boundary too. One only ever shown everywhere is not marked, and builds as it did.
    def finalize_background_boxes
      boxed = backgrounds_that(&:held_to_box?)
      held = boxed.to_h { |name, background| [name, background.box.last] }
      @program.walk.each { |node| node.boxed = held[node.name] if node.kind == :background && held.key?(node.name) }
      whole = boxed.select { |_, background| background.hidden_whole && !background.boxed_in_part }.keys
      @inline_box_nodes.each { |node| node.whole = true if whole.include?(node.name) }
      write_between_frames(@inline_box_nodes, boxed) do |name, background|
        x, y, width, height, on = background.box.map { |var| Build.var_ref(var) }
        while_any_scene_up(background.scene_gates,
                           Build.box_background(name, x: x, y: y, width: width, height: height, held: on,
                                                      whole: whole.include?(name) || nil))
      end
    end

    # Everything the build knows about the background called +name+ — the record
    # {Tiled#background} made on the line that declared it.
    #
    # fetch, not a lookup that makes one: every caller but that verb is reached from a
    # handle the verb already handed back, so a name with no record is a bug here rather
    # than something to shrug at. Made silently, an empty record would be written into,
    # walked at finalize, and emit a write for a background that does not exist.
    def declared_background(name)
      @backgrounds.fetch(name)
    end

    # The declared backgrounds the block returns true for, in declaration order —
    # `backgrounds_that(&:scrolls?)`.
    def backgrounds_that
      @backgrounds.select { |_name, background| yield(background) }
    end

    # Put a write per thing in the gap between frames, at every frame boundary there is — the
    # shared half of the passes above and below, which differ only in what they are about
    # (the backgrounds that scroll, the ones handed a map, the lists of colours that change)
    # and what each one writes. +things+ is those, by name; the block is handed each
    # name and what is kept about it, and gives back the write.
    #
    # +inline_nodes+ are the writes recorded where the author called for them, dropped here
    # because there is a better place to put them. A program with no frame boundary keeps
    # them: nothing is pacing it, so there is no gap to move them to.
    #
    # They are written back to front, because each write is inserted directly after the wait
    # and so pushes the one before it further along — reversing puts them back in the order
    # they were declared.
    def write_between_frames(inline_nodes, things)
      return if things.empty? || @frame_boundaries.empty?

      inline_nodes.each { |node| node.parent&.children&.delete(node) }

      @frame_boundaries.each do |wait_node|
        container = wait_node.parent
        at = container&.children&.index(wait_node)
        next unless at

        things.reverse_each do |name, thing|
          node = yield(name, thing)
          container.children.insert(at + 1, node)
          node.parent = container
        end
      end
    end

    # A write made only on a frame where the answer changed. +requested+ is the variable
    # holding what the game last set, and +in_force+ the one holding what the write last put
    # in place; they differ exactly on the frame to write on, and the write then makes them
    # agree. See #finalize_background_maps for why it is two variables and not a write
    # where the game set it.
    def write_if_changed(requested:, in_force:, write:)
      # A fresh var_ref each time: no node is ever shared between two places in the tree.
      Build.if_(Build.binop(:!=, Build.var_ref(requested), Build.var_ref(in_force)),
                *Array(write),
                Build.set(in_force, Build.var_ref(requested)))
    end

    # Copy a whole map into a background's cells, in the gap between frames, and only on a
    # frame where the answer changed.
    #
    # A cell of a map is one half-word, so `set_tile` can write it wherever the game
    # happens to be: nothing can read a half-word half-written, and the worst that happens
    # is one 8-pixel cell split across a single frame. A whole map is thousands of cells,
    # and there the same write really would show half of the old room and half of the new.
    # So the copy waits for the gap, which is the one moment the display is not reading.
    #
    # Why two variables rather than a copy where `show_map` was called. `show_map` sets
    # which map is showing — a statement about the world, the same shape as a scroll
    # position — so a game may call it every frame, from inside a branch, from a scene. What
    # the console must not do is copy thousands of cells every frame. Holding what the game
    # SET apart from what is really in the cells turns that into one comparison: they
    # differ exactly on the frame the answer changed, which is the frame to copy on.
    def finalize_background_maps
      write_between_frames(@inline_map_nodes, backgrounds_that(&:swaps_maps?)) do |name, background|
        # ...and the walls the game changes of it are the new map's, as declared, from then on.
        walls = every_kept_walls.select { |kept| kept.background == name }.map { |kept| Build.set(kept.fresh, Build.int(0)) }
        write_if_changed(requested: background.shown_map, in_force: background.live_map,
                         write: [Build.show_map(name, which: Build.var_ref(background.shown_map)), *walls])
      end
    end

    # Show the cells a held background's pass changed, all at once, at each frame boundary.
    #
    # One write for the whole program, however many backgrounds are held: the changes wait in
    # one queue, in the order they were made (see IR::Nodes::ShowHeldTiles). It goes in the gap
    # before a map handed over in the same pass, as an unheld change written during the pass
    # lands before that map's copy: a change made in the pass that walks into another room is
    # gone with the room either way. A program with no frame boundary has no moment to hold the
    # changes for, so its changes are written where the game makes them.
    def finalize_held_tiles
      changes = @held_tile_changes || []
      return if changes.empty?
      return changes.each { |node| node.held = nil } if @frame_boundaries.empty?

      write_between_frames([], { held: true }) { Build.show_held_tiles }
    end

    # Write a layer's colours into the display's table, in the gap between frames, and only
    # on a frame where the answer changed — the colour twin of the map copy above, and held
    # apart the same way and for the same reasons.
    #
    # The gap matters more here than the saving does. Every pixel on screen is drawn by
    # looking its colour up in one shared table, so a table written while the display is
    # reading shows the top of the screen in one set of colours and the bottom in another.
    def finalize_background_colors
      write_between_frames(@inline_color_nodes, backgrounds_that(&:draws_with_colors?)) do |name, background|
        write = write_if_changed(requested: background.shown_colors, in_force: background.live_colors,
                                 write: Build.background_colors(name, which: Build.var_ref(background.shown_colors)))
        # Gated to the owning scene, as a scroll is: a scene's backgrounds draw from colour
        # groups other scenes use while they are up, so a list asked for from elsewhere waits
        # until its scene is back, and goes in then.
        while_any_scene_up(background.scene_gates, write)
      end
    end

    # Move every affine background's matrix write to the frame boundary — the same
    # reason {#finalize_background_scrolls} moves scroll writes there: the console reads
    # a background's rotate/scale registers for the whole frame it draws, so writing them
    # mid-frame would show two different pictures on one screen. See that method for the
    # rest of the reasoning; this is its `rotate`/`scale` sibling.
    #
    # Each write is gated to its owning scene (see #defer_affine_write), the same as a
    # scene-owned sprite or HUD glyph — a background turned only inside one scene must stop
    # writing BG2's registers once that scene isn't the live one — and gated again on the
    # turn having actually moved, which is #affine_write_if_changed below.
    def finalize_background_affine
      # A pivot can be named after the turn that reads it (`.scale(2.0).turns_around(...)`),
      # and a program with no frame boundary keeps the writes where the author put them —
      # so the ones being kept are told now, when every line has been read.
      @inline_affine_nodes.each do |node|
        pivot = declared_background(node.name).pivot
        next unless pivot

        node.around_x, node.around_y = pivot
        node.map_x, node.map_y = declared_background(node.name).pivot_map_point || pivot
      end

      write_between_frames(@inline_affine_nodes, backgrounds_that(&:turns_each_frame?)) do |name, background|
        affine_write_if_changed(name, background)
      end
    end

    # Write the turn only on a frame where it changed — the same two-variables trick
    # {#finalize_background_maps} plays on a map, and here it buys something the map's
    # version does not.
    #
    # A picture that has stopped moving is told to hold still by being told nothing, and
    # the display holds it: the numbers that set how the layer is turned and where it is
    # pinned stay where they were put. So writing them again every frame is not only work
    # nobody asked for — a divide and two table lookups before the write itself — it is
    # a risk the still picture has no reason to run. The display reads where the layer is
    # pinned as it draws, so a write landing after the drawing has started moves the layer
    # for the rest of that picture: one frame showing the layer somewhere else, and then it
    # snaps back. Every game has frames that start late, and on those frames this write
    # lands there. A scroll written late is invisible, which is why the scroll registers
    # beside it have never needed this.
    #
    # Holding what the display was told apart from what the program has SINCE SET turns
    # all of that into two comparisons: they differ exactly on the frame the answer moved,
    # which is the frame worth writing on.
    def affine_write_if_changed(name, background)
      told_angle, told_size = declare_last_affine_vars(name)
      changed = Build.binop(:or,
                            Build.binop(:!=, Build.var_ref(background.angle), Build.var_ref(told_angle)),
                            Build.binop(:!=, Build.var_ref(background.scale), Build.var_ref(told_size)))
      write = Build.if_(changed,
                        Build.affine_background(name, angle: Build.var_ref(background.angle),
                                                      scale: Build.var_ref(background.scale),
                                                      around: background.pivot || @console.middle,
                                                      map_point: background.pivot_map_point),
                        Build.set(told_angle, Build.var_ref(background.angle)),
                        Build.set(told_size, Build.var_ref(background.scale)))

      # A background turned inside one scene writes nothing at all while another scene is up:
      # the display has one turning layer and they share it, so a title screen's zoom must
      # not go on distorting the game that took over from it.
      while_any_scene_up(background.scene_gates, write)
    end

    # The angle and the size the display was last told. They are declared here rather than
    # beside the angle and the size themselves because this is the only thing that reads
    # them: a program with no gap between frames writes where the author asked for it and
    # pays for none of this.
    #
    # Both start at nought, which is what makes the first frame write whatever else is
    # true — no background is a size of nought, the smallest one anybody can ask for being
    # more than nothing. So the pair starts out disagreeing, and the frame that finds them
    # disagreeing is the frame that puts the picture on screen.
    def declare_last_affine_vars(name)
      vars = %i[angle size].map { |part| Messages::MadeNames.make(:told_turn, background: name, part: part) }
      vars.each do |var|
        at_boot(Build.set(var, Build.int(0)))
        ensure_var(var)
      end
      vars
    end

    # Tell the display again how see-through the see-through layer is, once per frame.
    #
    # Only a picture whose amount the game works out needs this — fog that thickens,
    # water that gets murkier as you go down. A number the author wrote is written once
    # at boot and never again, and this puts nothing anywhere.
    #
    # It goes at the frame boundary for the reason the scroll writes do: that gap is the
    # one moment the display is not reading, so the whole picture is drawn at one amount
    # rather than half at each. And it goes first, before the sprites are put where they
    # go, so the frame that is about to be drawn is drawn at the amount this frame has.
    def finalize_layer_blend
      return if @frame_boundaries.empty? || @layers_node.nil?

      # With a see-through layer on more than one screen, which of them the display is
      # mixing changes as the screens take turns, so every one is told again at every
      # boundary and each backend tells only the one on screen.
      layers = @layers_node.see_through
      told = layers.size > 1 ? layers : layers.reject { |layer| fixed_blend_amounts?(layer) }
      return if told.empty?

      @frame_boundaries.each do |wait_node|
        container = wait_node.parent
        at = container&.children&.index(wait_node)
        next unless at

        told.each_with_index do |layer, i|
          added = !layer.split && layer.shows.kind == :int && layer.shows.value == 100
          node = Build.see_through(layer.name, added: added || nil)
          container.children.insert(at + 1 + i, node)
          node.parent = container
        end
      end
    end

    # A layer whose amounts are both numbers the author wrote is told once, at boot.
    def fixed_blend_amounts?(layer)
      [layer.shows, layer.behind].all? { |amount| DSL::Value.fixed_number(amount) }
    end

    # Run every per-frame routine at each frame boundary — once per frame that really
    # passed, which on a program keeping up is once, and on one that overran its frame
    # is twice or three times.
    #
    # That repeat is the whole of the promise. A pass of the game loop is not a frame;
    # it is a frame on a program that fits and two frames on one that does not. So a
    # body called once per pass and described as running every frame quietly runs at
    # half speed on a heavy game, and a fade told to take half a second takes a second
    # and a half. Counting the frames instead is what makes the word mean what it says.
    #
    # One loop around all of them rather than one each, so a late pass replays the frame
    # in order — every routine once, then every routine again — rather than running each
    # routine twice before starting the next.
    #
    # They go at the boundary for the same reason the scroll writes do: that is the
    # gap between frames, the one moment the display is not reading, so whatever they
    # change takes effect on the whole picture rather than half of it. And they go in
    # here rather than where `once_a_frame` was called because such a routine is
    # normally set off by an event — a brick breaking, a life lost — while what it
    # produces has to be applied on every frame after that, including the frames the
    # triggering code does not run on.
    #
    # A program with no frame boundary (no game loop) never calls them at all. That
    # is a real footgun, so a verb built on this wants a guardrail for it — see
    # Effects::Packs::ScreenShake::NeedsGameLoop.
    def finalize_per_frame_routines
      return if @per_frame_routines.empty? || @frame_boundaries.empty?

      ensure_var(IR::Frames::STEP)
      @frame_boundaries.each_with_index do |wait_node, boundary|
        container = wait_node.parent
        at = container&.children&.index(wait_node)
        next unless at

        index = :"__once_a_frame_#{boundary}"
        ensure_var(index)
        calls = @per_frame_routines.map { |name| Build.call(name) }
        node = Build.repeat(Build.var_ref(IR::Frames::STEP), index, *calls)
        container.children.insert(at + 1, node)
        node.parent = container
      end
    end

    # Routines called once a pass, straight after each frame boundary: work the framework spreads
    # over a game's passes, such as writing a save a piece at a time. Once a pass and not once a
    # frame like the ones above, because what they leave for the game to read — a save that has
    # just finished — has to hold for one whole pass of the game's own code, and a late pass
    # that replayed them would clear it again before the game got to look.
    def finalize_per_pass_routines
      return if @per_pass_routines.empty?

      @frame_boundaries.each do |wait_node|
        container = wait_node.parent
        at = container&.children&.index(wait_node)
        next unless at

        @per_pass_routines.reverse_each do |name|
          node = Build.call(name)
          container.children.insert(at + 1, node)
          node.parent = container
        end
      end
    end

    # Give every "call the routine this variable names" its list of routines: the names that
    # variable can hold, in the order they were numbered.
    #
    # It has to be now rather than where the call was written, and the reason is ordinary
    # program order: a name is one of the set from the first time anything uses it, and a
    # routine's body is built at finalize — so a state set only inside another routine was not
    # known yet. By here every body has been built and the set cannot grow again.
    def finalize_name_dispatches
      @name_dispatches.each { |node, held| node.targets = held.names }
    end

    # A name that picks a scene. `call mode` runs the routine its variable names, and when
    # those names are scenes it is exactly a scene dispatch (a case node) over them — so it is made one, here,
    # before any scene's body is built. Everything that asks which scene a thing belongs to
    # reads case dispatches (a scene's text, sprites and scenery are shown only while it
    # runs; the display is told its layers as it takes over), and it all then works for
    # scenes picked by name with nothing else knowing the difference.
    #
    # Every scene the game declares is given a number now. A name normally gets one the first
    # time it is used, and a scene first named deep inside another scene's body — the walk
    # a menu hands over to — would get one only as that body is built, after this dispatch
    # was fixed. Numbering them all first costs nothing: a number the variable never holds
    # simply never runs its scene.
    def convert_scene_name_dispatches
      scenes = @functions.keys.filter_map { |name| name.to_s.delete_prefix("_scene_").to_sym if name.to_s.start_with?("_scene_") }
      @name_dispatches.reject! do |node, held|
        next false unless node.which.kind == :var_ref && held.names.intersect?(scenes)

        refuse_scene_routine_name_clash!(held.names)
        scenes.each { |scene| held.number_for(scene) }
        @scene_name_sets << held
        clauses = held.names.each_with_index.map { |name, number| [number, :"_scene_#{name}"] }
        swap_node(node, Build.case_(node.which.name, clauses))
        true
      end
    end

    def refuse_scene_routine_name_clash!(names)
      both = names.find { |name| @functions.key?(name) && @functions.key?(:"_scene_#{name}") }
      return unless both

      raise ArgumentError, "`call` was given a variable that holds :#{both}, and :#{both} is both a scene " \
                           "and a func, so it cannot tell which to run. To fix this, rename one of them."
    end

    # A variable that picks a scene is the game's screen: each of its names is a scene, shown
    # while the variable holds it. A func among them would be a screen that is not a scene —
    # looked for as a scene and not found, or, when the name first turned up inside a routine's
    # body after the dispatch was made, a value that silently runs nothing. So it is refused,
    # and only once every body is built, since that is when the set of names stops growing.
    #
    # A dispatch whose names held no scene when scenes were picked out is still a plain one, and
    # a scene set inside a routine later joins it there: that is the same mix the other way
    # round, looked for as a func and not found, so it is refused in the same words.
    def refuse_non_scenes_in_scene_dispatch!
      scene = ->(name) { @functions.key?(:"_scene_#{name}") }
      later = @name_dispatches.filter_map { |node, held| held if node.which.kind == :var_ref && held.names.any?(scene) }
      (@scene_name_sets + later).each do |held|
        others = held.names.reject(&scene)
        next if others.empty?

        funcs, missing = others.partition { |name| @functions.key?(name) }
        raise ArgumentError, non_scenes_in_scene_dispatch_message(funcs, missing)
      end
    end

    def non_scenes_in_scene_dispatch_message(funcs, missing)
      listed = ->(list) { list.map { |name| ":#{name}" }.join(", ") }
      found = ["`call` was given a variable that picks a scene."]
      found << "It also holds funcs (#{listed.(funcs)})." unless funcs.empty?
      unless missing.empty?
        found << (missing.one? ? "It also holds #{listed.(missing)}, which is not a scene or a func." :
                                 "It also holds #{listed.(missing)}, which are not scenes or funcs.")
      end
      fixes = []
      fixes << "make each func a scene, or keep the funcs in a variable of their own" unless funcs.empty?
      fixes << "declare each missing name with `scene`, or correct the name where the variable is set" unless missing.empty?
      "#{found.join(' ')} A variable that picks a scene can hold only scenes. To fix this, #{fixes.join('; and ')}."
    end

    # Put +replacement+ where +node+ sits in the tree.
    def swap_node(node, replacement)
      siblings = node.parent.children
      siblings[siblings.index { |child| child.equal?(node) }] = replacement
      replacement.parent = node.parent
    end

    # Note a variable on first mention, for the checks that ask which variables a game has
    # (and #variables). Where it is kept is each lowering's business, since each console has
    # memory of its own. Only a Symbol names a variable, so any other operand — a literal, an
    # expression — is ignored: callers can pass a value operand straight through without
    # guarding, and a non-name never notes a phantom entry. (Operand types are already
    # validated upstream at the Value.node_for coercion boundary, so ensure_var needn't gate
    # them.)
    def ensure_var(name)
      @variables << name if name.is_a?(Symbol)
    end

    # --- Importing art from image files ---

    # This gem's own source directory. Frames of the call stack under here are
    # framework internals; the first frame outside it is the user's script — which
    # is where a relative image path should be resolved from (see #resolve_asset_path).
    SOURCE_ROOT = __dir__.freeze

    # Turn an image path the user wrote into a real file path. An absolute path is
    # taken as-is. A relative one is resolved *next to the script that named it* —
    # the natural expectation ("hero.png is beside my game") — falling back to the
    # working directory, and finally a plain-language error that names where it
    # looked. (Resolving against the current directory alone is a classic footgun:
    # it works when you run from the project root and mysteriously fails otherwise.)
    def resolve_asset_path(path)
      return path if File.absolute_path?(path) || path.start_with?("/") # "/x" is rooted on Windows too

      dir = caller_script_dir
      if dir
        beside_script = File.expand_path(path, dir)
        return beside_script if File.exist?(beside_script)
      end
      return path if File.exist?(path) # a working-directory-relative path that happens to resolve

      looked = [dir && File.expand_path(path, dir), File.expand_path(path)].compact.uniq
      raise ArgumentError,
            "Cannot find the image #{path.inspect}. Looked at #{looked.map(&:inspect).join(' and ')}. " \
            "Put the image next to your script, or pass a full path."
    end

    # The directory of the nearest caller that isn't framework code — i.e. the user's
    # script — so an asset path can be resolved relative to it. nil if the whole
    # stack is internal (nothing sensible to resolve against).
    def caller_script_dir
      path, = author_frame
      path && File.dirname(path)
    end

    # The file and line of the nearest caller that isn't framework code, or nil. A normal Ruby
    # block is run through `eval` (see DSL::PlainRuby), and such a frame has no absolute path,
    # only the file name it was given.
    def author_frame
      caller_locations.each do |loc|
        path = loc.absolute_path || author_eval_path(loc)
        return [path, loc.lineno] if path && !path.start_with?(SOURCE_ROOT)
      end
      nil
    end

    def author_eval_path(loc) = File.exist?(loc.path) ? File.expand_path(loc.path) : nil

    # A sheet cell's pixel size: one number means a square cell, [w, h] a rectangle.
    def sheet_tile_size(name, tile)
      case tile
      when Integer then [tile, tile]
      when Array then tile
      when nil
        raise ArgumentError, "To import #{name} from an image, give tile:. tile: is the size of each cell in pixels."
      else
        raise ArgumentError, "tile: must be a number (square) or [width, height]. You gave #{Messages::PlainWords.words_for_given(tile)}."
      end
    end

    # Where a cell sits in a sheet grid: [column, row], or a single number counting
    # cells left-to-right then top-to-bottom. +label+ names it in any error.
    def sheet_cell_at(label, where, cols)
      case where
      when Array then where
      when Integer then [where % cols, where / cols]
      else raise ArgumentError, "#{label} must be a cell number or [column, row]. You gave #{Messages::PlainWords.words_for_given(where)}."
      end
    end

    # A table given a slot of the data pack takes the slot's width and sign. A width or sign the
    # line gives as well must be the slot's, since two answers to one question are a mistake.
    def refuse_table_unlike_slot!(name, handle, width, signed)
      layout = handle.layout
      return if (width.nil? || width == layout.width) && (signed.nil? || signed == layout.signed)

      raise ArgumentError, "table #{name.inspect} reads slot :#{layout.name}. The slot holds #{layout.width.inspect} " \
                           "numbers with signed: #{layout.signed}. The table line gives width: #{width.inspect} and " \
                           "signed: #{signed.inspect}. If a table reads a slot, the slot sets the width and the sign. " \
                           "Remove width: and signed: from the table line."
    end

    # A table's values must be a non-empty array of whole numbers.
    def validate_table_values!(name, values)
      unless values.is_a?(Array) && !values.empty?
        raise ArgumentError, "table #{name.inspect} needs a non-empty array of numbers."
      end
      unless values.all?(Numeric)
        raise ArgumentError,
              "table #{name.inspect} can hold numbers only. You gave #{values.find { |v| !v.is_a?(Numeric) }.inspect}."
      end
      values
    end

    # How many fraction bits a table's values carry: a table with a Float anywhere in
    # it holds numbers with a fraction, and every read from it hands back a value that
    # carries it. This is what lets a sine table be written as plain trigonometry — the
    # scaling that used to be spelled out in the table's own definition is done here.
    def table_fraction_bits(values)
      DSL::Fraction::DEFAULT_BITS if values.any?(Float)
    end

    # Every value must fit the element width. A value that does not fit would be
    # cut down silently on the console, so stop the build and name the fix.
    def check_table_values_fit!(name, values, width, signed)
      bytes = Build::ELEMENT_BYTES.fetch(width) do
        raise ArgumentError, "table #{name.inspect} width must be :byte, :half, or :word. You gave #{width.inspect}."
      end
      bits = bytes * 8
      low, high = signed ? [-(1 << (bits - 1)), (1 << (bits - 1)) - 1] : [0, (1 << bits) - 1]
      bad = values.find { |value| value < low || value > high }
      return unless bad

      kind = signed ? "signed" : "unsigned"
      raise ArgumentError,
            "table #{name.inspect} has the value #{bad}. It does not fit a #{kind} :#{width} element " \
            "(range #{low} to #{high}). Use a wider width, or make the values smaller."
    end

    # --- IR tree construction ---

    # Note that the game wrote +verb+, for a verb that is written in other verbs and leaves no step
    # of its own (IR::Nodes::Program#verbs_written). Called by the verb itself, first thing.
    def note_verb_written(verb)
      @program.verbs_written = (@program.verbs_written || []) | [verb]
    end

    # Attach a freshly built IR node to the open container and return it — the route
    # every flat DSL verb takes, so it's also where an open `layer` block gets its say
    # about what was just written.
    def record(node)
      place_in_layer(node)
      attach(node)
    end

    # Put a node in the open container. Stamp it with the DSL call site that built it
    # (unless it already carries one), so a later guardrail finding can point the
    # author straight at the line.
    def attach(node)
      node.source ||= caller_source_location
      @container_stack.last.add_child(node)
      node
    end

    # The user's call site that led here — "hero.rb:42", the nearest caller that
    # isn't framework code — for diagnostics. nil if the whole stack is internal.
    def caller_source_location
      path, line = author_frame
      path && "#{File.basename(path)}:#{line}"
    end

    # Build a container node, attach it, and keep it open while the block runs so
    # nested statements land inside it — then close it. The block-taking control
    # methods (loops, conditionals, func bodies) use this.
    #
    # A block that raises can leave a test it opened a step at a time (#open_branch, the rewritten
    # `if`) open inside this one, so the stacks go back to how they were before this container.
    # A builder made by hand stays the thread's current game after the error (Builder::Session),
    # and with a container left open it would record whatever plain Ruby later runs on that thread
    # as game code.
    def push_container(node)
      record(node)
      depth = @container_stack.length
      shown_depth = @shown_while.length
      @container_stack.push(node)
      # A test the block is written under is also a test anything declared in the block is
      # only shown under (see #gated_by_open_conditions) — the same statement reads both ways, and a
      # thing the framework redraws for you every frame has no other way to hear about it.
      @shown_while.push(node.cond) if node.kind == :if
      begin
        yield
      rescue Exception # rubocop:disable Lint/RescueException -- put the stacks back for any error, then raise it again
        @container_stack.slice!(depth..)
        @shown_while.slice!(shown_depth..)
        raise
      ensure
        # The block's end, a `throw` or a `break` closes this container alone.
        unless @container_stack.length == depth
          @shown_while.pop if node.kind == :if
          @container_stack.pop
        end
      end
    end

    # Run a DSL block (a game loop body, a func body…) at the current build
    # point. It runs in the block's own context, not instance_eval'd onto the builder,
    # so its `self` stays wherever the block was written: this builder at the top level
    # (where these blocks live inside VBlank.build's instance_eval, so `self` already
    # is the builder), or a plain Ruby object when a game is split across files — there
    # the block still sees that object's @ivars, while its bare verbs resolve against the
    # build it was handed (see examples/shmup). +args+ pass through to a block that takes them (a loop
    # index). Sub-DSLs with their own vocabulary — `entry`, `font`, `song` —
    # keep instance_eval instead, since their blocks speak a different verb set.
    def run_block(*args)
      yield(*args)
    end

    # Low-level entry context for raw instruction emission.
    # Collects the raw ARM emitted inside an `entry` block into a byte string,
    # which becomes a raw IR node the backend appends verbatim.
    class EntryContext
      attr_reader :bytes

      def initialize
        @bytes = +"".b
      end

      def loop_forever
        @bytes << IR::Backends::GBA::ASM.loop_forever
      end

      def nop
        @bytes << IR::Backends::GBA::ASM.nop
      end
    end
  end
end
