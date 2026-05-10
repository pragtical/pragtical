#version 450

layout(location = 0) in vec2 in_position;

layout(set = 1, binding = 0) uniform VertexUniforms {
  vec4 target;
} u;

void main() {
  vec2 ndc = vec2(
    (in_position.x / u.target.x) * 2.0 - 1.0,
    (in_position.y / u.target.y) * -2.0 + 1.0
  );
  gl_Position = vec4(ndc, 0.0, 1.0);
}
