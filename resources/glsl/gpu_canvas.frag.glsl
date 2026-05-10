#version 450

layout(set = 2, binding = 0) uniform sampler2D canvas_sampler;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
  out_color = texture(canvas_sampler, in_uv);
}
