# frozen_string_literal: true

module VBlank
  module DSL
    # Many of one thing
    #
    # A pool holds up to a fixed number of things of one kind, each with numbers of its own:
    # bullets, enemies, particles, coins. Builder#pool hands one back.
    #
    # ```ruby
    # bullets = pool :bullet, x: 0, y: 0, vy: 0, capacity: 64
    # bullets.spawn x: ship.x, y: ship.y, vy: -4
    # bullets.each { |b| b.y += b.vy; b.remove if b.y < 0 }
    # ```
    #
    # Pool#spawn adds a thing and Pool#each visits every live one, handing the block a
    # Pool::Instance whose fields read and change like variables. Spawning and removing cost
    # the same however full the pool is, and a thing keeps its place until it is removed.
    #
    # The things are kept in the order they were spawned, so Pool#each visits the oldest first
    # and the newest last. That order is what a player can see: things that each roll a random
    # number roll them one after another, and the first to reach something gets it. A pool that
    # draws its things draws them in that order too, the oldest in front.
    #--
    # Behind the scenes each field is a backing List, one slot per instance, alongside an
    # `active` column (which slots are live) and a `free` stack (open slot indices). So spawn
    # and remove are O(1), pop or push a free index; a live instance keeps its slot (stable
    # identity), and the fields can never desync because there's no way to touch one without
    # the others. It all desugars onto list ops and a `repeat`, so every backend runs it and the
    # cost model sees straight through it.
    #
    # Which slot a thing lands in shows nothing about when it came, so the slots are not the
    # order a walk goes in. Every slot also holds which slot came next and which came before it,
    # and the pool keeps the first and the last: a chain through the live things in the order
    # they were spawned, which is how a console game keeps the things in a room. A spawn joins
    # the end of it and a removal closes the gap, so `each` walks only what is in the chain
    # rather than every slot. See #stacked_list for the drawing order.
    #++
    class Pool
      Build = IR::Build # :nodoc:

      # The slot number that means "no slot": the end of the chain, and an empty pool's
      # first and last.
      NONE = -1 # :nodoc:

      # The pool's name, as the game gave it to Builder#pool.
      attr_reader :name
      # The most things that can be live at once, as the game gave it to Builder#pool.
      attr_reader :capacity

      # Built by Builder#pool, which allocates the backing lists and boot-fills them.
      #
      # @param builder [Builder] the build these operations record into
      # @param name [Symbol] the pool's name
      # @param fields [Hash{Symbol=>Object}] field name => default value
      # @param capacity [Integer] the live cap (the most instances at once)
      # @param image [Symbol, nil] the sprite image each live instance draws (nil = pure data)
      # @param hitbox [Array(Integer,Integer,Integer,Integer), nil] the collision box
      #   [x, y, w, h] relative to an instance's top-left, from the image (nil = no size)
      # @param on_full [Symbol] what spawn does when there's no free slot — :drop (ignore
      #   it, a safe no-op), :recycle_oldest (reuse the longest-lived instance) or :stop (stop the game)
      # @param art [Builder::Composition::PoolArt, nil] what the instances look like — the
      #   pictures they can show and how a slot picks one (nil for a pure-data pool)
      def initialize(builder, name, fields, capacity, image: nil, hitbox: nil, on_full: :drop, art: nil)
        @builder = builder
        @name = name
        @fields = fields
        @capacity = capacity
        @image = image
        @hitbox = hitbox
        @on_full = on_full
        @art = art
        @fast = nil
        # A field declared with a NAME — `state: :idle` — holds one of a set of them, exactly as
        # a variable declared with one does, and each instance keeps its own. The set belongs to
        # the field rather than to an instance: thirty guards can each be in a different state,
        # and there is one list of what those states are.
        @field_names = fields.filter_map do |field, default|
          next unless default.is_a?(Symbol)

          held = NameSet.new("the #{field.inspect} field of `pool :#{name}`")
          held.number_for(default) # the name it was declared with is the first of them
          [field, held]
        end.to_h
      end

      # The sprite image live instances draw (nil for a pure-data pool), and the collision
      # box derived from it (nil when there's no size).
      attr_reader :image, :hitbox, :art # :nodoc:

      # Which of the console's two work memories the pool's lists are kept in, the way a
      # list's `fast:` sets it: false for out of the quick one, true to insist on it, nil
      # for the build to decide. Settled by the build once it knows how big the pool is (see
      # Builder::Composition#pool), and read by the lists a pool only gains later.
      attr_accessor :fast # :nodoc:

      # The scene a pool that draws was declared in, as the variable the game picks its scenes
      # with and the value that picks this one; nil for a pool declared outside every scene.
      # Its things show only while that scene is up, so that is when they are put in order.
      attr_accessor :scene_gate # :nodoc:

      # Whether instances draw themselves as sprites.
      def spriteful? = !@art.nil? # :nodoc:

      # Whether a spawn onto a full pool reuses the oldest live instance (rather than
      # dropping the spawn). When true the pool keeps a little extra bookkeeping (below).
      def recycle_oldest? = @on_full == :recycle_oldest # :nodoc:

      # The name of one of the pool's sprite objects. There is one for each thing that can be
      # live at once, and +place+ counts them back to front.
      def object_name(place) = part_name("obj_#{place}") # :nodoc:

      # What each of the pool's sprites shows is worked out every frame, from the chain.
      #
      # A pool that draws has one sprite for each thing that can be live at once, and where
      # two sprites overlap the one declared later is in front. If each sprite always showed
      # the same slot, which of two things was in front would follow the slots they landed
      # in, and a slot shows nothing about when its thing came: a slot given back is the next
      # one handed out, so the newest thing would sometimes cover an older one and sometimes
      # not.
      #
      # So a sprite shows a place in the order rather than a slot. Before each frame is
      # drawn the chain is walked once, oldest first, and what each live thing looks like —
      # where it is, which picture, which colours — is copied into lists kept in that order.
      # The frontmost sprite then shows the first entry, the next one back the second, and a
      # sprite with no entry left to show is hidden. The oldest thing is in front of every
      # thing spawned after it, whatever slots they are in.
      #
      # The copy is one loop for the whole pool, and that is why it is a copy. Each sprite
      # could instead look up which slot stands at its place and read that slot's fields, but
      # a sprite's code is written out once per sprite, so every read through a second list
      # is paid in code for every slot the pool has, in the memory the frame's own code has
      # to fit — a pool's cost in code would grow with its capacity. Copied, each sprite
      # reads its own entry exactly as it used to read its own slot, and the pool pays one
      # loop however big it is, and a few bytes of memory a slot.
      #
      # +stacked_list+ names those lists and +stacked_var+ holds how many entries they hold.
      def stacked_list(part) = part_name("stacked#{part}") # :nodoc:
      def stacked_var = part_name(:stacked) # :nodoc:
      def stacking_cursor_var = part_name(:stacking_at) # :nodoc:
      def stacking_index_var = part_name(:stacking_pass) # :nodoc:

      # What a pool copies for each thing: where it is, then its picture when there is more
      # than one to choose from, then its colours when it was ever told to draw with others.
      def stacked_parts # :nodoc:
        parts = %i[x y]
        parts << :pose if posed?
        parts << :colors if recolorable?
        parts << :order_key if ordered? && !order_key_read_from_copy?
        parts
      end

      # Put this pool's things in an order the game works out (see Builder#draw_in_order).
      # +key+ is handed an instance and gives back the number that thing is ordered by, so
      # the number is worked out per thing as the copy above walks them and copied for its
      # place beside where it is — unless it can be read from the copy (#order_key_read_from_copy?).
      def order_by(key) # :nodoc:
        @order_key = key
      end

      # Whether this pool is in a draw order.
      def ordered? = !@order_key.nil? # :nodoc:

      # A key read from the copy. The copy above already holds where each thing is, by its rank,
      # so a key that reads nothing of a thing but its x and y — `bottom`, the default, is y and
      # the box — is the same number worked out from the copy, in the order's own routine, which
      # runs after the copy is made. The copy then neither works the key out nor keeps it, and
      # the routine reads it at a fixed place rather than through the pool's slot.
      #
      # Worked out in the copy, each key was read through the slot, written into a list of its
      # own through the count the copy keeps (an index tested each time), and copied on again by
      # the order's routine; read from the copy, it is one read at a fixed place and the sum.
      #
      # A key that reads anything else of the thing (another field, its slot) is worked out
      # during the copy as before, and so is one with anything in it but the thing's place,
      # numbers written in the program and sums of them: a variable could have changed for a
      # place the copy has not filled since, which would then sort by today's number rather
      # than the one it had. The one difference left is a place no thing has filled yet, which
      # reads the copy's noughts through the sum rather than a nought; nothing is drawn there.
      def order_key_read_from_copy? # :nodoc:
        return @order_key_read_from_copy unless @order_key_read_from_copy.nil?

        key = order_key_at_cursor
        @order_key_read_from_copy = key_reads_copy_only?(Value.node_for(key))
        key.discard! if key.is_a?(Value)
        @order_key_read_from_copy
      end

      # The number the sprite at +place+ is put in order by, as a value node: worked out from the
      # copy, or read from the list the copy keeps it in.
      def order_key_at_place(place) # :nodoc:
        rank = rank_at_place(place)
        order_key_read_from_copy? ? copied_order_key(rank) : stacked_at(:order_key, rank)
      end

      # The key of the thing with +rank+ older things before it, as a value node read from the
      # copy (see #order_key_read_from_copy?).
      private def copied_order_key(rank)
        node = Value.node_for(order_key_at_cursor)
        return copied_field_read(node, rank) if cursor_field_read?(node)

        node.walk.select { |each_node| cursor_field_read?(each_node) }.each do |read|
          read.parent.replace_operand(read, copied_field_read(read, rank))
        end
        node
      end

      # The kinds a key read from the copy may be made of besides the thing's place: numbers
      # written in the program and sums of them.
      COPY_KEY_KINDS = %i[int binop bit_not absolute].freeze # :nodoc:

      # The fields the copy holds for every pool that draws.
      COPIED_FIELDS = %i[x y].freeze # :nodoc:

      # The key the game's block gives for the thing in the slot the copy is on.
      private def order_key_at_cursor = key_at_cursor(@order_key)

      # What +key+, given rather than the pool's own, gives for the thing in the slot the copy is on.
      private def key_at_cursor(key)
        key.call(Instance.new(self, Value.handed_to_block(@builder, Build.var_ref(stacking_cursor_var))))
      end

      # How many fraction bits +key+ gives a thing of this pool, or nil for a whole number. The
      # number is worked out and dropped. Public for Builder::DrawOrder#order_key_bits, which asks
      # before the pool is ordered, so an order whose numbers are of two kinds is refused.
      def order_key_fraction_bits(key) # :nodoc:
        answer = key_at_cursor(key)
        answer.discard! if answer.is_a?(Value)
        Fraction.bits_of(answer)
      end

      # Whether +node+ reads the slot the copy is on only to read a copied field there.
      private def key_reads_copy_only?(node)
        node.walk.all? do |each_node|
          case each_node.kind
          when :list_get then cursor_field_read?(each_node)
          when :var_ref then cursor_field_read?(each_node.parent) && each_node.parent.index.equal?(each_node)
          else COPY_KEY_KINDS.include?(each_node.kind)
          end
        end
      end

      private def cursor_field_read?(node)
        node.is_a?(IR::Node) && node.kind == :list_get && node.index.kind == :var_ref &&
          node.index.name == stacking_cursor_var && COPIED_FIELDS.any? { |field| node.name == field_list(field) }
      end

      private def copied_field_read(read, rank)
        stacked_at(COPIED_FIELDS.find { |field| read.name == field_list(field) }, rank)
      end

      # Whether a thing's picture is something to read at all: a pool given one picture
      # always shows it.
      def posed? = @art.faces? || @art.animates? # :nodoc:

      # The routine that makes the copy (see #stacking_nodes), called before each frame is
      # drawn.
      def stacking_routine = Messages::MadeNames.make(:pool_stacking, pool: @name) # :nodoc:

      # How many things are older than the one the sprite at +place+ shows. The sprites are
      # declared back to front, so the last of them shows the oldest thing.
      def rank_at_place(place) = @capacity - 1 - place # :nodoc:

      # One part of the thing with +rank+ older things before it, as a value node.
      def stacked_at(part, rank) = Build.list_get(stacked_list(part), Build.int(rank)) # :nodoc:

      # Whether any live thing has +rank+ older things before it, as a value node. The GBA
      # lowering reads this shape — the count held, greater than the rank — to hide the places
      # past the count a store each (Backends::GBA::SpriteDrawing#live_count_var): change it,
      # and change that.
      def rank_taken(rank) = Build.binop(:>, Build.var_ref(stacked_var), Build.int(rank)) # :nodoc:

      # The statements that make the copy: walk the chain from its first thing and copy each
      # live one into the next entry. A dead thing can still be in the chain — one removed
      # during a walk that a save was made in the middle of — and is passed over.
      def stacking_nodes # :nodoc:
        at = -> { Build.var_ref(stacking_cursor_var) }
        copies = stacked_parts.map do |part|
          Build.list_set(stacked_list(part), Build.var_ref(stacked_var), part_of_slot(part, at))
        end
        live = Build.binop(:==, Build.list_get(active_list, at.call), Build.int(1))
        [Build.set(stacked_var, Build.int(0)),
         Build.set(stacking_cursor_var, Build.var_ref(head_var)),
         Build.repeat(Build.int(@capacity), stacking_index_var,
                      Build.if_(live, *copies, Build.add(stacked_var, Build.int(1))),
                      Build.set(stacking_cursor_var, Build.list_get(next_list, at.call)),
                      stop_when: Build.binop(:==, at.call, Build.int(NONE)))]
      end

      # One part of the thing in the slot +at+ gives, read from the pool's own lists. +at+ is
      # called for a fresh node at each use, since a node belongs to one statement.
      def part_of_slot(part, at) # :nodoc:
        case part
        when :pose then pose_of_slot(at)
        when :colors then Build.list_get(colors_list, at.call)
        when :order_key
          # The thing is handed over, and a key the same for every thing of the pool never reads it.
          Value.node_for(@order_key.call(Instance.new(self, Value.handed_to_block(@builder, at.call))))
        else Build.list_get(field_list(part), at.call)
        end
      end

      # --- backing-storage names ---------------------------------------------------
      #
      # Framework-internal: `Builder#pool` (builder/composition.rb) calls these to wire
      # the pool's storage up. They are not part of the pool authoring interface — a
      # game reaches an instance's data through `each`/`spawn`/`field_ref`, never these.
      #
      # A field's list and the pool's own are spelled apart (see Messages::MadeNames), so a
      # field can be called what the pool calls one of its own — `frame`, `active`, `count` —
      # and still be a list of its own. +part_name+ is every name of the pool's own: a list,
      # a variable or a routine.

      def field_list(field) = Pool.field_list(@name, field) # :nodoc:
      def part_name(part) = Pool.part_name(@name, part) # :nodoc:
      def self.field_list(name, field) = Messages::MadeNames.make(:pool_field, pool: name, field: field) # :nodoc:
      def self.part_name(name, part) = Messages::MadeNames.make(:pool_part, pool: name, part: part) # :nodoc:

      def current_var = part_name(:current) # :nodoc:
      def active_list = Pool.active_list(@name) # :nodoc:
      def free_list = Pool.free_list(@name) # :nodoc:
      def count_var = Pool.count_var(@name) # :nodoc:

      # The three that hold how many instances are live, by the pool's name alone: which slots
      # are (a byte each, 1 for live), the stack of slots that are free, and the count. They are
      # what a finished cartridge is written to hold a pool full (see
      # Diagnostics::FullCollections), so they are spelled here once for both.
      def self.active_list(name) = part_name(name, :active) # :nodoc:
      def self.free_list(name) = part_name(name, :free) # :nodoc:
      def self.count_var(name) = part_name(name, :count) # :nodoc:

      # The pool whose live-slot column +list+ is, or nil when it is not one.
      def self.named_by_active_list(list) # :nodoc:
        kind, parts = Messages::MadeNames.read(list)
        parts[:pool].to_sym if kind == :pool_part && parts[:part] == "active"
      end

      def slot_var = part_name(:slot) # :nodoc:

      # The chain the walk follows: for each slot, the slot spawned after it and the one
      # spawned before it, and the first and last of the chain.
      # Spelled here by the pool's name alone too, for the same reason as the three above.
      def next_list = Pool.next_list(@name) # :nodoc:
      def prev_list = Pool.prev_list(@name) # :nodoc:
      def head_var = Pool.head_var(@name) # :nodoc:
      def tail_var = Pool.tail_var(@name) # :nodoc:
      def self.next_list(name) = part_name(name, :next) # :nodoc:
      def self.prev_list(name) = part_name(name, :prev) # :nodoc:
      def self.retired_list(name) = part_name(name, :retired) # :nodoc:
      def self.head_var(name) = part_name(name, :head) # :nodoc:
      def self.tail_var(name) = part_name(name, :tail) # :nodoc:

      # A thing removed while the pool is being walked stays in the chain until the walk is
      # over, and its slot is not free until then either. A walk is following the chain, and
      # if a removal closed the gap at once — or a spawn reused the slot — the walk could step
      # off the end early or onto a thing spawned during the walk. So a removal during a walk
      # only marks the thing dead and puts its slot here, and the outermost walk, as it ends,
      # takes each one out of the chain and frees its slot. +walking_var+ counts the walks of
      # this pool in progress, since one can run inside another.
      def retired_list = Pool.retired_list(@name) # :nodoc:
      def walking_var = part_name(:walking) # :nodoc:
      def unlink_var = part_name(:unlink) # :nodoc:
      def unlink_before_var = part_name(:before) # :nodoc:
      def unlink_after_var = part_name(:after) # :nodoc:
      def release_index_var = part_name(:release) # :nodoc:

      # The variables the chain's routines work in, for the build to set aside.
      def chain_scratch_vars = [slot_var, unlink_var, unlink_before_var, unlink_after_var, release_index_var] # :nodoc:

      # What a variable of the pool holds at power-on: an empty chain has no first or last.
      def power_on_value(var) = [head_var, tail_var].include?(var) ? NONE : 0 # :nodoc:

      # Pose bookkeeping (allocated only for a pool whose instances face or animate): which
      # way each instance faces, where each is in its cycle, and the one counter that
      # decides when the whole pool steps.
      def facing_list = part_name(:facing) # :nodoc:
      def frame_list = part_name(:frame) # :nodoc:
      def tick_var = part_name(:tick) # :nodoc:

      # Which of those two this pool actually keeps — so the boot fill gives every slot one
      # of each, the same way it does for a field.
      def pose_lists # :nodoc:
        lists = []
        lists << facing_list if @art&.faces?
        lists << frame_list if @art&.animates?
        lists
      end

      # Which picture the thing with +rank+ older things before it shows, as a value node. A
      # pool given one picture always shows it; any other reads the picture copied for that
      # place in the order.
      def pose_node(rank) = posed? ? stacked_at(:pose, rank) : Build.int(0) # :nodoc:

      # Which picture the thing in one slot shows, as a value node. A pool that faces reads
      # the slot's direction; one that animates reads its frame; one that does both composes
      # them — direction * frames-per-direction + frame, which is the order the pictures were
      # flattened in. +at+ gives the slot, called for a fresh node at each use.
      def pose_of_slot(at) # :nodoc:
        facing = Build.list_get(facing_list, at.call) if @art.faces?
        frame = Build.list_get(frame_list, at.call) if @art.animates?
        return frame || facing unless facing && frame

        Build.binop(:+, Build.binop(:*, facing, Build.int(@art.per_dir)), frame)
      end

      # Stops every thing of this pool from moving through a background's solid tiles.
      #
      # It is the same verb a sprite takes (HardwareSprite#blocked_by), written once for the whole
      # pool. After this, Pool::Instance#move stops at the walls, and Pool::Instance#can_move?
      # answers whether a step is clear.
      #
      # ```ruby
      # guards.blocked_by maze
      # guards.each { |g| g.move :left, by: 1 }
      # ```
      #--
      # It belongs to the pool rather than to an instance because an instance handle lives only
      # for the `each` iteration that yielded it, where the background is the same one every time
      # round. A game with many movers is exactly the case that wants tile collision.
      #++
      def blocked_by(background)
        @solid_cells = background.solid_lookup
        self
      end

      # The background's grid of solid cells, or nil if this pool was never blocked by one.
      attr_reader :solid_cells # :nodoc:

      # Puts every thing of this pool in another of the declared layers, from now until it is
      # told otherwise.
      #
      # It is the verb a sprite has (HardwareSprite#put_in_layer), written once for all of them.
      # A room whose things walk under its arches and a room whose things stand in front of its
      # furniture can then share one pool, moved as each room takes over.
      #
      # ```ruby
      # guards.put_in_layer :walking
      # guards.put_in_layer [:upper, :walking], showing: floor
      # ```
      #
      # A number outside the list leaves them in the layer the pool was declared in. The change
      # shows on the frame their positions and pictures next do. Every thing reads one variable,
      # so moving them costs what moving one sprite does, however many there are.
      #
      # * `showing:` - with a list of layers, the number that picks one of them.
      def put_in_layer(which, showing: nil)
        unless spriteful?
          raise ArgumentError,
                "pool :#{@name} was told to put_in_layer, but its instances draw nothing. " \
                "Give the pool pictures with image:, facing: or frames:."
        end

        @builder.put_objects_in_layer(stacked_objects, :"__pool_#{@name}_layer", which, showing: showing,
                                                                                       subject: "The pool :#{@name}")
        self
      end

      # The builder this pool was declared on — an instance reaches it to place the shared
      # tile-collision routine's call.
      attr_reader :builder # :nodoc:

      # Which row of the pictures a direction name means, for Instance#face.
      def facing_row(direction) = @art&.dirs&.[](direction) # :nodoc:
      def facing_names = @art&.dirs&.keys || [] # :nodoc:

      # Point one instance at a direction (its row among the pictures): a number, or a value node
      # the game works out.
      def set_facing(index, row) # :nodoc:
        record(Build.list_set(facing_list, index.node, row.is_a?(Integer) ? Build.int(row) : row))
        self
      end

      # Which other list of colours each instance is drawn with (see Instance#draw_with), kept
      # only by a pool that was ever told to draw with one.
      def colors_list = part_name(:colors) # :nodoc:

      # The sprites the pool's things are drawn as, back to front, for a pool whose instances
      # draw (see #stacked_list for which thing each one shows).
      def stacked_objects = @stacked_objects ||= [] # :nodoc:

      # Draw the instance at slot +index+ with other colours — the same verb a sprite has, and
      # the same rules (see HardwareSprite#draw_with). Each instance keeps its own choice, except
      # for the list a pose's frame picks as the game starts, which the whole pool follows.
      def draw_with(index, which, showing) # :nodoc:
        # A list a pose's frame picks as the game starts (Builder#list_chosen_at_start?) is
        # followed, as a sprite told it is (Pool#follow_lists_chosen_at_start).
        which = { which => which } if which.is_a?(Symbol) && @builder.list_chosen_at_start?(which)
        if which.is_a?(Hash) && !@builder.one_list_for_pose_lists?(which) && which.keys.any? { |own| @builder.list_chosen_at_start?(own) }
          return follow_lists_chosen_at_start(which, showing)
        end

        refuse_following_and_drawing_with! if @following
        @recolors ||= begin
          unless spriteful?
            raise ArgumentError,
                  "#{author_words(opening: true)} was told to draw_with other colors, but its things draw " \
                  "nothing. #{pictures_fix}"
          end
          @builder.make_pool_recolorable(self)
          recolors = Recolors.new(@builder, subject: "pool :#{@name}", poses: @art.poses)
          stacked_objects.each { |node| recolors.attach_object(node) }
          recolors
        end
        choice = FieldRef.new(builder: @builder, list: colors_list, index: index.node, pool: @name, field: :colors)
        @recolors.draw_with(choice, which, showing)
        self
      end

      # A pool told to draw with the list a pose's frame picks, in a build that reads its pack as
      # the game starts: which list that is is in the player's file, so the build cannot write it
      # into the instance's choice as the build that holds the pack does. Each sprite the pool's
      # things are drawn as follows the lists instead (Builder::PackPoses
      # #follow_lists_chosen_at_start), as one sprite told the same does, and a pose shows what the
      # list its frame picks holds now.
      #
      # Those sprites show each instance in turn, so they follow for every instance, from the
      # start. Where the game tells every instance, that is what the build that holds the pack
      # shows. An instance never told, or not told yet, shows what the list holds as well, where
      # that build shows the colours the list was declared with: the two differ once the list is
      # recoloured. A pool also told another list is refused (#refuse_following_and_drawing_with!).
      private def follow_lists_chosen_at_start(lists, showing)
        unless spriteful?
          raise ArgumentError, "#{author_words(opening: true)} was told to draw_with other colors, but its things " \
                               "draw nothing. #{pictures_fix}"
        end
        refuse_following_and_drawing_with! if @recolors
        stacked_objects.each do |node|
          @builder.follow_pose_lists(node, lists, poses: @art.poses, showing: showing, subject: "pool :#{@name}")
        end
        @following = true
        self
      end

      private def refuse_following_and_drawing_with!
        raise ArgumentError,
              "pool :#{@name} was told to draw_with the list that a frame picks, and to draw_with another list. " \
              "This build reads its pack as the game starts. So the pool follows the lists of its frames for all " \
              "its instances. It cannot also draw with another list. To fix this, change the colors of the list " \
              "with `recolor`. Or build the game all-in-one."
      end

      # A pool never told to draw with other colours takes back the writes every spawn made
      # just in case, so it emits nothing for colours at all. Called once the whole program is
      # built, when that is known.
      def drop_unused_color_resets # :nodoc:
        return if @recolors

        color_resets.each { |node| node.parent&.children&.delete(node) }
      end

      # Whether any instance was ever told to draw with other colours, so the pool keeps a
      # colours column (see #colors_list).
      def recolorable? = !@recolors.nil? # :nodoc:

      # One field of every thing in a pool
      #
      # What Pool#field hands back: one field of the pool, every thing's, for a SaveData record
      # to keep on its own.
      #
      # ```ruby
      # files.keep guards.field(:hp)
      # ```
      Column = Data.define(:pool, :field) do
        def inspect = "field :#{field} of pool :#{pool.name}" # :nodoc:
      end

      # One field of every thing in the pool, as a Pool::Column for a SaveData record to keep.
      #
      # `keep guards.field(:hp)` keeps how hurt each guard is and nothing else about it. A field
      # the pool does not have is a friendly error.
      #
      # ```ruby
      # files.keep guards.field(:hp)
      # ```
      def field(name)
        return Column.new(pool: self, field: name) if field?(name)

        raise ArgumentError, "pool :#{@name} has no field :#{name}. It has " \
                             "#{field_names.map { |one| ":#{one}" }.join(', ')}. To fix this, use one of those."
      end

      # Everything that makes this pool what it is, for a save_data record to keep the whole of
      # it: the lists — every field, which slots are live, the free slots, and each slot's
      # facing, place in its cycle and colours where the pool keeps them, and the chain that
      # holds what order they came in, with the removals a walk has not yet taken out of it —
      # and then the variables — how many are live, the first and last of the chain, and the
      # step counter of one that animates. Asked once the program is built, since a pool keeps
      # its colours column only once something has told it to draw with others. What slot a
      # walk is on is not here: a save keeps what the pool holds, not where a walk stands.
      def saved_lists_and_vars # :nodoc:
        lists = [*field_names.map { |one| field_list(one) }, active_list, free_list, *pose_lists,
                 next_list, prev_list, retired_list]
        lists << colors_list if recolorable?
        vars = [count_var, head_var, tail_var]
        vars << tick_var if @art&.animates?
        [lists, vars]
      end

      def inspect = "pool :#{@name}" # :nodoc:

      # The field names, in declaration order.
      def field_names = @fields.keys # :nodoc:

      # Whether +name+ is one of this pool's fields (used by an instance handle).
      def field?(name) = @fields.key?(name) # :nodoc:

      # Adds a live thing to the pool, setting the fields named.
      #
      # A field left out starts at the value it was declared with. All the fields are set
      # together, so a thing is never half made.
      #
      # ```ruby
      # bullets.spawn x: ship.x, y: ship.y, vy: -4
      # ```
      #
      # What happens when the pool is full depends on the `on_full:` given to Builder#pool. The
      # default, `:drop`, adds nothing and changes nothing; ask Pool#full? or Pool#count to know.
      # With `:recycle_oldest`, the oldest thing is taken for the new one, so a new one always
      # appears. With `:stop`, the game stops, naming the pool.
      def spawn(**values) = spawn_with(values, during_walk: true)

      # Pool#spawn, where +during_walk+ false means the build knows no walk of this pool can be
      # under way where it runs, so a :stop pool builds no taking of a slot a walk removed
      # (#spawn_dropping). What StructArray#<< calls.
      def spawn_with(values, during_walk:) # :nodoc:
        unknown = values.keys - @fields.keys
        unless unknown.empty?
          raise ArgumentError,
                "pool :#{@name} has no field #{unknown.first.inspect} — its fields are #{@fields.keys.join(', ')}"
        end

        record(release_when_idle)
        recycle_oldest? ? spawn_recycling(values) : spawn_dropping(values, during_walk: during_walk)
        self
      end

      # Runs the block once for each live thing, oldest first.
      #
      # The block is handed a Pool::Instance whose fields read and change like variables
      # (`b.x += 1`, `b.y = 0`) and which can remove itself (`b.remove`).
      #
      # ```ruby
      # bullets.each do |b|
      #   b.y += b.vy
      #   b.remove if b.y < 0
      # end
      # ```
      #
      # The walk stops after the thing that was newest when it began, so a thing spawned during
      # the walk is first visited by the next one. A thing removed during the walk is not visited
      # after that.
      #
      # * `newest_first:` - true to walk from the newest thing to the oldest, for a game where
      #   the last thing added has to act first. A thing spawned during that walk is also first
      #   visited by the next one.
      #--
      # The walk follows the chain from its first thing. It looks one step ahead before running
      # the block, and nothing the block does can change that step: a removal during a walk
      # leaves the chain alone until the walk is over (see #retired_list). A thing removed before
      # its turn is still in the chain, dead, and is passed over. `newest_first: true` follows
      # each thing's link back to the one added before it, and stops at the thing that was first
      # when it began.
      #++
      def each(newest_first: false, &block)
        refuse_unknown_walk_order!(newest_first)
        pool = self
        active = List.new(@builder, active_list)
        at, ahead, last = walk_vars
        start, finish, links = newest_first ? [tail_var, head_var, prev_list] : [head_var, tail_var, next_list]
        record(Build.add(walking_var, Build.int(1)))
        preserving_current_slot do
          record(Build.set(ahead, Build.var_ref(start)))
          record(Build.set(last, Build.var_ref(finish)))
          finished = Value.new(@builder, Build.var_ref(ahead)) == NONE
          @builder.repeat(@capacity, stop_when: finished) do
            record(Build.set(at, Build.var_ref(ahead)))
            step = Build.if_(Build.binop(:==, Build.var_ref(at), Build.var_ref(last)), Build.set(ahead, Build.int(NONE)))
            step.else = Build.else_(Build.set(ahead, Build.list_get(links, Build.var_ref(at))))
            record(step)
            slot = Value.new(@builder, Build.var_ref(at), name: at)
            # The walk can pass a thing removed before its turn, so the body is only for a live
            # one.
            if active[slot] == 1
              record_current_slot(slot)
              yield(Instance.new(pool, slot))
            end
          end
          mark_walk(@builder.last_recorded_statement, at, ahead, last, links)
        end
        record(Build.sub(walking_var, Build.int(1)))
        record(release_when_idle)
        self
      end

      # The repeat a walk made, marked as one (IR::WalkShape): the thing it is on, the one it goes to
      # next, the last it visits, and the links it steps along, by the first two of its statements.
      def mark_walk(repeat_node, at, ahead, last, links)
        return unless repeat_node&.kind == :repeat

        repeat_node.pool_walk = Ractor.make_shareable(IR::WalkShape.new(pool: @name, at: at, ahead: ahead, last: last, links: links,
                                                            step_statements: 2))
      end
      private :mark_walk

      def refuse_unknown_walk_order!(newest_first)
        return if [true, false].include?(newest_first)

        raise ArgumentError,
              "`each` on pool :#{@name} was given newest_first: #{newest_first.inspect}. It needs true or false. " \
              "With true, the walk " \
              "starts at the thing added last. With false, or with nothing said, it starts at the thing added first."
      end
      private :refuse_unknown_walk_order!

      # Makes a routine that works on one thing of the pool, called from inside Pool#each.
      #
      # It is the body of `each` moved into a routine of its own, which is where a game of any
      # size puts it. The routine is handed the thing the walk is on.
      #
      # ```ruby
      # guards.func(:chase) { |g| g.x.approach! hero.x, 1 }
      # guards.each { |g| call g.state }
      # ```
      #
      # A plain Builder#func has no way to name which guard is chasing, because a routine is
      # built once, wherever it is called from. Called anywhere but inside a walk of its pool,
      # such a routine would run on whichever thing was walked last, so that is refused when
      # the game is built.
      #--
      # This pool hands the routine the instance being walked right now, and the walk itself is
      # what sets which that is (see #record_current_slot). The refusal is
      # Builder#verify_instance_routines!.
      #++
      def func(name, &block)
        raise ArgumentError, "`pool :#{@name}` needs a block to make a routine out of." unless block

        @builder.declare_instance_routine(self, name, &block)
        self
      end

      # The routines this pool declared for one instance at a time, in declaration order.
      def instance_routines = @instance_routines ||= [] # :nodoc:

      # One instance of this pool, as a routine of its own sees it: the one the walk is on.
      #
      # This is built for every such routine before its body runs, and a routine with nothing
      # to do with its instance never reads it. So its slot is a number handed over rather
      # than one worked out: left unused, it is not the game's to be blamed for.
      def current_instance = Instance.new(self, Value.handed_to_block(@builder, Build.var_ref(current_var))) # :nodoc:

      # Build the body of routine +name+ into the routine being built, yielding the instance
      # it runs for.
      #
      # A routine that walks its own pool — the stepper checked against every other thing —
      # needs its instance in a variable of its own. The instance reads current_var, and a walk
      # of the pool moves that on to each thing it visits, so inside the walk `e` would read
      # the walk's thing. That holds for a read written inside the walk and for one made before
      # it and kept in a name (`mover = e.index`), since both are reads of current_var. In plain
      # Ruby `e` stays the routine's own thing under any walk.
      #
      # Every walk already keeps the instance it began on, to put current_var back as it ends
      # (#preserving_current_slot). In a routine that instance is the routine's own, so the
      # routine's variable is that kept copy: each outermost walk of the pool in the body keeps
      # current_var in the routine's variable, and the reads of current_var inside the walk read
      # it there. Outside the walks current_var is the routine's own thing anyway, and those
      # reads stay as they were. So the routine does no more work than one reading current_var
      # throughout: the copy is the store the walk made before.
      #
      # A walk inside the walk keeps the thing the outer walk is on, as before, so a routine of
      # the pool called inside the outer walk after it still runs for that thing.
      #
      # Every read of `e` is one node, the instance's slot, wherever it is used, and so is a
      # read kept in a name (`here = e.x`), which can be used both before a walk and inside it.
      # So a read inside a walk is not renamed where it stands: each value worked out inside the
      # walk that reads current_var is replaced by a copy of its own reading the routine's
      # variable, and the reads outside are left alone.
      #
      # Only a routine whose body walks its pool does any of this: any other keeps reading
      # current_var, and builds the bytes it always did.
      #
      # Returns the routine's own variable, for the build to declare, or nil when it has none.
      def build_routine_body(name) # :nodoc:
        own_var = part_name("routine#{instance_routines.index(name)}_at")
        walks_before = walk_saves.length
        yield current_instance
        walks = walk_saves.drop(walks_before)
        return nil if walks.empty?

        outermost = outermost_walks(walks)
        inner_saves = Set.new.compare_by_identity.merge((walks - outermost).map(&:first))
        outermost.each do |saved, restored|
          walk_statements(saved, restored).each { |statement| retarget_current_reads(statement, own_var, inner_saves) }
          saved.var = own_var
          restored.value = Build.var_ref(own_var)
        end
        own_var
      end

      # The walks of this pool, each as the statement keeping current_var before it and the one
      # putting it back after (#preserving_current_slot), in the order they were finished.
      private def walk_saves = @walk_saves ||= []

      # The statements a walk runs between keeping current_var and putting it back.
      def walk_statements(saved, restored)
        siblings = saved.parent.children
        first = siblings.index { |node| node.equal?(saved) }
        last = siblings.index { |node| node.equal?(restored) }
        siblings[(first + 1)...last]
      end

      # The walks of +walks+ that no other of them runs inside.
      def outermost_walks(walks)
        inner = Set.new.compare_by_identity
        walks.each do |saved, restored|
          walk_statements(saved, restored).each { |statement| inner.merge(statement.walk.to_a) }
        end
        walks.reject { |saved, _restored| inner.include?(saved) }
      end

      # Make every value +statement+ and the statements in it work out read +own_var+ where it
      # read current_var. +skipped+ are the inner walks' statements keeping current_var, which
      # keep reading it.
      def retarget_current_reads(statement, own_var, skipped)
        return if skipped.include?(statement)

        statement.children.each { |child| retarget_current_reads(child, own_var, skipped) }
        statement.attrs.each do |_field, held|
          fresh = retargeted_operand(held, own_var, skipped)
          statement.replace_operand(held, fresh) unless fresh.equal?(held)
        end
      end

      # +operand+ as it reads inside the walk: a value reading current_var as a copy reading
      # +own_var+, a list with each element so, a statement changed where it stands, and
      # anything else as it is.
      def retargeted_operand(operand, own_var, skipped)
        case operand
        when Array
          fresh = operand.map { |element| retargeted_operand(element, own_var, skipped) }
          fresh.zip(operand).all? { |now, before| now.equal?(before) } ? operand : fresh
        when IR::Node
          unless operand.value?
            retarget_current_reads(operand, own_var, skipped)
            return operand
          end
          return operand unless operand.walk.any? { |node| current_read?(node) }

          operand.copy.tap { |copy| copy.walk { |node| node.name = own_var if current_read?(node) } }
        else operand
        end
      end

      # Whether +node+ reads current_var.
      def current_read?(node) = node.kind == :var_ref && node.name == current_var
      private :walk_statements, :outermost_walks, :retarget_current_reads, :retargeted_operand, :current_read?

      # How many things are live right now, as a Value.
      #
      # ```ruby
      # draw_number bullets.count, 8, 8, :white
      # ```
      def count = Value.new(@builder, Build.var_ref(count_var))

      # Whether the pool has no room for another thing, as a test to branch on with `if`.
      #
      # This is whether Pool#spawn will find room, rather than how many are live. During a walk
      # a thing removed is no longer counted, but its room is not free until the walk ends.
      #
      # ```ruby
      # bullets.spawn x: ship.x, y: ship.y, vy: -4 unless bullets.full?
      # ```
      def full? = Condition.new(@builder, Build.binop(:==, Build.list_len(free_list), Build.int(0)))

      # Retire the instance at slot +index+ (a {Value}): it leaves the order and stops being
      # drawn and updated. Called by {Instance#remove}; safe to call mid-`each`, on any
      # instance of the pool. Outside a walk its slot is free at once; during one it is freed
      # as the walk ends (see #retired_list). A slot that is not live is left alone, so a thing
      # removed twice — a slot number kept after a walk, say — is not freed twice.
      #
      # The work is one routine of the pool's, called from every place a thing is removed,
      # since closing the gap in the chain is a dozen statements a game would otherwise carry
      # once per `remove` it writes.
      def remove_at(index) # :nodoc:
        record(Build.set(unlink_var, index.node))
        @builder.call(removal_routine)
        self
      end

      # Retire the oldest live thing, when there is one: what `shift` does to an Array of Structs.
      # During a walk a removed thing stays in the chain until the walk ends, so the first thing
      # in the chain may be dead, and the oldest live one is found by stepping past the dead.
      # Outside a walk the first is live, so +during_walk+ false, where the build knows no walk can
      # be under way, removes the first and builds no steps.
      def remove_oldest(during_walk: true) # :nodoc:
        unless during_walk
          remove_at(Value.new(@builder, Build.var_ref(head_var))) if count > 0
          return self
        end

        record(Build.set(unlink_var, Build.var_ref(head_var)))
        finished = Value.new(@builder, Build.var_ref(unlink_var)) == NONE
        @builder.repeat(@capacity, stop_when: finished) do
          live = Build.binop(:==, Build.list_get(active_list, Build.var_ref(unlink_var)), Build.int(1))
          found = Build.if_(live, Build.call(removal_routine), Build.set(unlink_var, Build.int(NONE)))
          found.else = Build.else_(Build.set(unlink_var, Build.list_get(next_list, Build.var_ref(unlink_var))))
          record(found)
        end
        self
      end

      # Declares the routine +name+ that puts the live things in the order +key+ gives (a
      # DSL::SortOrder::Key: fields, each the smallest or the biggest first, each after the first
      # breaking the ties of those before): what `sort_by!` does to an Array of Structs. What
      # changes is the order they are walked in, and so drawn in; no field moves. Level things keep
      # the order they had. +name+ is Messages::MadeNames `array_sort`, one for each line that sorts.
      #
      # The live slots are gathered from the chain into a list of their own, put in order by the
      # fields' lists (IR list_sort, which every console's build writes, as draw order uses it),
      # and the chain is linked again in that order. list_sort keeps level slots in the order
      # they had, so a key of several fields is one sort for each, the last field first: each
      # sort after it keeps the order the one before made among the slots it finds level.
      #
      # The routine relinks the chain, so it must not run while a walk follows it. StructArray
      # refuses a sort written in a walk of the Array and one written in a routine a walk may
      # call (StructArray#refuse_sort_in_walk!); a scene's body or the game loop outside a walk
      # is where one runs, and the chain holds only live things there.
      def declare_sort(name, key) # :nodoc:
        @builder.declare_routine_once(name) { sort_nodes(key) }
        self
      end

      # The list a sort gathers the live slots into, and the variables it works in.
      def sort_list = part_name(:sorted) # :nodoc:
      def sort_slot_var = part_name(:sort_slot) # :nodoc:
      def sort_index_var = part_name(:sort_at) # :nodoc:

      def sort_nodes(key)
        @builder.declare_pool_sort_storage(self)
        slot = -> { Build.var_ref(sort_slot_var) }
        at = -> { Build.var_ref(sort_index_var) }
        sorted_at = ->(offset) { Build.list_get(sort_list, Build.binop(:+, at.call, Build.int(offset))) }
        count = Build.list_len(sort_list)
        last = Build.list_get(sort_list, Build.binop(:-, Build.list_len(sort_list), Build.int(1)))
        [Build.repeat(Build.list_len(sort_list), sort_index_var, Build.list_drop(sort_list, from: :back)),
         Build.set(sort_slot_var, Build.var_ref(head_var)),
         Build.repeat(@capacity, sort_index_var,
                      Build.list_push(sort_list, slot.call),
                      Build.set(sort_slot_var, Build.list_get(next_list, slot.call)),
                      stop_when: Build.binop(:==, Build.var_ref(sort_slot_var), Build.int(NONE))),
         *key.fields.reverse.map { |field| Build.list_sort(sort_list, by: field_list(field.name), descending: field.descending) },
         Build.if_(Build.binop(:>, count, Build.int(0)),
                   Build.set(head_var, Build.list_get(sort_list, Build.int(0))),
                   Build.list_set(prev_list, Build.var_ref(head_var), Build.int(NONE)),
                   Build.repeat(Build.binop(:-, count.copy, Build.int(1)), sort_index_var,
                                Build.list_set(next_list, sorted_at.call(0), sorted_at.call(1)),
                                Build.list_set(prev_list, sorted_at.call(1), sorted_at.call(0))),
                   Build.set(tail_var, last),
                   Build.list_set(next_list, Build.var_ref(tail_var), Build.int(NONE)))]
      end
      private :sort_nodes

      # The chain is kept by four routines of the pool's, each declared the first time it is
      # needed and called from every place that needs it: removing a thing, putting a spawn at
      # the end, taking a slot out of the middle, and freeing what a walk removed. Each is a
      # handful of statements a game would otherwise carry once per `spawn` and `remove` it
      # writes. They pass the slot they work on in slot_var or unlink_var.

      # Remove the thing whose slot is in unlink_var.
      def removal_routine
        pool_routine(:remove) do
          free_now = Build.if_(not_walking,
                               Build.call(unlink_routine), Build.list_push(free_list, Build.var_ref(unlink_var)))
          free_now.else = Build.else_(Build.list_push(retired_list, Build.var_ref(unlink_var)))
          live = Build.binop(:==, Build.list_get(active_list, Build.var_ref(unlink_var)), Build.int(1))
          [Build.if_(live,
                     Build.list_set(active_list, Build.var_ref(unlink_var), Build.int(0)),
                     Build.sub(count_var, Build.int(1)),
                     free_now)]
        end
      end

      # Take everything removed during the walks just ended out of the chain, and free its
      # slot, last removed first.
      def release_routine
        pool_routine(:release_removed) do
          index = release_index_var
          [Build.repeat(Build.list_len(retired_list), index,
                        Build.set(unlink_var, Build.list_get(retired_list,
                                                             Build.binop(:-, Build.list_len(retired_list), Build.int(1)))),
                        Build.list_drop(retired_list, from: :back),
                        Build.call(unlink_routine),
                        Build.list_push(free_list, Build.var_ref(unlink_var)))]
        end
      end

      # Put the slot in slot_var at the end of the chain: after the last thing, or as the
      # first and last of an empty one.
      def append_routine
        pool_routine(:append) do
          slot = -> { Build.var_ref(slot_var) }
          tail = -> { Build.var_ref(tail_var) }
          join = Build.if_(Build.binop(:==, tail.call, Build.int(NONE)), Build.set(head_var, slot.call))
          join.else = Build.else_(Build.list_set(next_list, tail.call, slot.call))
          [Build.list_set(next_list, slot.call, Build.int(NONE)),
           Build.list_set(prev_list, slot.call, tail.call),
           join,
           Build.set(tail_var, slot.call)]
        end
      end

      # Take the slot in unlink_var out of the chain, joining the things either side of it.
      # The slot's own links are left as they were.
      def unlink_routine
        pool_routine(:unlink) do
          # Each neighbour is read once into a variable: a read of a list is several
          # instructions, and this would otherwise make eight of them.
          before_var = unlink_before_var
          after_var = unlink_after_var
          before = -> { Build.var_ref(before_var) }
          after = -> { Build.var_ref(after_var) }
          front = Build.if_(Build.binop(:==, before.call, Build.int(NONE)), Build.set(head_var, after.call))
          front.else = Build.else_(Build.list_set(next_list, before.call, after.call))
          back = Build.if_(Build.binop(:==, after.call, Build.int(NONE)), Build.set(tail_var, before.call))
          back.else = Build.else_(Build.list_set(prev_list, after.call, before.call))
          [Build.set(before_var, Build.list_get(prev_list, Build.var_ref(unlink_var))),
           Build.set(after_var, Build.list_get(next_list, Build.var_ref(unlink_var))),
           front, back]
        end
      end

      # A test that holds while no walk of this pool is in progress.
      def not_walking = Build.binop(:==, Build.var_ref(walking_var), Build.int(0))

      # A statement that frees what earlier walks removed, when no walk is in progress and
      # something is waiting. A walk records it as it ends. A spawn records it too, because a save
      # made during a walk keeps things that walk had not yet let go of, and a game that loads
      # it and spawns before any walk ends would otherwise find those slots still taken.
      def release_when_idle
        waiting = Build.binop(:>, Build.list_len(retired_list), Build.int(0))
        Build.if_(Build.binop(:and, not_walking, waiting), Build.call(release_routine))
      end

      # The name of the pool's routine for +job+, declared with the statements the block
      # gives the first time it is asked for.
      def pool_routine(job)
        @pool_routines ||= {}
        @pool_routines[job] ||= begin
          name = part_name(job)
          nodes = yield
          builder = @builder
          builder.func(name) { nodes.each { |node| builder.record_statement(node) } }
          name
        end
      end
      private :removal_routine, :release_routine, :append_routine, :unlink_routine, :pool_routine, :not_walking, :release_when_idle

      # One field of the thing at a slot, as a FieldRef that reads and changes like a variable.
      #
      # The slot is the number Pool::Instance#index handed back, kept in a variable, so a game
      # can act after a walk on the thing it picked during it: the nearest enemy, or the one
      # just hit.
      #
      # ```ruby
      # enemies.each { |e| nearest = e.index if e.x < best_x }
      # enemies.field_ref(:hp, nearest).decrease! 1
      # ```
      def field_ref(field, index)
        field_ref_at_node(field, index.node)
      end

      # One field of one slot, with everything it needs to read, write and complain clearly.
      def field_ref_at_node(field, index_node) # :nodoc:
        FieldRef.new(builder: @builder, list: field_list(field), index: index_node,
                     pool: @name, field: field, fraction_bits: field_bits(field),
                     names: @field_names[field], advice: @kind_advice&.call(field))
      end

      # What a field keeps, without building a handle to ask it (see FieldRef.scale).
      def field_scale(field) # :nodoc:
        FieldRef.scale(pool: @name, field: field, bits: field_bits(field), names: @field_names[field],
                       advice: @kind_advice&.call(field))
      end

      # What a number of the wrong kind for a field is told, in place of the pool's own words:
      # +advice+ is handed a field and gives Value's `declaring:` and `mixing:` for it. An Array of
      # Structs kept as a pool (StructArray) speaks of the Struct, which is what its game wrote.
      def explain_kinds_with(&advice) # :nodoc:
        @kind_advice = advice
        self
      end

      # What a field holds, taken from the default it was declared with. Writing `vy: 0.0`
      # is how a pool declares a field carries a fraction, exactly as writing `var :vy, 0.0` does
      # for a variable — so a game with sixty particles drifting at fractional speeds never
      # picks a scale of its own.
      def field_bits(field) = Fraction.bits_of(@fields[field]) # :nodoc:

      # How a message names this pool to the author: the Array of Structs the game wrote, or its
      # `pool` line (Builder#collection_words). Public for Instance, whose messages name it too.
      def author_words(opening: false) = @builder.collection_words(@name, verb: :pool, opening: opening) # :nodoc:

      # How to give this pool's things pictures: `drawn_as` in the Struct, or a `pool` setting.
      def pictures_fix # :nodoc:
        if @builder.collections_from_arrays.key?(@name)
          "To fix this, give the Struct pictures with `drawn_as` in its block."
        else
          "Give the pool pictures with image:, facing: or frames:."
        end
      end

      private

      # The default policy: create in a free slot, or leave a full pool untouched. Guarded
      # on a free slot existing, so a full pool is a clean no-op (nothing half-written).
      #
      # The :stop policy is the same with the game stopped where a full pool would drop it, naming
      # the pool, as a push onto a full list stops it.
      #
      # +during_walk+ is for a :stop spawn that can run while a walk of the pool is under way. A
      # thing the walk removed keeps its slot until the walk ends (see #retired_list), so the
      # pool can be full while its count shows room, which Ruby would have. The slot cannot be
      # given to the new thing then: it is still in the chain the walk follows, at the place of
      # the thing removed, and a new thing is the newest. So that spawn stops the game with words
      # of its own, saying the room comes when the walk ends (Faults.full_in_walk).
      def spawn_dropping(values, during_walk: false)
        slot = Build.var_ref(slot_var)
        body = claim_free_slot(slot) + [Build.call(append_routine)] + assign_fields(slot, values) + pose_reset_nodes(slot)
        spawn = Build.if_(free_available, *body)
        if @on_full == :stop
          full = Build.stop_full(@name, @capacity)
          if during_walk
            removed_in_walk = Build.binop(:>, Build.list_len(retired_list), Build.int(0))
            full = Build.if_(removed_in_walk, Build.stop_full(@name, @capacity, in_walk: true)).tap do |test|
              test.else = Build.else_(full)
            end
          end
          spawn.else = Build.else_(full)
        end
        record(spawn)
      end

      # The :recycle_oldest policy: take a free slot when there is one, otherwise reuse the
      # longest-lived instance's slot — so a new spawn always appears. The oldest is the
      # first in the chain, so finding it is one read. Either way the slot then joins the end
      # of the chain, as the newest.
      #
      # The one place it cannot take the oldest is a walk of this same pool: the walk is
      # following the chain, and moving its first thing to the end would cut the walk short, or
      # carry a newest-first walk past the thing it stops at. There, a full pool drops the spawn, as a `:drop` pool always does.
      def spawn_recycling(values)
        slot = Build.var_ref(slot_var)
        take_oldest = Build.if_(not_walking,
                                Build.set(slot_var, Build.var_ref(head_var)),
                                Build.set(unlink_var, Build.var_ref(head_var)),
                                Build.call(unlink_routine))
        choose = Build.if_(free_available, *claim_free_slot(slot))
        choose.else = Build.else_(Build.set(slot_var, Build.int(NONE)), take_oldest)
        record(choose)
        body = [Build.call(append_routine)] + assign_fields(slot, values) + pose_reset_nodes(slot)
        record(Build.if_(Build.binop(:!=, Build.var_ref(slot_var), Build.int(NONE)), *body))
      end

      # Pop the newest free slot into slot_var, mark it live, and grow the count — the "there
      # is room" path both policies share.
      def claim_free_slot(slot)
        [Build.set(slot_var, last_free_index),
         Build.list_drop(free_list, from: :back),
         Build.list_set(active_list, slot, Build.int(1)),
         Build.add(count_var, Build.int(1))]
      end

      # A new instance starts facing the first direction and at the start of its cycle,
      # whatever the slot it took was doing before. Instances spawned at different moments
      # therefore sit at different points in the same cycle, which is what stops a pool of
      # them pulsing as one.
      #
      # It starts in its own colours too. Whether the pool is ever recoloured is not known yet —
      # the spawn is usually written before the walk that recolours — so a pool whose instances
      # draw always writes it here, and #drop_unused_color_resets takes it out again if nothing needed it.
      def pose_reset_nodes(slot)
        nodes = []
        nodes << Build.list_set(facing_list, slot, Build.int(0)) if @art&.faces?
        nodes << Build.list_set(frame_list, slot, Build.int(0)) if @art&.animates?
        if spriteful?
          reset = Build.list_set(colors_list, slot, Build.int(Build::NO_RECOLOR))
          color_resets << reset
          nodes << reset
        end
        nodes
      end

      def color_resets = @color_resets ||= []

      # The list_set nodes that write each field of the instance at +slot+ (omitted fields
      # take their declared default).
      def assign_fields(slot, values)
        @fields.map do |field, default|
          given = values.fetch(field, default)
          # Checked against what the field holds, so spawning with a fraction into a whole
          # field — or the other way round — is the same friendly error as writing one later.
          node = field_scale(field).node_matching(given, "hold")
          Build.list_set(field_list(field), slot, node)
        end
      end

      # A condition that's true while the pool has a free slot.
      def free_available = Build.binop(:>, Build.list_len(free_list), Build.int(0))

      # The value node for the last free slot index: free[len - 1].
      def last_free_index
        Build.list_get(free_list, Build.binop(:-, Build.list_len(free_list), Build.int(1)))
      end

      def record(node) = @builder.record_statement(node)

      # Three variables of one walk's own — the slot it is on, the one it goes to next, and
      # the last it will visit — so a walk inside another walk of this pool keeps its place.
      def walk_vars
        @walks = @walks.to_i + 1
        %i[at ahead last].map { |part| part_name("walk#{@walks}_#{part}") }
      end

      # The variables a pool's own walks hold a slot in: the slot a walk is on (#walk_vars), the
      # one a routine of the pool runs for (#record_current_slot) and that routine's own copy of
      # it (#build_routine_body), and the one the copy for its
      # sprites is on (#stacking_nodes). Each starts at nought, and is read for the pool's lists
      # only once the walk has seen that it holds a slot and not NONE. So whenever one is read
      # there it is a slot below the pool's capacity, and a lowering can read the pool's own lists
      # there without testing the index first.
      SLOT_PARTS = /\A(?:current|stacking_at|walk\d+_at|routine\d+_at)\z/ # :nodoc:

      # The ones of those that never hold none: each is written only with a slot the walk has seen
      # is not NONE, or put back from a copy of itself. The copy for the sprites steps its slot
      # along the chain, NONE at the end included (#stacking_nodes), so it is not one of these. A
      # number in one of these is always below the pool's capacity, so a lowering that keeps
      # numbers in halves knows its high half is nought for good.
      SLOT_ONLY_PARTS = /\A(?:current|walk\d+_at|routine\d+_at)\z/ # :nodoc:

      # The name of the pool whose slot +var+ always holds (see SLOT_PARTS), or nil.
      def self.walked_by(var) # :nodoc:
        kind, parts = Messages::MadeNames.read(var)
        parts[:pool] if kind == :pool_part && SLOT_PARTS.match?(parts[:part])
      end

      # Whether +var+ only ever holds one of its pool's slots, never NONE (see SLOT_ONLY_PARTS).
      def self.holds_only_slots?(var) # :nodoc:
        kind, parts = Messages::MadeNames.read(var)
        kind == :pool_part && SLOT_ONLY_PARTS.match?(parts[:part])
      end

      # The slot a walk goes to next (#walk_vars), a slot or NONE. It is set from the chain's links
      # on one line only, on a turn the walk began because it held a slot, and that slot is the one
      # whose link is read (`at = ahead`, then `ahead = links[at]`). So as that line runs it holds a
      # slot, with a high half of nought, and a lowering that keeps numbers in halves need only write
      # the high half when the link read is NONE.
      NEXT_SLOT_PARTS = /\Awalk\d+_ahead\z/ # :nodoc:

      # The slot a walk is on (#walk_vars), set at the top of every turn and read straight after:
      # the thing's link to the next, and whether it is live, are each a list read at that slot.
      WALK_SLOT_PARTS = /\Awalk\d+_at\z/ # :nodoc:

      # Whether +var+ is the slot a walk is on (see WALK_SLOT_PARTS).
      def self.walk_slot?(var) # :nodoc:
        kind, parts = Messages::MadeNames.read(var)
        kind == :pool_part && WALK_SLOT_PARTS.match?(parts[:part])
      end

      # Whether +var+ is a walk's next slot (see NEXT_SLOT_PARTS).
      def self.next_slot_of_walk?(var) # :nodoc:
        kind, parts = Messages::MadeNames.read(var)
        kind == :pool_part && NEXT_SLOT_PARTS.match?(parts[:part])
      end

      # The name of the pool +list+ belongs to, a field's list or one of the pool's own, or nil.
      def self.owner_of_list(list) # :nodoc:
        kind, parts = Messages::MadeNames.read(list)
        parts[:pool] if %i[pool_field pool_part].include?(kind)
      end

      # Which instance a routine of this pool is running for, written at the top of every live
      # pass of a walk. A routine is built once and called from wherever, so the one thing it
      # cannot be handed in its own code is which instance — this variable is how the walk tells
      # it, and `current_instance` is how the routine reads it.
      #
      # It costs a store per live instance per pass, and only a pool with such a routine pays it:
      # the write is recorded here and taken out again at the end of the build when nothing
      # wanted it (Builder#finalize_pool_walks).
      def record_current_slot(index)
        node = Build.set(current_var, index.node)
        record(node)
        current_writes << node
        @builder.record_walk_instance_writes(self, node)
      end

      # The writes #record_current_slot made, one for each walk.
      private def current_writes = @current_writes ||= []

      # A walk whose body never asks which thing it is on writes it down for nobody. Only a call
      # can reach a routine of the pool, which reads it, and a routine's own reads inside its walks
      # read its own variable (#build_routine_body); a walk inside reads it to keep it. So a walk
      # whose body has no call and no read of it, the inner walk of a thing checked against each
      # other thing above all, goes without the write, one store for every thing it visits. What
      # it was before the walk is what it is during it, and the walk puts that back as it ends.
      # Called at the end of the build (Builder#finalize_pool_walks), once every routine's body has
      # been read.
      public def drop_unread_current_writes # :nodoc:
        current_writes.each do |write|
          body = write.parent.children.drop_while { |node| !node.equal?(write) }.drop(1)
          next if body.any? { |statement| statement.walk.any? { |node| node.callees.any? || current_read?(node) } }

          write.parent.children.delete(write)
        end
      end

      # ...and a walk puts it back as it leaves, because the walks nest. Two walks over one pool
      # — a pairwise test, or a routine that walks the pool it was called from — would otherwise
      # leave the outer one running on whatever instance the inner one finished at, for the rest
      # of that pass. A save and a restore per walk, not per instance, settles it whichever way
      # the nesting came about, including through a call this cannot see.
      def preserving_current_slot
        held = @builder.pool_walk_scratch_var
        saved = Build.set(held, Build.var_ref(current_var))
        record(saved)
        yield
        restored = Build.set(current_var, Build.var_ref(held))
        record(restored)
        walk_saves << [saved, restored]
        @builder.record_walk_instance_writes(self, saved, restored)
      end

      # One thing of a pool
      #
      # One live thing of a pool, as the block of Pool#each sees it. Its fields are reached by
      # name (`b.x`, `b.hp`), each a FieldRef that reads and changes like a variable.
      # Pool::Instance#remove takes it out of the pool, and Pool::Instance#index hands back its
      # slot as a Value.
      #
      # ```ruby
      # enemies.each do |e|
      #   e.x += 1
      #   e.remove if e.hp <= 0
      # end
      # ```
      #
      # An instance belongs to the turn of the walk that handed it over, so it is not something
      # to keep. Its index is a number, so keep that instead, and reach the thing later with
      # Pool#field_ref.
      #
      # A thing of a pool that draws also has a box: its x and y fields and its picture's size.
      # So it can ask Bounds#overlaps?, the screen-edge tests and Pool::Instance#clamp_to_screen:
      # `bullet.overlaps?(enemy)`, `b.off_screen?`.
      class Instance
        include Bounds # overlaps? + off_screen?/edge tests, from left/top/right/bottom below

        def initialize(pool, index)
          @pool = pool
          @index = index # a Value: the loop's current slot
        end

        # The build this pool belongs to, which {Bounds} asks for the screen.
        def collision_builder = @pool.builder # :nodoc:

        # Draws this thing with another list of colours, or one of several picked by a number,
        # or its own again.
        #
        # It is what HardwareSprite#draw_with does, for one thing of a pool. Each thing keeps its
        # own choice.
        #
        # ```ruby
        # guards.each { |g| g.draw_with :angry if g.hp < 2 }
        # ```
        #
        # * `showing:` - with several lists, the number that picks one of them.
        def draw_with(which, showing: nil)
          @pool.draw_with(@index, which, showing)
          self
        end

        # Takes this thing out of the pool, so it stops being drawn and its room is free for a
        # new one.
        #
        # It is safe inside Pool#each. During a walk, its room is freed as the walk ends.
        #
        # ```ruby
        # bullets.each { |b| b.remove if b.y < 0 }
        # ```
        def remove
          @pool.remove_at(@index)
        end

        # Turns this thing to face a direction, among the `facing:` pictures the pool was given.
        #
        # It is the same verb, spelled the same way, that a sprite given `facing:` takes
        # (HardwareSprite#face). Each thing holds its own direction, so ten guards in one pool
        # can face ten ways.
        #
        # ```ruby
        # guards.each { |g| g.face :left }
        # guards.each { |g| g.face [:left, :right], showing: g.side }
        # ```
        #
        # * `showing:` - with a list of directions, the number that picks one of them, worked
        #   out for each thing.
        def face(direction, showing: nil)
          unless showing.nil?
            @pool.builder.write_picked_pose(direction, showing, subject: "pool :#{@pool.name}",
                                                                row_of: ->(name) { @pool.facing_row(name) }) do |row|
              @pool.set_facing(@index, row)
            end
            return self
          end
          row = @pool.facing_row(direction)
          if row.nil?
            known = @pool.facing_names
            raise ArgumentError,
                  "#{@pool.author_words(opening: true)} has no direction #{direction.inspect}. " \
                  "#{known.empty? ? 'It was not given facing: pictures.' : "It faces #{known.join(', ')}."}"
          end
          @pool.set_facing(@index, row)
          self
        end

        # This thing's own slot in the pool, as a Value.
        #
        # The instance itself does not last past the turn of Pool#each that handed it over, but
        # a slot is a number. Keep it in a variable to remember which thing won a comparison,
        # such as the nearest enemy or the one just hit, and act on it after the walk with
        # Pool#field_ref.
        #
        # ```ruby
        # enemies.each { |e| hit = e.index if e.overlaps?(hero) }
        # ```
        def index = @index

        # The left edge of this thing's box, as a Value: its x field and its picture's box.
        #
        # The pool needs a picture, which gives a thing its size.
        #
        # ```ruby
        # e.remove if e.left > 240
        # ```
        def left = field(:x) + hitbox_part(0)

        # The top edge of this thing's box, as a Value: its y field and its picture's box.
        #
        # ```ruby
        # e.remove if e.top > 160
        # ```
        def top = field(:y) + hitbox_part(1)

        # The right edge of this thing's box, as a Value, one past its last column.
        #
        # ```ruby
        # e.remove if e.right < 0
        # ```
        def right = field(:x) + hitbox_part(0) + hitbox_part(2)

        # The bottom edge of this thing's box, as a Value, one past its last row.
        #
        # ```ruby
        # e.remove if e.bottom < 0
        # ```
        def bottom = field(:y) + hitbox_part(1) + hitbox_part(3)

        # Moves this thing, stopping at the scenery's solid tiles if the pool was told
        # Pool#blocked_by.
        #
        # It is the counterpart for one thing to HardwareSprite#move, spelled the same way: a
        # direction name with `by:`, or a step across and down. Each axis is checked on its own,
        # so a thing slides along a wall it is pressed against instead of sticking to it.
        #
        # ```ruby
        # guards.each { |g| g.move :left, by: 1 }
        # guards.each { |g| g.move 1, -1 }
        # ```
        #
        # A pool with `facing:` pictures turns the thing to face the way it moved, so one line
        # leaves ten guards leaning ten ways.
        #
        # * `by:` - how many pixels a direction name moves it.
        def move(direction_or_dx, dy = nil, by: 1)
          if direction_or_dx.is_a?(Symbol)
            step_x, step_y = Direction.unit(direction_or_dx)
            step(:x, step_x * by) unless step_x.zero?
            step(:y, step_y * by) unless step_y.zero?
            face(direction_or_dx) if @pool.facing_row(direction_or_dx)
          else
            step(:x, direction_or_dx) if direction_or_dx != 0
            step(:y, dy) if !dy.nil? && dy != 0
          end
          self
        end

        # Whether this thing could step in a direction without meeting a solid tile, as a test
        # to branch on.
        #
        # It is for a game that decides for itself what a blocked thing does. The pool must have
        # been told Pool#blocked_by.
        #
        # ```ruby
        # guards.each { |g| g.face :right unless g.can_move?(:left, by: 2) }
        # ```
        #
        # * `by:` - how many pixels the step is.
        def can_move?(direction, by: 1)
          cells = @pool.solid_cells or raise ArgumentError,
                                            "pool :#{@pool.name} was not told `blocked_by` a background, so an " \
                                            "instance has no solid tiles to test against."

          step_x, step_y = Direction.unit(direction)
          emit_tile_check(cells, field(:x) + (step_x * by), field(:y) + (step_y * by))
        end

        # Keeps this thing wholly on the screen, using its picture's own size.
        #
        # It is the counterpart for one thing to a sprite's `clamp_to_screen`, and changes the
        # thing's x and y fields where they stand.
        #
        # ```ruby
        # players.each { |p| p.clamp_to_screen }
        # ```
        def clamp_to_screen
          hit_x, hit_y, hit_w, hit_h = require_box!
          width, height = collision_builder.console.screen_size
          field(:x).clamp!(-hit_x, width - hit_x - hit_w)
          field(:y).clamp!(-hit_y, height - hit_y - hit_h)
          self
        end

        private

        # Move one axis: a plain nudge when nothing blocks this pool, else only if the
        # instance's box at the destination is clear of the scenery's solid tiles.
        def step(axis, delta)
          var = field(axis)
          cells = @pool.solid_cells
          if cells.nil?
            var.increase! delta
          else
            target_x = axis == :x ? field(:x) + delta : field(:x)
            target_y = axis == :y ? field(:y) + delta : field(:y)
            var.increase! delta if emit_tile_check(cells, target_x, target_y)
          end
        end

        # The same shared routine a `sprite` calls — see Builder::Collision. A pool of
        # thirty-two instances and a hand-declared sprite of the same size consult one copy
        # of it between them.
        def emit_tile_check(cells, target_x, target_y)
          hit_x, hit_y, hit_w, hit_h = require_box!
          builder = @pool.builder
          routine = builder.tile_collision_routine(cells, hit_x, hit_y, hit_w, hit_h)
          builder.store!(routine.x, Value.node_for(target_x))
          builder.store!(routine.y, Value.node_for(target_y))
          builder.call(routine.name)
          Value.new(builder, IR::Build.var_ref(routine.clear), name: routine.clear) == 1
        end

        def field(name) = @pool.field_ref(name, @index)

        def hitbox_part(component) = require_box![component]

        # The pool's collision box, or a friendly error if it has no size (no image).
        def require_box!
          @pool.hitbox || raise(ArgumentError,
                                "#{@pool.author_words(opening: true)} has no size, so its things have no " \
                                "rectangle for overlaps?, the off-screen tests and clamp_to_screen. " \
                                "#{@pool.pictures_fix}")
        end

        # A field read like `b.x` becomes a FieldRef at this instance's slot.
        def method_missing(name, *args)
          return @pool.field_ref(name, @index) if args.empty? && @pool.field?(name)

          super
        end

        def respond_to_missing?(name, include_private = false)
          @pool.field?(name) || super
        end
      end
    end
  end
end
