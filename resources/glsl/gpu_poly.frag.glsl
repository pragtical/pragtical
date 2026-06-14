#version 450

layout(location = 0) in float in_coverage;
layout(location = 0) out vec4 out_color;

layout(set = 3, binding = 0) uniform FragmentUniforms {
  vec4 color;
} u;

void main() {
  out_color = vec4(u.color.rgb, u.color.a * clamp(in_coverage, 0.0, 1.0));
}
