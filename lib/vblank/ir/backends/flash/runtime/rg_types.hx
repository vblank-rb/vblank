/*
 * The classes the runtime keeps things in. Unlike every other runtime file, which is a part of the
 * class Main, this one stands at the top of the module, after the class (see Flash#class_text).
 */

/* A game's list, as rg_list.hx keeps one: the items in an array as long as the capacity, used as a ring. */
class RgList {
  public var items:Vector<Int>;
  public var capacity:Int;
  public var width:Int;
  public var front:Int;
  public var length:Int;
  public var name:String;

  public function new(capacity:Int, width:Int, name:String) {
    this.items = new Vector<Int>(capacity < 1 ? 1 : capacity);
    this.capacity = capacity;
    this.width = width;
    this.front = 0;
    this.length = 0;
    this.name = name;
  }
}

/* The game stopped, on purpose or because it went wrong. Thrown rather than returned, so it comes out of
 * however deep in the game's routines it happened, and the driver catches it. */
class RgStopped {
  public var message:String;
  public var wentWrong:Bool;

  public function new(message:String, wentWrong:Bool) {
    this.message = message;
    this.wentWrong = wentWrong;
  }
}

/* One timer: whether it has ever been started, whether it is running, its rate, its frames a second, and how
 * far it has ticked since it was last started, in frames_a_second-ths of a tick. */
class RgTimer {
  public var started:Int = 0;
  public var running:Int = 0;
  public var ticksASecond:Int = 0;
  public var framesASecond:Int = 0;
  public var parts:Float = 0;

  public function new() {}
}

/* A sprite as the game last drew it: whose it is, which of its pictures, and where. */
class RgDrawnSprite {
  public var name:Int;
  public var picture:Int;
  public var x:Int;
  public var y:Int;

  public function new(name:Int, picture:Int, x:Int, y:Int) {
    this.name = name;
    this.picture = picture;
    this.x = x;
    this.y = y;
  }
}

/* The filter the finished picture is read through while a fade or a light changes a colour: the colour shown
 * for each value a cell can hold (-1 where it is not worked out yet, which +fill+ works out), and where it
 * reaches (see runtime_features.rb). */
class RgShownFilter {
  public var table:Vector<Int>;
  public var everywhere:Bool;
  public var rows:Vector<Int>;
  public var remix:Bool;
  public var fill:Int -> Int;

  public function new(table:Vector<Int>, everywhere:Bool, rows:Vector<Int>, remix:Bool, fill:Int -> Int) {
    this.table = table;
    this.everywhere = everywhere;
    this.rows = rows;
    this.remix = remix;
    this.fill = fill;
  }
}

/* The box a background is held to: whether it is held to one, and its left, top, and the column and row just past it. */
class RgBox {
  public var held:Int = 0;
  public var left:Int = 0;
  public var top:Int = 0;
  public var right:Int = 0;
  public var bottom:Int = 0;

  public function new() {}

  public function copy():RgBox {
    var made = new RgBox();
    made.held = held;
    made.left = left;
    made.top = top;
    made.right = right;
    made.bottom = bottom;
    return made;
  }
}

/* A background's own copy of the cells of a map (or none, while it shows the declared one), and whose map it is a copy of. */
class RgCells {
  public var which:Int = 0;
  public var of:Int = 0;
  public var cells:Vector<Int> = null;

  public function new() {}
}

/* Where a background's window sits. */
class RgScroll {
  public var x:Int = 0;
  public var y:Int = 0;

  public function new(x:Int = 0, y:Int = 0) {
    this.x = x;
    this.y = y;
  }
}

/* What a background is turned by. */
class RgTurn {
  public var turned:Int = 0;
  public var angle:Int = 0;
  public var size:Int = 0;
  public var pivot_x:Int = 0;
  public var pivot_y:Int = 0;

  public function new() {}
}

/* A change to a cell waiting to be shown. */
class RgHeldTile {
  public var background:Int;
  public var col:Int;
  public var row:Int;
  public var tile:Int;

