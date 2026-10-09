#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEV_DIR="${SCRIPT_DIR}"
ENV_FILE="${DEV_DIR}/.env"
SERVER_PROJECT="${ROOT_DIR}/Crest.Host.csproj"

if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

# The devcontainer's default LANG=C.UTF-8 has no named .NET culture, so
# CultureInfo.InstalledUICulture resolves to "" (invariant) - requests then throw
# ArgumentException("cultureName") in the localization pipeline. Pin LANG so local
# dev always has a real installed culture (same fix as Crest.Host/dev/dev.sh).
export LANG="${LANG_OVERRIDE:-en_US.UTF-8}"
export ASPNETCORE_ENVIRONMENT="${ASPNETCORE_ENVIRONMENT:-Development}"

export CREST_HOST_SERVER_URL="${CREST_HOST_SERVER_URL:-http://crest.localhost:5014}"
export CREST_HOST_SERVER_PORT="${CREST_HOST_SERVER_PORT:-5014}"
# Crest's browser harness reads these; this host's autosetup credentials
# (dev/appsettings.Development.json > AdminUsername/AdminPassword) are the source of truth.
export ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-CrestRules1!}"
# The member shell's base and the setup recipe, for the checks that need them
# (dev/appsettings.Development.json > Crest_Member:MemberUrlPrefix and RecipeName).
export MEMBER_URL_PREFIX="${MEMBER_URL_PREFIX:-app}"
export SETUP_RECIPE_NAME="${SETUP_RECIPE_NAME:-CrestDev}"
# Outgoing e-mail in dev and test: the tenants' SMTP provider (Crest.Email.Smtp,
# enabled by the setup recipe) writes .eml files here instead of sending (delivery method
# in dev/appsettings.Development.json); the browser suite reads CREST_MAIL_DIR to assert on
# what a workflow sent. Tenants share it - checks match on their own markers.
export CREST_MAIL_DIR="${CREST_MAIL_DIR:-${DEV_DIR}/mail}"
mkdir -p "${CREST_MAIL_DIR}"
export Crest__Crest_Email_Smtp__PickupDirectoryLocationBase="${CREST_MAIL_DIR}"
# The host installs its own Playwright (package.json) rather than borrowing a sibling
# checkout's node_modules - this host must not depend on any other repo being present.
export NODE_PATH="${NODE_PATH:-${ROOT_DIR}/node_modules}"

usage() {
  cat <<'EOF'
Usage:
  bash dev/dev.sh up        One command up: restore, then run the dev server in the foreground.
  bash dev/dev.sh server    Alias for up.
  bash dev/dev.sh build     Rebuild Crest.Host.csproj only (no server, no test run).
  bash dev/dev.sh stop      Stop a locally running dev server (processes only).
  bash dev/dev.sh down      One command down: stop the server, shut down build servers,
                            remove all bin/obj. App_Data (tenant state) survives - the
                            next 'up' restores + rebuilds.
  bash dev/dev.sh reset     down + delete App_Data tenant state. Next 'up' provisions fresh.
  bash dev/dev.sh test      Rebuild, start the dev server if it isn't already up, run every Playwright script in the repo.
  bash dev/dev.sh pack      Repack Crest's modules into their output/ folder even if
                            unchanged. 'up'/'build'/'test' repack them automatically when
                            the source changed.
  bash dev/dev.sh pack all  Also repack Crest's platform (src/; slow) first.
EOF
}

# --- Local package feeds -------------------------------------------------------
# This host consumes the platform and Crest as NuGet packages, never as project
# references - the same way it will once they are served from a package feed. The Crest
# submodule packs both into its output/ folder (git-ignored there), and NuGet.config maps
# the package family to those folders. Dependency order matters:
#   platform     - Crest's platform, forked from OrchardCore (modules/Crest/src, package ids
#                  Crest.*), packed from Crest's Crest.Platform.slnx into
#                  modules/Crest/output/platform. A full-solution Release pack: slow, so
#                  done only when that folder is empty, or by `dev.sh pack all`.
#   Crest        - its modules reference the platform as projects; packed from Crest.slnx
#                  into modules/Crest/output/crest.
# Crest's modules are repacked automatically whenever their source changes (a stamp of
# the submodule's commit, working-tree diff and untracked files). Every pack is version 4.0.0-local, so a repack also evicts that
# version from the NuGet global cache - restore would otherwise keep using the old copy.
LOCAL_VERSION="4.0.0-local"
CREST_DIR="${ROOT_DIR}/modules/Crest"
PLATFORM_OUT="${CREST_DIR}/output/platform"
CREST_OUT="${CREST_DIR}/output/crest"
NUGET_CACHE="${NUGET_PACKAGES:-${HOME}/.nuget/packages}"
FORCE_RESTORE=0

ensure_submodules() {
  local dir
  for dir in "${CREST_DIR}"; do
    if [ -z "$(ls -A "${dir}" 2>/dev/null)" ]; then
      echo "Checking out submodule ${dir#${ROOT_DIR}/}..."
      git -C "${ROOT_DIR}" submodule update --init "${dir#${ROOT_DIR}/}"
    fi
  done
}

