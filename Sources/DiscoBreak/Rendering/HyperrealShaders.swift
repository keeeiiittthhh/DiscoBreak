/// GPU code for the third ball. Compiled at runtime by `HyperrealPainter`, which
/// keeps the build to plain `swift build` — no Xcode project, no metallib step.
///
/// World space is the ball's own: units of one ball radius, origin at its centre,
/// +y up, +z toward the viewer. The screen is the wall the light lands on, and it
/// stands `wall` radii behind the ball. Screen space is points, origin
/// bottom-left, same as the overlay window.
///
/// Eight draws per frame, every one of them instanced over the same tile buffer
/// (or a single quad), so the CPU cost is fixed no matter how many mirrors there are:
///
///     dim     darkens the whole screen behind the show    over
///     shadow  the ball blocking the lamp, on the wall     over
///     beams   faint haze shafts from ball to wall         additive
///     specks  the light itself, landing on the screen     additive
///     cord    what the ball hangs from                    over
///     core    the dark sphere the tiles are glued to      over
///     tiles   the mirrors                                 over
///     glints  soft bloom on the brightest mirrors only    additive
enum HyperrealShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Tile {
    float4 normal;   // xyz: where it sits on the unit sphere. w: half-width, radii
    float4 mirror;   // xyz: which way it faces, a hair off true. w: brightness
    float4 tint;     // rgb: warm or cool cast of what it throws. w: flicker phase
};

struct Frame {
    float2 viewSize;
    float2 centre;
    float  radius;
    float  theta;
    float  time;
    float  opacity;
    float  eye;
    float  wall;
    float  intensity;
    float  hasCamera;
    float4 light;      // xyz: toward the lamp. w: haze strength, 0 = no beams
    float2 pivot;
    float  cordWidth;
    float  dim;        // 0 = leave the screen alone
};

constant float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };

// Every corner of a skipped instance lands on the same point: zero area, and the
// rasteriser drops it before any pixel work.
constant float4 nowhere = float4(-2, -2, 0, 1);

// The turn. Same sense as ReflectionSolver, so all three balls spin the same way.
static float3 spin(float3 v, float a) {
    float c = cos(a), s = sin(a);
    return float3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c);
}

static float4 clip(float2 p, constant Frame& f) {
    return float4(p / f.viewSize * 2.0 - 1.0, 0.0, 1.0);
}

// A little perspective, so the tiles near the rim foreshorten like a real sphere.
static float2 project(float3 p, constant Frame& f) {
    return f.centre + p.xy * (f.eye / (f.eye - p.z)) * f.radius;
}

static float3 towardEye(float3 p, constant Frame& f) {
    return normalize(float3(0.0, 0.0, f.eye) - p);
}

// MARK: - The light each mirror throws

struct Speck {
    bool   lit;
    float2 from;    // on the ball, screen points
    float2 at;      // on the wall, screen points
    float2 dir;     // which way the ellipse stretches
    float  major;
    float  minor;
    float3 light;
};

// Reflect the lamp in this tile and follow the ray to the wall. A ray that hits
// the wall at a slant smears into an ellipse; a longer throw is wider and dimmer.
static Speck speckFor(Tile t, constant Frame& f) {
    Speck s;
    s.lit = false;
    float3 L = f.light.xyz;
    float3 n = normalize(spin(t.mirror.xyz, f.theta));
    float facing = dot(n, L);
    if (facing < 0.02) return s;                  // turned away from the lamp
    float3 r = 2.0 * facing * n - L;
    if (r.z > -0.03) return s;                    // heading into the room, not the wall

    float3 o = spin(t.normal.xyz, f.theta);
    float travel = (-f.wall - o.z) / r.z;
    if (travel <= 0.0) return s;

    s.at = f.centre + (o.xy + r.xy * travel) * f.radius;
    s.from = project(o, f);
    // Each speck is the image of one small square mirror, so its size is set in
    // points, not by the ball: a big ball has more mirrors, not bigger ones. A
    // slanted throw stretches it, but only so far — past that a real one
    // fades out before it smears.
    s.minor = clamp(0.03 * travel * f.radius, 5.0, 14.0);
    s.major = s.minor * min(2.2, 1.0 / max(0.2, -r.z));
    float len = length(r.xy);
    s.dir = len > 1e-4 ? r.xy / len : float2(1.0, 0.0);

    // Each tile shimmers on its own clock, as a real one does when the ball
    // wobbles on its motor.
    float flicker = 0.8 + 0.2 * sin(f.time * (2.0 + 3.0 * t.tint.w) + t.tint.w * 6.2832);
    float power = 3.0 * facing / (1.0 + 0.1 * travel * travel) * flicker * f.intensity;
    // Rolls off instead of clipping, so the Light intensity slider brightens
    // specks without ever blowing them out to white.
    power = 0.8 * (1.0 - exp(-power)) * f.opacity;
    s.light = t.tint.rgb * power;
    s.lit = power > 0.003;
    return s;
}

