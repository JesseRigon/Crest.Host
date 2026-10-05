#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEV_DIR="${SCRIPT_DIR}"
SERVER_PROJECT="${ROOT_DIR}/OrchardCore.Crest.Host.csproj"

# The devcontainer's default LANG=C.UTF-8 has no named .NET culture, so
# CultureInfo.InstalledUICulture resolves to "" (invariant) - requests then throw
# ArgumentException("cultureName") in the localization pipeline. Pin LANG so local
# dev always has a real installed culture (same fix as fruitful.host/dev/dev.sh).
export LANG="${LANG_OVERRIDE:-en_US.UTF-8}"

export CREST_SERVER_URL="${CREST_SERVER_URL:-http://crest.localhost:5014}"
export CREST_SERVER_PORT="${CREST_SERVER_PORT:-5014}"
# The browser harness in the submodule signs in with these; pass them explicitly rather
# than letting it fall back to a default that happens to match this host's autosetup
# (appsettings.Development.json › AdminUsername/AdminPassword).
export ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-CrestRules1!}"
# Playwright isn't installed locally in this repo; reuse fruitful.host's install
# unless the caller already points NODE_PATH somewhere else.
export NODE_PATH="${NODE_PATH:-/workspaces/fruitful.host/node_modules}"

usage() {
  cat <<'EOF'
Usage:
  bash dev/dev.sh up        One command up: restore, then run the dev server in the foreground.
  bash dev/dev.sh server    Alias for up.
  bash dev/dev.sh build     Rebuild OrchardCore.Crest.Host.csproj only (no server, no test run).
  bash dev/dev.sh stop      Stop a locally running dev server (processes only).
  bash dev/dev.sh down      One command down: stop the server, shut down build servers,
                            remove all bin/obj. App_Data (tenant state) survives - the
                            next 'up' restores + rebuilds.
  bash dev/dev.sh reset     down + delete App_Data tenant state. Next 'up' provisions fresh.
  bash dev/dev.sh test      Rebuild, start the dev server if it isn't already up, run every Playwright script in the repo.
  bash dev/dev.sh feed      Force-pack the OrchardCore fork (modules/OrchardCore) into the
                            in-repo local-nuget-feed/, even when a sibling dev feed exists.
                            'up'/'build' run this automatically when NO feed is found.
EOF
}

# --- OrchardCore fork feed -----------------------------------------------------
# Crest pins every OrchardCore package to 4.0.0-local, a version that only exists
# in a feed packed from the custom fork (jesse-forked/OrchardCore, branch Crest -
# the AdminNode UniqueId changes pending upstream in OrchardCMS/OrchardCore#19771).
# Two layouts are supported, and NuGet.config maps OrchardCore* to BOTH sources:
#   dev:        a prebuilt sibling feed at /workspaces/local-nuget-feed (packed once
#               from a sibling /workspaces/OrchardCore checkout).
#   standalone: no sibling feed - the fork is cloned as the modules/OrchardCore
#               submodule and packed into the in-repo local-nuget-feed/ folder.
OC_FEED_VERSION="4.0.0-local"
SIBLING_FEED="/workspaces/local-nuget-feed"
REPO_FEED="${ROOT_DIR}/local-nuget-feed"
OC_SUBMODULE="${ROOT_DIR}/modules/OrchardCore"

feed_has_packages() {
  [ -f "$1/OrchardCore.Application.Cms.Targets.${OC_FEED_VERSION}.nupkg" ]
}

