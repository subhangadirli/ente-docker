#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DATA_DIR="${HOME}/.ente-docker"
STATE_FILE="${SCRIPT_DIR}/.ente.state"

INTERACTIVE=0
FORCED_ENGINE=""
DATA_DIR="${DEFAULT_DATA_DIR}"
MINIO_CONSOLE_ENABLE="no"
MINIO_CONSOLE_PORT="9001"

ENGINE=""
COMPOSE_FILE=""
COMPOSE_OVERRIDE_FILE=""
ENV_FILE=""

declare -a COMPOSE_CMD
declare -a COMPOSE_FILES

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*" >&2; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --interactive            Run guided setup prompts
  --engine docker|podman  Force a container runtime
  --data-dir PATH         Set persistent data directory
  --minio-console yes|no  Enable MinIO console port mapping
  --help                  Show this help
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --interactive)
        INTERACTIVE=1
        shift
        ;;
      --engine)
        FORCED_ENGINE="${2:-}"
        shift 2
        ;;
      --data-dir)
        DATA_DIR="${2:-}"
        shift 2
        ;;
      --minio-console)
        MINIO_CONSOLE_ENABLE="${2:-}"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

trim_lower() {
  local value="$1"
  value="${value,,}"
  echo "${value}"
}

is_yes() {
  [[ "$(trim_lower "$1")" == "yes" || "$(trim_lower "$1")" == "y" ]]
}

is_no() {
  [[ "$(trim_lower "$1")" == "no" || "$(trim_lower "$1")" == "n" ]]
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    error "Missing required value for ${name}"
    exit 1
  fi
}

sudo_if_needed() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_os_like() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    echo "${ID:-}|${ID_LIKE:-}"
  else
    echo "unknown|unknown"
  fi
}

has_podman_compose() {
  if ! command -v podman >/dev/null 2>&1; then
    return 1
  fi

  if podman compose version >/dev/null 2>&1; then
    return 0
  fi

  command -v podman-compose >/dev/null 2>&1
}

has_docker_compose() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  if docker compose version >/dev/null 2>&1; then
    return 0
  fi

  command -v docker-compose >/dev/null 2>&1
}

install_docker_debian() {
  local os_like
  os_like="$(detect_os_like)"

  if [[ "${os_like}" != *"ubuntu"* && "${os_like}" != *"debian"* ]]; then
    error "No container runtime found and automatic Docker install is only supported on Debian/Ubuntu right now."
    exit 1
  fi

  info "No supported runtime found. Installing Docker for Debian/Ubuntu..."
  sudo_if_needed apt-get update -y
  sudo_if_needed apt-get install -y docker.io docker-compose-plugin

  if command -v systemctl >/dev/null 2>&1; then
    sudo_if_needed systemctl enable --now docker || true
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    if ! groups | grep -qw docker; then
      warn "Your user is not in the docker group. Commands may need sudo until you run: sudo usermod -aG docker $USER"
    fi
  fi
}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local reply=""
  read -r -p "${prompt} [${default}]: " reply
  if [[ -z "${reply}" ]]; then
    echo "${default}"
  else
    echo "${reply}"
  fi
}

interactive_setup() {
  local suggested_engine="${ENGINE}"
  if [[ -z "${suggested_engine}" ]]; then
    suggested_engine="podman"
  fi

  FORCED_ENGINE="$(prompt_with_default "Which container runtime do you want? (docker/podman)" "${suggested_engine}")"
  DATA_DIR="$(prompt_with_default "Where should data be stored?" "${DATA_DIR}")"
  MINIO_CONSOLE_ENABLE="$(prompt_with_default "Enable MinIO web console? (yes/no)" "${MINIO_CONSOLE_ENABLE}")"
}

detect_engine() {
  local forced
  forced="$(trim_lower "${FORCED_ENGINE}")"

  if [[ -n "${forced}" ]]; then
    case "${forced}" in
      podman)
        if has_podman_compose; then
          ENGINE="podman"
          return
        fi
        error "Requested engine 'podman' but podman compose support is not available."
        exit 1
        ;;
      docker)
        if has_docker_compose; then
          ENGINE="docker"
          return
        fi
        error "Requested engine 'docker' but docker compose support is not available."
        exit 1
        ;;
      *)
        error "Invalid engine: ${FORCED_ENGINE}. Use docker or podman."
        exit 1
        ;;
    esac
  fi

  if has_podman_compose; then
    ENGINE="podman"
    return
  fi

  if has_docker_compose; then
    ENGINE="docker"
    return
  fi

  install_docker_debian

  if has_docker_compose; then
    ENGINE="docker"
    return
  fi

  error "Docker installation completed but compose is still unavailable."
  exit 1
}