struct Glow {
    float4 position [[position]];
    float2 uv;
    float3 light;
};

vertex Glow speckVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        const device Tile* tiles [[buffer(0)]],
                        constant Frame& f [[buffer(1)]]) {
    Glow o;
    o.position = nowhere; o.uv = 0; o.light = 0;
    Speck s = speckFor(tiles[iid], f);
    if (!s.lit) return o;

    float2 c = corners[vid] * 1.15;               // room for the soft edge to fade out
    float2 side = float2(-s.dir.y, s.dir.x);
    o.position = clip(s.at + s.dir * c.x * s.major + side * c.y * s.minor, f);
    o.uv = c;
    o.light = s.light;
    return o;
}

fragment float4 speckFragment(Glow in [[stage_in]]) {
    // A rounded square with a soft rim, like the patch of light a small
    // square mirror really throws, rather than a round blur.
    float2 a = abs(in.uv);
    float d = pow(pow(a.x, 4.0) + pow(a.y, 4.0), 0.25);
    float glow = (1.0 - smoothstep(0.3, 1.1, d)) * (0.85 + 0.15 * (1.0 - d));
    float3 c = min(in.light * glow, float3(1.0));
    // Real alpha, like Mirror tiles' spots. With alpha 0 the light only adds to
    // what's already on screen, so it vanishes on a white window and the window
    // server can drop it altogether over other apps. Alpha as bright as the
    // brightest channel keeps it valid premultiplied colour and lets it show on anything.
    return float4(c, max(c.r, max(c.g, c.b)));
}

// The same ray again, seen side-on through a little haze.
vertex Glow beamVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       const device Tile* tiles [[buffer(0)]],
                       constant Frame& f [[buffer(1)]]) {
    Glow o;
    o.position = nowhere; o.uv = 0; o.light = 0;
    if (f.light.w <= 0.0) return o;
    Speck s = speckFor(tiles[iid], f);
    if (!s.lit) return o;

    float2 d = s.at - s.from;
    float len = length(d);
    if (len < 1.0) return o;
    float2 dir = d / len;
    float2 side = float2(-dir.y, dir.x);
    float2 c = corners[vid];
    float along = c.y * 0.5 + 0.5;                // 0 at the ball, 1 at the wall
    float halfWidth = mix(1.0, s.minor * 0.6, along);
    o.position = clip(mix(s.from, s.at, along) + side * c.x * halfWidth, f);
    o.uv = float2(c.x, along);
    o.light = s.light * f.light.w;
    return o;
}

fragment float4 beamFragment(Glow in [[stage_in]]) {
    float across = 1.0 - in.uv.x * in.uv.x;
    float along = (1.0 - in.uv.y) * smoothstep(0.0, 0.06, in.uv.y);
    float3 c = min(in.light * across * along, float3(1.0));
    return float4(c, max(c.r, max(c.g, c.b)));      // real alpha, as for the specks
}

// MARK: - The cord

struct Cord {
    float4 position [[position]];
    float across;      // points from the centre line
};

vertex Cord cordVertex(uint vid [[vertex_id]], constant Frame& f [[buffer(1)]]) {
    float2 toBall = f.centre - f.pivot;
    float len = length(toBall);
    float2 dir = len > 0.0 ? toBall / len : float2(0.0, -1.0);
    float2 bottom = f.centre - dir * f.radius * 0.97;
    float2 side = float2(-dir.y, dir.x);
    float2 c = corners[vid];
    float halfWidth = f.cordWidth * 0.5 + 1.0;    // one point of feather for smooth edges
    Cord o;
    o.position = clip(mix(f.pivot, bottom, c.y * 0.5 + 0.5) + side * c.x * halfWidth, f);
    o.across = c.x * halfWidth;
    return o;
}

fragment float4 cordFragment(Cord in [[stage_in]], constant Frame& f [[buffer(0)]]) {
    float a = saturate(f.cordWidth * 0.5 + 0.5 - abs(in.across)) * f.opacity;
    float shade = mix(0.6, 0.2, saturate(in.across / f.cordWidth + 0.5));   // lit from the left
    return float4(float3(shade) * a, a);
}

// MARK: - The ball

struct Disc {
    float4 position [[position]];
    float2 uv;
};

// The sphere under the mirrors. Where tiles don't quite meet, this is what shows.
vertex Disc coreVertex(uint vid [[vertex_id]], constant Frame& f [[buffer(1)]]) {
    float2 c = corners[vid] * 1.04;
    float silhouette = f.eye / sqrt(f.eye * f.eye - 1.0);   // perspective makes it a touch wider than one radius
    Disc o;
    o.position = clip(f.centre + c * f.radius * silhouette, f);
    o.uv = c;
    return o;
}

