#!/usr/bin/env bash
#
# Lampac NextGen — native install for Debian / Ubuntu (amd64, arm64).
# Lampac NextGen installer managed copy (managed by installer).
# Downloads the GitHub release zip (same payload CI publishes), creates a system user,
# installs .NET ASP.NET Core 10 runtime + OS deps aligned with the Docker runner image,
# and registers a systemd unit.
#
# Update mode (--update): uses rsync --delete to remove old files not in the release,
# preserving user data via exclude patterns.
#
# Run as any user; sudo is used when needed.
#
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
INSTALL_ROOT="${LAMPAC_INSTALL_ROOT:-/opt/lampac}"
readonly LAMPAC_USER="${LAMPAC_USER:-lampac}"
readonly SERVICE_NAME="${LAMPAC_SERVICE_NAME:-lampac}"
readonly SYSTEMD_UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
# Override with LAMPAC_GITHUB_REPO=owner/name if your releases live elsewhere
readonly GITHUB_REPO="${LAMPAC_GITHUB_REPO:-lampac-nextgen/lampac}"
readonly RELEASE_ZIP_NAME="lampac-nextgen.zip"
readonly DOTNET_INSTALL_DIR="${LAMPAC_DOTNET_ROOT:-/usr/share/dotnet}"
readonly DOTNET_CHANNEL="${LAMPAC_DOTNET_CHANNEL:-10.0}"
readonly ICU_PACKAGE_CANDIDATES=(libicu78 libicu76 libicu74 libicu72 libicu70 libicu67)
LISTEN_PORT="${LAMPAC_PORT:-9118}"
# Имя скрипта — исключается из синхронизации при обновлении
readonly UPDATE_SCRIPT_NAME="install.sh"
# Имя файлика для хранения установленной версии Лампака
readonly VERSION_FILE_NAME="version.txt"
# Максимум символов ввода при явном подтверждении дисклеймера (длиннее — отказ)
readonly DISCLAIMER_MAX_INPUT_LEN=64
readonly MENU_MAX_INPUT_LEN=16

REMOVE=0
UPDATE=0
INSTALL_SETUP_ONLY=0
DRY_RUN=0
PRE_RELEASE=0
VERBOSE=0
FORCE=0
TARGET_VERSION=""
ARCH=""
PUBLISH_URL=""
OPERATION_SKIPPED=0
RECENT_RELEASE_TAGS=()
MENU_KIND=""
MENU_ALCOPAC_ITEM=""
MENU_BOOTSTRAP_ITEM=""
MENU_SESSION_ACTIVE=0
MENU_CHECKS_READY=0
POST_INSTALL_MENU=0
DISCLAIMER_ACCEPTED=0
PROGRESS_TOTAL=0
SETUP_MENU_ITEM=""
PORT_MENU_ITEM=""
CLEANUP_PATHS=()
# Set while service is stopped during --update; EXIT trap may restart it.
_UPDATE_SERVICE_STOPPED=0

# ─── Colors ──────────────────────────────────────────────────────────────────

_tty_escape() { printf '\033[%sm' "$1"; }

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$(_tty_escape 0)
  C_BOLD=$(_tty_escape 1)
  C_DIM=$(_tty_escape 2)
  C_RED=$(_tty_escape "1;31")
  C_GREEN=$(_tty_escape "1;32")
  C_YELLOW=$(_tty_escape "1;33")
  C_BLUE=$(_tty_escape "1;34")
  C_CYAN=$(_tty_escape "1;36")
  C_WHITE=$(_tty_escape "1;37")
  C_GRAY=$(_tty_escape "0;37")
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW=""
  C_BLUE="" C_CYAN="" C_WHITE="" C_GRAY=""
fi

# ─── Logging ─────────────────────────────────────────────────────────────────

log_info()    { printf '  %s→%s  %s\n'     "$C_BLUE"   "$C_RESET" "$*"; }
log_ok()      { printf '  %s✓%s  %s\n'     "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()    { printf '  %s⚠%s  %s\n'     "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()     { printf '  %s✗%s  %s\n'     "$C_RED"    "$C_RESET" "$*" >&2; }
log_skip()    { printf '  %s·%s  %s%s%s\n' "$C_GRAY"   "$C_RESET" "$C_DIM" "$*" "$C_RESET"; }
log_del()     { printf '  %s−%s  %s%s%s\n' "$C_RED"    "$C_RESET" "$C_DIM" "$*" "$C_RESET"; }
log_upd()     { printf '  %s+%s  %s\n'     "$C_GREEN"  "$C_RESET" "$*"; }

run_quiet() {
  local label="$1"; shift
  if [[ "$VERBOSE" -eq 1 ]]; then
    log_info "$label"
    if ! "$@"; then
      log_err "$label — failed"
      exit 1
    fi
    log_ok "$label"
    return 0
  fi
  local _log exit_code
  _log="$(mktemp)"
  spinner_start "$label"
  if ! "$@" >"$_log" 2>&1; then
    exit_code=$?
    spinner_stop
    log_err "$label"
    printf '\n' >&2
    tail -20 "$_log" | sed 's/^/    /' >&2
    printf '\n' >&2
    rm -f "$_log"
    exit "$exit_code"
  fi
  spinner_ok "$label"
  rm -f "$_log"
}

progress_render() {
  local completed="$1" total="$2" phase="$3" status="$4"
  local width=24 filled percent i
  filled=$(( completed * width / total ))
  percent=$(( completed * 100 / total ))

  printf '\n  Прогресс: %s[' "$C_CYAN"
  for ((i = 0; i < width; i = i + 1)); do
    if (( i < filled )); then
      printf '#'
    elif (( i == filled && completed < total )); then
      printf '>'
    else
      printf '-'
    fi
  done
  printf ']%s %3d%%\n' "$C_RESET" "$percent"
  printf '  Этап:   %s\n' "$phase"
  printf '  Сейчас: %s\n\n' "$status"
}

step() {
  local n="$1" total="$2" label="$3" status="$4"
  PROGRESS_TOTAL="$total"
  progress_render "$((n - 1))" "$total" "${n} из ${total} — ${label}" "$status"
}

progress_finish() {
  local status="${1:-Все этапы завершены.}"
  (( PROGRESS_TOTAL > 0 )) || return 0
  progress_render "$PROGRESS_TOTAL" "$PROGRESS_TOTAL" "Все этапы завершены" "$status"
}

# ─── Spinner ─────────────────────────────────────────────────────────────────

_SPINNER_PID=""

spinner_start() {
  [[ ! -t 1 ]] && return
  local msg="${1:-Working...}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local start=$SECONDS
  (
    local i=0
    while true; do
      local elapsed=$(( SECONDS - start ))
      printf '\r  %s%s%s  %s %s(%ds)%s' \
        "$C_CYAN" "${frames[$((i % ${#frames[@]}))]}" "$C_RESET" \
        "$msg" "$C_DIM" "$elapsed" "$C_RESET"
      sleep 0.1
      (( i++ )) || true
    done
  ) &
  _SPINNER_PID=$!
  disown "$_SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
  [[ -z "$_SPINNER_PID" ]] && return
  kill "$_SPINNER_PID" 2>/dev/null || true
  wait "$_SPINNER_PID" 2>/dev/null || true
  _SPINNER_PID=""
  printf '\r\033[K'
}

spinner_ok() {
  spinner_stop
  log_ok "$1"
}

spinner_err() {
  spinner_stop
  log_err "$1"
}

# ─── Banner ──────────────────────────────────────────────────────────────────

print_banner() {
  printf '\n'
  printf '%s  ██╗      █████╗ ███╗   ███╗██████╗  █████╗  ██████╗%s\n'  "$C_CYAN" "$C_RESET"
  printf '%s  ██║     ██╔══██╗████╗ ████║██╔══██╗██╔══██╗██╔════╝%s\n'  "$C_CYAN" "$C_RESET"
  printf '%s  ██║     ███████║██╔████╔██║██████╔╝███████║██║%s\n'        "$C_CYAN" "$C_RESET"
  printf '%s  ██║     ██╔══██║██║╚██╔╝██║██╔═══╝ ██╔══██║██║%s\n'       "$C_CYAN" "$C_RESET"
  printf '%s  ███████╗██║  ██║██║ ╚═╝ ██║██║     ██║  ██║╚██████╗%s\n'  "$C_CYAN" "$C_RESET"
  printf '%s  ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝     ╚═╝  ╚═╝ ╚═════╝%s\n' "$C_CYAN" "$C_RESET"
  printf '%s                                          %sNextGen%s\n'      "$C_CYAN" "$C_WHITE" "$C_RESET"
  printf '\n'
}

# ─── Disclaimer ──────────────────────────────────────────────────────────────

# Интерактивный режим: stdout — терминал и /dev/tty доступен для чтения.
# При curl | bash stdout остаётся терминалом, подтверждение читается из /dev/tty.
has_interactive_tty() {
  [[ -t 1 ]] && [[ -r /dev/tty ]]
}

# Запуск с CLI-операцией (--remove / --update / --tag / --pre-release) идёт
# напрямую и в интерактивное меню (а значит, и в гейт дисклеймера) не входит.
cli_operation_requested() {
  (( REMOVE == 1 || UPDATE == 1 || PRE_RELEASE == 1 || INSTALL_SETUP_ONLY == 1 )) || [[ -n "$TARGET_VERSION" ]]
}

show_disclaimer() {
  # Печать без ANSI: текст читается и без цвета, и при NO_COLOR.
  cat <<'EOF_DISCLAIMER'
================================================================================

  Дисклеймер — прочитайте полностью перед продолжением

  Программа Lampac NextGen предоставляется «как есть» (as is) и без
  каких-либо гарантий. Автор и сопровождающие репозитория не принимают
  ответственность за прямой или косвенный ущерб, в пределах, допускаемых
  применимым правом.

  Продолжая, вы принимаете на себя риски использования и обязаны
  самостоятельно проверить:

    - законность использования программы в вашей юрисдикции;
    - права на контент и взаимодействие со сторонними сервисами;
    - безопасность, настройки сети и доступ к серверу;
    - целостность данных и наличие резервных копий.

  Установка и обновление меняют программное обеспечение, конфигурацию
  и системные службы. Этот текст не является юридической консультацией
  и не лишает вас законных прав. Продолжать при несогласии с условиями
  нельзя: любой ввод, кроме явного согласия, остановит установщик до
  выполнения каких-либо операций.

  Summary (EN): Lampac NextGen is provided "as is", with no warranty.
  The author and repository maintainers accept no liability for direct
  or indirect damage, to the extent permitted by applicable law. You
  carry the risks and are responsible for checking legality of use,
  content rights, security, network and access settings, third-party
  services, and data integrity and backups. Install and update change
  the software, configuration, and services. This notice is not legal
  advice and does not waive your statutory rights. Type exactly "yes"
  to continue; anything else stops the installer.

================================================================================
EOF_DISCLAIMER
}

# Явное согласие с дисклеймером: только точное «yes» или «да».
# Возвращает 0 при согласии и 1 при отказе; при EOF завершает работу (код 1).
confirm_disclaimer() {
  local answer

  printf '  Введите %syes%s или %sда%s для продолжения (любое другое значение — выход): ' \
    "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"

  # Ctrl+C во время вопроса — предсказуемый выход: операции ещё не начаты.
  trap 'printf "\n"; log_warn "Ввод прерван (Ctrl+C) — согласие не дано."; exit 130' INT
  if ! read -r answer </dev/tty; then
    trap - INT
    log_warn "Ввод закрыт (EOF) — согласие не дано."
    exit 1
  fi
  trap - INT

  if (( ${#answer} > DISCLAIMER_MAX_INPUT_LEN )); then
    log_warn "Слишком длинный ввод — согласие не дано."
    return 1
  fi

  case "$answer" in
    yes|да)
      return 0
      ;;
    "")
      log_warn "Пустой ввод — согласие не дано."
      return 1
      ;;
    *)
      log_warn "Подтверждение не распознано (ожидается точно: yes или да)."
      return 1
      ;;
  esac
}

ensure_disclaimer_consent() {
  (( DISCLAIMER_ACCEPTED )) && return 0
  show_disclaimer
  if ! confirm_disclaimer; then
    log_info "Согласие не дано — операция не выполнялась."
    return 1
  fi
  DISCLAIMER_ACCEPTED=1
}

# ─── Existing installations (read-only check) ───────────────────────────────
#
# Диагностика ранее установленных копий перед неявной установкой. Разрешено
# только читающее: systemctl show (load/active state, Description, ExecStart,
# FragmentPath), проверка наличия ровно ожидаемых файлов (Core.dll у Lampac;
# lampac-go, config.toml у Al(co)pac) в каталоге юнита или в установленном
# INSTALL_ROOT, read-only docker container inspect по точным именам lampac и
# alcopac (running, image и host-пути bind mounts; env, labels и секреты не читаются).
# Запрещено и не выполняется: чтение значений секретов и содержимого
# config.toml / init.conf / .env, вывод Environment из юнитов, запуск,
# остановка или перезапуск служб и контейнеров, запись, сканирование диска.
# Итог для повторного использования (будущее меню): числовые уровни по каждому
# продукту и сводный счётчик EXISTING_HITS после run_existing_checks.

# Уровни уверенности: не найдено / вероятно / подтверждено.
readonly CHK_NOT_FOUND=0
readonly CHK_PROBABLE=1
readonly CHK_CONFIRMED=2

# Документированные следы Al(co)pac (wiki.alcopa.cc/docs/install/curl/ и
# wiki.alcopa.cc/docs/install/docker/): юнит alcopac.service, каталог
# /opt/lampac, бинарь lampac-go, конфиг config.toml, в Docker — контейнер
# с точным именем alcopac.
readonly ALCOPAC_UNIT="alcopac.service"
readonly ALCOPAC_DOC_PATH="/opt/lampac"
readonly ALCOPAC_DOCKER_NAME="alcopac"
readonly ALCOPAC_SYSTEMD_UNIT_PATH="/etc/systemd/system/alcopac.service"
readonly LAMPAC_SYSTEMD_UNIT_PATH="/etc/systemd/system/lampac.service"

# Lampac NextGen в Docker (docker-compose.yaml): точное имя контейнера lampac
# и образ ghcr.io/lampac-nextgen/lampac. Тег/дайджест того же имени реестра
# считается NextGen; имена других образов подтверждением не являются.
readonly LAMPAC_DOCKER_NAME="lampac"
readonly LAMPAC_DOCKER_IMAGE="ghcr.io/lampac-nextgen/lampac"

# Сброс результатов проверки (для повторного вызова из будущего меню).
reset_existing_state() {
  # lampac.service: NextGen по метке юнита либо неуточнённый (legacy-кандидат).
  EXISTING_LAMPAC=$CHK_NOT_FOUND
  EXISTING_LAMPAC_KIND="none"
  EXISTING_LAMPAC_LOAD=""
  EXISTING_LAMPAC_ACTIVE=""
  EXISTING_LAMPAC_DESC=""
  EXISTING_LAMPAC_PATH=""
  EXISTING_LAMPAC_PATH_SRC=""
  EXISTING_LAMPAC_UNIT_PATH=""
  EXISTING_LAMPAC_EXEC_PATH=""
  EXISTING_LAMPAC_LAYOUT=0
  EXISTING_LAMPAC_LAYOUT_PATH=""
  # alcopac.service: подтверждено только при найденном бинаре lampac-go.
  EXISTING_ALCOPAC=$CHK_NOT_FOUND
  EXISTING_ALCOPAC_LOAD=""
  EXISTING_ALCOPAC_ACTIVE=""
  EXISTING_ALCOPAC_DESC=""
  EXISTING_ALCOPAC_PATH=""
  EXISTING_ALCOPAC_PATH_SRC=""
  EXISTING_ALCOPAC_FILES=""
  EXISTING_ALCOPAC_UNIT_PATH=""
  EXISTING_ALCOPAC_EXEC_PATH=""
  # Контейнер alcopac (Docker).
  EXISTING_ALCOPAC_DOCKER=$CHK_NOT_FOUND
  EXISTING_ALCOPAC_DOCKER_RUNNING=""
  EXISTING_ALCOPAC_DOCKER_IMAGE=""
  EXISTING_ALCOPAC_DOCKER_BIND_PATHS=""
  # Контейнер lampac (Docker): NextGen по образу либо неуточнённый.
  EXISTING_LAMPAC_DOCKER=$CHK_NOT_FOUND
  EXISTING_LAMPAC_DOCKER_RUNNING=""
  EXISTING_LAMPAC_DOCKER_IMAGE=""
  EXISTING_LAMPAC_DOCKER_BIND_PATHS=""
  EXISTING_DOCKER_PRESENT=0
  EXISTING_DOCKER_UNAVAILABLE=0
  EXISTING_SYSTEMD_UNAVAILABLE=0
  EXISTING_HITS=0
}

reset_existing_state

# Обрезать пробелы по краям строки.
trim_string() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Убрать управляющие символы (в т.ч. escape-последовательности) из текста,
# полученного извне, перед выводом в терминал. UTF-8 сохраняется.
sanitize_external_text() {
  printf '%s' "$1" | tr -d '\000-\010\013-\037\177'
}

show_system_info() {
  local os_name="Linux"

  if [[ -r /etc/os-release ]]; then
    os_name="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n1)"
    os_name="${os_name#\"}"
    os_name="${os_name%\"}"
    os_name="$(sanitize_external_text "$os_name")"
  fi

  printf '\n  %s─── Проверка системы ───%s\n\n' "$C_CYAN" "$C_RESET"
  printf '  %sОС:%s           %s\n' "$C_BOLD" "$C_RESET" "$os_name"
  printf '  %sАрхитектура:%s  %s\n' "$C_BOLD" "$C_RESET" "$ARCH"
}

aspnetcore_runtime_version() {
  local dotnet_path="${DOTNET_INSTALL_DIR}/dotnet" dotnet_runtimes=""
  if [[ -x "${DOTNET_INSTALL_DIR}/dotnet" ]]; then
    dotnet_runtimes="$("$dotnet_path" --list-runtimes 2>/dev/null || true)"
    printf '%s\n' "$dotnet_runtimes" | awk '$1 == "Microsoft.AspNetCore.App" && $2 ~ /^10\./ {print $2; exit}'
  fi
}

required_system_packages() {
  printf '%s\n' \
    ca-certificates curl jq fontconfig \
    gstreamer1.0-libav gstreamer1.0-plugins-bad gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-base-apps gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly \
    gstreamer1.0-tools imagemagick libgstreamer-plugins-base1.0-0 libgstreamer1.0-0 \
    libjpeg-dev libnspr4 libpng-dev libwebp-dev unzip rsync
}

package_is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

minimum_installer_dependencies_ready() {
  package_is_installed ca-certificates && command -v curl >/dev/null 2>&1
}

# Read-only preflight: compares the same apt package list as install_os_packages,
# plus separately installed runtime/browser dependencies.
show_install_dependency_check() {
  local package runtime_version icu_found=0 installed=0 total=0

  printf '\n  %s─── Проверка зависимостей установки (read-only) ───%s\n\n' "$C_BOLD" "$C_RESET"
  if ! command -v dpkg-query >/dev/null 2>&1; then
    log_warn "dpkg-query недоступен — статус системных пакетов не удалось проверить."
    return 0
  fi

  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    total=$((total + 1))
    if package_is_installed "$package" && { [[ "$package" != "curl" ]] || command -v curl >/dev/null 2>&1; }; then
      installed=$((installed + 1))
    fi
  done < <(required_system_packages)

  total=$((total + 1))
  for package in "${ICU_PACKAGE_CANDIDATES[@]}"; do
    if package_is_installed "$package"; then
      icu_found=1
      installed=$((installed + 1))
      break
    fi
  done

  printf '  APT-зависимости: %d из %d установлено.\n' "$installed" "$total"
  if (( installed < total )); then
    log_warn "Недостающее будет подготовлено при установке/обновлении; базовые средства загрузки можно установить отдельным пунктом меню."
  else
    log_ok "Все проверяемые APT-зависимости уже установлены."
  fi

  runtime_version="$(aspnetcore_runtime_version)"
  if [[ -n "$runtime_version" ]]; then
    log_ok "ASP.NET Core ${runtime_version} установлен."
  else
    log_warn "ASP.NET Core ${DOTNET_CHANNEL} не установлен; установщик добавит runtime при выборе операции."
  fi
  if command -v google-chrome-stable >/dev/null 2>&1; then
    log_ok "Google Chrome установлен."
  else
    log_warn "Google Chrome не установлен; установщик добавит его при выборе операции."
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
    log_ok "Менеджер systemd доступен."
  else
    log_warn "Менеджер systemd недоступен; запуск службы может быть невозможен в этой среде."
  fi
}

# systemctl show — только чтение: LoadState / ActiveState / Description /
# ExecStart / FragmentPath. Environment юнита и содержимое юнит-файла целиком
# не печатаются и не читаются (Environment может содержать секреты).
# Возврат: 0 — юнит загружен, 1 — юнита нет, 2 — systemd недоступен.
unit_info() {
  local unit="$1" line out rc=0

  EXISTING_UNIT_LOAD=""
  EXISTING_UNIT_ACTIVE=""
  EXISTING_UNIT_DESC=""
  EXISTING_UNIT_EXEC=""
  EXISTING_UNIT_FRAGMENT=""

  out="$(systemctl show "$unit" \
    -p LoadState -p ActiveState -p Description -p ExecStart -p FragmentPath \
    2>/dev/null)" || rc=$?

  if (( rc != 0 )) || [[ -z "$out" ]]; then
    return 2
  fi

  while IFS= read -r line; do
    case "$line" in
      LoadState=*)    EXISTING_UNIT_LOAD="${line#LoadState=}" ;;
      ActiveState=*)  EXISTING_UNIT_ACTIVE="${line#ActiveState=}" ;;
      Description=*)  EXISTING_UNIT_DESC="${line#Description=}" ;;
      ExecStart=*)    EXISTING_UNIT_EXEC="${line#ExecStart=}" ;;
      FragmentPath=*) EXISTING_UNIT_FRAGMENT="${line#FragmentPath=}" ;;
    esac
  done <<< "$out"

  # systemd отвечает, но свойств не вернул — считаем недоступным.
  [[ -n "$EXISTING_UNIT_LOAD" ]] || return 2

  case "$EXISTING_UNIT_LOAD" in
    not-found) return 1 ;;
  esac
  return 0
}

