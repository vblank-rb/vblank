# frozen_string_literal: true

require "test_helper"

# Where the PlayStation's build keeps its textures in video RAM (PS1::TextureMemory): at the depth their
# colours allow, sharing colour tables, and packed so none overlaps another or runs out of its texture
# page. What they draw is checked against the interpreter in test_ps1_painted_screen.rb; these are the
# numbers psx-spx's texture formats hold the placement to.
class TestPS1TextureMemory < Minitest::Test
  TextureMemory = VBlank::IR::Backends::PS1::TextureMemory

  def test_each_texture_takes_the_smallest_depth_its_colours_allow
    memory = TextureMemory.new
    few = memory.add_texture(width: 16, height: 1, colors: [nil, *1..15])
    some = memory.add_texture(width: 17, height: 1, colors: (1..17).to_a)
    many = memory.add_texture(width: 20, height: 13, colors: (1..260).to_a)
    memory.allocate!

    assert_equal [4, 8, 15], [few, some, many].map(&:depth)
    assert_equal [0, 1 << 7, 2 << 7], [few, some, many].map { |texture| texture.draw_mode & (3 << 7) }
    assert_equal [4, 9, 20], [few, some, many].map(&:width_halfwords)
  end

  def test_textures_whose_colours_fit_together_share_a_colour_table
    memory = TextureMemory.new
    red_words = memory.add_texture(width: 4, height: 1, colors: [nil, 31, 31, nil])
    green_words = memory.add_texture(width: 4, height: 1, colors: [nil, 992, nil, 992])
    rainbow = memory.add_texture(width: 16, height: 1, colors: (100..115).to_a)
    memory.allocate!

    assert_same red_words.table, green_words.table
    refute_same red_words.table, rainbow.table
    assert_equal 2, memory.tables.length
  end

  # A see-through pixel is the table entry 0000h, which the chip does not draw, and black is 8000h, drawn.
  def test_see_through_is_nought_in_the_table_and_black_is_not
    memory = TextureMemory.new
    memory.add_texture(width: 2, height: 1, colors: [nil, 0])
    memory.allocate!

    assert_equal [0x0000, 0x8000].sort, memory.tables.first.entries.sort
  end

  # Four 4-bit texels a halfword, the leftmost in the low bits, and a row's last halfword filled out.
  def test_four_bit_texels_are_packed_leftmost_low
    memory = TextureMemory.new
    texture = memory.add_texture(width: 5, height: 2, colors: [nil, 1, 2, 3, 1, 3, 2, 1, nil, nil])
    memory.allocate!
    index = ->(color) { texture.table.index_of(TextureMemory.texel_for_color(color)) }
    row = ->(*colors) { colors.each_with_index.sum { |color, i| index.call(color) << (4 * i) } }

    assert_equal [row.call(nil, 1, 2, 3), row.call(1), row.call(3, 2, 1, nil), row.call(nil)], texture.halfwords
  end

  # Eight pictures of 192 × 256 at 15 bits are 393,216 halfwords, more than the 704 × 512 beside the
  # screen. Six of 16 colours at 4 bits and two of 200 at 8 take 6 × 48 × 256 + 2 × 96 × 256, and their
  # tables 6 × 16 + 2 × 256.
  def test_textures_and_tables_fit_where_fifteen_bits_would_not
    memory = TextureMemory.new
    textures = (0...8).map do |n|
      count = n < 6 ? 16 : 200
      memory.add_texture(width: 192, height: 256, colors: Array.new(192 * 256) { |at| (n * 1000) + (at % count) })
    end
    memory.allocate!

    assert_equal (6 * 48 * 256) + (2 * 96 * 256) + (6 * 16) + (2 * 256), memory.halfwords_used
    assert_none_overlap(textures)
    textures.each { |texture| assert_inside_its_page(texture) }
  end

  # Many textures of mixed sizes and depths: none overlaps another, the screen's pages or a colour table,
  # and each lies inside the texture page its draw mode names.
  def test_textures_are_packed_without_overlap_inside_their_pages
    memory = TextureMemory.new
    counts = [3, 40, 300]
    table_lines = [*240...256, *496...512]
    textures = (0...60).map do |n|
      width = 9 + ((n * 37) % 180)
      height = 5 + ((n * 53) % 120)
      count = counts[n % 3]
      memory.add_texture(width: width, height: height, colors: Array.new(width * height) { |at| (n * 400) + (at % count) })
    end
    memory.allocate!

    assert_none_overlap(textures)
    textures.each do |texture|
      assert_inside_its_page(texture)
      assert_operator texture.x, :>=, VBlank::Console::PS1Hardware::SCREEN_WIDTH
    end
    memory.tables.each do |table|
      assert_includes table_lines, table.y
      assert_equal 0, table.x % 16
      assert_operator table.x + table.capacity, :<=, VBlank::Console::PS1Hardware::SCREEN_WIDTH
    end
  end

  # The rows under the pages hold 32 tables of 256. Forty small textures of 200 colours each, none
  # sharing, need forty: the first 32 get one, and the rest keep their colours at 15 bits, which their
  # room beside the screen has space for, rather than the build being refused.
  def test_textures_past_the_last_colour_table_are_kept_at_fifteen_bits
    memory = TextureMemory.new
    textures = (0...40).map { |n| memory.add_texture(width: 20, height: 10, colors: Array.new(200) { |k| (n * 200) + k + 1 }) }
    memory.allocate!

    assert_equal [32, 8], [textures.count { |texture| texture.depth == 8 }, textures.count { |texture| texture.depth == 15 }]
    assert_equal 32, memory.tables.uniq(&:y).length
    assert_none_overlap(textures)
  end

  # An aligned texture starts in its page at a multiple of its width across and of its height down, so
  # the texture window can repeat it, whatever lies before it: a face's picture beside odd-sized words.
  def test_an_aligned_texture_starts_at_a_multiple_of_its_size_in_its_page
    memory = TextureMemory.new
    words = [[3, 5], [7, 40], [30, 9]].map { |w, h| memory.add_texture(width: w, height: h, colors: Array.new(w * h) { |at| at + 1 }) }
    walls = [[16, 16, 3], [64, 32, 200], [8, 8, 300]].map do |w, h, base|
      memory.add_texture(width: w, height: h, colors: Array.new(w * h) { |at| base + (at % 3) }, align: true)
    end
    memory.allocate!

    walls.each do |wall|
      corner = wall.texture_corner
      assert_equal [0, 0], [(corner & 0xFF) % wall.width, ((corner >> 8) & 0xFF) % wall.height], "a #{wall.width} × #{wall.height}"
      assert_inside_its_page(wall)
    end
    assert_none_overlap(words + walls)
  end

  def test_an_aligned_texture_has_sides_of_powers_of_two
    assert_raises(ArgumentError) { TextureMemory.new.add_texture(width: 12, height: 8, colors: Array.new(96, 1), align: true) }
  end

  def test_textures_that_do_not_fit_are_refused_in_plain_words
    memory = TextureMemory.new
    8.times { |n| memory.add_texture(width: 192, height: 256, colors: Array.new(192 * 256) { |at| (n * 7) + at }) }

    error = assert_raises(TextureMemory::Full) { memory.allocate! }
    assert_match(/video memory/, error.message)
  end

  private

  def assert_none_overlap(textures)
    cells = {}
    textures.each do |texture|
      texture.height.times do |down|
        texture.width_halfwords.times do |across|
          at = [texture.x + across, texture.y + down]
          refute cells.key?(at), "two textures share video RAM at #{at.inspect}"
          cells[at] = true
        end
      end
    end
  end

  # Read back through the draw mode and the corner, as the chip reads them: the page's left edge and top,
  # and u, v inside it, must come back to where the texture is, and its last texel must still be in the page.
  def assert_inside_its_page(texture)
    mode = texture.draw_mode
    corner = texture.texture_corner
    page_x = (mode & 0xF) * 64
    page_y = ((mode >> 4) & 1) * 256
    texels_a_halfword = 16 / { 4 => 4, 8 => 8, 15 => 16 }.fetch(texture.depth) # bits a texel
    u = corner & 0xFF
    v = (corner >> 8) & 0xFF

    assert_equal [texture.x, texture.y], [page_x + (u / texels_a_halfword), page_y + v]
    assert_operator u + texture.width, :<=, 256
    assert_operator v + texture.height, :<=, 256
  end
end