  public function new(background:Int, col:Int, row:Int, tile:Int) {
    this.background = background;
    this.col = col;
    this.row = row;
    this.tile = tile;
  }
}

/* One picture as the screen reads it (see picture_of). */
class RgArt {
  public var pixels:Vector<Int>;
  public var start:Int;
  public var width:Int;
  public var height:Int;
  public var colors:Int;

  public function new(pixels:Vector<Int>, start:Int, width:Int, height:Int, colors:Int) {
    this.pixels = pixels;
    this.start = start;
    this.width = width;
    this.height = height;
    this.colors = colors;
  }
}

/* A sprite as it is put on screen: which, its picture, where, its level, how it is turned, and the slices of it a crowded
 * line leaves out (each [line, piece, first column left out]), or none. */
class RgPlaced {
  public var sprite:Int;
  public var image:Int;
  public var x:Int;
  public var y:Int;
  public var level:Int;
  public var see_through:Int;
  public var fade_place:Int;
  public var turned:Int;
  public var angle:Int;
  public var size:Int;
  public var resizes:Int;
  public var cuts:Array<Array<Int>> = null;

  public function new(sprite:Int, image:Int, x:Int, y:Int, level:Int, see_through:Int, fade_place:Int, turned:Int, angle:Int, size:Int, resizes:Int) {
    this.sprite = sprite;
    this.image = image;
    this.x = x;
    this.y = y;
    this.level = level;
    this.see_through = see_through;
    this.fade_place = fade_place;
    this.turned = turned;
    this.angle = angle;
    this.size = size;
    this.resizes = resizes;
  }
}

/* Where a sprite was last drawn straight onto the picture (Reference @obj_prev). */
class RgDrawnPlace {
  public var drawn:Int = 0;
  public var x:Int = 0;
  public var y:Int = 0;

  public function new() {}
}

/* A piece of a sprite's picture, kept for a crowded line (rg_sprites.c's line pieces). */
class RgLinePiece {
  public var sprite:RgPlaced;
  public var piece:Int;
  public var left:Int;
  public var width:Int;
  public var from:Int;

  public function new(sprite:RgPlaced, piece:Int, left:Int, width:Int, from:Int) {
    this.sprite = sprite;
    this.piece = piece;
    this.left = left;
    this.width = width;
    this.from = from;
  }
}

/* A loudness that fades: now, the samples it holds a step, the samples left of this step, and whether it swells. */
class RgLoudness {
  public var volume:Int;
  public var hold_samples:Int;
  public var left:Int;
  public var up:Bool;

  public function new(volume:Int, hold_samples:Int, left:Int, up:Bool) {
    this.volume = volume;
    this.hold_samples = hold_samples;
    this.left = left;
    this.up = up;
  }
}

/* A square voice of the console. */
class RgSquare {
  public var wave_ticks:Int = 0;
  public var eighths_high:Int = 0;
  public var loudness:RgLoudness = new RgLoudness(0, 0, 0, false);
  public var eighth:Int = 0;
  public var eighth_progress:Int = 0;
  public var slide:Int = 0;
  public var slide_left:Int = 0;
  public var slid_ticks:Int = 0;

  public function new() {}
}

/* One voice of the mixer. */
class RgMixVoice {
  public var sounding:Int = 0;
  public var owner:Int = 0;
  public var effect:Int = 0;
  public var lane:Int = 0;
  public var rank:Int = 0;
  public var loops:Int = 0;
  public var ticket:Int = 0;
  public var recording:Int = 0;
  public var position:Int = 0;
  public var fraction:Int = 0;
  public var step:Int = 0;
  public var back:Int = 0;
  public var loudness:Int = 0;
  public var gain:Int = 0;
  public var ramp:Int = 0;
  public var shaped:Int = 0;
  public var level:Int = 0;
  public var phase:Int = 0;
  public var attack:Int = 0;
  public var decay:Int = 0;
  public var sustain:Int = 0;
  public var release:Int = 0;

  public function new() {}
}
