#version 450

layout(location = 0) out vec4 out_color;

layout(set = 3, binding = 0) uniform FragmentUniforms {
  vec4 color;
} u;

void main() {
  out_color = u.color;
}
