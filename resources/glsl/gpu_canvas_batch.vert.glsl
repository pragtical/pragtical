#version 450

layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_uv;

layout(set = 1, binding = 0) uniform VertexUniforms {
  vec4 target;
} u;

layout(location = 0) out vec2 out_uv;

void main() {
  vec2 ndc = vec2(
    (in_position.x / u.target.x) * 2.0 - 1.0,
    (in_position.y / u.target.y) * -2.0 + 1.0
  );
  gl_Position = vec4(ndc, 0.0, 1.0);
  out_uv = in_uv;
}