fragment float4 coreFragment(Disc in [[stage_in]], constant Frame& f [[buffer(0)]]) {
    float d = length(in.uv);
    float aa = fwidth(d);
    float a = (1.0 - smoothstep(0.985 - aa, 0.985, d)) * f.opacity;
    float3 c = float3(0.018, 0.019, 0.024) * (1.0 + 0.5 * in.uv.y);
    return float4(c * a, a);
}

struct Mirror {
    float4 position [[position]];
    float3 world;
    float3 facing;
    float2 uv;
    float  bright;
};

vertex Mirror tileVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device Tile* tiles [[buffer(0)]],
                         constant Frame& f [[buffer(1)]]) {
    Mirror o;
    o.position = nowhere; o.world = 0; o.facing = float3(0, 0, 1); o.uv = 0; o.bright = 0;
    Tile t = tiles[iid];
    float3 n = spin(t.normal.xyz, f.theta);
    if (dot(n, towardEye(n, f)) < 0.0) return o;   // round the back

    // Lay a flat square on the sphere: east and north at this point.
    float3 east = normalize(cross(float3(0.0, 1.0, 0.0), n));
    float3 north = cross(n, east);
    float2 c = corners[vid];
    float3 p = n + (east * c.x + north * c.y) * t.normal.w;

    o.position = clip(project(p, f), f);
    o.world = p;
    o.facing = spin(t.mirror.xyz, f.theta);
    o.uv = c;
    o.bright = t.mirror.w;
    return o;
}

// With no camera: a dark room with a couple of soft studio lights in it, so the
// mirrors always have something to show.
static float3 studio(float3 r, float3 L) {
    float up = saturate(r.y * 0.5 + 0.5);
    float3 c = mix(float3(0.07, 0.075, 0.09), float3(0.34, 0.36, 0.4), up);
    c += float3(1.0, 0.96, 0.9) * smoothstep(0.9, 0.985, dot(r, L)) * 0.8;            // key, where the lamp is
    c += float3(0.8, 0.88, 1.0) * smoothstep(0.8, 0.95, r.y) * 0.35;                    // strip overhead
    c += float3(1.0, 0.72, 0.48)
       * smoothstep(0.7, 0.95, dot(r, normalize(float3(-0.8, -0.15, 0.55)))) * 0.3;   // warm bounce, low left
    c += float3(0.7, 0.8, 1.0)
       * smoothstep(0.75, 0.95, dot(r, normalize(float3(0.9, -0.3, 0.3)))) * 0.25;   // cool rim, right
    return c;
}

// With the camera: its picture, wrapped round the ball. Straight out of the
// screen is the middle of the frame; the further a mirror looks from there, the
// further out it reads, and past the edge the picture folds back on itself — so
// every tile catches a scrap of the room.
static float3 surroundings(float3 r, constant Frame& f,
                           texture2d<float> room, sampler s) {
    float3 lights = studio(r, f.light.xyz);
    if (f.hasCamera < 0.5) return lights;

    float2 across = r.xy;
    float len = length(across);
    across = len > 1e-4 ? across / len : float2(0.0);
    float reach = acos(clamp(r.z, -1.0, 1.0)) / 0.6;   // 0.6 rad: roughly the camera's half field of view
    float aspect = float(room.get_width()) / float(room.get_height());
    // The camera faces the viewer, so its left is our right.
    float2 uv = 0.5 - 0.5 * reach * float2(across.x, across.y * aspect);
    float3 cam = room.sample(s, uv).rgb;

    // Behind the ball is the wall; the camera never saw it, so keep it dim.
    float front = smoothstep(-0.3, 0.6, r.z);
    return cam * mix(0.3, 0.85, front) + lights * 0.35;
}

fragment float4 tileFragment(Mirror in [[stage_in]],
                             constant Frame& f [[buffer(0)]],
                             texture2d<float> room [[texture(0)]],
                             sampler roomSampler [[sampler(0)]]) {
    float3 V = towardEye(in.world, f);
    float3 n = normalize(in.facing);
    float3 r = reflect(-V, n);

    // Metal, not paint: all the colour is reflection. Silvered glass is a
    // touch warm, and like every metal gets a little brighter at a grazing angle.
    float3 F0 = float3(0.95, 0.94, 0.91);
    float3 F = F0 + (1.0 - F0) * pow(1.0 - saturate(dot(n, V)), 5.0);
    float3 c = surroundings(r, f, room, roomSampler) * F * in.bright;

    // The lamp itself, seen in this mirror. A tight lobe is what very low
    // roughness looks like.
    c += pow(saturate(dot(r, f.light.xyz)), 150.0) * 2.5 * f.intensity;

    // Grout: a line about a pixel wide round every tile, whatever the ball's size.
    float e = max(abs(in.uv.x), abs(in.uv.y));
    float px = fwidth(e);
    float grout = smoothstep(1.0 - 2.2 * px, 1.0 - 0.8 * px, e);
    c = mix(c, float3(0.012), grout);

    return float4(c, 1.0) * f.opacity;
}