# Путь бинаря приложения из argv[] юнита. systemctl show обычно выдаёт
# `argv[]=/path/to/app arg1 ; ...`; старые форматы могли использовать скобки
# и разделять аргументы точкой с запятой.
exec_app_path_hint() {
  local exec_line="$1" argv token
  local toks=()

  argv="${exec_line#*argv\[\]=}"
  if [[ "$argv" == "$exec_line" ]]; then
    return 1
  fi
  if [[ "$argv" == \{* ]]; then
    argv="${argv#\{}"
    argv="${argv%%\}*}"
    argv="${argv//;/ }"
  else
    argv="${argv%%;*}"
  fi

  read -r -a toks <<< "$argv" || return 1
  for token in "${toks[@]}"; do
    token="$(trim_string "$token")"
    case "$token" in
      */Core.dll|*/lampac-go)
        printf '%s\n' "$token"
        return 0
        ;;
    esac
  done
  return 1
}

# Каталог установки из пути приложения, указанного в ExecStart.
exec_dir_hint() {
  local app_path

  app_path="$(exec_app_path_hint "$1")" || return 1
  printf '%s\n' "${app_path%/*}"
}

# Рабочий каталог установки из юнита: строка WorkingDirectory= юнит-файла
# (читается только она), иначе каталог бинаря из ExecStart.
unit_workdir_hint() {
  local wd

  if [[ -n "$EXISTING_UNIT_FRAGMENT" && -r "$EXISTING_UNIT_FRAGMENT" ]]; then
    wd="$(grep -m1 '^WorkingDirectory=' "$EXISTING_UNIT_FRAGMENT" 2>/dev/null)" || wd=""
    if [[ -n "$wd" ]]; then
      wd="${wd#WorkingDirectory=}"
      wd="$(trim_string "$wd")"
      wd="${wd#-}"    # "-" в systemd = «игнорировать, если не существует»
      if [[ "${#wd}" -ge 2 && "$wd" == \"*\" && "$wd" == *\" ]]; then
        wd="${wd#\"}"
        wd="${wd%\"}"
      fi
      if [[ -n "$wd" ]]; then
        printf '%s\n' "$wd"
        return 0
      fi
    fi
  fi

  exec_dir_hint "$EXISTING_UNIT_EXEC"
}

# Наличие ожидаемых файлов Al(co)pac в каталоге. Содержимое НЕ читается:
# только имена. Печатает найденные имена через пробел.
alcopac_probe_dir() {
  local dir="$1" found=""

  [[ -n "$dir" ]] || { printf '\n'; return 0; }

  if [[ -e "$dir/lampac-go" ]]; then
    found="lampac-go"
  fi
  if [[ -f "$dir/config.toml" ]]; then
    found="${found:+$found }config.toml"
  fi
  printf '%s\n' "$found"
}

# Native Lampac: существующий lampac.service. Явная метка «Lampac NextGen»
# в Description юнита — признак NextGen (подтверждено); юнит без метки —
# неуточнённый вариант, он так и называется, без ложных утверждений.
check_unit_lampac() {
  local rc=0 desc hint exec_path

  if (( EXISTING_SYSTEMD_UNAVAILABLE )); then
    return 0
  fi

  unit_info lampac.service || rc=$?
  if (( rc == 2 )); then
    EXISTING_SYSTEMD_UNAVAILABLE=1
    return 0
  fi
  if (( rc != 0 )); then
    return 0
  fi

  EXISTING_LAMPAC_LOAD="$EXISTING_UNIT_LOAD"
  EXISTING_LAMPAC_ACTIVE="$EXISTING_UNIT_ACTIVE"
  EXISTING_LAMPAC_UNIT_PATH="$(sanitize_external_text "$EXISTING_UNIT_FRAGMENT")"
  exec_path="$(exec_app_path_hint "$EXISTING_UNIT_EXEC")" || exec_path=""
  EXISTING_LAMPAC_EXEC_PATH="$(sanitize_external_text "$exec_path")"

  desc="$EXISTING_UNIT_DESC"
  if [[ -z "$desc" && -n "$EXISTING_UNIT_FRAGMENT" && -r "$EXISTING_UNIT_FRAGMENT" ]]; then
    desc="$(grep -m1 '^Description=' "$EXISTING_UNIT_FRAGMENT" 2>/dev/null)" || desc=""
    desc="$(trim_string "${desc#Description=}")"
  fi
  EXISTING_LAMPAC_DESC="$(sanitize_external_text "$desc")"

  case "${EXISTING_LAMPAC_DESC,,}" in
    *"lampac nextgen"*)
      EXISTING_LAMPAC="$CHK_CONFIRMED"
      EXISTING_LAMPAC_KIND="nextgen"
      ;;
    *)
      EXISTING_LAMPAC="$CHK_PROBABLE"
      EXISTING_LAMPAC_KIND="unknown"
      ;;
  esac

  hint="$(unit_workdir_hint)" || hint=""
  if [[ -n "$hint" ]]; then
    EXISTING_LAMPAC_PATH="$(sanitize_external_text "$hint")"
    EXISTING_LAMPAC_PATH_SRC="unit"
    if [[ -e "$hint/Core.dll" ]]; then
      EXISTING_LAMPAC_LAYOUT=1
      if [[ -z "$EXISTING_LAMPAC_LAYOUT_PATH" ]]; then
        EXISTING_LAMPAC_LAYOUT_PATH="${EXISTING_LAMPAC_PATH}/Core.dll"
      fi
    fi
  fi
  return 0
}

# Native Al(co)pac: юнит alcopac.service. «Подтверждено» — это сочетание
# юнита и бинаря lampac-go в рабочем каталоге юнита или в документированном
# /opt/lampac. config.toml — дополнительный признак, один он подтверждением
# не является. Отсутствие файлов факт юнита не отменяет: уровень снижается.
check_unit_alcopac() {
  local rc=0 hint probe p d exec_path
  local probe_dirs=()
  local display_dir="" display_src=""

  if (( EXISTING_SYSTEMD_UNAVAILABLE )); then
    return 0
  fi

  unit_info "$ALCOPAC_UNIT" || rc=$?
  if (( rc == 2 )); then
    EXISTING_SYSTEMD_UNAVAILABLE=1
    return 0
  fi
  if (( rc != 0 )); then
    return 0
  fi

  EXISTING_ALCOPAC="$CHK_PROBABLE"
  EXISTING_ALCOPAC_LOAD="$EXISTING_UNIT_LOAD"
  EXISTING_ALCOPAC_ACTIVE="$EXISTING_UNIT_ACTIVE"
  EXISTING_ALCOPAC_DESC="$(sanitize_external_text "$EXISTING_UNIT_DESC")"
  EXISTING_ALCOPAC_UNIT_PATH="$(sanitize_external_text "$EXISTING_UNIT_FRAGMENT")"
  exec_path="$(exec_app_path_hint "$EXISTING_UNIT_EXEC")" || exec_path=""
  EXISTING_ALCOPAC_EXEC_PATH="$(sanitize_external_text "$exec_path")"

  hint="$(unit_workdir_hint)" || hint=""
  if [[ -n "$hint" ]]; then
    probe_dirs+=("$hint")
  fi
  if [[ -z "$hint" || "$hint" != "$ALCOPAC_DOC_PATH" ]]; then
    probe_dirs+=("$ALCOPAC_DOC_PATH")
  fi

  for d in "${probe_dirs[@]}"; do
    probe="$(alcopac_probe_dir "$d")"
    for p in $probe; do
      case " $EXISTING_ALCOPAC_FILES " in
        *" $p "*) ;;
        *) EXISTING_ALCOPAC_FILES="${EXISTING_ALCOPAC_FILES:+$EXISTING_ALCOPAC_FILES }$p" ;;
      esac
    done
    if [[ -n "$probe" && -z "$display_dir" ]]; then
      display_dir="$d"
      if [[ "$d" == "$ALCOPAC_DOC_PATH" ]]; then
        display_src="default"
      else
        display_src="unit"
      fi
    fi
    if [[ " $probe " == *" lampac-go "* ]]; then
      EXISTING_ALCOPAC="$CHK_CONFIRMED"
      break
    fi
  done

  if [[ -z "$display_dir" ]]; then
    if [[ -n "$hint" ]]; then
      display_dir="$hint"
      display_src="unit"
    else
      display_dir="$ALCOPAC_DOC_PATH"
      display_src="default"
    fi
  fi

  EXISTING_ALCOPAC_PATH="$(sanitize_external_text "$display_dir")"
  EXISTING_ALCOPAC_PATH_SRC="$display_src"
  return 0
}

# Образ однозначно указывает на Lampac NextGen: точное имя реестра из
# docker-compose.yaml с необязательным тегом (…:1.2.3) или дайджестом
# (…@sha256:…). Форки, локальные сборки и пустое значение подтверждением
# NextGen не являются.
lampac_docker_image_is_nextgen() {
  case "$1" in
    "$LAMPAC_DOCKER_IMAGE"|"$LAMPAC_DOCKER_IMAGE:"*|"$LAMPAC_DOCKER_IMAGE@"*) return 0 ;;
  esac
  return 1
}

alcopac_docker_image_is_supported() {
  case "$1" in
    alcopac|alcopac:*) return 0 ;;
  esac
  return 1
}

# Пути bind-mount контейнера — это каталоги хоста, а не содержимое конфигурации.
# Показываются только для уже найденного контейнера, чтобы диагностика объясняла
# нестандартное расположение данных без чтения env, labels или файлов.
docker_bind_mount_paths() {
  local name="$1" out line paths=""

  out="$(docker container inspect \
    --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\\n"}}{{end}}{{end}}' \
    "$name" 2>/dev/null)" || return 0

  while IFS= read -r line; do
    line="$(sanitize_external_text "$line")"
    [[ -n "$line" ]] || continue
    paths="${paths:+$paths; }$line"
  done <<< "$out"
  printf '%s' "$paths"
}

# Docker: точные имена контейнеров lampac (Lampac NextGen) и alcopac.
# Основной inspect сообщает running и image. Для найденного контейнера отдельно
# читаются только bind-mount пути; env, labels, порты, секреты и весь список
# контейнеров не читаются. Отсутствие контейнера — стандартное «следов не
# найдено»; недоступный демон или запрет доступа — «Docker недоступен для проверки».
check_docker_containers() {
  local out rc=0 line rest
  local got_lampac=0 got_alcopac=0

  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  EXISTING_DOCKER_PRESENT=1

  out="$(docker container inspect \
    --format '{{.Name}}|{{.State.Running}}|{{.Config.Image}}' \
    "$LAMPAC_DOCKER_NAME" "$ALCOPAC_DOCKER_NAME" 2>&1)" || rc=$?

  # docker печатает данные найденных контейнеров даже при rc != 0
  # (частичный успех, когда одного из имён нет).
  while IFS= read -r line; do
    case "$line" in
      "/${LAMPAC_DOCKER_NAME}|"*|"${LAMPAC_DOCKER_NAME}|"*)
        got_lampac=1
        rest="${line#*|}"    # после первого поля: "<running>|<image>" — '|' в имени образа нет
        EXISTING_LAMPAC_DOCKER_RUNNING="$(trim_string "${rest%%|*}")"
        EXISTING_LAMPAC_DOCKER_IMAGE="$(sanitize_external_text "${rest#*|}")"
        ;;
      "/${ALCOPAC_DOCKER_NAME}|"*|"${ALCOPAC_DOCKER_NAME}|"*)
        got_alcopac=1
        rest="${line#*|}"
        EXISTING_ALCOPAC_DOCKER_RUNNING="$(trim_string "${rest%%|*}")"
        EXISTING_ALCOPAC_DOCKER_IMAGE="$(sanitize_external_text "${rest#*|}")"
        ;;
    esac
  done <<< "$out"

  if (( got_lampac )); then
    EXISTING_LAMPAC_DOCKER_BIND_PATHS="$(docker_bind_mount_paths "$LAMPAC_DOCKER_NAME")"
    if lampac_docker_image_is_nextgen "$EXISTING_LAMPAC_DOCKER_IMAGE"; then
      EXISTING_LAMPAC_DOCKER="$CHK_CONFIRMED"
    else
      EXISTING_LAMPAC_DOCKER="$CHK_PROBABLE"
    fi
  fi
  if (( got_alcopac )); then
    EXISTING_ALCOPAC_DOCKER_BIND_PATHS="$(docker_bind_mount_paths "$ALCOPAC_DOCKER_NAME")"
    if alcopac_docker_image_is_supported "$EXISTING_ALCOPAC_DOCKER_IMAGE"; then
      EXISTING_ALCOPAC_DOCKER="$CHK_CONFIRMED"
    else
      EXISTING_ALCOPAC_DOCKER="$CHK_PROBABLE"
    fi
  fi

  case "$out" in
    *"No such container"*|*"No such object"*) : ;;
    *)
      if (( rc != 0 )); then
        EXISTING_DOCKER_UNAVAILABLE=1
      fi
      ;;
  esac
  return 0
}

# Read-only проверка всех продуктов; числовой итог — в EXISTING_HITS.
run_existing_checks() {
  reset_existing_state

  if ! command -v systemctl >/dev/null 2>&1; then
    EXISTING_SYSTEMD_UNAVAILABLE=1
  fi
  check_unit_lampac
  check_unit_alcopac

  check_docker_containers

  if [[ -f "${INSTALL_ROOT}/Core.dll" ]]; then
    EXISTING_LAMPAC_LAYOUT=1
    if [[ -z "$EXISTING_LAMPAC_LAYOUT_PATH" ]]; then
      EXISTING_LAMPAC_LAYOUT_PATH="${INSTALL_ROOT}/Core.dll"
    fi
    if (( EXISTING_LAMPAC == CHK_NOT_FOUND )); then
      EXISTING_LAMPAC="$CHK_PROBABLE"
    fi
  fi

  EXISTING_HITS=$(( (EXISTING_LAMPAC > 0) + (EXISTING_ALCOPAC > 0) + (EXISTING_LAMPAC_DOCKER > 0) + (EXISTING_ALCOPAC_DOCKER > 0) ))
}

