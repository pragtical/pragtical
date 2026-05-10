#!/usr/bin/env bash
set -euo pipefail

shadercross="${SHADERCROSS:-/usr/bin/shadercross}"
if [[ ! -x "$shadercross" ]]; then
  echo "shadercross not found: $shadercross" >&2
  exit 1
fi
glslc="${GLSLC:-glslc}"
if ! command -v "$glslc" >/dev/null 2>&1; then
  echo "glslc not found: $glslc" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

emit_header() {
  local input="$1"
  local stage="$2"
  local dest="$3"
  local var="$4"
  local output="$5"
  local ext

  case "$dest" in
    SPIRV) ext="spv" ;;
    DXBC) ext="dxbc" ;;
    MSL) ext="msl" ;;
    *) echo "unsupported shader destination: $dest" >&2; exit 1 ;;
  esac

  local blob="$tmpdir/$var.$ext"
  local spv="$tmpdir/$var.source.spv"
  "$glslc" -fshader-stage="$stage" "$repo_root/$input" -o "$spv"

  if [[ "$dest" == "SPIRV" ]]; then
    cp "$spv" "$blob"
  else
    "$shadercross" "$spv" \
      --source SPIRV \
      --dest "$dest" \
      --stage "$stage" \
      --entrypoint main \
      --output "$blob"
  fi

  {
    echo "/*"
    echo " * Generated from $input."
    echo " * Regenerate with: ./scripts/generate-gpu-shaders.sh"
    echo " * Uses: $glslc and $shadercross"
    echo " */"
    echo "static const unsigned char ${var}[] = {"
    xxd -i < "$blob" | sed 's/^/  /'
    echo "};"
    echo "static const unsigned int ${var}_len = sizeof(${var});"
  } > "$repo_root/$output"
}

for dest in SPIRV DXBC MSL; do
  case "$dest" in
    SPIRV) suffix="spv" ;;
    DXBC) suffix="dxbc" ;;
    MSL) suffix="msl" ;;
  esac

  emit_header resources/glsl/gpu_text.vert.glsl vertex "$dest" gpu_text_vert_"$suffix" src/shaders/gpu_text.vert."$suffix".h
  emit_header resources/glsl/gpu_text.frag.glsl fragment "$dest" gpu_text_frag_"$suffix" src/shaders/gpu_text.frag."$suffix".h
  emit_header resources/glsl/gpu_canvas.vert.glsl vertex "$dest" gpu_canvas_vert_"$suffix" src/shaders/gpu_canvas.vert."$suffix".h
  emit_header resources/glsl/gpu_canvas.frag.glsl fragment "$dest" gpu_canvas_frag_"$suffix" src/shaders/gpu_canvas.frag."$suffix".h
  emit_header resources/glsl/gpu_poly.vert.glsl vertex "$dest" gpu_poly_vert_"$suffix" src/shaders/gpu_poly.vert."$suffix".h
  emit_header resources/glsl/gpu_poly.frag.glsl fragment "$dest" gpu_poly_frag_"$suffix" src/shaders/gpu_poly.frag."$suffix".h
done
