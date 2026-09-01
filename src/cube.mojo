from std.math import sin, cos, min, max
from std.time import sleep
from std.python import Python, PythonObject
from std.algorithm.functional import vectorize

comptime DISTANCE_FROM_CAM: Float32 = 100.0
comptime K1: Float32 = 40.0
comptime INCREMENT_SPEED: Float32 = 0.6
comptime FRAME_DELAY: Float64 = 0.016

# Cube size relative to the subpixel buffer. Each cell is a 2x2 quadrant
# grid, but a quadrant subpixel is a tall rectangle (not square), so sizing
# uses pixel_width/2 — the same physical scale as pixel_height — not the
# raw quadrant column count.
comptime CUBE_SIZE_RATIO: Float32 = 0.23

# Lane count for the vectorized fire/corona/buffer-fill passes.
comptime SIMD_WIDTH = 8

# 3-tap blur weights used to both cool and spread intensity as it rises off
# the cube's surface.
comptime FIRE_CENTER_W: Float32 = 0.55
comptime FIRE_SIDE_W: Float32 = 0.20
comptime FIRE_COOL: Float32 = 0.04

# Directional lighting — each face's normal is rotated along with the cube
# and lit like a headlamp at the camera, so whichever faces currently turn
# toward the viewer blaze bright and the ones turning away fall into a dim
# ember glow. This is what actually separates face from face: distinct,
# continuously shifting light/shadow as the cube tumbles, not a fixed tier.
comptime LIGHT_FLOOR: Float32 = 0.16  # shadow side still glows, never goes fully dark

# Surface turbulence — modulates each sample point's heat so the cube reads
# as roiling plasma with dark sunspot patches instead of flat-shaded faces.
comptime TURB_FLOOR: Float32 = 0.6  # darkest spots still burn a solid red

# Corona — a bright halo hugging the cube's silhouette on every side (not
# just rising upward like the flame trail), the way a sun's corona wraps
# its disk. Recomputed fresh from `fire` each frame via repeated isotropic
# box blurs (never fed back into `fire` itself, so it can't runaway-bloom).
comptime CORONA_STRENGTH: Float32 = 1.1


@fieldwise_init
struct Color(Copyable, Movable, ImplicitlyCopyable):
    var r: UInt8
    var g: UInt8
    var b: UInt8


@fieldwise_init
struct Vec3(Copyable, Movable, ImplicitlyCopyable):
    var x: Float32
    var y: Float32
    var z: Float32


@fieldwise_init
struct RotationMatrix(Copyable, Movable, ImplicitlyCopyable):
    # Precomputed 3x3 rotation matrix for Euler angles (a, b, c), built once
    # per frame instead of re-deriving sin/cos(a, b, c) from scratch for
    # every point sampled that frame — see `from_angles`.
    var m00: Float32
    var m01: Float32
    var m02: Float32
    var m10: Float32
    var m11: Float32
    var m12: Float32
    var m20: Float32
    var m21: Float32
    var m22: Float32

    @staticmethod
    def from_angles(a: Float32, b: Float32, c: Float32) -> Self:
        var ca = cos(a)
        var sa = sin(a)
        var cb = cos(b)
        var sb = sin(b)
        var cc = cos(c)
        var sc = sin(c)
        return Self(
            cb * cc, sa * sb * cc + ca * sc, sa * sc - ca * sb * cc,
            -cb * sc, ca * cc - sa * sb * sc, sa * cc + ca * sb * sc,
            sb, -sa * cb, ca * cb,
        )

    def apply(self, v: Vec3) -> Vec3:
        return Vec3(
            self.m00 * v.x + self.m01 * v.y + self.m02 * v.z,
            self.m10 * v.x + self.m11 * v.y + self.m12 * v.z,
            self.m20 * v.x + self.m21 * v.y + self.m22 * v.z,
        )