# Сводный список найденного: продукт + способ + уровень уверенности.
# Используется на экране проверки и в блокирующем сообщении main.
existing_found_list() {
  local list=""
  if (( EXISTING_LAMPAC == CHK_CONFIRMED )); then
    list="Lampac NextGen (системная установка, не Docker) — подтверждено"
  elif (( EXISTING_LAMPAC == CHK_PROBABLE )); then
    list="Lampac legacy или неуточнённая версия (системная установка, не Docker) — вероятно"
  fi
  if (( EXISTING_ALCOPAC == CHK_CONFIRMED )); then
    list+="${list:+; }Al(co)pac (системная установка, не Docker) — подтверждено"
  elif (( EXISTING_ALCOPAC == CHK_PROBABLE )); then
    list+="${list:+; }Al(co)pac (системная установка, не Docker) — вероятно"
  fi
  if (( EXISTING_LAMPAC_DOCKER == CHK_CONFIRMED )); then
    list+="${list:+; }Lampac NextGen (Docker) — подтверждено"
  elif (( EXISTING_LAMPAC_DOCKER == CHK_PROBABLE )); then
    list+="${list:+; }Lampac (Docker, неуточнённая версия) — вероятно"
  fi
  if (( EXISTING_ALCOPAC_DOCKER == CHK_CONFIRMED )); then
    list+="${list:+; }Al(co)pac (Docker) — подтверждено"
  fi
  printf '%s' "$list"
}

# Экран краткой сводки проверки. Путь показывается только если он пришёл
# из юнита или это документированный дефолт Al(co)pac.
show_existing_checks() {
  printf '\n  %s─── Проверка ранее установленных копий (read-only, ничего не изменяется) ───%s\n\n' \
    "$C_BOLD" "$C_RESET"

  if (( EXISTING_HITS == 0 )); then
    log_ok "Lampac NextGen и Al(co)pac не обнаружены."
    if (( EXISTING_SYSTEMD_UNAVAILABLE )); then
      log_warn "systemd недоступен для проверки системных установок."
    fi
    if (( EXISTING_DOCKER_UNAVAILABLE )); then
      log_warn "Docker недоступен для проверки контейнеров."
    elif (( ! EXISTING_DOCKER_PRESENT )); then
      log_skip "Docker не найден — проверка контейнеров недоступна."
    fi
    return 0
  fi

  if (( EXISTING_SYSTEMD_UNAVAILABLE )); then
    log_skip "systemd недоступен для проверки системных служб (lampac.service, ${ALCOPAC_UNIT})"
  fi

  if (( EXISTING_LAMPAC == CHK_CONFIRMED )); then
    log_ok "Lampac NextGen — подтверждено: юнит lampac.service найден (load: ${EXISTING_LAMPAC_LOAD:-n/a}, active: ${EXISTING_LAMPAC_ACTIVE:-n/a}, описание юнита: «${EXISTING_LAMPAC_DESC}»)"
  elif (( EXISTING_LAMPAC == CHK_PROBABLE )); then
    if [[ -n "$EXISTING_LAMPAC_LOAD" ]]; then
      log_warn "Lampac legacy или неуточнённая версия — вероятная установка: юнит lampac.service найден (load: ${EXISTING_LAMPAC_LOAD:-n/a}, active: ${EXISTING_LAMPAC_ACTIVE:-n/a}), метки «Lampac NextGen» в описании нет"
    else
      log_warn "Lampac legacy или неуточнённая версия — вероятная установка: найдены файлы ${EXISTING_LAMPAC_LAYOUT_PATH}, юнит lampac.service не найден или проверка недоступна"
    fi
  else
    if (( ! EXISTING_SYSTEMD_UNAVAILABLE )); then
      log_skip "Lampac NextGen (системная установка): следов не найдено"
    fi
  fi
  if (( EXISTING_LAMPAC > 0 )); then
    if [[ "$EXISTING_LAMPAC_PATH_SRC" == "unit" && -n "$EXISTING_LAMPAC_PATH" ]]; then
      if [[ "$EXISTING_LAMPAC_PATH" == "$INSTALL_ROOT" ]]; then
        log_info "Каталог установки (из юнита): ${EXISTING_LAMPAC_PATH}"
      else
        log_info "Нестандартный каталог установки (из юнита): ${EXISTING_LAMPAC_PATH}"
      fi
    fi
    if [[ -n "$EXISTING_LAMPAC_LAYOUT_PATH" ]]; then
      log_info "Файлы найдены: ${EXISTING_LAMPAC_LAYOUT_PATH}"
    fi
  fi

  if (( EXISTING_ALCOPAC == CHK_CONFIRMED )); then
    log_ok "Al(co)pac — подтверждено: юнит ${ALCOPAC_UNIT} найден (load: ${EXISTING_ALCOPAC_LOAD:-n/a}, active: ${EXISTING_ALCOPAC_ACTIVE:-n/a}), файлы: ${EXISTING_ALCOPAC_FILES}"
  elif (( EXISTING_ALCOPAC == CHK_PROBABLE )); then
    if [[ -n "$EXISTING_ALCOPAC_FILES" ]]; then
      log_warn "Al(co)pac — обнаружен unit, состав не подтверждён: найдены только ${EXISTING_ALCOPAC_FILES}, бинарь lampac-go не найден"
    else
      log_warn "Al(co)pac — обнаружен unit, состав не подтверждён: ${ALCOPAC_UNIT} найден (load: ${EXISTING_ALCOPAC_LOAD:-n/a}, active: ${EXISTING_ALCOPAC_ACTIVE:-n/a}), ожидаемые файлы lampac-go/config.toml не найдены"
    fi
  else
    if (( ! EXISTING_SYSTEMD_UNAVAILABLE )); then
      log_skip "Al(co)pac (системная установка, не Docker): следов не найдено"
    fi
  fi
  if (( EXISTING_ALCOPAC > 0 )); then
    case "$EXISTING_ALCOPAC_PATH_SRC" in
      unit)
        if [[ "$EXISTING_ALCOPAC_PATH" == "$ALCOPAC_DOC_PATH" ]]; then
          log_info "Каталог установки (из юнита): ${EXISTING_ALCOPAC_PATH}"
        else
          log_info "Нестандартный каталог установки (из юнита): ${EXISTING_ALCOPAC_PATH}"
        fi
        ;;
      default)
        log_info "Каталог (документированный путь Al(co)pac по умолчанию): ${EXISTING_ALCOPAC_PATH}"
        ;;
    esac
  fi

  if (( EXISTING_LAMPAC_DOCKER == CHK_CONFIRMED )); then
    if [[ "$EXISTING_LAMPAC_DOCKER_RUNNING" == "true" ]]; then
      log_ok "Lampac NextGen (Docker) — подтверждено: контейнер ${LAMPAC_DOCKER_NAME} запущен, image: ${EXISTING_LAMPAC_DOCKER_IMAGE:-n/a}"
    else
      log_ok "Lampac NextGen (Docker) — подтверждено: контейнер ${LAMPAC_DOCKER_NAME} существует (не запущен), image: ${EXISTING_LAMPAC_DOCKER_IMAGE:-n/a}"
    fi
    if [[ -n "$EXISTING_LAMPAC_DOCKER_BIND_PATHS" ]]; then
      log_info "Каталоги хоста для Lampac NextGen (Docker, bind mounts): ${EXISTING_LAMPAC_DOCKER_BIND_PATHS}"
    fi
  elif (( EXISTING_LAMPAC_DOCKER == CHK_PROBABLE )); then
    if [[ "$EXISTING_LAMPAC_DOCKER_RUNNING" == "true" ]]; then
      log_warn "Lampac (Docker, неуточнённая версия) — вероятная установка: контейнер ${LAMPAC_DOCKER_NAME} запущен, image: ${EXISTING_LAMPAC_DOCKER_IMAGE:-n/a} — имя образа не подтверждает Lampac NextGen"
    else
      log_warn "Lampac (Docker, неуточнённая версия) — вероятная установка: контейнер ${LAMPAC_DOCKER_NAME} существует (не запущен), image: ${EXISTING_LAMPAC_DOCKER_IMAGE:-n/a} — имя образа не подтверждает Lampac NextGen"
    fi
  fi
  if (( EXISTING_ALCOPAC_DOCKER == CHK_CONFIRMED )); then
    if [[ "$EXISTING_ALCOPAC_DOCKER_RUNNING" == "true" ]]; then
      log_ok "Al(co)pac (Docker) — подтверждено: контейнер ${ALCOPAC_DOCKER_NAME} запущен, image: ${EXISTING_ALCOPAC_DOCKER_IMAGE:-n/a}"
    else
      log_ok "Al(co)pac (Docker) — подтверждено: контейнер ${ALCOPAC_DOCKER_NAME} существует (не запущен), image: ${EXISTING_ALCOPAC_DOCKER_IMAGE:-n/a}"
    fi
    if [[ -n "$EXISTING_ALCOPAC_DOCKER_BIND_PATHS" ]]; then
      log_info "Каталоги хоста для Al(co)pac (Docker, bind mounts): ${EXISTING_ALCOPAC_DOCKER_BIND_PATHS}"
    fi
  elif (( EXISTING_ALCOPAC_DOCKER == CHK_PROBABLE )); then
    log_warn "Al(co)pac (Docker) — контейнер ${ALCOPAC_DOCKER_NAME} найден, но image ${EXISTING_ALCOPAC_DOCKER_IMAGE:-n/a} не подтверждён; удаление недоступно"
  fi

  if (( EXISTING_DOCKER_UNAVAILABLE )); then
    log_warn "Docker недоступен для проверки (контейнеры ${LAMPAC_DOCKER_NAME}, ${ALCOPAC_DOCKER_NAME})"
  elif (( EXISTING_DOCKER_PRESENT )); then
    if (( EXISTING_LAMPAC_DOCKER == CHK_NOT_FOUND && EXISTING_ALCOPAC_DOCKER == CHK_NOT_FOUND )); then
      log_skip "Docker: контейнеры ${LAMPAC_DOCKER_NAME}, ${ALCOPAC_DOCKER_NAME} не найдены"
    elif (( EXISTING_LAMPAC_DOCKER == CHK_NOT_FOUND )); then
      log_skip "Docker: контейнер ${LAMPAC_DOCKER_NAME} не найден"
    else
      log_skip "Docker: контейнер ${ALCOPAC_DOCKER_NAME} не найден"
    fi
  else
    log_skip "docker не найден — контейнеры ${LAMPAC_DOCKER_NAME}, ${ALCOPAC_DOCKER_NAME} не проверялись"
  fi

  if (( EXISTING_HITS > 0 )); then
    # Сводка: по каждому результату различимы продукт и уровень уверенности.
    local found_list
    found_list="$(existing_found_list)"

    printf '\n'
    log_warn "Итог: обнаружено совпадений по продуктам — ${EXISTING_HITS}: ${found_list}."
    if (( EXISTING_LAMPAC > 0 || EXISTING_ALCOPAC > 0 )); then
      log_warn "Lampac legacy, Lampac NextGen и Al(co)pac могут использовать один каталог (${ALCOPAC_DOC_PATH})."
    fi
    if (( EXISTING_LAMPAC_DOCKER > 0 || EXISTING_ALCOPAC_DOCKER > 0 )); then
      log_warn "Возможен конфликт порта ${LISTEN_PORT}: Docker-контейнер и системная служба не могут слушать один порт."
    fi
    log_skip "Проверка ничего не перезаписала и не удалила; установка не выполняла операций."
  else
    log_ok "Подтверждённых или вероятных установок не найдено — можно продолжать."
  fi
}

# ─── Экран перехода (после чистой проверки следов) ───────────────────────────
#
# Отдельный экран между проверкой следов и установкой: пользователь явным
# номером решает, запускать ли установку. Здесь только отрисовка и разбор
# ввода; сами операции установки остаются в main и начинаются после возврата.

# Максимум символов ввода на экране перехода (длиннее — отказ)
readonly TRANSITION_MAX_INPUT_LEN=16

# Печать экрана-перехода. Используются только уже известные значения и текст:
# никаких сетевых запросов, resolve_publish_url и вызовов системных команд.
show_install_transition() {
  printf '\n'
  printf '%s  ─── Следов других установок не найдено ───%s\n\n' "$C_GREEN" "$C_RESET"
  printf '  Установщик готов развернуть Lampac NextGen:\n\n'
  printf '    Arch:      %s\n' "$ARCH"
  printf '    Directory: %s\n' "$INSTALL_ROOT"
  printf '    Service:   %s (systemd, порт %s)\n' "$SERVICE_NAME" "$LISTEN_PORT"
  printf '    Состав:    релиз-архив, системные пакеты, ASP.NET Core %s\n' "$DOTNET_CHANNEL"
  printf '\n'
  printf '  Установка изменит системные пакеты, каталог %s и создаст службу %s.\n' "$INSTALL_ROOT" "$SERVICE_NAME"
  printf '\n'
  printf '    %s1%s) Продолжить к установке\n' "$C_BOLD" "$C_RESET"
  printf '    %s0%s) Выйти — ничего не устанавливать\n' "$C_BOLD" "$C_RESET"
  printf '\n'
}

# Разбор ввода экрана-перехода. Установку запускает только явный ввод «1»
# (возврат 0). Пустой, неверный или слишком длинный ввод, EOF и Ctrl+C
# ничего не устанавливают: краткое объяснение и безопасное завершение.
prompt_install_transition() {
  local answer

  # Ctrl+C от показа экрана и до конца ввода — предсказуемый выход:
  # операции ещё не начаты.
  trap 'printf "\n"; log_warn "Ввод прерван (Ctrl+C) — установка не запущена."; exit 130' INT

  show_install_transition

  if [[ ! -r /dev/tty ]]; then
    log_err "Нет терминала для ввода — установка не запущена."
    return 1
  fi

  if ! read -r answer </dev/tty; then
    trap - INT
    log_warn "Ввод закрыт (EOF) — установка не запущена."
    return 1
  fi
  trap - INT

  if (( ${#answer} > TRANSITION_MAX_INPUT_LEN )); then
    log_warn "Слишком длинный ввод — установка не запущена."
    return 1
  fi

  case "$answer" in
    1)
      log_ok "Продолжаем к установке."
      return 0
      ;;
    0)
      log_info "Выбран выход — установка не запущена."
      return 1
      ;;
    "")
      log_warn "Пустой ввод — установка не запущена."
      return 1
      ;;
    *)
      log_warn "Неизвестный пункт (ожидается 1 или 0) — установка не запущена."
      return 1
      ;;
  esac
}

# ─── Interactive menu ────────────────────────────────────────────────────────

show_main_menu() {
  local next_item=1
  local has_installation=0

  printf '\n  %s─── Lampac NextGen: меню действий ───%s\n\n' "$C_CYAN" "$C_RESET"
  if (( EXISTING_HITS > 0 )); then
    has_installation=1
    log_info "Обнаружено: $(existing_found_list)"
  fi

  if (( EXISTING_LAMPAC == CHK_CONFIRMED )) && lampac_native_update_available; then
    MENU_KIND="lampac"
    printf '  Lampac NextGen: %s (%s)\n\n' "$INSTALL_ROOT" "$(get_installed_version)"
    printf '    %s1%s) Обновить до последней версии (этапы установки)\n' "$C_BOLD" "$C_RESET"
    printf '    %s2%s) Обновить до последней версии с подробными логами\n' "$C_BOLD" "$C_RESET"
    printf '    %s3%s) Откатиться на одну из 10 последних более ранних версий\n' "$C_BOLD" "$C_RESET"
    printf '    %s4%s) Удалить Lampac NextGen\n' "$C_BOLD" "$C_RESET"
    printf '    %s5%s) Показать установленную версию\n' "$C_BOLD" "$C_RESET"
    printf '    %s6%s) Повторить проверку системы и установок\n' "$C_BOLD" "$C_RESET"
    next_item=7

    PORT_MENU_ITEM="$next_item"
    printf '    %s%d%s) Изменить HTTP-порт\n' "$C_BOLD" "$next_item" "$C_RESET"
    next_item=$((next_item + 1))

    SETUP_MENU_ITEM="$next_item"
    printf '    %s%d%s) Установить команду управления lampac setup\n' "$C_BOLD" "$next_item" "$C_RESET"
    next_item=$((next_item + 1))
  elif (( EXISTING_LAMPAC == 0 && EXISTING_LAMPAC_DOCKER == 0 && has_installation == 0 )); then
    MENU_KIND="fresh"
    SETUP_MENU_ITEM=""
    PORT_MENU_ITEM=""
    printf '  Установки не обнаружены. Можно начать чистую установку.\n\n'
    printf '    %s1%s) Установить последнюю версию (этапы установки)\n' "$C_BOLD" "$C_RESET"
    printf '    %s2%s) Установить выбранную версию из 10 последних релизов\n' "$C_BOLD" "$C_RESET"
    printf '    %s3%s) Установить последнюю версию с подробными логами\n' "$C_BOLD" "$C_RESET"
    printf '    %s4%s) Повторить проверку системы и установок\n' "$C_BOLD" "$C_RESET"
    next_item=5
  else
    MENU_KIND="other"
    SETUP_MENU_ITEM=""
    PORT_MENU_ITEM=""
    printf '  Управление Lampac NextGen недоступно для обнаруженного типа установки.\n'
    printf '  Docker и неподтверждённые установки доступны только для диагностики.\n\n'
    printf '    %s1%s) Повторить проверку системы и установок\n' "$C_BOLD" "$C_RESET"
    next_item=2
  fi

  if minimum_installer_dependencies_ready; then
    MENU_BOOTSTRAP_ITEM=""
  else
    MENU_BOOTSTRAP_ITEM="$next_item"
    printf '    %s%d%s) Установить минимальные зависимости для загрузки релизов\n' "$C_BOLD" "$next_item" "$C_RESET"
    next_item=$((next_item + 1))
  fi

  if native_alcopac_removal_available; then
    MENU_ALCOPAC_ITEM="$next_item"
    printf '    %s%d%s) Удалить Al(co)pac\n' "$C_BOLD" "$next_item" "$C_RESET"
    next_item=$((next_item + 1))
  else
    MENU_ALCOPAC_ITEM=""
  fi
  printf '    %s0%s) Выйти\n\n' "$C_BOLD" "$C_RESET"
  printf '  Выберите пункт: '
}

