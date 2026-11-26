/*
 * The game's arithmetic, in Haxe, giving exactly the answers lib/vblank/ir/int32.rb gives (the
 * JavaScript runtime's rg_int32.js, function for function).
 *
 * Every number a game keeps is a signed 32-bit whole number that wraps round at the ends, the way
 * the console's registers do. Haxe's Int is that on the Flash target, but a product of two of them is
 * worked out as a 64-bit float, which loses the low bits of a big one, so a product is put together
 * from 16-bit halves, and every sum is brought back to 32 bits. The cases IR::Int32 spells out
 * (dividing by nought, shifting by 32 or more) are each tested for.
 *
 * The game never writes +, <, / or any other operator on one of its numbers; it calls one of
 * these. A comparison is a number, 1 or 0, the way the game's conditions are.
 *
 * Each runtime file is a part of one class (see Flash#class_text): the functions are static, and every
 * file's can call every other's.
 */

static inline var RG_INT32_MIN:Int = -2147483648;
static inline var RG_INT32_MAX:Int = 2147483647;

static inline function rg_add(a:Int, b:Int):Int { return (a + b) | 0; }
static inline function rg_sub(a:Int, b:Int):Int { return (a - b) | 0; }
static inline function rg_neg(a:Int):Int { return (-a) | 0; }

/* The low 32 bits of a product. Each half of +a+ times +b+ is under 2**47, which a float holds exactly. */
static function rg_mul(a:Int, b:Int):Int {
  var low:Float = (a & 0xFFFF);
  var high:Float = (a >>> 16);
  return Std.int(low * b + (Std.int(high * b) << 16));
}

/* How far from nought: the lowest number has no positive partner, so it stays itself. */
static inline function rg_abs(a:Int):Int { return a < 0 ? (-a) | 0 : a; }

/* Held at the floor first and the ceiling second, so a floor above its ceiling gives the ceiling. */
static function rg_clamp(a:Int, min:Int, max:Int):Int {
  var floored = a < min ? min : a;
  return floored > max ? max : floored;
}

/* Dividing by nought gives what the console's divide routine gives: 1 or -1 following the
 * numerator's sign. The lowest number divided by -1 wraps back to itself. A quotient of two 32-bit
 * numbers is never close enough to a whole number for the float division to land on the wrong
 * side of it, so truncating the float is the whole-number answer. */
static function rg_div(a:Int, b:Int):Int {
  if (b == 0) return a < 0 ? -1 : 1;
  if (a == RG_INT32_MIN && b == -1) return RG_INT32_MIN;
  var quotient:Float = a / b;
  return Std.int(quotient < 0 ? Math.ceil(quotient) : Math.floor(quotient));
}

/* What is left over, with Ruby's meaning: it takes the sign of the divisor. */
static function rg_mod(a:Int, b:Int):Int {
  if (b == 0) return a;
  if (b == -1) return 0;
  var rem:Float = a - (b * Std.int(rg_div(a, b)));
  var remainder:Int = Std.int(rem);
  return remainder != 0 && (remainder < 0) != (b < 0) ? (remainder + b) | 0 : remainder;
}

/* The low 32 bits of a whole number held in a float, signed. */
static inline function rg_wrap(n:Float):Int { return Std.int(n); }

static inline var RG_SAFE:Float = 9007199254740992.0; /* 2**53: below it, a float holds every whole number */

/* --- numbers that hold a fraction ---
 *
 * Such a number is kept multiplied up by 2**bits, +bits+ 0 to 32. A product of two is worked out
 * whole and brought back down by rounding down. The float holds the product exactly whenever it is
 * under 2**53, which is nearly always; the rare bigger one is done in 64 bits. */
static function rg_mul_fix(a:Int, b:Int, bits:Int):Int {
  var product:Float = (a:Float) * b;
  if (product < RG_SAFE && product > -RG_SAFE) return rg_wrap(Math.floor(product / Math.pow(2, bits)));
  var whole = haxe.Int64.mul(haxe.Int64.ofInt(a), haxe.Int64.ofInt(b));
  return (whole >> bits).low;
}