def surface_turbulence(point: Vec3, a: Float32, b: Float32, c: Float32) -> Float32:
    # Three independent octaves multiplied together: each is a smooth [0,1]
    # wave, but the product is patchy — bright cores, dark sunspot gaps —
    # and slowly churns over time via the (already-animating) rotation
    # angles, so the plasma texture never repeats or freezes.
    var n1 = 0.5 + 0.5 * sin(point.x * 0.45 + point.z * 0.30 + a * 2.5)
    var n2 = 0.5 + 0.5 * sin(point.y * 0.50 - point.x * 0.20 + b * 3.1)
    var n3 = 0.5 + 0.5 * cos((point.x + point.y + point.z) * 0.25 - c * 5.0)
    return n1 * n2 * n3


def face_light(rot: RotationMatrix, normal: Vec3) -> Float32:
    # A face pointing toward the camera (-z, since the cube sits out at +z)
    # is fully lit, one pointing away falls to the ambient floor. Every
    # point on a given face shares this exact value — callers compute it
    # once per face per frame, not once per sample point.
    var rotated = rot.apply(normal)
    var facing = -rotated.z
    if facing < 0.0:
        facing = 0.0
    if facing > 1.0:
        facing = 1.0
    return LIGHT_FLOOR + (1.0 - LIGHT_FLOOR) * facing


def plot_surface(
    mut fire: List[Float32],
    mut z_buffer: List[Float32],
    width: Int,
    pixel_height: Int,
    point: Vec3,
    light: Float32,
    a: Float32,
    b: Float32,
    c: Float32,
    rot: RotationMatrix,
):
    var rotated = rot.apply(point)
    var z = rotated.z + DISTANCE_FROM_CAM

    var ooz = 1.0 / z
    # Each quadrant subpixel is a tall rectangle, not square (2 horizontal
    # steps span one character cell's width, but 2 vertical steps span its
    # full height, which is ~2x its width) — double the x term to compensate,
    # same fix the original cube.c used for the terminal's cell aspect ratio.
    var xp = Int(Float32(width) / 2 + K1 * ooz * rotated.x * 2.0)
    var yp = Int(Float32(pixel_height) / 2 + K1 * ooz * rotated.y)

    var idx = xp + yp * width
    if idx >= 0 and idx < width * pixel_height:
        if ooz > z_buffer[idx]:
            z_buffer[idx] = ooz
            var turb = surface_turbulence(point, a, b, c)
            var shade = TURB_FLOOR + (1.0 - TURB_FLOOR) * turb
            fire[idx] = light * shade


def draw_cube(
    mut fire: List[Float32],
    mut z_buffer: List[Float32],
    width: Int,
    pixel_height: Int,
    cube_width: Float32,
    a: Float32,
    b: Float32,
    c: Float32,
):
    var rot = RotationMatrix.from_angles(a, b, c)

    # Each face's light term is constant across all of its sample points —
    # compute it once per face here, not once per point in the hot loop.
    var light1 = face_light(rot, Vec3(0.0, 0.0, -1.0))
    var light2 = face_light(rot, Vec3(1.0, 0.0, 0.0))
    var light3 = face_light(rot, Vec3(-1.0, 0.0, 0.0))
    var light4 = face_light(rot, Vec3(0.0, 0.0, 1.0))
    var light5 = face_light(rot, Vec3(0.0, -1.0, 0.0))
    var light6 = face_light(rot, Vec3(0.0, 1.0, 0.0))

    var cube_x = -cube_width
    while cube_x < cube_width:
        var cube_y = -cube_width
        while cube_y < cube_width:
            plot_surface(fire, z_buffer, width, pixel_height, Vec3(cube_x, cube_y, -cube_width), light1, a, b, c, rot)
            plot_surface(fire, z_buffer, width, pixel_height, Vec3(cube_width, cube_y, cube_x), light2, a, b, c, rot)
            plot_surface(fire, z_buffer, width, pixel_height, Vec3(-cube_width, cube_y, -cube_x), light3, a, b, c, rot)
            plot_surface(fire, z_buffer, width, pixel_height, Vec3(-cube_x, cube_y, cube_width), light4, a, b, c, rot)
            plot_surface(fire, z_buffer, width, pixel_height, Vec3(cube_x, -cube_width, -cube_y), light5, a, b, c, rot)
            plot_surface(fire, z_buffer, width, pixel_height, Vec3(cube_x, cube_width, cube_y), light6, a, b, c, rot)
            cube_y += INCREMENT_SPEED
        cube_x += INCREMENT_SPEED


