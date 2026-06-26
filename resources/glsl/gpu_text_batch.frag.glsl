#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D atlas_sampler;

layout(set = 3, binding = 0) uniform FragmentUniforms {
  uint format;
  uint pass;
} u;

void main() {
  vec4 sample_color = texture(atlas_sampler, in_uv);
  if (u.format == 2u) {
    out_color = sample_color * in_color;
  } else if (u.format == 1u) {
    // Subpixel (LCD) glyphs carry per-channel coverage in rgb. Correct blending
    // needs a per-channel destination factor, which SDL_GPU can only express via
    // two passes (it has no dual-source blend factors):
    //   pass 1 attenuates the destination: src=ZERO, dst=ONE_MINUS_SRC_COLOR
    //   pass 2 adds the foreground:        src=ONE,  dst=ONE
    vec3 mask = sample_color.rgb;
    if (u.pass == 2u) {
      out_color = vec4(in_color.rgb * mask * in_color.a, 0.0);
    } else if (u.pass == 1u) {
      out_color = vec4(mask * in_color.a, 0.0);
    } else {
      // Legacy single-pass fallback (single combined coverage).
      float coverage = sample_color.a;
      vec3 color = coverage > 0.0 ? in_color.rgb * mask / coverage : vec3(0.0);
      out_color = vec4(color, coverage * in_color.a);
    }
  } else {
    float coverage = sample_color.a;
    out_color = vec4(in_color.rgb, coverage * in_color.a);
  }
}
