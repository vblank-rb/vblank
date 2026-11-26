/*
 * The classes the runtime keeps things in. Unlike every other runtime file, which is a part of the
 * class Rg, this one stands at the top of the module, after the class (see Flash#class_text).
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