def step_fire(mut fire: List[Float32], width: Int, pixel_height: Int):
    # Rise + cool + blur one row per frame, vectorized across each row's
    # interior via the stdlib's `vectorize` (std.algorithm.functional) —
    # it calls the closure with a shrunk `w` for whatever remainder doesn't
    # divide evenly by SIMD_WIDTH, so there's no separate scalar tail loop
    # to hand-maintain. The two edge pixels still use scalar boundary-
    # replicated blending, since they sit outside the interior range.
    var ptr = fire.unsafe_ptr()
    for y in range(1, pixel_height):
        var src_row = y * width
        var dst_row = (y - 1) * width

        var lv = fire[src_row] * (FIRE_CENTER_W + FIRE_SIDE_W) + fire[src_row + 1] * FIRE_SIDE_W - FIRE_COOL
        fire[dst_row] = max(lv, Float32(0.0))

        def blur_row[w: Int](idx: Int) {imm ptr, imm src_row, imm dst_row}:
            var base = src_row + 1 + idx
            var center = ptr.unsafe_load[width=w](base)
            var left = ptr.unsafe_load[width=w](base - 1)
            var right = ptr.unsafe_load[width=w](base + 1)
            var blended = center * FIRE_CENTER_W + left * FIRE_SIDE_W + right * FIRE_SIDE_W - FIRE_COOL
            ptr.unsafe_store[width=w](dst_row + 1 + idx, blended.clamp(0.0, 1.0))

        vectorize[SIMD_WIDTH](width - 2, blur_row)

        var rv = fire[src_row + width - 1] * (FIRE_CENTER_W + FIRE_SIDE_W) + fire[src_row + width - 2] * FIRE_SIDE_W - FIRE_COOL
        fire[dst_row + width - 1] = max(rv, Float32(0.0))


def box_blur_pass(src: List[Float32], mut dst: List[Float32], width: Int, pixel_height: Int):
    # Isotropic 3x3 box blur (center weighted double), SIMD-vectorized across
    # each row's interior via `vectorize` (auto-handles the tail — see
    # step_fire); edges fall back to scalar boundary-replicated blending.
    # Every element of `dst` is written unconditionally, so callers never
    # need to zero it first.
    var sptr = src.unsafe_ptr()
    var dptr = dst.unsafe_ptr()
    for y in range(pixel_height):
        var row = y * width
        var row_above = row - width
        if y == 0:
            row_above = row
        var row_below = row + width
        if y == pixel_height - 1:
            row_below = row

        var lv = (
            src[row_above] * 2.0 + src[row_above + 1] +
            src[row] * 3.0 + src[row + 1] +
            src[row_below] * 2.0 + src[row_below + 1]
        ) / 10.0
        dst[row] = lv

        def blur_row[w: Int](idx: Int) {imm sptr, imm dptr, imm row_above, imm row, imm row_below}:
            var above = sptr.unsafe_load[width=w](row_above + 1 + idx - 1) + sptr.unsafe_load[width=w](row_above + 1 + idx) + sptr.unsafe_load[width=w](row_above + 1 + idx + 1)
            var mid = sptr.unsafe_load[width=w](row + 1 + idx - 1) + sptr.unsafe_load[width=w](row + 1 + idx) * 2.0 + sptr.unsafe_load[width=w](row + 1 + idx + 1)
            var below = sptr.unsafe_load[width=w](row_below + 1 + idx - 1) + sptr.unsafe_load[width=w](row_below + 1 + idx) + sptr.unsafe_load[width=w](row_below + 1 + idx + 1)
            var total = (above + mid + below) / 10.0
            dptr.unsafe_store[width=w](row + 1 + idx, total.clamp(0.0, 1.0))

        vectorize[SIMD_WIDTH](width - 2, blur_row)

        var rv = (
            src[row_above + width - 2] + src[row_above + width - 1] * 2.0 +
            src[row + width - 2] + src[row + width - 1] * 3.0 +
            src[row_below + width - 2] + src[row_below + width - 1] * 2.0
        ) / 10.0
        dst[row + width - 1] = rv