pack_orchardcore_feed() {
  require_dotnet
  echo "Packing the OrchardCore fork into ${REPO_FEED} (version ${OC_FEED_VERSION})..."
  if [ ! -f "${OC_SUBMODULE}/OrchardCore.slnx" ]; then
    echo "Cloning the OrchardCore fork submodule (modules/OrchardCore)..."
    git -C "${ROOT_DIR}" submodule update --init modules/OrchardCore
  fi
  mkdir -p "${REPO_FEED}"
  # OrchardCore's own repo-root NuGet.config governs this restore/pack. This is a
  # full-solution Release pack and takes a long while on first run.
  (cd "${OC_SUBMODULE}" && dotnet pack OrchardCore.slnx -c Release -p:Version="${OC_FEED_VERSION}" -o "${REPO_FEED}")
  if ! feed_has_packages "${REPO_FEED}"; then
    echo "Pack finished but ${REPO_FEED} is missing OrchardCore.Application.Cms.Targets.${OC_FEED_VERSION}.nupkg." >&2
    exit 1
  fi
}

ensure_orchardcore_feed() {
  # NuGet.config declares both feed folders; restore fails if either path is absent.
  mkdir -p "${SIBLING_FEED}" 2>/dev/null || true
  mkdir -p "${REPO_FEED}"
  if feed_has_packages "${SIBLING_FEED}" || feed_has_packages "${REPO_FEED}"; then
    return 0
  fi
  echo "No OrchardCore ${OC_FEED_VERSION} feed found (sibling or in-repo) - bootstrapping from the fork."
  pack_orchardcore_feed
}

require_dotnet() {
  if ! command -v dotnet >/dev/null 2>&1; then
    echo ".NET SDK is not installed in this environment." >&2
    exit 1
  fi
}

url_is_up() {
  local url="$1"
  curl -fsS --max-time 2 -o /dev/null "$url" >/dev/null 2>&1
}

remove_build_output() {
  dotnet build-server shutdown >/dev/null 2>&1 || true
  find "${ROOT_DIR}" \( -name node_modules -o -name .git \) -prune -o \
    -type d \( -name bin -o -name obj \) -prune -print0 2>/dev/null | xargs -0 -r rm -rf
}

run_build() {
  require_dotnet
  ensure_orchardcore_feed
  dotnet build "${SERVER_PROJECT}"
}

# dotnet watch, not dotnet run: this host serves the Blazor WASM framework assets out
# of the referenced projects' staticwebassets (Program.cs maps /_framework), and a bare
# run never produces them on a rebuild.
run_server() {
  require_dotnet
  ensure_orchardcore_feed
  cd "${ROOT_DIR}"
  dotnet build-server shutdown || true
  dotnet restore "${SERVER_PROJECT}" --configfile "${ROOT_DIR}/NuGet.config"
  dotnet watch --project "${SERVER_PROJECT}"
}

down() {
  echo "Stopping the dev server..."
  stop_server
  echo "Shutting down build servers and removing bin/obj..."
  remove_build_output
  echo "Down. App_Data (tenant state) was preserved - 'reset' removes it too."
}

reset() {
  down
  echo "Deleting App_Data tenant state..."
  rm -rf "${ROOT_DIR}/App_Data"
  echo "Reset complete. Run 'bash dev/dev.sh up' to provision a fresh site."
}

stop_server() {
  # dotnet watch supervises a child host process; kill the watcher first so it does not
  # restart what the second pattern is about to kill.
  pkill -f "dotnet watch --project .*OrchardCore.Crest.Host.csproj" >/dev/null 2>&1 || true
  pkill -f "${ROOT_DIR}/bin/.*/OrchardCore.Crest.Host$" >/dev/null 2>&1 || true
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti :"${CREST_SERVER_PORT}" | xargs -r kill -9 >/dev/null 2>&1 || true
  fi
}

start_server_background() {
  dotnet restore "${SERVER_PROJECT}" --configfile "${ROOT_DIR}/NuGet.config"
  mkdir -p "${DEV_DIR}/logs"
  (cd "${ROOT_DIR}" && nohup dotnet watch --project "${SERVER_PROJECT}" > "${DEV_DIR}/logs/server.log" 2>&1 &)

  echo "Waiting for ${CREST_SERVER_URL} to come up..."
  for _ in $(seq 1 60); do
    if url_is_up "${CREST_SERVER_URL}"; then
      return 0
    fi
    sleep 5
  done

  echo "Timed out waiting for the dev server to start; check dev/logs/server.log" >&2
  return 1
}


