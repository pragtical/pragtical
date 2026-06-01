#version 450

const vec2 positions[6] = vec2[](
  vec2(0.0, 0.0),
  vec2(1.0, 0.0),
  vec2(1.0, 1.0),
  vec2(0.0, 0.0),
  vec2(1.0, 1.0),
  vec2(0.0, 1.0)
);

layout(set = 1, binding = 0) uniform VertexUniforms {
  vec4 dst;
  vec4 uv;
  vec4 target;
} u;

layout(location = 0) out vec2 out_uv;

void main() {
  vec2 p = positions[gl_VertexIndex];
  vec2 ndc = vec2(
    ((u.dst.x + p.x * u.dst.z) / u.target.x) * 2.0 - 1.0,
    ((u.dst.y + p.y * u.dst.w) / u.target.y) * -2.0 + 1.0
  );
  gl_Position = vec4(ndc, 0.0, 1.0);
  out_uv = u.uv.xy + p * u.uv.zw;
}