// MARK: - The room goes dark, and the ball blocks the lamp

// One quad over the whole screen, so the show is the brightest thing on it.
vertex Disc dimVertex(uint vid [[vertex_id]], constant Frame& f [[buffer(1)]]) {
    Disc o;
    o.position = float4(corners[vid], 0.0, 1.0);
    o.uv = corners[vid];
    return o;
}

fragment float4 dimFragment(Disc in [[stage_in]], constant Frame& f [[buffer(0)]]) {
    // A touch lighter under the ball, as if the lamp spills a little there.
    float2 p = (in.uv * 0.5 + 0.5) * f.viewSize;
    float near = exp(-length(p - f.centre) / (f.radius * 2.5));
    float a = f.dim * (1.0 - 0.3 * near) * f.opacity;
    return float4(0.0, 0.0, 0.0, a);
}

// The ball's shadow on the wall. The lamp is up, right and in front, so the
// shadow falls down and to the left, as far as the wall is behind the ball. The
// light arrives at a slant, so the shadow stretches along that direction, and
// it softens with distance the way a real one does.
static float2 shadowCentre(constant Frame& f, thread float2& dir, thread float& stretch) {
    float3 L = f.light.xyz;
    float2 back = -L.xy / max(0.2, L.z);          // where a ray from the lamp through the centre lands, per radius of depth
    float len = length(back);
    dir = len > 1e-4 ? back / len : float2(0.0, -1.0);
    stretch = 1.0 / max(0.3, L.z);
    return f.centre + back * f.wall * f.radius;
}

vertex Disc shadowVertex(uint vid [[vertex_id]], constant Frame& f [[buffer(1)]]) {
    float2 dir; float stretch;
    float2 c = shadowCentre(f, dir, stretch);
    float2 side = float2(-dir.y, dir.x);
    float2 k = corners[vid] * 1.8;                // room for the penumbra
    Disc o;
    o.position = clip(c + dir * k.x * f.radius * stretch + side * k.y * f.radius, f);
    o.uv = k;
    return o;
}

fragment float4 shadowFragment(Disc in [[stage_in]], constant Frame& f [[buffer(0)]]) {
    float d = length(in.uv);
    float soft = 0.25 + 0.06 * f.wall;            // further wall, softer edge
    float a = (1.0 - smoothstep(1.0 - soft, 1.0 + soft, d)) * 0.55 * f.opacity;
    return float4(0.0, 0.0, 0.0, a);
}

// MARK: - Bloom
//
// Only on the mirrors bright enough to flare: the few lined up between lamp and
// eye. A soft halo and a faint four-point star, drawn as one small sprite each,
// instead of blurring the whole screen to find them.

vertex Glow glintVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        const device Tile* tiles [[buffer(0)]],
                        constant Frame& f [[buffer(1)]]) {
    Glow o;
    o.position = nowhere; o.uv = 0; o.light = 0;
    Tile t = tiles[iid];
    float3 n = spin(t.normal.xyz, f.theta);
    float3 V = towardEye(n, f);
    if (dot(n, V) < 0.1) return o;

    float3 r = reflect(-V, normalize(spin(t.mirror.xyz, f.theta)));
    float g = pow(saturate(dot(r, f.light.xyz)), 150.0);
    g *= 0.75 + 0.25 * sin(f.time * 9.0 + t.tint.w * 40.0);
    if (g < 0.2) return o;

    float size = t.normal.w * f.radius * (2.5 + 5.0 * g);
    o.position = clip(project(n, f) + corners[vid] * size, f);
    o.uv = corners[vid];
    o.light = float3(1.0, 0.97, 0.92) * g * f.intensity * f.opacity;
    return o;
}

fragment float4 glintFragment(Glow in [[stage_in]]) {
    float2 a = abs(in.uv);
    float halo = exp(-dot(in.uv, in.uv) * 4.0);
    float star = exp(-a.x * 24.0) * exp(-a.y * 3.0) + exp(-a.y * 24.0) * exp(-a.x * 3.0);
    float3 c = min(in.light * (0.8 * halo + 0.5 * star), float3(1.0));
    return float4(c, max(c.r, max(c.g, c.b)));      // real alpha, as for the specks
}
"""#
}
