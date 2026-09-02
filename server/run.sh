#!/usr/bin/env bash
# Convenience launcher: finds a libonnxruntime.so and starts the daemon.
# Override any of these via the environment before running.
set -euo pipefail
cd "$(dirname "$0")"

# Locate an onnxruntime shared library if ORT_DYLIB_PATH isn't already set.
if [[ -z "${ORT_DYLIB_PATH:-}" ]]; then
  ORT_DYLIB_PATH="$(find "$HOME" -name 'libonnxruntime.so*' 2>/dev/null | head -1 || true)"
  if [[ -z "$ORT_DYLIB_PATH" ]]; then
    echo "ERROR: no libonnxruntime.so found. Set ORT_DYLIB_PATH to one." >&2
    exit 1
  fi
fi
export ORT_DYLIB_PATH
echo "Using ORT_DYLIB_PATH=$ORT_DYLIB_PATH"

# WebGPU (Vulkan on Linux, D3D12 on Windows, Metal on macOS) is an optional
# GPU-acceleration plugin EP — see CLAUDE.md's Gotchas section. It ships as a
# separate shared library, not compiled into libonnxruntime itself, so it
# isn't found by the ORT_DYLIB_PATH search above; fetch it from its NuGet
# package (the same artifact Microsoft.ML.OnnxRuntime.EP.WebGpu ships) unless
# already present or explicitly disabled.
WEBGPU_EP_VERSION="0.3.0"
# Must be absolute: ORT resolves a relative plugin-library path against the
# directory of libonnxruntime.so itself, not the shell's cwd.
WEBGPU_EP_CACHE_DIR="$(cd "$(dirname "$0")" && pwd)/.cache/onnxruntime-webgpu/$WEBGPU_EP_VERSION"

if [[ -z "${GLINER2_WEBGPU_EP_LIB:-}" && "${GLINER2_NO_WEBGPU:-}" != "1" ]]; then
  GLINER2_WEBGPU_EP_LIB="$(find "$HOME" -name 'libonnxruntime_providers_webgpu.so*' 2>/dev/null | head -1 || true)"

  if [[ -z "$GLINER2_WEBGPU_EP_LIB" ]]; then
    case "$(uname -s)-$(uname -m)" in
      Linux-x86_64) WEBGPU_EP_RID="linux-x64"; WEBGPU_EP_FILE="libonnxruntime_providers_webgpu.so" ;;
      Darwin-arm64) WEBGPU_EP_RID="osx-arm64"; WEBGPU_EP_FILE="libonnxruntime_providers_webgpu.dylib" ;;
      *) WEBGPU_EP_RID="" ;;
    esac

    if [[ -n "$WEBGPU_EP_RID" ]]; then
      WEBGPU_EP_DEST="$WEBGPU_EP_CACHE_DIR/$WEBGPU_EP_RID/$WEBGPU_EP_FILE"
      if [[ ! -f "$WEBGPU_EP_DEST" ]]; then
        echo "Fetching WebGPU EP plugin ($WEBGPU_EP_RID, one-time ~40 MB download)…"
        mkdir -p "$(dirname "$WEBGPU_EP_DEST")"
        WEBGPU_EP_NUPKG="$(mktemp -t clipcloak-webgpu-ep-XXXXXX.nupkg)"
        NUPKG_URL="https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.ep.webgpu/$WEBGPU_EP_VERSION/microsoft.ml.onnxruntime.ep.webgpu.$WEBGPU_EP_VERSION.nupkg"
        if curl -fsSL "$NUPKG_URL" -o "$WEBGPU_EP_NUPKG" \
          && unzip -p "$WEBGPU_EP_NUPKG" "runtimes/$WEBGPU_EP_RID/native/$WEBGPU_EP_FILE" > "$WEBGPU_EP_DEST.tmp"; then
          mv "$WEBGPU_EP_DEST.tmp" "$WEBGPU_EP_DEST"
        else
          echo "WARNING: WebGPU EP download failed; continuing on CPU. Set GLINER2_NO_WEBGPU=1 to silence this." >&2
          rm -f "$WEBGPU_EP_DEST.tmp"
        fi
        rm -f "$WEBGPU_EP_NUPKG"
      fi
      [[ -f "$WEBGPU_EP_DEST" ]] && GLINER2_WEBGPU_EP_LIB="$WEBGPU_EP_DEST"
    fi
  fi
fi

if [[ -n "${GLINER2_WEBGPU_EP_LIB:-}" ]]; then
  export GLINER2_WEBGPU_EP_LIB
  echo "Using GLINER2_WEBGPU_EP_LIB=$GLINER2_WEBGPU_EP_LIB"
else
  echo "WebGPU EP plugin not available; running on CPU."
fi

# PII_MODELS_DIR : local dir of the 8 ONNX fragments + tokenizer.json (skips HF download)
# PII_TOKEN      : bearer token the extension must send (recommended)
# PII_PORT       : default 8731
# PII_LABELS     : comma-separated entity labels
exec ./target/release/clipcloak-server
