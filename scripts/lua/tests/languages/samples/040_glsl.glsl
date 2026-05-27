#version 330 core

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 uv;

uniform mat4 model;
uniform mat4 view;
uniform mat4 projection;

out vec2 frag_uv;

void main() {
  frag_uv = uv;
  gl_Position = projection * view * model * vec4(position, 1.0);
}

struct Light {
  vec3 position;
  vec3 color;
};

uniform sampler2D albedo_map;
uniform Light lights[4];

layout(std140) uniform Material {
  vec4 base_color;
  float roughness;
};

vec3 shade(vec3 normal, vec2 texcoord) {
  vec3 albedo = texture(albedo_map, texcoord).rgb;
  vec3 total = vec3(0.0);
  for (int i = 0; i < 4; ++i) {
    float n_dot_l = max(dot(normal, normalize(lights[i].position)), 0.0);
    total += albedo * lights[i].color * n_dot_l;
  }
  return clamp(total * base_color.rgb, 0.0, 1.0);
}
