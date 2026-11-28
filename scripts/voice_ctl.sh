#!/usr/bin/env bash
set -Eeuo pipefail

# Lifecycle controller for the internal Rosely Voice Avatar services
# (Qwen3-ASR, Chatterbox Turbo TTS, Ditto TensorRT, optional LiveKit agent,
# and loopback-only voice_gateway).
#
# Usage: voice_ctl.sh {start|stop|restart|status}

CMD="${1:-status}"
WORKSPACE="${WORKSPACE:-/workspace}"
STATE_DIR="${STATE_DIR:-/workspace/.rosely-h3-zit}"
VOICE_APP_DIR="${ROSELY_VOICE_APP_DIR:-${WORKSPACE}/rosely-vast-voice-avatar}"
ENV_FILE="${VOICE_ENV_FILE:-${WORKSPACE}/rosely-voice-avatar.env}"
LOGS="${WORKSPACE}/rosely-logs"
RUN="${WORKSPACE}/rosely-run"

mkdir -p "$STATE_DIR" "$LOGS" "$RUN"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

GATEWAY_PORT="${GATEWAY_PORT:-8000}"
ASR_PORT="${ASR_PORT:-8001}"
TTS_PORT="${TTS_PORT:-8002}"
DITTO_PORT="${DITTO_PORT:-8005}"
LIVE_PORT="${LIVE_PORT:-8006}"
LIVE_CALL_ENABLED="${LIVE_CALL_ENABLED:-1}"
DITTO_SOURCE_CACHE_DISK_GB="${DITTO_SOURCE_CACHE_DISK_GB:-10}"

export VOICE_API_KEY="${VOICE_API_KEY:-}"
export GATEWAY_API_KEY="${GATEWAY_API_KEY:-}"
export BUNDLE_ROOT="${BUNDLE_ROOT:-${WORKSPACE}/rosely-voice-v1}"
export ASR_MODEL_PATH="${ASR_MODEL_PATH:-${BUNDLE_ROOT}/models/Qwen3-ASR-0.6B}"
export TTS_MODEL_PATH="${TTS_MODEL_PATH:-${BUNDLE_ROOT}/models/chatterbox-turbo}"
export VOICES_DIR="${VOICES_DIR:-${BUNDLE_ROOT}/voices}"
export AVATAR_MEDIA_ROOT="${AVATAR_MEDIA_ROOT:-${WORKSPACE}/rosely-avatar-data}"
export DITTO_ROOT="${DITTO_ROOT:-${BUNDLE_ROOT}/source/ditto-talkinghead}"
export DITTO_MODELS="${DITTO_MODELS:-${BUNDLE_ROOT}/models/ditto}"
export DITTO_CUDNN8_DIR="${DITTO_CUDNN8_DIR:-${WORKSPACE}/rosely-venvs/ditto/cudnn8/nvidia/cudnn/lib}"
export DITTO_SOURCE_CACHE_DISK_GB
export ASR_PORT TTS_PORT DITTO_PORT LIVE_PORT GATEWAY_PORT LIVE_CALL_ENABLED
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
export CUDA_MODULE_LOADING=LAZY
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export TOKENIZERS_PARALLELISM=false
export HF_HOME="${WORKSPACE}/rosely-hf-cache"

log() { printf '[%s] [voice-ctl] %s\n' "$(date -Iseconds)" "$*"; }

stop_pid() {
  local pidfile="$1" pid
  [[ -s "$pidfile" ]] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    if tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'uvicorn'; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
    fi
  fi
  rm -f "$pidfile"
}

stop_all() {
  for name in gateway live ditto avatar tts asr; do
    stop_pid "$RUN/$name.pid"
  done
  log "Voice services stopped"
}

wait_health() {
  local url="$1" logfile="$2" name="$3" max_polls="${4:-120}"
  for _ in $(seq 1 "$max_polls"); do
    if curl -fsS --max-time 2 "$url" 2>/dev/null | grep -q '"ok":true'; then
      log "$name ready: $url"
      return 0
    fi
    sleep 1
  done
  log "ERROR: $name did not become healthy ($url); tail of $logfile:" >&2
  tail -n 80 "$logfile" >&2 || true
  return 1
}

launch_api() {
  local name="$1" envname="$2" module="$3" bind="$4" port="$5" extra_ld="${6:-}"
  local pybin="${WORKSPACE}/rosely-venvs/${envname}/bin/python"
  local uvicorn="${WORKSPACE}/rosely-venvs/${envname}/bin/uvicorn"
  [[ -x "$uvicorn" ]] || { log "ERROR: missing $uvicorn" >&2; return 1; }
  log "Starting $name on $bind:$port"
  # Spawn detached daemon with close_fds=True so background uvicorn workers NEVER
  # inherit our flock descriptor (fd 9) or caller stdout/stderr pipes.
  "$pybin" - "$uvicorn" "${module}:app" "$bind" "$port" "$LOGS/$name.log" "$RUN/$name.pid" "$extra_ld" <<'PY'
import os, subprocess, sys
uvicorn_bin, app_ref, bind, port, log_path, pid_path, extra_ld = sys.argv[1:]
env = os.environ.copy()
if extra_ld:
    prev = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = f"{extra_ld}:{prev}" if prev else extra_ld
with open(log_path, "wb") as log_fh:
    proc = subprocess.Popen(
        [uvicorn_bin, app_ref, "--host", bind, "--port", port, "--workers", "1"],
        stdin=subprocess.DEVNULL,
        stdout=log_fh,
        stderr=subprocess.STDOUT,
        close_fds=True,
        start_new_session=True,
        env=env,
    )
with open(pid_path, "w", encoding="utf-8") as pid_fh:
    pid_fh.write(f"{proc.pid}\n")
PY
}