source_stamp() {
  local dir="$1"
  {
    git -C "${dir}" rev-parse HEAD
    git -C "${dir}" diff HEAD
    git -C "${dir}" ls-files --others --exclude-standard -z | (cd "${dir}" && xargs -0 -r sha1sum)
  } | sha1sum | cut -d' ' -f1
}

# Evict this version of every package in an output folder from the NuGet global cache.
evict_from_cache() {
  local nupkg id
  for nupkg in "$1"/*."${LOCAL_VERSION}".nupkg; do
    [ -e "${nupkg}" ] || continue
    id="$(basename "${nupkg}" ".${LOCAL_VERSION}.nupkg")"
    rm -rf "${NUGET_CACHE}/${id,,}/${LOCAL_VERSION}"
  done
}

pack_into_output() {
  local dir="$1" solution="$2" out="$3" stamp="$4"
  echo "Packing ${dir#${ROOT_DIR}/}/${solution} into ${out#${ROOT_DIR}/} (${LOCAL_VERSION})..."
  evict_from_cache "${out}"
  rm -rf "${out}"
  mkdir -p "${out}"
  (cd "${dir}" && dotnet pack "${solution}" -c Release -p:Version="${LOCAL_VERSION}" -p:PackageVersion="${LOCAL_VERSION}" -o "${out}")
  evict_from_cache "${out}"
  if [ -n "${stamp}" ]; then
    echo "${stamp}" > "${out}/.source-stamp"
  fi
  FORCE_RESTORE=1
}

pack_platform() {
  require_dotnet
  ensure_submodules
  # Crest's repo-root NuGet.config governs this restore/pack.
  pack_into_output "${CREST_DIR}" Crest.Platform.slnx "${PLATFORM_OUT}" ""
  if [ ! -f "${PLATFORM_OUT}/Crest.Application.Cms.Targets.${LOCAL_VERSION}.nupkg" ]; then
    echo "Pack finished but Crest.Application.Cms.Targets.${LOCAL_VERSION}.nupkg is missing." >&2
    exit 1
  fi
}

# Pack Crest's modules when their source changed since the last pack (or always, with
# force=1).
ensure_package_feeds() {
  local force="${1:-0}"
  require_dotnet
  ensure_submodules
  mkdir -p "${PLATFORM_OUT}" "${CREST_OUT}"
  if [ ! -f "${PLATFORM_OUT}/Crest.Application.Cms.Targets.${LOCAL_VERSION}.nupkg" ]; then
    echo "No platform ${LOCAL_VERSION} packages in modules/Crest/output/platform - packing it (slow, first run only)."
    pack_platform
  fi

  local crest_stamp
  crest_stamp="$(source_stamp "${CREST_DIR}")"
  if [ "${force}" = 1 ] || [ "$(cat "${CREST_OUT}/.source-stamp" 2>/dev/null)" != "${crest_stamp}" ]; then
    pack_into_output "${CREST_DIR}" Crest.slnx "${CREST_OUT}" "${crest_stamp}"
  fi
}

# After a repack the packages keep their version, so a no-op restore would not notice
# them; --force re-resolves against the fresh output/ folders.
restore_host() {
  local args=()
  if [ "${FORCE_RESTORE}" = 1 ]; then
    args+=(--force)
  fi
  dotnet restore "$1" --configfile "${ROOT_DIR}/NuGet.config" "${args[@]}"
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
  ensure_package_feeds
  restore_host "${SERVER_PROJECT}"
  dotnet build "${SERVER_PROJECT}" --no-restore
}

# The whole solution, test projects included. `dev.sh test` needs this rather than
# run_build: building only the host csproj leaves the test assemblies unbuilt, and
# `dotnet test --no-build` would then fail on them.
run_build_all() {
  ensure_package_feeds
  restore_host "${ROOT_DIR}/Crest.Host.slnx"
  dotnet build "${ROOT_DIR}/Crest.Host.slnx" --no-restore
}

# dotnet watch, not dotnet run: this host serves the Blazor WASM framework assets out
# of the referenced projects' staticwebassets (Program.cs maps /_framework), and a bare
# run never produces them on a rebuild.
run_server() {
  ensure_package_feeds
  cd "${ROOT_DIR}"
  dotnet build-server shutdown || true
  restore_host "${SERVER_PROJECT}"
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
  # dotnet watch supervises a child host process; stop the watcher first so it does not
  # restart what the second pattern is about to kill. It ignores SIGTERM, so a watcher that
  # is still there after a moment is killed outright - otherwise every stop leaves one
  # behind, and the stale watchers restart the host and fight over the port.
  local watch_pattern="dotnet(-watch\.dll| watch) --project .*Crest\.Host\.csproj"
  pkill -f "${watch_pattern}" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -f "${watch_pattern}" >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -9 -f "${watch_pattern}" >/dev/null 2>&1 || true
  pkill -f "${ROOT_DIR}/bin/.*/Crest.Host$" >/dev/null 2>&1 || true
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti :"${CREST_HOST_SERVER_PORT}" | xargs -r kill -9 >/dev/null 2>&1 || true
  fi
}