set_compose_cmd() {
  case "${ENGINE}" in
    podman)
      if podman compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(podman compose)
      elif command -v podman-compose >/dev/null 2>&1; then
        COMPOSE_CMD=(podman-compose)
      else
        error "podman compose not found."
        exit 1
      fi
      ;;
    docker)
      if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(docker compose)
      elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD=(docker-compose)
      else
        error "docker compose not found."
        exit 1
      fi
      ;;
    *)
      error "Runtime engine is not set."
      exit 1
      ;;
  esac
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '\n'
  else
    head -c 48 /dev/urandom | base64 | tr -d '\n'
  fi
}

write_env_file_if_missing() {
  if [[ -f "${ENV_FILE}" ]]; then
    info "Existing environment detected at ${ENV_FILE}; keeping current values."
    return
  fi

  local postgres_password minio_password app_secret jwt_secret
  postgres_password="$(generate_secret)"
  minio_password="$(generate_secret)"
  app_secret="$(generate_secret)"
  jwt_secret="$(generate_secret)"

  cat >"${ENV_FILE}" <<EOF
CONTAINER_ENGINE=${ENGINE}
DATA_DIR=${DATA_DIR}

ENTE_BIND_ADDRESS=127.0.0.1
ENTE_PORT=8080
ENTE_PUBLIC_URL=http://localhost:8080
ENTE_LOG_LEVEL=info

POSTGRES_DB=ente_db
POSTGRES_USER=ente
POSTGRES_PASSWORD=${postgres_password}

MINIO_ROOT_USER=ente_s3
MINIO_ROOT_PASSWORD=${minio_password}
MINIO_BUCKET=ente
S3_REGION=us-east-1
MINIO_CONSOLE_ENABLE=${MINIO_CONSOLE_ENABLE}
MINIO_CONSOLE_PORT=${MINIO_CONSOLE_PORT}

ENTE_APP_SECRET=${app_secret}
ENTE_JWT_SECRET=${jwt_secret}
EOF

  info "Generated secure .env at ${ENV_FILE}"
}

write_compose_files() {
  cp "${SCRIPT_DIR}/docker-compose.yml" "${COMPOSE_FILE}"

  if is_yes "${MINIO_CONSOLE_ENABLE}"; then
    cat >"${COMPOSE_OVERRIDE_FILE}" <<'EOF'
services:
  minio:
    ports:
      - 127.0.0.1:${MINIO_CONSOLE_PORT}:9001
EOF
    info "MinIO console enabled at http://127.0.0.1:${MINIO_CONSOLE_PORT}"
  else
    rm -f "${COMPOSE_OVERRIDE_FILE}"
  fi
}

load_env() {
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

build_compose_files() {
  COMPOSE_FILES=(-f "${COMPOSE_FILE}")
  if [[ -f "${COMPOSE_OVERRIDE_FILE}" ]]; then
    COMPOSE_FILES+=(-f "${COMPOSE_OVERRIDE_FILE}")
  fi
}

write_state_file() {
  cat >"${STATE_FILE}" <<EOF
ENGINE=${ENGINE}
DATA_DIR=${DATA_DIR}
EOF
}

start_stack() {
  build_compose_files
  "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" "${COMPOSE_FILES[@]}" up -d
}

print_summary() {
  local api_url storage_info runtime_cmd
  api_url="http://localhost:8080"
  if [[ -n "${ENTE_PUBLIC_URL:-}" ]]; then
    api_url="${ENTE_PUBLIC_URL}"
  fi
  storage_info="MinIO bucket '${MINIO_BUCKET}' backed by ${DATA_DIR}/minio"

  runtime_cmd="${COMPOSE_CMD[*]} --env-file ${ENV_FILE} ${COMPOSE_FILES[*]}"

  cat <<EOF

Ente local self-host is up.

API URL:
  ${api_url}

Storage:
  ${storage_info}

Useful commands:
  ./ente start
  ./ente stop
  ./ente logs
  ./ente reset

Direct compose command:
  ${runtime_cmd}
EOF
}

main() {
  parse_args "$@"

  detect_engine

  if [[ "${INTERACTIVE}" -eq 1 ]]; then
    interactive_setup
    detect_engine
  fi

  MINIO_CONSOLE_ENABLE="$(trim_lower "${MINIO_CONSOLE_ENABLE}")"
  if ! is_yes "${MINIO_CONSOLE_ENABLE}" && ! is_no "${MINIO_CONSOLE_ENABLE}"; then
    error "--minio-console must be yes or no"
    exit 1
  fi

  DATA_DIR="${DATA_DIR/#\~/${HOME}}"
  COMPOSE_FILE="${DATA_DIR}/docker-compose.yml"
  COMPOSE_OVERRIDE_FILE="${DATA_DIR}/docker-compose.override.yml"
  ENV_FILE="${DATA_DIR}/.env"

  require_value "data directory" "${DATA_DIR}"

  mkdir -p "${DATA_DIR}" "${DATA_DIR}/postgres" "${DATA_DIR}/minio"

  set_compose_cmd
  write_env_file_if_missing
  load_env
  write_compose_files
  write_state_file
  start_stack
  print_summary
}

main "$@"