/* Rounded down, as a float: Math.floor gives an Int, which would wrap a number past 32 bits. */
static function rg_floor(x:Float):Float {
  var whole:Float = x - (x % 1.0);
  return x < 0 && whole != x ? whole - 1 : whole;
}

/* The size of a number as a 64-bit one, which the lowest number, with no positive partner in 32 bits, needs. */
static function rg_magnitude(a:Int):haxe.Int64 {
  return a == RG_INT32_MIN ? haxe.Int64.make(0, 0x80000000) : haxe.Int64.ofInt(a < 0 ? -a : a);
}

/* Dividing two of them: the numerator moved up once more first, the answer truncated toward
 * nought and held at the ends of the range rather than wrapped (Int32.div_fix). Dividing by nought
 * gives a raw 1 or -1. */
static function rg_div_fix(a:Int, b:Int, bits:Int):Int {
  if (b == 0) return a < 0 ? -1 : 1;
  var den:Float = Math.abs(b);
  var num:Float = Math.abs(a) * Math.pow(2, bits);
  var q:Float;
  if (num < RG_SAFE / 2) {
    q = rg_floor(num / den);
    if (q * den > num) q--;
    else if ((q + 1) * den <= num) q++;
  } else if (num >= 4611686018427387904.0) {
    // 2**62 or more over a divisor under 2**32 is past the end of the range
    q = 4294967296.0;
  } else {
    var quotient = haxe.Int64.div(haxe.Int64.shl(rg_magnitude(a), bits), rg_magnitude(b));
    q = quotient.high == 0 && quotient.low >= 0 ? quotient.low : 4294967296.0;
  }
  var negative = (a < 0) != (b < 0) && num != 0;
  if (negative) return q >= 2147483648.0 ? RG_INT32_MIN : Std.int(-q);
  return q > RG_INT32_MAX ? RG_INT32_MAX : Std.int(q);
}

/* --- the bits themselves --- */

static inline function rg_and(a:Int, b:Int):Int { return a & b; }
static inline function rg_or(a:Int, b:Int):Int { return a | b; }
static inline function rg_xor(a:Int, b:Int):Int { return a ^ b; }
static inline function rg_not(a:Int):Int { return ~a; }

/* A shift count outside 0..31 pushes every bit off the end, so the number is emptied: 0 going
 * left, and going right whatever fills in behind. */
static function rg_shl(a:Int, count:Int):Int {
  if (count < 0 || count >= 32) return 0;
  return a << count;
}

static function rg_shr(a:Int, count:Int):Int {
  if (count < 0 || count >= 32) return a < 0 ? -1 : 0;
  return a >> count;
}

/* --- comparisons and conditions --- */

static inline function rg_lt(a:Int, b:Int):Int { return a < b ? 1 : 0; }
static inline function rg_le(a:Int, b:Int):Int { return a <= b ? 1 : 0; }
static inline function rg_gt(a:Int, b:Int):Int { return a > b ? 1 : 0; }
static inline function rg_ge(a:Int, b:Int):Int { return a >= b ? 1 : 0; }
static inline function rg_eq(a:Int, b:Int):Int { return a == b ? 1 : 0; }
static inline function rg_ne(a:Int, b:Int):Int { return a != b ? 1 : 0; }
/* Both sides were worked out before the call, as the interpreter works them out. */
static inline function rg_both(a:Int, b:Int):Int { return a != 0 && b != 0 ? 1 : 0; }
static inline function rg_either(a:Int, b:Int):Int { return a != 0 || b != 0 ? 1 : 0; }

/* --- keeping a number in a narrow slot: its low bits, read back with the slot's top bit as the
 * sign, so 200 in a byte reads back as -56 --- */

static inline function rg_to_byte(a:Int):Int { return (a << 24) >> 24; }
static inline function rg_to_half(a:Int):Int { return (a << 16) >> 16; }
