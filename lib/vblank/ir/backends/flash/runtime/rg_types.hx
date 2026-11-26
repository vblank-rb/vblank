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