lampac_setup_command_is_managed() {
  [[ -f /usr/local/bin/lampac && ! -L /usr/local/bin/lampac ]] \
    && grep -Fq '# Lampac NextGen setup command (managed by installer)' /usr/local/bin/lampac
}

install_lampac_setup_command() {
  local target=/usr/local/bin/lampac setup_dir=/usr/local/lib/lampac-nextgen repo_file=/usr/local/lib/lampac-nextgen/repository.conf tmp

  if [[ "$SERVICE_NAME" != lampac ]]; then
    log_err "Команда lampac setup пока поддерживает только lampac.service; текущий юнит: ${SERVICE_NAME}."
    return 1
  fi
  if { [[ -e "$target" ]] || [[ -L "$target" ]]; } && ! lampac_setup_command_is_managed; then
    log_err "$target уже существует и не принадлежит установщику; файл оставлен без изменений."
    return 1
  fi
  if [[ -L "$setup_dir" ]] || { [[ -e "$setup_dir" ]] && [[ ! -d "$setup_dir" ]]; }; then
    log_err "$setup_dir существует, но не является обычным каталогом."
    return 1
  fi
  if { [[ -e "$repo_file" ]] || [[ -L "$repo_file" ]]; } \
    && { [[ -L "$repo_file" ]] || ! grep -Fq '# Lampac NextGen setup repository (managed by installer)' "$repo_file"; }; then
    log_err "$repo_file уже существует и не принадлежит установщику; файл оставлен без изменений."
    return 1
  fi
  [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { log_err "Некорректный GITHUB_REPO: $GITHUB_REPO"; return 1; }

  install -d -o root -g root -m 755 "$setup_dir" || return 1
  tmp="$(mktemp "$setup_dir/.repository.XXXXXX")" || return 1
  printf '# Lampac NextGen setup repository (managed by installer)\n%s\n' "$GITHUB_REPO" >"$tmp"
  if ! install -o root -g root -m 644 "$tmp" "$repo_file"; then
    rm -f -- "$tmp"
    log_err "Не удалось сохранить настройки setup-команды."
    return 1
  fi
  rm -f -- "$tmp"

  mkdir -p /usr/local/bin || return 1
  tmp="$(mktemp /usr/local/bin/.lampac.XXXXXX)" || return 1
  cat >"$tmp" <<'LAMPAC_SETUP_EOF'
#!/usr/bin/env bash
# Lampac NextGen setup command (managed by installer)
set -uo pipefail

readonly SERVICE_NAME=lampac.service
readonly SELF=/usr/local/bin/lampac
readonly SETUP_REPOSITORY=/usr/local/lib/lampac-nextgen/repository.conf
readonly APP_ARCHIVE=lampac-nextgen.zip
UPDATE_STOPPED=0
UPDATE_STAGE=''

error() { printf 'Ошибка: %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*"; }

progress() {
  local completed="$1" total="$2" phase="$3" status="$4" width=24 filled percent i
  filled=$(( completed * width / total ))
  percent=$(( completed * 100 / total ))
  printf '\n  Прогресс: ['
  for ((i = 0; i < width; i++)); do
    if (( i < filled )); then printf '#'; elif (( i == filled && completed < total )); then printf '>'; else printf '-'; fi
  done
  printf '] %3d%%\n  Этап:   %s\n  Сейчас: %s\n\n' "$percent" "$phase" "$status"
}

service_root() {
  local root fragment description exec_start
  root="$(systemctl show "$SERVICE_NAME" -p WorkingDirectory --value 2>/dev/null)" || return 1
  fragment="$(systemctl show "$SERVICE_NAME" -p FragmentPath --value 2>/dev/null)" || return 1
  description="$(systemctl show "$SERVICE_NAME" -p Description --value 2>/dev/null)" || return 1
  exec_start="$(systemctl show "$SERVICE_NAME" -p ExecStart --value 2>/dev/null)" || return 1
  [[ "$fragment" == "/etc/systemd/system/$SERVICE_NAME" && -f "$fragment" && ! -L "$fragment" ]] || return 1
  [[ "$description" == 'Lampac NextGen' ]] || return 1
  [[ "$root" == /opt/* || "$root" == /*/*/* ]] || return 1
  [[ "$root" == /* && "$root" != / && -d "$root" && -f "$root/Core.dll" ]] || return 1
  [[ "$(readlink -f -- "$root" 2>/dev/null)" == "$root" ]] || return 1
  [[ "$exec_start" == *" $root/Core.dll"* ]] || return 1
  case "$root" in /bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 1 ;; esac
  printf '%s\n' "$root"
}

repository_name() {
  local repo
  repo="$(sed -n '2p' "$SETUP_REPOSITORY" 2>/dev/null)"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s\n' "$repo"
}

require_tools() {
  local tool missing=0
  local -a required_tools=("$@")
  if (( ${#required_tools[@]} == 0 )); then
    required_tools=(curl jq unzip rsync)
  fi
  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then error "Не найдена зависимость $tool; установите её через пакетный менеджер."; missing=1; fi
  done
  (( missing == 0 ))
}

confirm_token() {
  local token="$1" prompt="$2" answer
  [[ -r /dev/tty ]] || { error 'Невозможно запросить подтверждение без терминала; действие отменено.'; return 1; }
  printf '  %s Введите %s для подтверждения (иначе отмена): ' "$prompt" "$token"
  if ! IFS= read -r answer </dev/tty; then printf '\n'; return 1; fi
  [[ "$answer" == "$token" ]]
}

run_as_root() {
  if (( EUID == 0 )); then
    setup_internal "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$SELF" setup "$@"
  else
    error 'Для этого действия нужны права администратора (sudo не найден).'
    return 1
  fi
}

version_tag_is_older() {
  local candidate="${1#v}" current="${2#v}" first
  [[ "$candidate" != "$current" ]] || return 1
  first="$(printf '%s\n%s\n' "$candidate" "$current" | sort -V | head -n1)"
  [[ "$first" == "$candidate" ]]
}

release_version_is_current() {
  local latest="${1#v}" installed="${2#v}"
  latest="${latest#"${latest%%[![:space:]]*}"}"
  latest="${latest%"${latest##*[![:space:]]}"}"
  installed="${installed#"${installed%%[![:space:]]*}"}"
  installed="${installed%"${installed##*[![:space:]]}"}"
  [[ -n "$installed" && "$installed" != N/A && "$latest" == "$installed" ]]
}

fetch_release_tags() {
  local repo json
  repo="$(repository_name)" || { error 'Не удалось прочитать конфигурацию репозитория setup.'; return 1; }
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${repo}/releases?per_page=100")" \
    || { error 'Не удалось получить список релизов GitHub.'; return 1; }
  printf '%s' "$json" | jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
    | while IFS= read -r tag; do [[ "$tag" =~ ^v?[0-9]+([._+-][A-Za-z0-9.-]+|\.[0-9]+)*$ ]] && printf '%s\n' "$tag"; done
}

latest_release_tag() {
  local repo json tag
  repo="$(repository_name)" || { error 'Не удалось прочитать конфигурацию репозитория setup.'; return 1; }
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${repo}/releases/latest")" \
    || { error 'Не удалось получить последний релиз GitHub.'; return 1; }
  tag="$(printf '%s' "$json" | jq -er '.tag_name | select(type == "string")')" || return 1
  [[ "$tag" =~ ^v?[0-9]+([._+-][A-Za-z0-9.-]+|\.[0-9]+)*$ ]] || { error 'GitHub вернул некорректный тег релиза.'; return 1; }
  printf '%s\n' "$tag"
}

setup_cleanup() {
  if (( UPDATE_STOPPED )); then systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
  [[ -z "$UPDATE_STAGE" ]] || rm -rf -- "$UPDATE_STAGE"
}

update_release() {
  local tag="$1" root repo current user group zip_url archive stage name
  [[ "$tag" =~ ^v?[0-9]+([._+-][A-Za-z0-9.-]+|\.[0-9]+)*$ ]] || { error 'Некорректный тег релиза.'; return 1; }
  require_tools || return 1
  root="$(service_root)" || { error 'Не удалось определить безопасный каталог установленной службы.'; return 1; }
  repo="$(repository_name)" || { error 'Не удалось прочитать конфигурацию репозитория setup.'; return 1; }
  user="$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null)"
  group="$(systemctl show "$SERVICE_NAME" -p Group --value 2>/dev/null)"
  [[ -n "$user" ]] || user=lampac
  [[ -n "$group" ]] || group="$user"
  getent passwd "$user" >/dev/null && getent group "$group" >/dev/null \
    || { error 'Не удалось определить учётную запись службы; обновление не начато.'; return 1; }
  current='N/A'
  [[ ! -r "$root/version.txt" ]] || current="$(<"$root/version.txt")"
  if release_version_is_current "$tag" "$current"; then info "Уже установлена версия $tag; обновление не требуется."; return 0; fi

  stage="$(mktemp -d /tmp/lampac-setup-update.XXXXXX)" || return 1
  UPDATE_STAGE="$stage"
  trap setup_cleanup EXIT
  archive="$stage/$APP_ARCHIVE"
  zip_url="https://github.com/${repo}/releases/download/${tag}/${APP_ARCHIVE}"
  progress 1 4 'Загрузка релиза' "Загружаю $tag из $repo."
  curl -fSL --retry 3 -o "$archive" "$zip_url" || { error 'Загрузка релиза не удалась.'; return 1; }
  [[ -s "$archive" ]] || { error 'Архив релиза пуст.'; return 1; }
  mkdir "$stage/app"
  progress 2 4 'Подготовка файлов' 'Проверяю архив и распаковываю его во временный каталог.'
  unzip -tq "$archive" >/dev/null || { error 'Архив релиза повреждён.'; return 1; }
  unzip -oq "$archive" -d "$stage/app" || return 1
  local -a dirs=() excludes=(--exclude=install.sh --exclude=init.conf --exclude=init.yaml --exclude='init.conf.backup.*' --exclude=mods/ --exclude=data/kinoukr.json --exclude=data/PizdatoeDb.json --exclude='*.db' --exclude='*.db-shm' --exclude='*.db-wal' --exclude=logs/ --exclude=cache/ --exclude=TorrServer --exclude=torrserver/ --exclude=data/ts/ --exclude=.local/ --exclude=.aspnet/ --exclude=.claude/ --exclude=.config/ --exclude=users.json --exclude=passwd --exclude=current.conf --exclude=database/ --exclude=wwwroot/ --exclude=plugins/override/ --exclude=notifications_date.txt --exclude=module/NextHUB/override/ --exclude=module/Catalog/override/ --exclude=excludes.conf --exclude=version.txt)
  mapfile -t dirs < <(find "$stage/app" -mindepth 1 -maxdepth 1 -type d)
  if (( ${#dirs[@]} == 1 )) && [[ ! -f "$stage/app/Core.dll" ]]; then
    shopt -s dotglob nullglob
    mv "${dirs[0]}"/* "$stage/app/"
    shopt -u dotglob nullglob
    rmdir "${dirs[0]}" 2>/dev/null || true
  fi
  [[ -f "$stage/app/Core.dll" ]] || { error 'В архиве отсутствует Core.dll.'; return 1; }
  if [[ -f "$root/excludes.conf" ]]; then
    while IFS= read -r name || [[ -n "$name" ]]; do
      [[ -z "$name" || "$name" == \#* ]] || excludes+=(--exclude="$name")
    done < "$root/excludes.conf"
  fi

  progress 3 4 'Обновление приложения' "Останавливаю $SERVICE_NAME и синхронизирую файлы в $root."
  systemctl stop "$SERVICE_NAME" || { error 'Не удалось остановить службу; файлы не изменены.'; return 1; }
  UPDATE_STOPPED=1
  rsync -a --delete "${excludes[@]}" "$stage/app/" "$root/" || { error 'Синхронизация файлов не удалась.'; return 1; }
  printf '%s\n' "${tag#v}" >"$root/version.txt"
  chown -R "$user:$group" "$root" || { error 'Не удалось восстановить владельца файлов приложения.'; return 1; }
  progress 4 4 'Запуск службы' "Запускаю $SERVICE_NAME с версией $tag."
  systemctl start "$SERVICE_NAME" || { error 'Не удалось запустить службу; проверьте systemctl status и журнал.'; return 1; }
  UPDATE_STOPPED=0
  trap - EXIT
  setup_cleanup
  info "Готово: Lampac NextGen $tag обновлён."
}

SELECTED_RELEASE_TAG=''
select_rollback_tag() {
  local current="$1" tag answer number index=0
  local -a choices=()
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    version_tag_is_older "$tag" "$current" || continue
    choices+=("$tag")
    (( ${#choices[@]} >= 10 )) && break
  done < <(fetch_release_tags)
  (( ${#choices[@]} > 0 )) || { error "Нет более ранних релизов среди последних опубликованных (установлена $current)."; return 1; }
  printf '\n  ─── Выберите версию для отката ───\n\n'
  for tag in "${choices[@]}"; do index=$((index + 1)); printf '    %d) %s\n' "$index" "$tag"; done
  printf '    0) Назад\n\n'
  while true; do
    printf '  Номер версии: '
    IFS= read -r answer </dev/tty || { printf '\n'; return 1; }
    case "$answer" in
      0) return 1 ;;
      ''|*[!0-9]*) error 'Введите номер из списка или 0.' ;;
      *) (( ${#answer} <= 3 )) || { error 'Слишком длинный ввод.'; continue; }
         number=$((10#$answer)); (( number >= 1 && number <= ${#choices[@]} )) || { error 'Такого номера нет.'; continue; }
         SELECTED_RELEASE_TAG="${choices[$((number - 1))]}"; return 0 ;;
    esac
  done
}

remove_installation() {
  local root
  root="$(service_root)" || { error 'Не удалось определить безопасный каталог установленной службы.'; return 1; }
  printf '\n  Будут остановлена служба %s и удалены %s и команда %s. Учётная запись службы останется без изменений.\n' \
    "$SERVICE_NAME" "$root" "$SELF"
  confirm_token REMOVE 'Введите REMOVE' || { info 'Удаление отменено.'; return 1; }
  confirm_token "$root" 'Чтобы подтвердить удаление именно этого каталога, введите его полный путь' \
    || { info 'Удаление отменено.'; return 1; }
  systemctl stop "$SERVICE_NAME" || { error 'Не удалось остановить службу; удаление отменено.'; return 1; }
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f -- "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload || { error 'Не удалось перечитать конфигурацию systemd.'; return 1; }
  rm -rf -- "$root" || { error "Не удалось удалить каталог $root."; return 1; }
  if [[ -f "$SELF" ]] && grep -Fq '# Lampac NextGen setup command (managed by installer)' "$SELF"; then rm -f -- "$SELF"; fi
  if [[ -f "$SETUP_REPOSITORY" ]] && grep -Fq '# Lampac NextGen setup repository (managed by installer)' "$SETUP_REPOSITORY"; then
    rm -f -- "$SETUP_REPOSITORY"
    rmdir --ignore-fail-on-non-empty "${SETUP_REPOSITORY%/*}" 2>/dev/null || true
  fi
  info 'Lampac NextGen удалён.'
}

setup_internal() {
  local action="${1:-}" arg="${2:-}" root current tag
  case "$action" in
    --update)
      (( $# == 1 )) || { error 'Для обновления лишние параметры не допускаются.'; return 2; }
      require_tools curl jq || return 1
      tag="$(latest_release_tag)" || return 1
      root="$(service_root)" || { error 'Не удалось определить установленную Lampac.'; return 1; }
      current='N/A'; [[ ! -r "$root/version.txt" ]] || current="$(<"$root/version.txt")"
      if release_version_is_current "$tag" "$current"; then
        info "Lampac NextGen уже обновлён до версии ${tag#v}; обновление не требуется."
        return 0
      fi
      require_tools unzip rsync || return 1
      confirm_token UPDATE "Обновление до $tag" || { info 'Обновление отменено.'; return 1; }
      update_release "$tag" ;;
    --rollback)
      (( $# <= 2 )) || { error 'Слишком много параметров для отката.'; return 2; }
      require_tools || return 1
      root="$(service_root)" || { error 'Не удалось определить установленную Lampac.'; return 1; }
      current='N/A'; [[ ! -r "$root/version.txt" ]] || current="$(<"$root/version.txt")"
      [[ "$current" != N/A ]] || { error 'Текущая версия неизвестна; откат невозможен.'; return 1; }
      [[ "$current" =~ ^v?[0-9]+([._+-][A-Za-z0-9.-]+|\.[0-9]+)*$ ]] || { error 'Записана некорректная текущая версия; откат остановлен.'; return 1; }
      if [[ -n "$arg" ]]; then tag="$arg"; else select_rollback_tag "$current" || return 1; tag="$SELECTED_RELEASE_TAG"; fi
      [[ "$tag" =~ ^v?[0-9]+([._+-][A-Za-z0-9.-]+|\.[0-9]+)*$ ]] || { error 'Некорректный тег отката.'; return 1; }
      version_tag_is_older "$tag" "$current" || { error 'Выбранный релиз не старше установленного.'; return 1; }
      confirm_token ROLLBACK "Откат ${current} → ${tag}" || { info 'Откат отменён.'; return 1; }
      update_release "$tag" ;;
    --remove) (( $# == 1 )) || { error 'Для удаления лишние параметры не допускаются.'; return 2; }; remove_installation ;;
    *) error 'Неизвестное действие setup.'; return 2 ;;
  esac
}

service_state() {
  systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
}

run_service_action() {
  local action="$1"
  if (( EUID == 0 )); then
    systemctl "$action" "$SERVICE_NAME"
  elif command -v sudo >/dev/null 2>&1; then
    sudo systemctl "$action" "$SERVICE_NAME"
  else
    printf 'Для %s службы нужны права администратора (sudo).\n' "$action" >&2
    return 1
  fi
}

show_recent_logs() {
  if (( EUID == 0 )); then
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager
  elif command -v sudo >/dev/null 2>&1; then
    sudo journalctl -u "$SERVICE_NAME" -n 50 --no-pager
  else
    printf 'Для просмотра системного журнала нужны права администратора (sudo).\n' >&2
    return 1
  fi
}

setup_menu() {
  local answer state root port ip url version config_file
  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'Команда lampac setup предназначена для интерактивного терминала.\n' >&2
    return 2
  fi

  while true; do
    root="$(service_root)"
    [[ -n "$root" ]] || root=/opt/lampac
    config_file="$root/init.conf"
    [[ -e "$root/init.yaml" ]] && config_file="$root/init.yaml"
    state="$(service_state)"
    case "$state" in active) state='работает' ;; inactive) state='остановлена' ;; failed) state='ошибка' ;; *) state='неизвестно' ;; esac
    version='N/A'
    if [[ -r "$root/version.txt" ]]; then
      version="$(<"$root/version.txt")"
      [[ -n "$version" ]] || version='N/A'
    fi
    port=9118
    if [[ -e "$root/init.yaml" ]]; then
      port=''
    elif command -v jq >/dev/null 2>&1 && [[ -r "$root/init.conf" ]]; then
      port="$(jq -r '.listen.port // 9118' "$root/init.conf" 2>/dev/null || printf 9118)"
      [[ "$port" =~ ^[0-9]{1,5}$ ]] || port=9118
    fi
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" ]] || ip='<IP-сервера>'
    if [[ -n "$port" ]]; then url="http://${ip}:${port}"; else url="см. init.yaml (порт не определён)"; fi

    printf '\n  ██╗      █████╗ ███╗   ███╗██████╗  █████╗  ██████╗\n'
    printf '  ██║     ██╔══██╗████╗ ████║██╔══██╗██╔══██╗██╔════╝\n'
    printf '  ██║     ███████║██╔████╔██║██████╔╝███████║██║\n'
    printf '  ██║     ██╔══██║██║╚██╔╝██║██╔═══╝ ██╔══██║██║\n'
    printf '  ███████╗██║  ██║██║ ╚═╝ ██║██║     ██║  ██║╚██████╗\n'
    printf '  ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝     ╚═╝  ╚═╝ ╚═════╝\n'
    printf '                                          NextGen\n\n'
    printf '  Installed Version: %s\n\n' "$version"
    printf '  ─── Lampac NextGen: меню управления службой ───\n\n'
    printf '  Каталог: %s\n' "$root"
    printf '  Состояние: %s\n' "$state"
    printf '  Config    %s\n' "$config_file"
    printf '  Service   systemctl status %s\n' "$SERVICE_NAME"
    printf '  Restart   systemctl restart %s\n' "$SERVICE_NAME"
    printf '  Logs      journalctl -u %s -f\n' "$SERVICE_NAME"
    printf '  URL       %s\n\n' "$url"
    printf '    1) Перезапустить Lampac\n'
    if [[ "$(service_state)" == active ]]; then
      printf '    2) Остановить Lampac\n'
    else
      printf '    2) Запустить Lampac\n'
    fi
    printf '    3) Обновить до последней версии\n'
    printf '    4) Откатиться на более ранний релиз\n'
    printf '    5) Удалить Lampac NextGen\n'
    printf '    6) Показать последние 50 строк логов\n'
    printf '    0) Выйти\n\n'
    printf '  Выберите пункт: '
    if ! IFS= read -r answer; then printf '\n'; return 0; fi
    if (( ${#answer} > 16 )); then printf 'Слишком длинный ввод.\n' >&2; continue; fi
    case "$answer" in
      1) run_service_action restart || printf 'Не удалось перезапустить службу.\n' >&2 ;;
      2)
        if [[ "$(service_state)" == active ]]; then
          run_service_action stop || printf 'Не удалось остановить службу.\n' >&2
        else
          run_service_action start || printf 'Не удалось запустить службу.\n' >&2
        fi
        ;;
      3) run_as_root --update || printf 'Обновление не выполнено.\n' >&2 ;;
      4) run_as_root --rollback || printf 'Откат не выполнен.\n' >&2 ;;
      5)
        run_as_root --remove
        if [[ ! -f "$root/Core.dll" ]]; then return 0; fi
        ;;
      6) show_recent_logs || printf 'Не удалось прочитать журнал службы.\n' >&2 ;;
      0) return 0 ;;
      '') printf 'Пустой ввод: выберите пункт от 1 до 6 или 0.\n' >&2 ;;
      *) printf 'Неизвестный пункт: выберите пункт от 1 до 6 или 0.\n' >&2 ;;
    esac
  done
}

if [[ "${1:-}" == setup && $# -eq 1 ]]; then
  setup_menu
  exit $?
fi
if [[ "${1:-}" == setup && $# -ge 2 ]]; then
  shift
  setup_internal "$@"
  exit $?
fi
printf 'Использование: lampac setup\n' >&2
exit 2
LAMPAC_SETUP_EOF
  chmod 755 "$tmp"
  if ! install -o root -g root -m 755 "$tmp" "$target"; then
    rm -f -- "$tmp"
    log_err "Не удалось установить $target."
    return 1
  fi
  rm -f -- "$tmp"
  if [[ -f /usr/local/lib/lampac-nextgen/install.sh && ! -L /usr/local/lib/lampac-nextgen/install.sh ]] \
    && grep -Fq '# Lampac NextGen installer managed copy (managed by installer).' /usr/local/lib/lampac-nextgen/install.sh; then
    rm -f -- /usr/local/lib/lampac-nextgen/install.sh
  fi
  log_ok "Команда lampac setup установлена: $target setup"
}

remove_lampac_setup_command() {
  if lampac_setup_command_is_managed; then
    rm -f -- /usr/local/bin/lampac
    log_ok "Удалена команда управления /usr/local/bin/lampac."
  fi
  if [[ -f /usr/local/lib/lampac-nextgen/repository.conf ]] \
    && grep -Fq '# Lampac NextGen setup repository (managed by installer)' /usr/local/lib/lampac-nextgen/repository.conf; then
    rm -f -- /usr/local/lib/lampac-nextgen/repository.conf
    rmdir --ignore-fail-on-non-empty /usr/local/lib/lampac-nextgen 2>/dev/null || true
    log_ok "Удалена конфигурация lampac setup."
  fi
  if [[ -f /usr/local/lib/lampac-nextgen/install.sh && ! -L /usr/local/lib/lampac-nextgen/install.sh ]] \
    && grep -Fq '# Lampac NextGen installer managed copy (managed by installer).' /usr/local/lib/lampac-nextgen/install.sh; then
    rm -f -- /usr/local/lib/lampac-nextgen/install.sh
  fi
  rmdir --ignore-fail-on-non-empty /usr/local/lib/lampac-nextgen 2>/dev/null || true
}

edit_installer_config() {
  local filter="$1" conf="${INSTALL_ROOT}/init.conf" tmp backup
  shift
  if [[ -e "${INSTALL_ROOT}/init.yaml" ]]; then
    log_err "Найден init.yaml. Чтобы не менять активную YAML-конфигурацию, настройка остановлена; сначала перенесите конфиг в init.conf вручную."
    return 1
  fi
  if [[ ! -f "$conf" || -L "$conf" ]] || ! jq -e 'type == "object"' "$conf" >/dev/null 2>&1; then
    log_err "init.conf отсутствует или не является корректным JSON. Файл не изменён; исправьте/создайте его и повторите настройку."
    return 1
  fi
  tmp="$(mktemp "${INSTALL_ROOT}/.init.conf.XXXXXX")" || return 1
  if ! jq "$@" "$filter" "$conf" >"$tmp"; then
    rm -f -- "$tmp"
    log_err "Не удалось безопасно обработать init.conf; файл не изменён."
    return 1
  fi
  if ! chown --reference="$conf" "$tmp"; then
    rm -f -- "$tmp"
    log_err "Не удалось сохранить владельца init.conf; исходный файл не изменён."
    return 1
  fi
  chmod --reference="$conf" "$tmp" 2>/dev/null || chmod 640 "$tmp"
  backup="$(mktemp "${conf}.backup.XXXXXX")" || { rm -f -- "$tmp"; return 1; }
  if ! cp -a -- "$conf" "$backup" || ! mv -f -- "$tmp" "$conf"; then
    rm -f -- "$tmp"
    log_err "Не удалось записать конфигурацию; резервная копия: $backup"
    return 1
  fi
  log_ok "Конфигурация сохранена; резервная копия: $backup"
}

configure_install_port() {
  local answer port
  sync_port_from_install_config
  [[ -e "${INSTALL_ROOT}/init.yaml" ]] && { log_err "Найден init.yaml; смена порта через установщик не поддерживается. YAML оставлен без изменений."; return 1; }
  while true; do
    printf '  Порт HTTP [%s], 1-65535 (Enter — оставить): ' "$LISTEN_PORT"
    if ! read -r answer </dev/tty; then printf '\n'; return 1; fi
    [[ -z "$answer" || "$answer" == 0 ]] && return 0
    if [[ "$answer" =~ ^[0-9]{1,5}$ ]] && (( 10#$answer >= 1 && 10#$answer <= 65535 )); then
      port=$((10#$answer))
      if edit_installer_config '.listen = (.listen // {}) | .listen.port = $port' --argjson port "$port"; then
        LISTEN_PORT="$port"
        if lampac_setup_command_is_managed; then
          log_info "Порт сохранён; после изменения перезапустите службу: systemctl restart ${SERVICE_NAME} или lampac setup."
        else
          log_info "Порт сохранён; после изменения перезапустите службу: systemctl restart ${SERVICE_NAME}."
        fi
        return 0
      fi
      return 1
    fi
    log_warn "Нужен номер порта от 1 до 65535, Enter — оставить текущий."
  done
}

initialize_fresh_install_config() {
  local conf="${INSTALL_ROOT}/init.conf"
  [[ -e "$conf" || -e "${INSTALL_ROOT}/init.yaml" ]] && return 0
  jq -n '{listen:{port:9118}}' >"$conf" \
    || { log_err "Не удалось создать начальную init.conf; служба не будет настроена автоматически."; return 1; }
  chmod 640 "$conf"
}

sync_port_from_install_config() {
  local port
  if [[ -e "${INSTALL_ROOT}/init.yaml" ]]; then
    LISTEN_PORT=""
    return 0
  fi
  [[ -r "${INSTALL_ROOT}/init.conf" ]] || return 0
  port="$(jq -r '.listen.port // empty' "${INSTALL_ROOT}/init.conf" 2>/dev/null || true)"
  if [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )); then
    LISTEN_PORT=$((10#$port))
  fi
}

lampac_native_update_available() {
  (( EXISTING_LAMPAC == CHK_CONFIRMED )) \
    && [[ "$EXISTING_LAMPAC_UNIT_PATH" == "$LAMPAC_SYSTEMD_UNIT_PATH" ]] \
    && [[ "$EXISTING_LAMPAC_PATH_SRC" == "unit" ]] \
    && native_removal_target_is_safe "$EXISTING_LAMPAC_PATH" Core.dll "$EXISTING_LAMPAC_EXEC_PATH" \
    && ! (( EXISTING_LAMPAC_DOCKER > 0 || EXISTING_ALCOPAC_DOCKER > 0 )) \
    && { (( EXISTING_ALCOPAC == 0 )) || ! native_paths_overlap "$EXISTING_LAMPAC_PATH" "$EXISTING_ALCOPAC_PATH"; }
}

use_detected_lampac_root() {
  if lampac_native_update_available; then
    INSTALL_ROOT="$EXISTING_LAMPAC_PATH"
  fi
}

fetch_recent_release_tags() {
  local json tag count=0

  if ! command -v curl >/dev/null 2>&1; then
    log_err "Для получения списка релизов требуется curl."
    return 1
  fi
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100")" || {
    log_err "Не удалось получить версии из ${GITHUB_REPO}. Проверьте подключение к GitHub."
    return 1
  }

  RECENT_RELEASE_TAGS=()
  while IFS= read -r tag; do
    [[ "$tag" =~ ^v?[0-9]+([._+-][A-Za-z0-9.-]+|\.[0-9]+)*$ ]] || continue
    RECENT_RELEASE_TAGS+=("$tag")
    count=$((count + 1))
    (( count >= 100 )) && break
  done < <(printf '%s' "$json" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

  if (( ${#RECENT_RELEASE_TAGS[@]} == 0 )); then
    log_err "В ${GITHUB_REPO} не найдены опубликованные версии."
    return 1
  fi
}

version_tag_is_older() {
  local candidate current first
  candidate="$(normalize_version "$1")"
  current="$(normalize_version "$2")"
  [[ -n "$candidate" && -n "$current" && "$candidate" != "$current" ]] || return 1
  first="$(printf '%s\n%s\n' "$candidate" "$current" | sort -V | head -n1)"
  [[ "$first" == "$candidate" ]]
}

select_release_version() {
  local mode="$1" current="" tag answer answer_num index=0
  local -a choices=()

  if [[ "$mode" == "older" ]]; then
    current="$(get_installed_version)"
    if [[ -z "$current" || "$current" == "N/A" ]]; then
      log_err "Текущая версия неизвестна — список для отката построить нельзя."
      return 1
    fi
  fi
  fetch_recent_release_tags || return 1

  for tag in "${RECENT_RELEASE_TAGS[@]}"; do
    if [[ "$mode" == "older" ]] && ! version_tag_is_older "$tag" "$current"; then
      continue
    fi
    choices+=("$tag")
    (( ${#choices[@]} >= 10 )) && break
  done

  if (( ${#choices[@]} == 0 )); then
    log_warn "Среди последних опубликованных релизов нет версии старше установленной (${current})."
    return 1
  fi

  printf '\n  %s─── Выберите версию из репозитория %s ───%s\n\n' "$C_CYAN" "$GITHUB_REPO" "$C_RESET"
  for tag in "${choices[@]}"; do
    index=$((index + 1))
    printf '    %s%d%s) %s\n' "$C_BOLD" "$index" "$C_RESET" "$(sanitize_external_text "$tag")"
  done
  printf '    %s0%s) Назад\n\n' "$C_BOLD" "$C_RESET"

  while true; do
    printf '  Выберите номер версии: '
    if ! read -r answer </dev/tty; then
      printf '\n'
      log_info "Ввод закрыт — выбор версии отменён."
      return 1
    fi
    case "$answer" in
      0) return 1 ;;
      ''|*[!0-9]*) log_warn "Введите номер из списка или 0 для возврата." ;;
      *)
        if (( ${#answer} > MENU_MAX_INPUT_LEN )); then
          log_warn "Слишком длинный ввод — выберите номер из списка или 0 для возврата."
          continue
        fi
        answer_num=$((10#$answer))
        if (( answer_num >= 1 && answer_num <= ${#choices[@]} )); then
          TARGET_VERSION="${choices[$((answer_num - 1))]}"
          return 0
        fi
        log_warn "Такого номера нет в списке версий."
        ;;
    esac
  done
}

confirm_version_rollback() {
  local target_version="$1" answer

  printf '\n  %s⚠  Откат Lampac NextGen%s\n' "$C_YELLOW" "$C_RESET"
  printf '  Текущая версия: %s\n' "$(get_installed_version)"
  printf '  Целевая версия: %s\n' "$target_version"
  printf '  Файлы приложения будут заменены; пользовательские данные сохраняются правилами обновления.\n'
  printf '  Введите %sROLLBACK%s для продолжения (иначе откат отменится): ' "$C_BOLD" "$C_RESET"
  if ! read -r answer </dev/tty; then
    printf '\n'
    log_info "Ввод закрыт — откат отменён."
    return 1
  fi
  [[ "$answer" == "ROLLBACK" ]]
}

native_paths_overlap() {
  local first="$1" second="$2" first_real second_real

  # Неизвестный путь другой установки — это небезопасное пересечение.
  [[ -n "$first" && -n "$second" ]] || return 0
  first_real="$(readlink -f -- "$first" 2>/dev/null)" || return 0
  second_real="$(readlink -f -- "$second" 2>/dev/null)" || return 0
  [[ -n "$first_real" && -n "$second_real" ]] || return 0
  [[ "$first_real" == "$second_real" || "$first_real" == "$second_real"/* || "$second_real" == "$first_real"/* ]]
}

# Автоудаление нестандартного каталога допускается только при точном пути из
# юнита и маркере приложения. Симлинки и одноуровневые корни исключены.
native_removal_target_is_safe() {
  local path="$1" marker="$2" exec_path="$3" resolved

  [[ "$path" == /* && "$path" != / && ( "$path" == /opt/* || "$path" == /*/*/* ) ]] || return 1
  case "$path" in
    /bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 1 ;;
  esac
  resolved="$(readlink -f -- "$path" 2>/dev/null)" || return 1
  [[ "$resolved" == "$path" && "$exec_path" == "$path/$marker" && -d "$path" && -e "$path/$marker" ]]
}

native_alcopac_removal_available() {
  (( EXISTING_ALCOPAC == CHK_CONFIRMED )) \
    && [[ "$EXISTING_ALCOPAC_UNIT_PATH" == "$ALCOPAC_SYSTEMD_UNIT_PATH" ]] \
    && native_removal_target_is_safe "$EXISTING_ALCOPAC_PATH" lampac-go "$EXISTING_ALCOPAC_EXEC_PATH" \
    && ! (( EXISTING_LAMPAC_DOCKER > 0 || EXISTING_ALCOPAC_DOCKER > 0 )) \
    && { (( EXISTING_LAMPAC == 0 )) || ! native_paths_overlap "$EXISTING_ALCOPAC_PATH" "$EXISTING_LAMPAC_PATH"; }
}

native_lampac_custom_removal_available() {
  (( EXISTING_LAMPAC == CHK_CONFIRMED )) \
    && [[ "$EXISTING_LAMPAC_UNIT_PATH" == "$LAMPAC_SYSTEMD_UNIT_PATH" ]] \
    && [[ "$EXISTING_LAMPAC_PATH_SRC" == "unit" && "$EXISTING_LAMPAC_PATH" != "${LAMPAC_INSTALL_ROOT:-/opt/lampac}" ]] \
    && native_removal_target_is_safe "$EXISTING_LAMPAC_PATH" Core.dll "$EXISTING_LAMPAC_EXEC_PATH" \
    && ! (( EXISTING_ALCOPAC_DOCKER > 0 || EXISTING_LAMPAC_DOCKER > 0 )) \
    && { (( EXISTING_ALCOPAC == 0 )) || ! native_paths_overlap "$EXISTING_LAMPAC_PATH" "$EXISTING_ALCOPAC_PATH"; }
}

confirm_native_removal() {
  local product="$1" target="$2" consequences="$3" token="$4" expected_path="${5:-}" answer

  printf '\n  %s⚠  Удаление %s%s\n' "$C_YELLOW" "$product" "$C_RESET"
  printf '  %sОбъект:%s %s\n' "$C_BOLD" "$C_RESET" "$target"
  printf '  %sПоследствие:%s %s\n\n' "$C_BOLD" "$C_RESET" "$consequences"
  if [[ -n "$expected_path" ]]; then
    printf '  Введите точный путь %s%s%s: ' "$C_BOLD" "$expected_path" "$C_RESET"
    if ! read -r answer </dev/tty; then
      printf '\n'
      log_warn "Ввод закрыт (EOF) — удаление отменено."
      return 1
    fi
    if [[ "$answer" != "$expected_path" ]]; then
      log_info "Путь не подтверждён — удаление отменено."
      return 1
    fi
  fi
  printf '  Введите %s%s%s для подтверждения: ' "$C_BOLD" "$token" "$C_RESET"
  if ! read -r answer </dev/tty; then
    printf '\n'
    log_warn "Ввод закрыт (EOF) — удаление отменено."
    return 1
  fi
  if [[ "$answer" != "$token" ]]; then
    log_info "Удаление отменено."
    return 1
  fi
  return 0
}

remove_alcopac_native() {
  local path="$EXISTING_ALCOPAC_PATH"

  if ! native_alcopac_removal_available; then
    log_err "Безопасное удаление системного Al(co)pac недоступно: установка должна иметь подтверждённый отдельный каталог и штатный юнит."
    return 1
  fi

  if [[ "$path" == "$ALCOPAC_DOC_PATH" ]]; then
    confirm_native_removal "Al(co)pac" "${ALCOPAC_UNIT} и ${path}" "служба будет остановлена и удалена; каталог с конфигурацией, базами и данными будет удалён безвозвратно." "REMOVE ALCOPAC" || return 0
  else
    confirm_native_removal "нестандартной установки Al(co)pac" "${ALCOPAC_UNIT} и ${path}" "служба будет остановлена и удалена; весь подтверждённый каталог с конфигурацией, базами и данными будет удалён безвозвратно." "REMOVE ALCOPAC" "$path" || return 0
  fi
  systemctl disable --now "$ALCOPAC_UNIT"
  rm -f -- "$ALCOPAC_SYSTEMD_UNIT_PATH"
  systemctl daemon-reload
  rm -rf -- "$path"
  log_ok "Системная установка Al(co)pac удалена."
}

remove_lampac_custom_native() {
  local path="$EXISTING_LAMPAC_PATH"

  if ! native_lampac_custom_removal_available; then
    log_err "Безопасное удаление нестандартного Lampac NextGen недоступно: нужен подтверждённый отдельный каталог и штатный юнит."
    return 1
  fi

  confirm_native_removal "нестандартной установки Lampac NextGen" "lampac.service и ${path}" "служба будет остановлена и удалена; весь подтверждённый каталог с конфигурацией и данными будет удалён безвозвратно. Учётная запись lampac не удаляется." "REMOVE LAMPAC" "$path" || return 0
  systemctl disable --now lampac.service
  rm -f -- "$LAMPAC_SYSTEMD_UNIT_PATH"
  systemctl daemon-reload
  rm -rf -- "$path"
  remove_lampac_setup_command
  log_ok "Нестандартная системная установка Lampac NextGen удалена."
}

run_alcopac_removal_menu() {
  local answer

  run_existing_checks
  printf '\n  %s─── Удаление Al(co)pac ───%s\n\n' "$C_YELLOW" "$C_RESET"
  if native_alcopac_removal_available; then
    if [[ "$EXISTING_ALCOPAC_PATH" == "$ALCOPAC_DOC_PATH" ]]; then
      printf '    %s1%s) Удалить системную установку Al(co)pac и её данные\n' "$C_BOLD" "$C_RESET"
    else
      printf '    %s1%s) Удалить нестандартную системную установку Al(co)pac: %s\n' "$C_BOLD" "$C_RESET" "$EXISTING_ALCOPAC_PATH"
    fi
  fi
  printf '    %s0%s) Назад\n\n' "$C_BOLD" "$C_RESET"

  while true; do
    printf '  Выберите пункт: '
    if ! read -r answer </dev/tty; then
      printf '\n'
      return 0
    fi
    case "$answer" in
      1)
        if native_alcopac_removal_available; then
          remove_alcopac_native
          return 0
        fi
        log_warn "Этот вариант недоступен для текущего состояния системы."
        ;;
      0) return 0 ;;
      "") log_warn "Пустой ввод — выберите доступный пункт или 0." ;;
      *) log_warn "Неизвестный пункт — выберите доступный пункт или 0." ;;
    esac
  done
}

prompt_menu_transition() {
  local answer

  printf '\n  %sУстановленных копий не найдено.%s\n\n' "$C_GREEN" "$C_RESET"
  printf '    %s1%s) Перейти к меню действий\n' "$C_BOLD" "$C_RESET"
  printf '    %s0%s) Выйти\n\n' "$C_BOLD" "$C_RESET"

  trap 'printf "\n"; log_info "Ввод прерван (Ctrl+C) — выход."; exit 130' INT
  while true; do
    printf '  Выберите пункт: '
    if ! read -r answer </dev/tty; then
      trap - INT
      printf '\n'
      log_info "Ввод закрыт (EOF) — выход."
      return 1
    fi

    if (( ${#answer} > MENU_MAX_INPUT_LEN )); then
      log_warn "Слишком длинный ввод — выберите 1 или 0."
      continue
    fi

    case "$answer" in
      1)
        trap - INT
        return 0
        ;;
      0)
        trap - INT
        log_info "Выбран выход."
        return 1
        ;;
      "")
        log_warn "Пустой ввод — выберите 1 или 0."
        ;;
      *)
        log_warn "Неизвестный пункт — выберите 1 или 0."
        ;;
    esac
  done
}

run_interactive_install() {
  if (( EXISTING_HITS > 0 )); then
    log_warn "Чистая установка не запущена: обнаружены установленные копии — $(existing_found_list)."
    return 0
  fi

  UPDATE=0 DRY_RUN=0 PRE_RELEASE=0 VERBOSE=0
  run_selected_operation
  if (( ! OPERATION_SKIPPED )) && [[ -f "${INSTALL_ROOT}/Core.dll" && -f "$SYSTEMD_UNIT_PATH" ]]; then
    POST_INSTALL_MENU=1
  fi
}

run_interactive_menu() {
  local answer

  MENU_SESSION_ACTIVE=1
  trap 'printf "\n"; log_info "Ввод прерван (Ctrl+C) — выход из меню."; exit 130' INT
  while true; do
    trap 'printf "\n"; log_info "Ввод прерван (Ctrl+C) — выход из меню."; exit 130' INT
    if (( POST_INSTALL_MENU )); then
      POST_INSTALL_MENU=0
      run_existing_checks
      use_detected_lampac_root
    elif (( MENU_CHECKS_READY )); then
      MENU_CHECKS_READY=0
      use_detected_lampac_root
    else
      run_existing_checks
      use_detected_lampac_root
    fi
    if lampac_native_update_available; then
      show_version
    else
      print_banner
    fi
    show_main_menu
    if ! read -r answer </dev/tty; then
      printf '\n'
      log_info "Ввод закрыт (EOF) — выход из меню."
      MENU_SESSION_ACTIVE=0
      return 0
    fi

    if (( ${#answer} > MENU_MAX_INPUT_LEN )); then
      log_warn "Слишком длинный ввод — выберите доступный пункт."
      continue
    fi

    if [[ "$answer" == "0" ]]; then
      log_info "Выбран выход."
      MENU_SESSION_ACTIVE=0
      return 0
    fi
    if [[ -n "$MENU_ALCOPAC_ITEM" && "$answer" == "$MENU_ALCOPAC_ITEM" ]]; then
      run_alcopac_removal_menu
      continue
    fi
    if [[ -n "$MENU_BOOTSTRAP_ITEM" && "$answer" == "$MENU_BOOTSTRAP_ITEM" ]]; then
      install_minimum_installer_dependencies
      continue
    fi
    if [[ "$MENU_KIND" == lampac && -n "$PORT_MENU_ITEM" && "$answer" == "$PORT_MENU_ITEM" ]]; then
      configure_install_port || true
      continue
    fi
    if [[ "$MENU_KIND" == lampac && -n "$SETUP_MENU_ITEM" && "$answer" == "$SETUP_MENU_ITEM" ]]; then
      install_lampac_setup_command || true
      continue
    fi

    case "$MENU_KIND:$answer" in
      lampac:1)
        if ensure_disclaimer_consent; then
          UPDATE=1 DRY_RUN=0 PRE_RELEASE=0 TARGET_VERSION="" VERBOSE=0
          run_selected_operation
        fi
        ;;
      lampac:2)
        if ensure_disclaimer_consent; then
          UPDATE=1 DRY_RUN=0 PRE_RELEASE=0 TARGET_VERSION="" VERBOSE=1
          run_selected_operation
          VERBOSE=0
        fi
        ;;
      lampac:3)
        TARGET_VERSION=""
        if select_release_version older && confirm_version_rollback "$TARGET_VERSION" && ensure_disclaimer_consent; then
          UPDATE=1 DRY_RUN=0 PRE_RELEASE=0 VERBOSE=0
          run_selected_operation
        fi
        ;;
      lampac:4)
        if [[ "$EXISTING_LAMPAC_PATH" != "${LAMPAC_INSTALL_ROOT:-/opt/lampac}" ]]; then
          if native_lampac_custom_removal_available; then
            remove_lampac_custom_native
          else
            log_warn "Нестандартный Lampac NextGen обнаружен, но безопасное автоматическое удаление недоступно."
          fi
        else
          do_remove 1
        fi
        run_existing_checks
        INSTALL_ROOT="${LAMPAC_INSTALL_ROOT:-/opt/lampac}"
        ;;
      lampac:5) : ;;
      lampac:6)
        show_system_info
        show_install_dependency_check
        run_existing_checks
        show_existing_checks
        MENU_CHECKS_READY=1
        ;;
      fresh:1)
        UPDATE=0 DRY_RUN=0 PRE_RELEASE=0 TARGET_VERSION="" VERBOSE=0
        run_interactive_install
        ;;
      fresh:2)
        UPDATE=0 DRY_RUN=0 PRE_RELEASE=0 VERBOSE=0 TARGET_VERSION=""
        if select_release_version install; then run_selected_operation; fi
        ;;
      fresh:3)
        UPDATE=0 DRY_RUN=0 PRE_RELEASE=0 TARGET_VERSION="" VERBOSE=1
        run_selected_operation
        VERBOSE=0
        ;;
      fresh:4|other:1)
        show_system_info
        show_install_dependency_check
        run_existing_checks
        show_existing_checks
        MENU_CHECKS_READY=1
        ;;
      *:'') log_warn "Пустой ввод — выберите доступный пункт." ;;
      *) log_warn "Неизвестный пункт — выберите доступный пункт." ;;
    esac
  done
}

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
  print_banner
  printf '%sUsage:%s  %s [OPTIONS]\n\n' "$C_BOLD" "$C_RESET" "$SCRIPT_NAME"
  printf 'Install, update, or remove Lampac NextGen on Debian/Ubuntu (x86_64 or arm64).\n\n'

  printf '%sEnvironment (optional):%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s%-24s%s %-34s %s(default: %s)%s\n' \
    "$C_CYAN" "LAMPAC_GITHUB_REPO" "$C_RESET" "GitHub owner/repo for releases" "$C_DIM" "$GITHUB_REPO" "$C_RESET"
  printf '  %s%-24s%s %-34s %s(default: %s)%s\n' \
    "$C_CYAN" "LAMPAC_INSTALL_ROOT" "$C_RESET" "Install directory" "$C_DIM" "$INSTALL_ROOT" "$C_RESET"
  printf '  %s%-24s%s %-34s %s(default: %s)%s\n' \
    "$C_CYAN" "LAMPAC_USER" "$C_RESET" "Service account name" "$C_DIM" "$LAMPAC_USER" "$C_RESET"
  printf '  %s%-24s%s %-34s %s(default: %s)%s\n' \
    "$C_CYAN" "LAMPAC_UID" "$C_RESET" "Preferred UID" "$C_DIM" "1000" "$C_RESET"
  printf '  %s%-24s%s %-34s %s(default: %s)%s\n' \
    "$C_CYAN" "LAMPAC_GID" "$C_RESET" "Preferred GID" "$C_DIM" "1000" "$C_RESET"
  printf '  %s%-24s%s %-34s %s(default: %s)%s\n' \
    "$C_CYAN" "LAMPAC_PORT" "$C_RESET" "HTTP port hint" "$C_DIM" "$LISTEN_PORT" "$C_RESET"
  printf '  %s%-24s%s Skip %s--remove%s confirmation when set to 1\n' \
    "$C_CYAN" "LAMPAC_CONFIRM_REMOVE" "$C_RESET" "$C_RED" "$C_RESET"
  printf '\n'

  printf '%sOptions:%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s%-16s%s %s\n' "$C_GREEN"  "--update"      "$C_RESET" "Replace app files from latest (or --tag) release"
  printf '  %s%-16s%s %s\n' "$C_GREEN"  "--tag VER"     "$C_RESET" "Install or update a specific release tag"
  printf '  %s%-16s%s %s\n' "$C_YELLOW" "--force"       "$C_RESET" "Reinstall even if the desired version is already installed"
  printf '  %s%-16s%s %s\n' "$C_YELLOW" "--dry-run"     "$C_RESET" "Preview an update; requires --update"
  printf '  %s%-16s%s %s\n' "$C_YELLOW" "--pre-release" "$C_RESET" "Use latest GitHub pre-release (${RELEASE_ZIP_NAME})"
  printf '  %s%-16s%s %s\n' "$C_RED"    "--remove"      "$C_RESET" "Remove systemd unit, user, and install directory"
  printf '  %s%-16s%s %s\n' "$C_GREEN"  "--install-setup" "$C_RESET" "Install only the lampac setup command for an existing NextGen service"
  printf '  %s%-16s%s %s\n' "$C_BLUE"   "-v, --verbose" "$C_RESET" "Show full output of all commands (for debugging)"
  printf '  %s%-16s%s %s\n' "$C_BLUE"   "-h, --help"    "$C_RESET" "Show this help and exit"
  printf '  %s%-16s%s %s\n' "$C_BLUE"   "--version"     "$C_RESET" "Show installed version"
  printf '\n'

  printf '%sExamples:%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s# install (latest)%s\n' "$C_DIM" "$C_RESET"
  printf '  curl -fsSL https://raw.githubusercontent.com/%s/main/install.sh | bash\n' "$GITHUB_REPO"
  printf '  %s# install / pin a tag%s\n' "$C_DIM" "$C_RESET"
  printf '  %s --tag v1.2.3\n' "$SCRIPT_NAME"
  printf '  %s# update / downgrade%s\n' "$C_DIM" "$C_RESET"
  printf '  %s --update\n' "$SCRIPT_NAME"
  printf '  %s --update --tag v1.2.3\n' "$SCRIPT_NAME"
  printf '  %s# force reinstall same version%s\n' "$C_DIM" "$C_RESET"
  printf '  %s --update --force\n' "$SCRIPT_NAME"
  printf '\n'
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
  spinner_stop
  local path
  (( ${#CLEANUP_PATHS[@]} )) || return 0
  for path in "${CLEANUP_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      rm -rf "$path"
    fi
  done
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

detect_arch() {
  case "$(uname -m)" in
    x86_64)       echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      log_err "Unsupported architecture: $(uname -m). Supported: amd64, arm64."
      exit 1
      ;;
  esac
}

get_prerelease_zip_url() {
  if ! command -v curl >/dev/null 2>&1; then
    log_err "curl is required for --pre-release."
    exit 1
  fi
  ensure_jq
  local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases"
  local url
  url=$(curl -sSL -H 'Accept: application/vnd.github+json' "$api_url" \
    | jq -r --arg name "$RELEASE_ZIP_NAME" \
      '.[] | select(.prerelease == true) | .assets[] | select(.name == $name) | .browser_download_url' \
    | head -n1) || true
  if [[ -z "${url:-}" ]]; then
    log_err "No pre-release asset named $RELEASE_ZIP_NAME found for $GITHUB_REPO."
    exit 1
  fi
  PUBLISH_URL="$url"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --pre-release)
        PRE_RELEASE=1
        shift
        ;;
      --remove)
        REMOVE=1
        shift
        ;;
      --install-setup)
        INSTALL_SETUP_ONLY=1
        shift
        ;;
      --update)
        UPDATE=1
        shift
        ;;
      --tag)
        if [[ $# -lt 2 || -z "${2:-}" || "$2" == -* ]]; then
          log_err "--tag requires a version argument (e.g. --tag v1.2.3)."
          usage >&2
          exit 1
        fi
        TARGET_VERSION="$2"
        shift 2
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      --version)
        show_version
        exit 0
        ;;
      *)
        log_err "Unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ -n "$TARGET_VERSION" && "$PRE_RELEASE" -eq 1 ]]; then
    log_err "--tag and --pre-release are mutually exclusive."
    exit 1
  fi
  if (( INSTALL_SETUP_ONLY == 1 )) \
    && { (( REMOVE == 1 || UPDATE == 1 || DRY_RUN == 1 || PRE_RELEASE == 1 || FORCE == 1 )) || [[ -n "$TARGET_VERSION" ]]; }; then
    log_err "--install-setup cannot be combined with other operation options."
    exit 1
  fi
  if [[ "$DRY_RUN" -eq 1 && "$UPDATE" -ne 1 ]]; then
    log_err "--dry-run requires --update; it does not preview a fresh installation."
    exit 1
  fi
  if [[ "$REMOVE" -eq 1 && ( "$UPDATE" -eq 1 || "$DRY_RUN" -eq 1 || -n "$TARGET_VERSION" || "$PRE_RELEASE" -eq 1 || "$FORCE" -eq 1 ) ]]; then
    log_err "--remove cannot be combined with install, update, or release-selection options."
    exit 1
  fi
}

# Re-exec under sudo. Materializes the script when run via curl|bash (/dev/fd/…).
require_root() {
  if [[ ${EUID} -eq 0 ]]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    log_err "This script must run as root (sudo not found)."
    exit 1
  fi

  local src="${BASH_SOURCE[0]:-$0}"
  local tmp=""

  # Regular on-disk script — sudo it directly.
  if [[ -f "$src" && -r "$src" && "$src" != /dev/fd/* && "$src" != /proc/self/fd/* ]]; then
    exec sudo -E bash "$src" "$@"
  fi

  # Piped / process-substitution: copy to a temp file first (fd is process-local).
  if [[ -r "$src" ]]; then
    tmp="$(mktemp /tmp/lampac-install.XXXXXX.sh)"
    cat "$src" > "$tmp"
    chmod 700 "$tmp"
    exec sudo -E bash "$tmp" "$@"
  fi

  log_err "Cannot re-exec as root (script source unreadable). Download install.sh and run: sudo bash install.sh …"
  exit 1
}

pick_libicu_package() {
  local p
  for p in "${ICU_PACKAGE_CANDIDATES[@]}"; do
    if apt-cache show "$p" &>/dev/null; then
      echo "$p"
      return 0
    fi
  done
  log_err "Could not find a suitable libicu package in apt caches."
  exit 1
}

# Install jq early when needed for --pre-release (before full package step).
ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_err "jq is required for a pre-release dry-run; install jq and retry."
    exit 1
  fi
  if [[ ${EUID} -ne 0 ]]; then
    log_err "jq is required but not installed."
    exit 1
  fi
  log_info "Installing jq..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq \
    || ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq -qq; then
    log_err "Failed to install jq (required for --pre-release)."
    exit 1
  fi
  log_ok "jq installed"
}

# Extract "tag_name" from a GitHub release JSON blob without jq.
json_extract_tag_name() {
  local json="$1"
  printf '%s' "$json" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n1 \
    | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# ─── Version ───────────────────────────────────────────────────────────

# Убрать ведущий "v" для сравнения и записи в version.txt
normalize_version() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  echo "${v#v}"
}

# Проверить, что asset релиза доступен по URL (без скачивания всего zip)
release_asset_exists() {
  local url="$1"
  local code
  code=$(curl -fsSIL -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || return 1
  [[ "$code" == "200" ]]
}

# Разрешить PUBLISH_URL для конкретного тега (с fallback v / без v)
resolve_tag_publish_url() {
  local input="$1"
  local -a candidates=()
  local tag url

  candidates+=("$input")
  if [[ "$input" == v* ]]; then
    candidates+=("${input#v}")
  else
    candidates+=("v${input}")
  fi

  for tag in "${candidates[@]}"; do
    url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/${RELEASE_ZIP_NAME}"
    if release_asset_exists "$url"; then
      PUBLISH_URL="$url"
      return 0
    fi
  done

  log_err "Release tag not found for ${GITHUB_REPO}: ${input} (asset ${RELEASE_ZIP_NAME})."
  exit 1
}

# Выбрать PUBLISH_URL: --tag, --pre-release или latest
resolve_publish_url() {
  if [[ -n "$TARGET_VERSION" ]]; then
    spinner_start "Resolving release tag ${TARGET_VERSION}..."
    resolve_tag_publish_url "$TARGET_VERSION"
    spinner_ok "Release URL resolved"
  elif [[ "$PRE_RELEASE" -eq 1 ]]; then
    spinner_start "Resolving latest pre-release asset..."
    get_prerelease_zip_url
    spinner_ok "Pre-release URL resolved"
  else
    PUBLISH_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/${RELEASE_ZIP_NAME}"
  fi
}

# Получить номер последнего [пре-]релиза Лампака с гитхаба
get_release_version() {
  if ! command -v curl >/dev/null 2>&1; then
    log_err "curl is required to get release version."
    exit 1
  fi

  local version json api_url

  if [[ "$PRE_RELEASE" -eq 1 ]]; then
    ensure_jq
    api_url="https://api.github.com/repos/${GITHUB_REPO}/releases"
    version=$(curl -sSL -H 'Accept: application/vnd.github+json' "$api_url" \
      | jq -r '.[] | select(.prerelease == true) | .tag_name' | head -n1) || true
  else
    # Same source of truth as PUBLISH_URL (.../releases/latest/download/...)
    api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    json=$(curl -sSL -H 'Accept: application/vnd.github+json' "$api_url") || true
    version="$(json_extract_tag_name "${json:-}")"
  fi

  version="$(normalize_version "${version:-}")"
  if [[ -z "${version:-}" ]]; then
    log_err "Could not determine release version from ${api_url}."
    exit 1
  fi
  echo "$version"
}

# Получить номер установленной версии Лампака из файлика
get_installed_version() {
  local version_file="${INSTALL_ROOT}/${VERSION_FILE_NAME}"
  if [[ -f "$version_file" ]]; then
    normalize_version "$(cat "$version_file")"
  else
    echo "N/A"
  fi
}

# Показать баннер и установленную версию Лампака для опции --version
show_version() {
  print_banner
  if [[ -d "$INSTALL_ROOT" ]] && [[ -f "${INSTALL_ROOT}/Core.dll" ]]; then
    printf '  %sInstalled Version:%s %s\n' "$C_BOLD" "$C_RESET" "$(get_installed_version)"
  else
    echo "Lampac is not installed."
  fi
  printf '\n'
}

# Сохранить версию в файлик, чтобы было что потом показывать
save_installed_version() {
  local version
  version="$(normalize_version "$1")"
  local version_file="${INSTALL_ROOT}/${VERSION_FILE_NAME}"
  echo "$version" > "$version_file"
}

# Не продолжать, если желаемая версия уже установлена (если нет --force)
confirm_same_version_or_exit() {
  local desired
  desired="$(normalize_version "$1")"
  local installed
  installed="$(get_installed_version)"

  if [[ "$installed" == "N/A" || "$installed" != "$desired" ]]; then
    return 0
  fi

  if [[ "$FORCE" -eq 1 ]]; then
    log_warn "Version ${desired} is already installed — continuing due to --force."
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_ok "Version ${desired} is already installed — nothing to do (dry-run)."
    printf '  Use %s--force%s to preview a reinstall of the same version.\n\n' "$C_YELLOW" "$C_RESET"
    OPERATION_SKIPPED=1
    return 0
  fi

  printf '\n  %sVersion %s is already installed.%s\n' "$C_YELLOW" "$desired" "$C_RESET"
  printf '  Continue anyway? [y/N]: '

  if [[ ! -r /dev/tty ]]; then
    printf '\n'
    log_err "Cannot prompt for confirmation (no TTY). Use --force to reinstall the same version."
    exit 1
  fi

  local answer
  read -r answer </dev/tty || true
  case "${answer:-}" in
    y|Y|yes|YES)
      log_warn "Reinstalling version ${desired}."
      return 0
      ;;
    *)
      log_ok "Skipped — already at version ${desired}."
      printf '\n'
      OPERATION_SKIPPED=1
      return 0
      ;;
  esac
}


# ─── Install steps ───────────────────────────────────────────────────────────

install_google_chrome() {
  if command -v google-chrome-stable >/dev/null 2>&1; then
    ln -sf /usr/bin/google-chrome-stable /usr/bin/chromium
    log_skip "Google Chrome already installed — skipping"
    return 0
  fi

  local chrome_url chrome_deb
  case "$ARCH" in
    arm64) chrome_url="https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb" ;;
    amd64) chrome_url="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" ;;
    *)
      log_err "Unsupported architecture for Google Chrome: $ARCH"
      exit 1
      ;;
  esac

  chrome_deb="/tmp/google-chrome-stable-$$.deb"
  CLEANUP_PATHS+=("$chrome_deb")

  run_quiet "Downloading Google Chrome ($ARCH)" \
    curl -fSL -o "$chrome_deb" "$chrome_url"
  run_quiet "Installing Google Chrome" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$chrome_deb"
  ln -sf /usr/bin/google-chrome-stable /usr/bin/chromium
}

# Устанавливает отсутствующие и обновляет устаревшие пакеты из заданного списка.
#
# Аргументы:
#   Все аргументы функции рассматриваются как имена пакетов.
#
# Пример использования:
#   manage_packages curl wget git docker-ce nginx
manage_packages() {
# Проверяем, передан ли хотя бы один пакет
  if [ "$#" -eq 0 ]; then
    log_err "Package list is empty."
    return 1
  fi

  local packages=("$@")
  local packages_to_install=()
  local packages_to_upgrade=()

  # Создаем временный файл для хранения списка upgradable-пакетов
  local upgradable_list=$(mktemp)
  # Получаем список пакетов, которые можно обновить.
  # sed отсекает заголовок и предупреждения.
  apt list --upgradable 2>/dev/null | sed '/^Listing/d' > "$upgradable_list"

  # Проходим по каждому пакету из аргументов
  for pkg in "${packages[@]}"; do
    # Проверяем, установлен ли пакет
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      # Пакет установлен. Проверим, есть ли он в списке на обновление.
      if [ -s "$upgradable_list" ] && grep -E "^$pkg/" "$upgradable_list" &>/dev/null; then
        packages_to_upgrade+=("$pkg")
      fi
    else
    # Пакет не установлен.
      packages_to_install+=("$pkg")
    fi
  done

  # Удаляем временный файл
  rm -f "$upgradable_list"

  # Выполняем установку и/или обновление, если это необходимо.
  # Этот блок выполняется, если хотя бы один из массивов (установки или обновления) не пуст.
  if [ "${#packages_to_install[@]}" -eq 0 ] && [ "${#packages_to_upgrade[@]}" -eq 0 ]; then
    log_skip "System packages already installed/upgdraded — skipping"
    return 0
  else
    if [ "${#packages_to_install[@]}" -gt 0 ]; then
      run_quiet "Installing system packages (curl, jq, fonts, GStreamer, ICU, ImageMagick, unzip, rsync)" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages_to_install[@]}"
    fi
    if [ "${#packages_to_upgrade[@]}" -gt 0 ]; then
      run_quiet "Updating system packages (curl, jq, fonts, GStreamer, ICU, ImageMagick, unzip, rsync)" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "${packages_to_upgrade[@]}"
    fi
  fi
}

install_os_packages() {
  run_quiet "Updating package lists" \
    apt-get update

  local icu_pkg
  local -a packages=()
  icu_pkg="$(pick_libicu_package)"
  mapfile -t packages < <(required_system_packages)

  manage_packages "${packages[@]}" "$icu_pkg"

  install_google_chrome

  apt-get clean -qq 2>/dev/null || true
  rm -rf /var/lib/apt/lists/*
}

install_minimum_installer_dependencies() {
  local -a packages=()

  if ! command -v apt-get >/dev/null 2>&1; then
    log_err "apt-get недоступен — минимальные зависимости установить нельзя."
    return 1
  fi

  package_is_installed ca-certificates || packages+=(ca-certificates)
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  if (( ${#packages[@]} == 0 )); then
    log_skip "Минимальные зависимости установщика уже готовы."
    return 0
  fi

  log_info "Минимальный набор: ${packages[*]}"
  run_quiet "Updating package lists" apt-get update
  run_quiet "Installing minimum installer dependencies" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"

  if ! minimum_installer_dependencies_ready; then
    log_err "Не удалось подготовить curl и сертификаты для загрузки релизов."
    return 1
  fi
  log_ok "Минимальные зависимости установлены; можно продолжить установку из меню."
}

install_aspnetcore_runtime() {
  local runtime_version
  runtime_version="$(aspnetcore_runtime_version)"
  if [[ -n "$runtime_version" ]]; then
    log_skip "ASP.NET Core ${runtime_version} runtime already present — skipping"
    return 0
  fi

  local installer="/tmp/dotnet-install-$$.sh"
  CLEANUP_PATHS+=("$installer")

  run_quiet "Downloading dotnet-install.sh" \
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$installer"
  chmod +x "$installer"

  run_quiet "Installing ASP.NET Core ${DOTNET_CHANNEL} runtime" \
    bash "$installer" --channel "$DOTNET_CHANNEL" --runtime aspnetcore \
      --install-dir "$DOTNET_INSTALL_DIR"
}

uid_in_use() { getent passwd "$1" &>/dev/null; }
gid_in_use() { getent group  "$1" &>/dev/null; }

ensure_service_user() {
  local prefer_uid="${LAMPAC_UID:-1000}"
  local prefer_gid="${LAMPAC_GID:-1000}"

  if getent group "$LAMPAC_USER" &>/dev/null; then
    log_skip "Group ${LAMPAC_USER} already exists"
  else
    if gid_in_use "$prefer_gid"; then
      local holder
      holder="$(getent group "$prefer_gid" | cut -d: -f1)"
      log_warn "GID ${prefer_gid} taken by \"${holder}\" — using system-assigned GID"
      groupadd -r "$LAMPAC_USER"
    else
      groupadd -r -g "$prefer_gid" "$LAMPAC_USER"
      log_ok "Group ${LAMPAC_USER} created (gid ${prefer_gid})"
    fi
  fi

  if getent passwd "$LAMPAC_USER" &>/dev/null; then
    log_skip "User ${LAMPAC_USER} already exists"
    return 0
  fi

  if uid_in_use "$prefer_uid"; then
    local holder
    holder="$(getent passwd "$prefer_uid" | cut -d: -f1)"
    log_warn "UID ${prefer_uid} taken by \"${holder}\" — using system-assigned UID"
    useradd -r -g "$LAMPAC_USER" -d "$INSTALL_ROOT" -s /usr/sbin/nologin "$LAMPAC_USER"
  else
    useradd -r -u "$prefer_uid" -g "$LAMPAC_USER" -d "$INSTALL_ROOT" -s /usr/sbin/nologin "$LAMPAC_USER"
  fi

  if ! getent passwd "$LAMPAC_USER" &>/dev/null; then
    log_err "Failed to create user ${LAMPAC_USER}."
    exit 1
  fi
  log_ok "User ${LAMPAC_USER} created (home ${INSTALL_ROOT})"
}

set_install_ownership() {
  chown -R "${LAMPAC_USER}:${LAMPAC_USER}" "$INSTALL_ROOT"
  log_ok "Ownership set to ${LAMPAC_USER}:${LAMPAC_USER}"
}

# ─── Build rsync excludes ────────────────────────────────────────────────────

build_rsync_excludes() {
  # Пути относительно INSTALL_ROOT, которые rsync никогда не должен трогать.
  local -n _out="$1"
  _out=(
    # Этот скрипт — не удалять его при обновлении
    "$UPDATE_SCRIPT_NAME"

    # Пользовательский конфиг
    "init.conf"
    "init.yaml"
    "init.conf.backup.*"

    # Пользовательские Roslyn-модули
    "mods/"

    # Локальные базы данных (не поставляются релизом)
    "data/kinoukr.json"
    "data/PizdatoeDb.json"

    # SQLite — состояние Sync/SISI/TimeCode
    "*.db"
    "*.db-shm"
    "*.db-wal"

    # Runtime-данные
    "logs/"
    "cache/"

    # TorrServer — бинарь и состояние управляются отдельно
    "TorrServer"
    "torrserver/"
    "data/ts/"

    # Домашняя директория пользователя lampac (Chrome nssdb, сертификаты и т.д.)
    # .playwright/ — НЕ исключаем: браузеры из релиза, должны обновляться вместе с приложением
    ".local/"
    ".aspnet/"
    ".claude/"
    ".config/"

    # Пользовательские данные приложения
    "users.json"
    "passwd"
    "current.conf"
    "database/"

    # Пользовательские файлы и кеш в wwwroot/ (темы, кнопки, lampa-main и т.д.)
    "wwwroot/"

    # Пользовательские плагины и состояние
    "plugins/override/"
    "notifications_date.txt"

    # Пользовательские переопределения сайтов NextHUB и Catalog ({site}.yaml, _.yaml)
    "module/NextHUB/override/"
    "module/Catalog/override/"

    # Файл с пользовательскими дополнительными исключениями
    "excludes.conf"

    # Файл установленной версии (не удалять при обновлении)
    "${VERSION_FILE_NAME}"
  )

  # Дополнительные исключения из excludes.conf (если файл существует)
  local excludes_file="${INSTALL_ROOT}/excludes.conf"
  if [[ -f "$excludes_file" ]]; then
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      _out+=("$line")
    done < "$excludes_file"
  fi
}

# ─── Download / extract ──────────────────────────────────────────────────────

download_and_extract_to_staging() {
  local staging_dir="$1"
  local tmp_zip
  tmp_zip="$(mktemp /tmp/lampac-nextgen.XXXXXX.zip)"
  CLEANUP_PATHS+=("$tmp_zip")

  spinner_start "Downloading release archive..."
  if ! curl -fSL --retry 3 -o "$tmp_zip" "$PUBLISH_URL" 2>/dev/null; then
    spinner_err "Download failed"
    return 1
  fi
  if [[ ! -s "$tmp_zip" ]]; then
    spinner_err "Downloaded file is empty"
    return 1
  fi
  spinner_ok "Archive downloaded"

  run_quiet "Extracting to staging directory" \
    bash -c "unzip -oq '$tmp_zip' -d '$staging_dir' </dev/null"
  rm -f "$tmp_zip"

  # Если архив содержит корневую папку — переносим файлы в корень staging_dir
  local subdirs
  subdirs=$(find "$staging_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)
  if [[ "$subdirs" -eq 1 ]]; then
    local only_subdir
    only_subdir=$(find "$staging_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)
    shopt -s dotglob nullglob
    mv "$only_subdir"/* "$staging_dir"/ 2>/dev/null || true
    shopt -u dotglob nullglob
    rmdir "$only_subdir" 2>/dev/null || true
  fi

  if [[ ! -f "${staging_dir}/Core.dll" ]]; then
    spinner_err "Expected Core.dll not found — check release layout"
    return 1
  fi
  spinner_ok "Archive extracted"
}

install_app() {
  local release_version="$1"

  local staging_dir
  staging_dir="$(mktemp -d /tmp/lampac-install-stage.XXXXXX)"
  CLEANUP_PATHS+=("$staging_dir")

  if ! download_and_extract_to_staging "$staging_dir"; then
    log_err "Install aborted — download or extraction failed."
    exit 1
  fi

  mkdir -p "$INSTALL_ROOT"

  run_quiet "Installing application files to ${INSTALL_ROOT}" \
    bash -c "shopt -s dotglob nullglob; cp -a '${staging_dir}'/* '${INSTALL_ROOT}'/"

  if [[ ! -f "${INSTALL_ROOT}/Core.dll" ]]; then
    log_err "Expected Core.dll not found in ${INSTALL_ROOT} — check release layout"
    exit 1
  fi

  save_installed_version "$release_version"
}

# ─── Update ──────────────────────────────────────────────────────────────────

# Best-effort restart if --update stopped the service and then failed.
_update_restart_service_if_needed() {
  if [[ "${_UPDATE_SERVICE_STOPPED}" -eq 1 ]]; then
    log_warn "Update interrupted — attempting to restart ${SERVICE_NAME}..."
    systemctl start "$SERVICE_NAME" 2>/dev/null || true
    _UPDATE_SERVICE_STOPPED=0
  fi
}

do_update() {
  local new_version="$1"

  if [[ ! -d "$INSTALL_ROOT" ]] || [[ ! -f "${INSTALL_ROOT}/Core.dll" ]]; then
    log_err "Installation not found at ${INSTALL_ROOT} — run without --update first."
    exit 1
  fi

  if ! command -v rsync >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_err "rsync is required for a dry-run update; install rsync and retry."
      return 1
    fi
    run_quiet "Updating package lists" apt-get update
    run_quiet "Installing rsync" \
      env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends rsync
  fi

  if [[ "$DRY_RUN" -ne 1 ]]; then
    ensure_service_user
  fi

  local staging_dir
  staging_dir="$(mktemp -d /tmp/lampac-update-stage.XXXXXX)"
  CLEANUP_PATHS+=("$staging_dir")

  if ! download_and_extract_to_staging "$staging_dir"; then
    log_err "Update aborted — download or extraction failed."
    exit 1
  fi

  # Копируем сам скрипт и excludes.conf в staging, чтобы rsync --delete их не удалил
  [[ -f "${INSTALL_ROOT}/${UPDATE_SCRIPT_NAME}" ]] && \
    cp -a "${INSTALL_ROOT}/${UPDATE_SCRIPT_NAME}" "${staging_dir}/${UPDATE_SCRIPT_NAME}"
  [[ -f "${INSTALL_ROOT}/excludes.conf" ]] && \
    cp -a "${INSTALL_ROOT}/excludes.conf" "${staging_dir}/excludes.conf"

  local -a RSYNC_EXCLUDES=()
  build_rsync_excludes RSYNC_EXCLUDES

  local rsync_exclude_args=()
  for excl in "${RSYNC_EXCLUDES[@]}"; do
    rsync_exclude_args+=(--exclude="$excl")
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '\n  %s┌─ DRY-RUN — no changes will be applied ─────────────────┐%s\n' "$C_YELLOW" "$C_RESET"

    local rsync_output
    rsync_output=$(rsync -a --delete --dry-run --itemize-changes \
      "${rsync_exclude_args[@]}" \
      "${staging_dir}/" \
      "${INSTALL_ROOT}/" \
      2>/dev/null || true)

    local del_files upd_files
    del_files=$(printf '%s' "$rsync_output" | awk '/\*deleting/ && !/\/$/ {sub(/\*deleting +/, ""); print}')
    upd_files=$(printf '%s' "$rsync_output" | grep -v '\*deleting' | grep -v '^$' | grep -v '/$' | grep '^.>' || true)

    printf '\n  %s  Files to be removed:%s\n' "$C_BOLD" "$C_RESET"
    if [[ -n "$del_files" ]]; then
      while IFS= read -r f; do
        log_del "$f"
      done <<< "$del_files"
    else
      log_skip "(nothing to remove)"
    fi

    printf '\n  %s  Files to be added / updated:%s\n' "$C_BOLD" "$C_RESET"
    if [[ -n "$upd_files" ]]; then
      while IFS= read -r f; do
        log_upd "$(printf '%s' "$f" | awk '{sub(/^.[ >][ f]......... /, ""); print}')"
      done <<< "$upd_files"
    else
      log_skip "(no new or changed files)"
    fi

    printf '\n  %s└─ Run without --dry-run to apply changes ───────────────┘%s\n\n' "$C_YELLOW" "$C_RESET"
    return 0
  fi

  # Реальное обновление
  trap '_update_restart_service_if_needed; cleanup' EXIT

  spinner_start "Stopping ${SERVICE_NAME}..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  _UPDATE_SERVICE_STOPPED=1
  spinner_ok "Service stopped"

  if ! rsync -a --delete \
      "${rsync_exclude_args[@]}" \
      "${staging_dir}/" \
      "${INSTALL_ROOT}/"; then
    log_err "Syncing release files (rsync --delete) — failed"
    exit 1
  fi
  log_ok "Syncing release files (rsync --delete)"

  set_install_ownership

  save_installed_version "$new_version"

  spinner_start "Starting ${SERVICE_NAME}..."
  systemctl start "$SERVICE_NAME"
  _UPDATE_SERVICE_STOPPED=0
  spinner_ok "Service started"

  # Restore the global cleanup-only trap from main.
  trap cleanup EXIT
}

# ─── Systemd ─────────────────────────────────────────────────────────────────

install_systemd_unit() {
  cat << EOF > "$SYSTEMD_UNIT_PATH"
[Unit]
Description=Lampac NextGen
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$LAMPAC_USER
Group=$LAMPAC_USER
WorkingDirectory=$INSTALL_ROOT
Environment=DOTNET_ROOT=$DOTNET_INSTALL_DIR
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$DOTNET_INSTALL_DIR
Environment=DOTNET_RUNNING_IN_CONTAINER=false
Environment=DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false
Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1
ExecStart=$DOTNET_INSTALL_DIR/dotnet $INSTALL_ROOT/Core.dll
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SYSTEMD_UNIT_PATH"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  log_ok "systemd unit installed and enabled → ${SYSTEMD_UNIT_PATH}"
}

# ─── Remove ──────────────────────────────────────────────────────────────────

remove_service() {
  if [[ ! -f "$SYSTEMD_UNIT_PATH" ]]; then
    log_skip "Service unit not found — skipping"
    return 0
  fi
  spinner_start "Stopping and disabling ${SERVICE_NAME}..."
  systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SYSTEMD_UNIT_PATH"
  systemctl daemon-reload
  spinner_ok "Service removed"
}

remove_user_and_group() {
  if getent passwd "$LAMPAC_USER" &>/dev/null; then
    spinner_start "Removing user ${LAMPAC_USER}..."
    userdel "$LAMPAC_USER" 2>/dev/null || true
    spinner_ok "User ${LAMPAC_USER} removed"
  fi
  if getent group "$LAMPAC_USER" &>/dev/null; then
    spinner_start "Removing group ${LAMPAC_USER}..."
    groupdel "$LAMPAC_USER" 2>/dev/null || true
    spinner_ok "Group ${LAMPAC_USER} removed"
  fi
}

remove_app() {
  if [[ ! -d "$INSTALL_ROOT" ]]; then
    log_skip "Install directory not found — skipping"
    return 0
  fi
  spinner_start "Removing ${INSTALL_ROOT}..."
  rm -rf "$INSTALL_ROOT"
  spinner_ok "${INSTALL_ROOT} removed"
}

do_remove() {
  local require_confirmation="${1:-0}" answer

  printf '\n  %s⚠  This will permanently delete the Lampac NextGen installation.%s\n' "$C_YELLOW" "$C_RESET"
  printf '  %sDirectory:%s %s\n' "$C_BOLD" "$C_RESET" "$INSTALL_ROOT"
  printf '  %sService:%s   %s\n\n' "$C_BOLD" "$C_RESET" "$SERVICE_NAME"
  if (( require_confirmation )) || [[ "${LAMPAC_CONFIRM_REMOVE:-}" != "1" ]]; then
    if [[ ! -r /dev/tty ]]; then
      log_err "Cannot prompt for confirmation (no TTY). Use an interactive shell, or set LAMPAC_CONFIRM_REMOVE=1 for non-interactive removal."
      exit 1
    fi
    printf '  Type %sREMOVE%s to permanently delete it: ' "$C_BOLD" "$C_RESET"
    if ! read -r answer </dev/tty; then
      printf '\n'
      log_warn "Ввод закрыт (EOF) — удаление отменено."
      return 0
    fi
    if [[ "$answer" != "REMOVE" ]]; then
      log_info "Удаление отменено."
      return 0
    fi
  fi

  remove_service
  remove_app
  remove_user_and_group
  remove_lampac_setup_command

  printf '\n  %s✓  Lampac NextGen has been removed.%s\n\n' "$C_GREEN" "$C_RESET"
}

start_service() {
  spinner_start "Starting ${SERVICE_NAME}..."
  systemctl start "$SERVICE_NAME"
  spinner_ok "Service started"
}

# ─── Post-install ─────────────────────────────────────────────────────────────

print_post_install() {
  local ip config_file
  progress_finish "Lampac NextGen установлен, служба запущена."
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z "$ip" ]] && ip="<your-ip>"

  local url="http://${ip}:${LISTEN_PORT}"
  [[ -n "$LISTEN_PORT" ]] || url="см. ${INSTALL_ROOT}/init.yaml (порт не определён)"
  config_file="${INSTALL_ROOT}/init.conf"
  [[ -e "${INSTALL_ROOT}/init.yaml" ]] && config_file="${INSTALL_ROOT}/init.yaml"

  printf '\n'
  printf '%s  ─── Поздравляем! Установка завершена ───%s\n' "$C_GREEN" "$C_RESET"
  printf '\n'
  printf '  %sConfig%s    %s\n' "$C_CYAN" "$C_RESET" "$config_file"
  printf '  %sService%s   %s\n' "$C_CYAN" "$C_RESET" "systemctl status ${SERVICE_NAME}"
  printf '  %sRestart%s   %s\n' "$C_CYAN" "$C_RESET" "systemctl restart ${SERVICE_NAME}"
  if lampac_setup_command_is_managed; then
    printf '  %sManage%s    %s\n' "$C_CYAN" "$C_RESET" 'lampac setup'
  fi
  printf '  %sLogs%s      %s\n' "$C_CYAN" "$C_RESET" "journalctl -u ${SERVICE_NAME} -f"
  printf '  %sURL%s       %s\n' "$C_CYAN" "$C_RESET" "${url}"
  printf '\n'
}

print_post_update() {
  progress_finish "Lampac NextGen обновлён, служба перезапущена."
  printf '  %s✓  Lampac NextGen обновлён и перезапущен.%s\n' "$C_GREEN" "$C_RESET"
  printf '  %sЛоги:%s journalctl -u %s -f\n\n' "$C_CYAN" "$C_RESET" "$SERVICE_NAME"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

run_selected_operation() {
  OPERATION_SKIPPED=0
  local mode_label="Install" release_version total_steps=4 packages_prepared=0
  [[ "$UPDATE" -eq 1 ]] && mode_label="Update"
  [[ "$DRY_RUN" -eq 1 ]] && mode_label="Dry-run update"
  [[ "$UPDATE" -eq 1 ]] && total_steps=3
  PROGRESS_TOTAL="$total_steps"

  if (( ! MENU_SESSION_ACTIVE )); then
    printf '  %sMode:%s      %s\n'         "$C_BOLD" "$C_RESET" "$mode_label"
    printf '  %sArch:%s      %s\n'         "$C_BOLD" "$C_RESET" "$ARCH"
    printf '  %sDirectory:%s %s\n'         "$C_BOLD" "$C_RESET" "$INSTALL_ROOT"
  fi

  if ! command -v curl >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_err "curl is required for a dry-run update; install curl and retry."
      return 1
    fi
    log_warn "curl отсутствует; сначала выполняется системный этап установки зависимостей."
    step 1 "$total_steps" "Системные зависимости" "Ставлю минимальные пакеты, необходимые для загрузки релиза."
    install_os_packages
    packages_prepared=1
  fi

  resolve_publish_url
  printf '  %sRelease:%s   %s\n'         "$C_BOLD" "$C_RESET" "$PUBLISH_URL"

  if [[ -n "$TARGET_VERSION" ]]; then
    release_version="$(normalize_version "$TARGET_VERSION")"
  else
    release_version="$(get_release_version)"
  fi
  if [[ "$UPDATE" -eq 1 ]] || [[ -d "$INSTALL_ROOT" && -f "${INSTALL_ROOT}/Core.dll" ]]; then
    printf '  %sInstalled Version:%s   %s\n' "$C_BOLD" "$C_RESET" "$(get_installed_version)"
  fi
  printf '  %sRelease Version:%s     %s\n' "$C_GREEN" "$C_RESET" "$release_version"

  confirm_same_version_or_exit "$release_version"
  (( OPERATION_SKIPPED )) && return 0

  # Dry-run update: preview rsync only — skip apt / runtime install.
  if [[ "$DRY_RUN" -eq 1 && "$UPDATE" -eq 1 ]]; then
    do_update "$release_version"
    return 0
  fi

  if (( ! packages_prepared )); then
    step 1 "$total_steps" "Системные зависимости" "Проверяю и устанавливаю нужные пакеты и Google Chrome."
    install_os_packages
  fi

  step 2 "$total_steps" "ASP.NET Core 10" "Проверяю наличие и устанавливаю ASP.NET Core Runtime."
  install_aspnetcore_runtime

  if [[ "$UPDATE" -eq 1 ]]; then
    step 3 "$total_steps" "Обновление приложения" "Загружаю релиз, обновляю файлы и перезапускаю службу."
    do_update "$release_version"
    print_post_update
    if lampac_setup_command_is_managed; then
      install_lampac_setup_command || log_warn "Не удалось обновить launcher lampac setup."
    fi
    return 0
  fi

  step 3 "$total_steps" "Системный пользователь" "Проверяю учётную запись службы Lampac."
  ensure_service_user

  step 4 "$total_steps" "Файлы приложения" "Загружаю и устанавливаю выбранный релиз Lampac NextGen."
  install_app "$release_version"
  if ! initialize_fresh_install_config; then
    log_err "Файлы приложения установлены, но конфигурация не подготовлена; systemd-служба не создавалась."
    return 1
  fi
  if (( MENU_SESSION_ACTIVE )); then
    configure_install_port || log_warn "Порт остался без изменений; продолжение установки."
  fi
  sync_port_from_install_config
  install_lampac_setup_command || log_warn "Не удалось установить команду lampac setup; используйте systemctl напрямую."
  install_systemd_unit
  set_install_ownership
  start_service
  print_post_install
}

main() {
  trap cleanup EXIT
  # Help/version must work without sudo (and before pipe re-exec).
  parse_args "$@"
  require_root "$@"

  if [[ "$(uname -s)" != "Linux" ]]; then
    log_err "This script supports Linux only."
    exit 1
  fi

  ARCH=$(detect_arch)

  if (( INSTALL_SETUP_ONLY == 1 )); then
    run_existing_checks
    if ! lampac_native_update_available; then
      log_err "Не найдена подтверждённая нативная установка Lampac NextGen; команда lampac setup не установлена."
      return 1
    fi
    use_detected_lampac_root
    install_lampac_setup_command || return 1
    log_ok "Команда lampac setup готова к запуску."
    return 0
  fi

  if [[ "$REMOVE" -eq 1 ]]; then
    print_banner
    do_remove
    return 0
  fi

  # ─── Интерактивный запуск ────────────────────────────────────────────────────
  # Обнаружение установок read-only. Для существующего NextGen сразу открываем
  # экран управления; согласие с дисклеймером запрашивается перед обновлением.
  if ! cli_operation_requested; then
    if has_interactive_tty; then
      # Проверка обнаружения read-only, чтобы известную установку сразу
      # открыть в коротком экране управления. Подробный вывод доступен
      # по пункту повторной диагностики.
      run_existing_checks
      if lampac_native_update_available; then
        use_detected_lampac_root
        MENU_CHECKS_READY=1
        run_interactive_menu
        return 0
      fi

      if ! ensure_disclaimer_consent; then
        exit 0
      fi
    else
      # Неинтерактивный запуск: дисклеймер показать нельзя, а неявная установка
      # запрещена. Ничего не ждём и не делаем — только сообщение и выход.
      # Явные CLI-операции (--update, --remove, --tag) в гейт не входят.
      log_err "Нет интерактивного терминала — дисклеймер не показан, установка не запущена."
      log_err "Запустите установщик в терминале или используйте явную CLI-операцию (--update, --remove, --tag)."
      exit 1
    fi

    show_system_info
    show_install_dependency_check
    show_existing_checks
    MENU_CHECKS_READY=1
    run_interactive_menu
    return 0
  fi

  print_banner
  run_selected_operation
}

main "$@"
