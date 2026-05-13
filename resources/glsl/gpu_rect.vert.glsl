#version 450

layout(location = 0) in vec4 in_dst;
layout(location = 1) in vec4 in_color;

layout(set = 1, binding = 0) uniform VertexUniforms {
  vec4 target;
} u;

layout(location = 0) out vec4 out_color;

void main() {
  vec2 corners[6] = vec2[](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 1.0)
  );
  vec2 corner = corners[gl_VertexIndex % 6];
  vec2 position = in_dst.xy + corner * in_dst.zw;
  vec2 ndc = vec2(
    (position.x / u.target.x) * 2.0 - 1.0,
    (position.y / u.target.y) * -2.0 + 1.0
  );
  gl_Position = vec4(ndc, 0.0, 1.0);
  out_color = in_color;
}
