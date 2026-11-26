/*
 * A stretched column (Reference#exec_draw_column_at): one column of a picture painted at a height the game works out as it
 * runs. A port of the JavaScript runtime's rg_columns.js, function for function (rg_columns.c says how, rule for rule). A
 * runtime feature (backends/runtime_features.rb), joined into the runtime after rg_screen.hx for a game that draws a
 * column, so it reads the screen's own state and painters as if it were written there.
 *
 * The screen never asks it anything: the game calls rg_screen_column.
 */

/* Reference#exec_draw_column_at. The edges are worked out as floats: a top a game gives may be as far off as a number
 * goes. */
static function rg_screen_column(image:Int, slice:Int, x:Int, top:Int, height:Int, width:Int):Void {
  if (height <= 0) return;
  var art = picture_of(image);
  var column = clamp_number(slice, 0, art.width - 1);
  var step = Std.int((art.height * 65536.0) / height);
  var above:Float = top < 0 ? -(top:Float) : 0;
  var first = above > height ? height : Std.int(above);
  var room:Float = RG_SCREEN_HEIGHT - (top:Float);
  var past = room < height ? Std.int(room) : height;
  for (row in first...past) {
    var source = clamp_number(Std.int(rg_floor((row * 1.0 * step) / 65536)), 0, art.height - 1);
    var color = picture_pixel(art, source * art.width + column);
    if (color == RG_NOT_DRAWN) continue;
    for (across in 0...width) set_pixel(x + across, top + row, color);
  }
}