start_server_background() {
  restore_host "${SERVER_PROJECT}"
  mkdir -p "${DEV_DIR}/logs"
  (cd "${ROOT_DIR}" && nohup dotnet watch --project "${SERVER_PROJECT}" > "${DEV_DIR}/logs/server.log" 2>&1 &)

  echo "Waiting for ${CREST_HOST_SERVER_URL} to come up..."
  for _ in $(seq 1 60); do
    if url_is_up "${CREST_HOST_SERVER_URL}"; then
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

# Crest's own tests/run-tests.sh (which walks its subproject layout and runs
# its C# projects and shared suite one by one) is for running the submodule standalone.
# From here it is NOT called: every Crest test project is in Crest.Host.slnx, and the shared
# Crest checks are the head of dev/run-admin-suite.js, so calling it would run both a
# second time. It is also slow by construction - one `dotnet test` process per project,
# each re-restoring the whole graph.
#
# This host supplies credentials/URLs and decides when to run tests. Any module this host
# declares under modules/ other than Crest gets walked here.
run_module_tests() {
  local module_dir="$1"
  local module_name
  module_name="$(basename "${module_dir}")"
  local tests_dir="${module_dir}/tests"

  # Crest's C# tests come from the solution-wide run, and its browser checks from
  # dev/run-admin-suite.js. Nothing to walk here.
  if [ "${module_name}" = "Crest" ]; then
    return 0
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
      if ! BASE_URL="${CREST_HOST_SERVER_URL}" node "${test_file}"; then
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
  run_build_all

  if ! url_is_up "${CREST_HOST_SERVER_URL}"; then
    start_server_background
  fi

  local overall_failed=0

  # Every C# test project in one process: they are all in Crest.Host.slnx, and run_build above
  # already built them, so --no-build skips re-restoring and re-evaluating the project
  # graph. A new tests/ project is added to the solution, not to a loop here.
  #
  # The solution is .slnx, not .sln, and that matters: `dotnet sln add` on a .sln mirrors
  # each project's directory as a solution folder, and a folder named identically to a
  # sibling project is MSB5004 ("two projects named X"). .slnx keeps a flat project list,
  # so the test projects sit beside everything else with no collisions.
  # A test project on disk but absent from the solution would be silently skipped and the
  # run would still pass. Compare the two first and fail loudly on a mismatch.
  local unlisted=0
  local csproj
  while IFS= read -r -d '' csproj; do
    if ! grep -q "$(basename "${csproj}")" "${ROOT_DIR}/Crest.Host.slnx"; then
      echo "Test project not in Crest.Host.slnx: ${csproj#${ROOT_DIR}/}" >&2
      echo "  add it with: dotnet sln Crest.Host.slnx add <path>" >&2
      unlisted=$((unlisted + 1))
    fi
  done < <(find "${ROOT_DIR}/modules" -path "*/tests/*" -name "*.csproj" \
             -not -path "*/obj/*" -not -path "*/bin/*" -print0 2>/dev/null | sort -z)

  echo "=== C# tests (dotnet test Crest.Host.slnx --no-build) === $(date +%T)"
  if ((unlisted > 0)); then
    echo "${unlisted} test project(s) missing from the solution - not running a partial suite." >&2
    overall_failed=1
  else
    dotnet test "${ROOT_DIR}/Crest.Host.slnx" --no-build || overall_failed=1
  fi

  # ONE aggregated browser run: the shared Crest checks and the Crest modules' checks, in
  # one browser with one login. Running it per module would multiply the
  # whole suite by the number of modules with a tests/playwright folder.
  echo
  echo "=== Admin suite (dev/run-admin-suite.js) === $(date +%T)"
  BASE_URL="${CREST_HOST_SERVER_URL}" node "${DEV_DIR}/run-admin-suite.js" || overall_failed=1

  # Crest's public-site checks (anonymous localization, site smoke, the Blazor counter
  # island), against this instance. Output stays in this repo, not the submodule's.
  echo
  echo "=== Client suite (Crest's run-client-suite.js) === $(date +%T)"
  BASE_URL="${CREST_HOST_SERVER_URL}" OUTPUT_ROOT="${DEV_DIR}/playwright-output/client" \
    node "${ROOT_DIR}/modules/Crest/tests/playwright/run-client-suite.js" || overall_failed=1

  # Anything else a module ships that is not part of the aggregated suite.
  local module_dir
  while IFS= read -r -d '' module_dir; do
    [ -d "${module_dir}/tests" ] || continue
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
  pack)
    if [ "${2:-}" = all ]; then
      pack_platform
    fi
    ensure_package_feeds 1
    restore_host "${ROOT_DIR}/Crest.Host.slnx"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
