/*
 * The state image (the JavaScript runtime's rg_state.js) is not made in Flash yet. The game writes its
 * own part of it, so the functions it calls are here, and stop the game in plain words if anything ever
 * reaches them: nothing in the Flash runtime asks for a state to be written or read.
 */

static function rg_state_refuse():Void {
  rg_fault("the Flash build does not write or read a state image yet");
}

static function rg_state_number(name:String, value:Int):Int {
  rg_state_refuse();
  return value;
}

static function rg_state_list(name:String, list:RgList):Void { rg_state_refuse(); }

static function rg_patch_visit_state(name:String, buffer:Int, width:Int, height:Int):Void { rg_state_refuse(); }