start_all() {
  [[ -f "$ENV_FILE" ]] || { log "ERROR: missing $ENV_FILE" >&2; return 1; }
  [[ -d "$VOICE_APP_DIR" ]] || { log "ERROR: missing $VOICE_APP_DIR" >&2; return 1; }

  if curl -fsS --max-time 2 "http://127.0.0.1:${GATEWAY_PORT}/health" 2>/dev/null | grep -q '"ok":true'; then
    log "Voice gateway already healthy on 127.0.0.1:${GATEWAY_PORT}"
    return 0
  fi

  mkdir -p "$AVATAR_MEDIA_ROOT" "$HF_HOME" "$VOICES_DIR"
  stop_all
  cd "$VOICE_APP_DIR"

  # Ensure Ditto's pyximport Cython blend extension is compiled once before
  # launching ditto_server and live_agent in parallel (prevents first-start race).
  local ditto_py="${WORKSPACE}/rosely-venvs/ditto/bin/python"
  if [[ -x "$ditto_py" && -d "$DITTO_ROOT/core/utils/blend" ]] \
     && ! compgen -G "${HOME:-/root}/.pyxbld/*/core/utils/blend/blend*.so" >/dev/null 2>&1; then
    log "Pre-compiling Ditto Cython blend extension before parallel start"
    DITTO_ROOT="$DITTO_ROOT" LD_LIBRARY_PATH="${DITTO_CUDNN8_DIR}:${LD_LIBRARY_PATH:-}" \
      "$ditto_py" - <<'PY' || log "WARN: Ditto blend pre-compile failed; continuing"
import os, sys
root = os.environ["DITTO_ROOT"]
sys.path.insert(0, root)
os.chdir(root)
from core.utils.blend import blend_images_cy  # noqa: F401
PY
  fi

  # Launch ASR, TTS, Ditto, and optional Live agent in parallel to minimize
  # switch-in latency (~10-20s instead of ~45-60s serial).
  launch_api asr asr asr_server 127.0.0.1 "$ASR_PORT"
  launch_api tts tts tts_server 127.0.0.1 "$TTS_PORT"
  launch_api ditto ditto ditto_server 127.0.0.1 "$DITTO_PORT" "$DITTO_CUDNN8_DIR"
  if [[ "$LIVE_CALL_ENABLED" == "1" || "$LIVE_CALL_ENABLED" == "true" ]]; then
    launch_api live ditto live_agent 127.0.0.1 "$LIVE_PORT" "$DITTO_CUDNN8_DIR"
  fi

  local failed=0
  wait_health "http://127.0.0.1:${ASR_PORT}/health" "$LOGS/asr.log" asr 180 || failed=1
  wait_health "http://127.0.0.1:${TTS_PORT}/health" "$LOGS/tts.log" tts 180 || failed=1
  wait_health "http://127.0.0.1:${DITTO_PORT}/health" "$LOGS/ditto.log" ditto 180 || failed=1
  if (( failed != 0 )); then
    stop_all
    return 1
  fi

  if [[ "$LIVE_CALL_ENABLED" == "1" || "$LIVE_CALL_ENABLED" == "true" ]]; then
    # Live calls are optional: if live_agent fails, turn-based ASR/TTS/Ditto keep working.
    wait_health "http://127.0.0.1:${LIVE_PORT}/health" "$LOGS/live.log" live 120 \
      || log "WARN: live agent failed; turn-based voice/avatar still operational" >&2
  fi

  # Bind voice_gateway strictly to loopback; model_server.py proxies & coordinates GPU lock.
  launch_api gateway asr voice_gateway 127.0.0.1 "$GATEWAY_PORT"
  if ! wait_health "http://127.0.0.1:${GATEWAY_PORT}/health" "$LOGS/gateway.log" gateway 60; then
    stop_all
    return 1
  fi
  log "Voice stack online (127.0.0.1:${GATEWAY_PORT})"
}

status_all() {
  if curl -fsS --max-time 2 "http://127.0.0.1:${GATEWAY_PORT}/health" 2>/dev/null; then
    echo
  else
    echo '{"ok":false,"status":"stopped"}'
  fi
}

exec 9>"$STATE_DIR/voice-ctl.lock"
flock -w 30 9 || { log "ERROR: Timed out acquiring $STATE_DIR/voice-ctl.lock" >&2; exit 1; }

case "$CMD" in
  start)   start_all ;;
  stop)    stop_all ;;
  restart) stop_all; start_all ;;
  status)  status_all ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