def compute_corona(
    fire: List[Float32],
    mut corona_a: List[Float32],
    mut corona_b: List[Float32],
    width: Int,
    pixel_height: Int,
):
    # Three passes widen the halo (each box blur pass ~doubles its reach,
    # same trick as approximating a Gaussian blur with repeated box blurs).
    # `corona_a`/`corona_b` are caller-owned scratch buffers reused every
    # frame — box_blur_pass fully overwrites its destination, so there's
    # nothing to zero and nothing to reallocate. The final pass leaves the
    # result in `corona_a`.
    box_blur_pass(fire, corona_a, width, pixel_height)
    box_blur_pass(corona_a, corona_b, width, pixel_height)
    box_blur_pass(corona_b, corona_a, width, pixel_height)


def lerp_color(lo: Color, hi: Color, f: Float32) -> Color:
    return Color(
        UInt8(Float32(lo.r) + (Float32(hi.r) - Float32(lo.r)) * f),
        UInt8(Float32(lo.g) + (Float32(hi.g) - Float32(lo.g)) * f),
        UInt8(Float32(lo.b) + (Float32(hi.b) - Float32(lo.b)) * f),
    )


def fire_color(t_in: Float32) -> Color:
    # Blackbody-style ramp. Only the very bottom stays charcoal/black; it
    # reaches saturated red quickly and spends most of its range blazing
    # through orange/yellow into a white-hot core, for a bright flame with
    # black/red only at the coolest edges (not a smoldering, dim look).
    var t = t_in
    if t < 0.0:
        t = 0.0
    if t > 1.0:
        t = 1.0

    if t < 0.10:
        return lerp_color(Color(0, 0, 0), Color(70, 0, 0), t / 0.10)
    elif t < 0.28:
        return lerp_color(Color(70, 0, 0), Color(210, 30, 0), (t - 0.10) / 0.18)
    elif t < 0.48:
        return lerp_color(Color(210, 30, 0), Color(255, 95, 0), (t - 0.28) / 0.20)
    elif t < 0.68:
        return lerp_color(Color(255, 95, 0), Color(255, 160, 0), (t - 0.48) / 0.20)
    elif t < 0.85:
        return lerp_color(Color(255, 160, 0), Color(255, 225, 90), (t - 0.68) / 0.17)
    else:
        return lerp_color(Color(255, 225, 90), Color(255, 255, 235), (t - 0.85) / 0.15)


def quadrant_glyph(pattern: Int) -> String:
    # pattern bit0=top-left, bit1=top-right, bit2=bottom-left, bit3=bottom-right
    if pattern == 0:
        return " "
    elif pattern == 1:
        return "▘"
    elif pattern == 2:
        return "▝"
    elif pattern == 3:
        return "▀"
    elif pattern == 4:
        return "▖"
    elif pattern == 5:
        return "▌"
    elif pattern == 6:
        return "▞"
    elif pattern == 7:
        return "▛"
    elif pattern == 8:
        return "▗"
    elif pattern == 9:
        return "▚"
    elif pattern == 10:
        return "▐"
    elif pattern == 11:
        return "▜"
    elif pattern == 12:
        return "▄"
    elif pattern == 13:
        return "▙"
    elif pattern == 14:
        return "▟"
    else:
        return "█"