# The legacy loop below discovers every *.js under a tests/playwright/ dir. That glob
# matches slashes, so without this exclusion it would also pick up checks/*.js and
# harness/*.js (not standalone-runnable — they just define a module.exports and no-op)
# and re-run run-admin-suite.js/run-client-suite.js a second time in full. Raw scripts
# that get converted should be deleted outright (git rm), not added here — this only
# excludes the harness/entrypoint machinery itself.
is_legacy_script() {
  case "$1" in
    */tests/playwright/checks/*|*/tests/playwright/harness/*) return 1 ;;
    */tests/playwright/run-admin-suite.js|*/tests/playwright/run-client-suite.js) return 1 ;;
    *) return 0 ;;
  esac
}

# This host supplies credentials/URLs (its own dev/.env, once it has one) and decides
# when to run tests, but does not know Crest's internal subproject layout —
# that knowledge stays owned by the submodule itself, in its own tests/run-tests.sh,
# which takes BASE_URL as an input and holds no credentials of its own. Any other module
# this host later declares (currently only Crest exists under modules/) gets
# walked directly here, same shape as fruitful.host/dev/dev.sh's module loop.
run_module_tests() {
  local module_dir="$1"
  local module_name
  module_name="$(basename "${module_dir}")"
  local tests_dir="${module_dir}/tests"

  if [ "${module_name}" = "Crest" ]; then
    echo "=== ${module_name} (delegated to modules/Crest/tests/run-tests.sh) ==="
    BASE_URL="${CREST_SERVER_URL}" bash "${tests_dir}/run-tests.sh"
    return $?
  fi

  local module_failed=0

  local csproj
  while IFS= read -r -d '' csproj; do
    echo "=== ${module_name} C# tests: $(basename "${csproj}") ==="
    dotnet test "${csproj}" || module_failed=1
  done < <(find "${tests_dir}" -mindepth 2 -maxdepth 2 -name "*.csproj" -print0 2>/dev/null | sort -z)

  if [ -d "${tests_dir}/playwright" ]; then
    echo "=== ${module_name} Playwright suite ==="
    local total=0
    local failures=0
    local failed_names=()
    while IFS= read -r -d '' test_file; do
      local relative="${test_file#${ROOT_DIR}/}"
      is_legacy_script "${relative}" || continue
      total=$((total + 1))
      echo "==> ${relative}"
      if ! BASE_URL="${CREST_SERVER_URL}" node "${test_file}"; then
        failures=$((failures + 1))
        failed_names+=("${relative}")
      fi
    done < <(find "${tests_dir}" -path "*/tests/playwright/*.js" -print0 2>/dev/null | sort -z)

    echo "${module_name} raw scripts: $((total - failures))/${total} passed"
    if ((failures > 0)); then
      echo "Failed:"
      printf '  %s\n' "${failed_names[@]}"
      module_failed=1
    fi
  fi

  return "${module_failed}"
}

run_tests() {
  require_dotnet
  run_build

  if ! url_is_up "${CREST_SERVER_URL}"; then
    start_server_background
  fi

  local overall_failed=0
  local module_dir
  while IFS= read -r -d '' module_dir; do
    [ -d "${module_dir}/tests" ] || continue
    echo
    run_module_tests "${module_dir}" || overall_failed=1
  done < <(find "${ROOT_DIR}/modules" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

  return "${overall_failed}"
}

command="${1:-up}"
case "${command}" in
  build)
    run_build
    ;;
  up|server)
    run_server
    ;;
  stop)
    stop_server
    ;;
  down)
    down
    ;;
  reset)
    reset
    ;;
  test)
    run_tests
    ;;
  feed)
    pack_orchardcore_feed
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
