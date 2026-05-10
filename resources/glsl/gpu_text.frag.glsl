#version 450

layout(set = 2, binding = 0) uniform sampler2D atlas_sampler;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

layout(set = 3, binding = 0) uniform FragmentUniforms {
  vec4 color;
  uint format;
} u;

void main() {
  vec4 sample_color = texture(atlas_sampler, in_uv);
  if (u.format == 2u) {
    out_color = vec4(sample_color.rgb * u.color.a, sample_color.a * u.color.a);
  } else if (u.format == 1u) {
    vec3 mask = sample_color.rgb;
    float coverage = sample_color.a;
    out_color = vec4(u.color.rgb * mask, coverage * u.color.a);
  } else {
    float coverage = sample_color.a;
    out_color = vec4(u.color.rgb, coverage * u.color.a);
  }
}