def render_frame(fire: List[Float32], corona: List[Float32], term_width: Int, term_height: Int, pixel_width: Int) -> String:
    # Each terminal cell packs a 2x2 quadrant of subpixels. A glyph can only
    # show 2 colors per cell, so the 4 values split into a "bright" and
    # "dim" group (above/below their own mean) — fg/bg take each group's
    # average, and the glyph picks out which quadrants are in the bright one.
    var out = String()
    for row in range(term_height):
        if row != 0:
            out += "\n"
        var top_row = (row * 2) * pixel_width
        var bot_row = (row * 2 + 1) * pixel_width
        for col in range(term_width):
            var tl_i = top_row + col * 2
            var tr_i = tl_i + 1
            var bl_i = bot_row + col * 2
            var br_i = bl_i + 1

            var tl = max(fire[tl_i], corona[tl_i] * CORONA_STRENGTH)
            var tr = max(fire[tr_i], corona[tr_i] * CORONA_STRENGTH)
            var bl = max(fire[bl_i], corona[bl_i] * CORONA_STRENGTH)
            var br = max(fire[br_i], corona[br_i] * CORONA_STRENGTH)

            var mean = (tl + tr + bl + br) / 4.0

            var pattern = 0
            var hi_sum: Float32 = 0.0
            var hi_count = 0
            var lo_sum: Float32 = 0.0
            var lo_count = 0

            if tl > mean:
                pattern += 1
                hi_sum += tl
                hi_count += 1
            else:
                lo_sum += tl
                lo_count += 1
            if tr > mean:
                pattern += 2
                hi_sum += tr
                hi_count += 1
            else:
                lo_sum += tr
                lo_count += 1
            if bl > mean:
                pattern += 4
                hi_sum += bl
                hi_count += 1
            else:
                lo_sum += bl
                lo_count += 1
            if br > mean:
                pattern += 8
                hi_sum += br
                hi_count += 1
            else:
                lo_sum += br
                lo_count += 1

            var fg_t = mean
            if hi_count > 0:
                fg_t = hi_sum / Float32(hi_count)
            var bg_t = mean
            if lo_count > 0:
                bg_t = lo_sum / Float32(lo_count)

            var fg = fire_color(fg_t)
            var bg = fire_color(bg_t)

            out += "\x1b[38;2;"
            out += String(Int(fg.r)) + ";" + String(Int(fg.g)) + ";" + String(Int(fg.b))
            out += ";48;2;"
            out += String(Int(bg.r)) + ";" + String(Int(bg.g)) + ";" + String(Int(bg.b))
            out += "m"
            out += quadrant_glyph(pattern)
    out += "\x1b[0m"
    return out


def main() raises:
    var shutil = Python.import_module("shutil")

    # Embedding CPython installs its own SIGINT handler, which only ever
    # gets checked while the interpreter's own eval loop is running. This
    # program spends almost all of its time in native Mojo code between the
    # brief per-frame `shutil.get_terminal_size()` call, so Ctrl+C would
    # otherwise sit pending and never actually fire. Restore the OS default
    # (immediate termination) instead.
    var signal = Python.import_module("signal")
    signal.signal(signal.SIGINT, signal.SIG_DFL)

    var a: Float32 = 0.0
    var b: Float32 = 0.0
    var c: Float32 = 0.0

    var fire = List[Float32]()
    var z_buffer = List[Float32]()
    var corona_a = List[Float32]()
    var corona_b = List[Float32]()

    var prev_width = 0
    var prev_height = 0

    print("\x1b[2J", end="")
    while True:
        var size = shutil.get_terminal_size()
        var width = Int(py=size.columns)
        var height = Int(py=size.lines)
        var pixel_width = width * 2
        var pixel_height = height * 2

        if width != prev_width or height != prev_height:
            var n = pixel_width * pixel_height
            fire = List[Float32](length=n, fill=0.0)
            z_buffer = List[Float32](length=n, fill=0.0)
            corona_a = List[Float32](length=n, fill=0.0)
            corona_b = List[Float32](length=n, fill=0.0)
            prev_width = width
            prev_height = height
            print("\x1b[2J", end="")

        var cube_width = min(Float32(pixel_width) / 2.0, Float32(pixel_height)) * CUBE_SIZE_RATIO

        step_fire(fire, pixel_width, pixel_height)

        Span(z_buffer).fill(0.0)
        draw_cube(fire, z_buffer, pixel_width, pixel_height, cube_width, a, b, c)

        compute_corona(fire, corona_a, corona_b, pixel_width, pixel_height)

        print("\x1b[H", end="")
        print(render_frame(fire, corona_a, width, height, pixel_width), end="", flush=True)

        a += 0.05
        b += 0.05
        c += 0.01
        sleep(FRAME_DELAY)
