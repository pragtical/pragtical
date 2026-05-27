cbuffer Camera : register(b0) {
  float4x4 model;
  float4x4 viewProjection;
  float exposure;
};

Texture2D diffuseTexture : register(t0);
SamplerState linearSampler : register(s0);
RWStructuredBuffer<float4> debugColors : register(u0);

struct VSInput {
  float3 position : POSITION;
  float2 uv : TEXCOORD0;
};

struct VSOutput {
  float4 position : SV_POSITION;
  float2 uv : TEXCOORD0;
};

float3 tone_map(float3 color) {
  return saturate(1.0 - exp(-color * exposure));
}

VSOutput main(VSInput input) {
  VSOutput output;
  output.position = mul(viewProjection, mul(model, float4(input.position, 1.0)));
  output.uv = input.uv;
  return output;
}

float4 ps_main(VSOutput input) : SV_Target {
  float4 color = diffuseTexture.Sample(linearSampler, input.uv);
  [branch]
  if (color.a < 0.1) discard;
  return float4(tone_map(color.rgb), color.a);
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
  debugColors[id.x] = float4((float)id.x, (float)id.y, 0.0, 1.0);
}
