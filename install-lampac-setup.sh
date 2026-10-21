#!/usr/bin/env bash
# Lampac NextGen setup command (managed by installer)
# Standalone installer and manager. This file does not load or download install.sh.
set -uo pipefail

readonly SERVICE_NAME='lampac.service'
readonly COMMAND_PATH='/usr/local/bin/lampac'
readonly UPSTREAM_REPOSITORY='lampac-nextgen/lampac'
readonly APP_ARCHIVE='lampac-nextgen.zip'
readonly SETUP_VERSION='1.1.0'
SELECTED_TAG=''
UPDATE_STAGE=''
UPDATE_STOPPED=0
UPDATE_SNAPSHOT=''
UPDATE_SNAPSHOT_COMPLETE=0
BACKUP_ARCHIVE=''
BACKUP_COMPLETE=0
BACKUP_STOPPED=0
BACKUP_LIST_FILE=''

error() { printf 'Ошибка: %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*"; }

service_root() {
  local root fragment description exec_start
  root="$(systemctl show "$SERVICE_NAME" -p WorkingDirectory --value 2>/dev/null)" || return 1
  fragment="$(systemctl show "$SERVICE_NAME" -p FragmentPath --value 2>/dev/null)" || return 1
  description="$(systemctl show "$SERVICE_NAME" -p Description --value 2>/dev/null)" || return 1
  exec_start="$(systemctl show "$SERVICE_NAME" -p ExecStart --value 2>/dev/null)" || return 1
  [[ "$fragment" == "/etc/systemd/system/$SERVICE_NAME" && -f "$fragment" && ! -L "$fragment" ]] || return 1
  [[ "$description" == 'Lampac NextGen' ]] || return 1
  [[ "$root" == /* && "$root" != / && -d "$root" && -f "$root/Core.dll" ]] || return 1
  [[ "$root" == /opt/* || "$root" == /*/*/* ]] || return 1
  [[ "$(readlink -f -- "$root" 2>/dev/null)" == "$root" ]] || return 1
  [[ "$exec_start" == *" $root/Core.dll"* ]] || return 1
  case "$root" in /bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 1 ;; esac
  printf '%s\n' "$root"
}

require_tools() {
  local tool missing=0
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then error "Не найдена зависимость $tool."; missing=1; fi
  done
  (( missing == 0 ))
}

confirm_token() {
  local token="$1" prompt="$2" answer
  [[ -r /dev/tty ]] || { error 'Для подтверждения требуется интерактивный терминал; действие отменено.'; return 1; }
  printf '  %s Введите %s для подтверждения (иначе отмена): ' "$prompt" "$token"
  IFS= read -r answer </dev/tty || { printf '\n'; return 1; }
  [[ "$answer" == "$token" ]]
}

run_admin() {
  if (( EUID == 0 )); then
    "$COMMAND_PATH" setup "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$COMMAND_PATH" setup "$@"
  else
    error 'Для этого действия нужны права администратора (sudo не найден).'
    return 1
  fi
}

release_version_is_current() {
  local latest="${1#v}" installed="${2#v}"
  latest="${latest#"${latest%%[![:space:]]*}"}"
  latest="${latest%"${latest##*[![:space:]]}"}"
  installed="${installed#"${installed%%[![:space:]]*}"}"
  installed="${installed%"${installed##*[![:space:]]}"}"
  [[ -n "$installed" && "$installed" != N/A && "$latest" == "$installed" ]]
}

latest_release_tag() {
  local json tag
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${UPSTREAM_REPOSITORY}/releases/latest")" \
    || { error 'Не удалось получить последний релиз GitHub.'; return 1; }
  tag="$(printf '%s' "$json" | jq -er '.tag_name | select(type == "string")')" || return 1
  [[ "$tag" =~ ^v?[0-9]+([._+-][A-Za-z0-9.-]+|\.[0-9]+)*$ ]] || { error 'GitHub вернул некорректный тег релиза.'; return 1; }
  printf '%s\n' "$tag"
}

version_tag_is_older() {
  local candidate="${1#v}" current="${2#v}" first
  [[ "$candidate" != "$current" ]] || return 1
  first="$(printf '%s\n%s\n' "$candidate" "$current" | sort -V | head -n1)"
  [[ "$first" == "$candidate" ]]
}

show_progress() {
  local completed="$1" phase="$2" status="$3" width=24 filled percent i
  filled=$(( completed * width / 4 )); percent=$(( completed * 25 ))
  printf '\n  Прогресс: ['
  for ((i = 0; i < width; i++)); do
    if (( i < filled )); then printf '#'; else printf '-'; fi
  done
  printf '] %3d%%\n  Этап:   %s\n  Сейчас: %s\n\n' "$percent" "$phase" "$status"
}

setup_cleanup() {
  if (( UPDATE_STOPPED || BACKUP_STOPPED )); then systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true; UPDATE_STOPPED=0; BACKUP_STOPPED=0; fi
  if [[ -n "$UPDATE_STAGE" ]]; then rm -rf -- "$UPDATE_STAGE"; UPDATE_STAGE=''; fi
  if (( ! UPDATE_SNAPSHOT_COMPLETE )) && [[ -n "$UPDATE_SNAPSHOT" ]]; then rm -f -- "$UPDATE_SNAPSHOT"; UPDATE_SNAPSHOT=''; fi
  if (( ! BACKUP_COMPLETE )) && [[ -n "$BACKUP_ARCHIVE" ]]; then rm -f -- "$BACKUP_ARCHIVE"; BACKUP_ARCHIVE=''; fi
  if [[ -n "$BACKUP_LIST_FILE" ]]; then rm -f -- "$BACKUP_LIST_FILE"; BACKUP_LIST_FILE=''; fi
}

create_installation_snapshot() {
  local root="$1" purpose="$2" backup_dir timestamp
  backup_dir='/var/backups/lampac-nextgen'
  install -d -o root -g root -m 700 "$backup_dir" || { error 'Не удалось создать защищённый каталог резервных копий.'; return 1; }
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  UPDATE_SNAPSHOT="$(mktemp --suffix=.tar.gz "$backup_dir/lampac-${purpose}-${timestamp}.XXXXXX")" || return 1
  if ! tar --xattrs -czf "$UPDATE_SNAPSHOT" -C "$root" . || [[ ! -s "$UPDATE_SNAPSHOT" ]]; then
    rm -f -- "$UPDATE_SNAPSHOT"
    UPDATE_SNAPSHOT=''
    error 'Не удалось создать полный снимок установки; операция не начата.'
    return 1
  fi
  chmod 600 "$UPDATE_SNAPSHOT" || { rm -f -- "$UPDATE_SNAPSHOT"; UPDATE_SNAPSHOT=''; return 1; }
  UPDATE_SNAPSHOT_COMPLETE=1
  info "Создан снимок для восстановления: $UPDATE_SNAPSHOT"
}

restore_installation_snapshot() {
  local root="$1" snapshot="$2"
  [[ -n "$snapshot" && -s "$snapshot" ]] || return 1
  mkdir -p -- "$root" || return 1
  find "$root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || return 1
  tar --xattrs -xzf "$snapshot" -C "$root"
}

restore_after_update_failure() {
  local root="$1" snapshot="$2"
  error 'Обновление не завершилось; восстанавливаю предыдущую установку.'
  if restore_installation_snapshot "$root" "$snapshot"; then
    if systemctl start "$SERVICE_NAME"; then
      UPDATE_STOPPED=0
      error 'Предыдущая версия восстановлена и служба запущена.'
    else
      error 'Предыдущая версия восстановлена, но службу не удалось запустить автоматически.'
    fi
  else
    error "Автоматическое восстановление не удалось. Снимок сохранён: $snapshot"
  fi
}

abort_update() {
  local root="$1" snapshot="$2"
  trap '' HUP INT TERM
  if [[ -n "$snapshot" && -s "$snapshot" ]]; then restore_after_update_failure "$root" "$snapshot"; fi
  setup_cleanup
  exit 143
}

abort_remove() {
  local root="$1" snapshot="$2" unit_backup="$3" was_enabled="$4" was_active="$5"
  trap '' HUP INT TERM
  error 'Удаление прервано; восстанавливаю установку и службу.'
  if restore_installation_snapshot "$root" "$snapshot" && restore_service_unit "$unit_backup" "$was_enabled" "$was_active"; then
    rm -f -- "$unit_backup"
    error 'Установка и unit-файл восстановлены.'
  else
    error "Автоматическое восстановление не удалось. Снимки сохранены: $snapshot и $unit_backup"
  fi
  exit 143
}

update_release() {
  local tag="$1" root current user group stage archive snapshot mode
  local -a excludes=()
  [[ "$tag" =~ ^v?[0-9]+([._+-][A-Za-z0-9.-]+|\.[0-9]+)*$ ]] || { error 'Некорректный тег релиза.'; return 1; }
  root="$(service_root)" || { error 'Не удалось определить безопасный каталог Lampac.'; return 1; }
  current='N/A'; [[ ! -r "$root/version.txt" ]] || current="$(<"$root/version.txt")"
  if release_version_is_current "$tag" "$current"; then
    info "Lampac NextGen уже обновлён до версии ${tag#v}; обновление не требуется."
    return 0
  fi
  require_tools curl jq unzip rsync tar find install date mktemp || return 1
  user="$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null)"
  group="$(systemctl show "$SERVICE_NAME" -p Group --value 2>/dev/null)"
  [[ -n "$user" ]] || user=lampac
  [[ -n "$group" ]] || group="$user"
  getent passwd "$user" >/dev/null && getent group "$group" >/dev/null \
    || { error 'Не удалось определить учётную запись службы; обновление не начато.'; return 1; }

  stage="$(mktemp -d /tmp/lampac-setup-update.XXXXXX)" || return 1
  UPDATE_STAGE="$stage"
  UPDATE_STOPPED=0
  UPDATE_SNAPSHOT=''
  UPDATE_SNAPSHOT_COMPLETE=0
  trap setup_cleanup EXIT
  archive="$stage/$APP_ARCHIVE"
  show_progress 1 'Загрузка релиза' "Загружаю $tag из ${UPSTREAM_REPOSITORY}."
  curl -fSL --retry 3 -o "$archive" "https://github.com/${UPSTREAM_REPOSITORY}/releases/download/${tag}/${APP_ARCHIVE}" \
    || { error 'Загрузка релиза не удалась.'; return 1; }
  [[ -s "$archive" ]] || { error 'Архив релиза пуст.'; return 1; }
  show_progress 2 'Подготовка файлов' 'Проверяю архив и распаковываю во временный каталог.'
  unzip -tq "$archive" >/dev/null || { error 'Архив релиза повреждён.'; return 1; }
  mkdir "$stage/app" && unzip -oq "$archive" -d "$stage/app" || return 1
  local -a dirs=()
  mapfile -t dirs < <(find "$stage/app" -mindepth 1 -maxdepth 1 -type d)
  if (( ${#dirs[@]} == 1 )) && [[ ! -f "$stage/app/Core.dll" ]]; then
    shopt -s dotglob nullglob
    mv "${dirs[0]}"/* "$stage/app/"
    shopt -u dotglob nullglob
    rmdir "${dirs[0]}" 2>/dev/null || true
  fi
  [[ -f "$stage/app/Core.dll" ]] || { error 'В архиве отсутствует Core.dll.'; return 1; }
  excludes=(--exclude=install.sh --exclude=init.conf --exclude=init.yaml --exclude='init.conf.backup.*' --exclude=mods/ --exclude=data/kinoukr.json --exclude=data/PizdatoeDb.json --exclude='*.db' --exclude='*.db-shm' --exclude='*.db-wal' --exclude=logs/ --exclude=cache/ --exclude=TorrServer --exclude=torrserver/ --exclude=data/ts/ --exclude=.local/ --exclude=.aspnet/ --exclude=.claude/ --exclude=.config/ --exclude=users.json --exclude=passwd --exclude=current.conf --exclude=database/ --exclude=wwwroot/ --exclude=plugins/override/ --exclude=notifications_date.txt --exclude=module/NextHUB/override/ --exclude=module/Catalog/override/ --exclude=excludes.conf --exclude=version.txt)
  if [[ -f "$root/excludes.conf" ]]; then
    mode="$(stat -c '%a' "$root/excludes.conf" 2>/dev/null)"
    [[ "$(stat -c '%U:%G' "$root/excludes.conf" 2>/dev/null)" == root:root && "$mode" =~ ^[0-7]{3,4}$ ]] \
      && (( (8#$mode & 0022) == 0 )) \
      || { error 'excludes.conf должен принадлежать root:root и быть недоступен для записи группе и остальным.'; return 1; }
    while IFS= read -r name || [[ -n "$name" ]]; do
      name="${name%$'\r'}"
      [[ -z "$name" || "$name" == \#* ]] || excludes+=(--exclude="$name")
    done < "$root/excludes.conf"
  fi

  show_progress 3 'Обновление приложения' "Останавливаю $SERVICE_NAME и обновляю $root."
  systemctl stop "$SERVICE_NAME" || { error 'Не удалось остановить службу; файлы не изменены.'; return 1; }
  UPDATE_STOPPED=1
  create_installation_snapshot "$root" update || return 1
  snapshot="$UPDATE_SNAPSHOT"
  trap 'abort_update "$root" "$snapshot"' HUP INT TERM
  if ! rsync -a --delete "${excludes[@]}" "$stage/app/" "$root/"; then
    restore_after_update_failure "$root" "$snapshot"
    trap - HUP INT TERM
    return 1
  fi
  if ! printf '%s\n' "${tag#v}" > "$root/version.txt" || ! chown -R "$user:$group" "$root"; then
    restore_after_update_failure "$root" "$snapshot"
    trap - HUP INT TERM
    return 1
  fi
  show_progress 4 'Запуск службы' "Запускаю $SERVICE_NAME с версией $tag."
  if ! systemctl start "$SERVICE_NAME"; then
    restore_after_update_failure "$root" "$snapshot"
    trap - HUP INT TERM
    return 1
  fi
  UPDATE_STOPPED=0
  trap - HUP INT TERM
  trap - EXIT
  setup_cleanup
  info "Готово: Lampac NextGen $tag обновлён. Снимок для ручного отката: $snapshot"
}

backup_user_data() {
  local root backup_dir timestamp item path was_active=0
  local -a data_paths=(init.conf init.yaml users.json passwd current.conf excludes.conf notifications_date.txt 'init.conf.backup.*' mods data database wwwroot plugins/override module/NextHUB/override module/Catalog/override .local .aspnet .config)
  require_tools tar mktemp install date || return 1
  root="$(service_root)" || { error 'Не удалось определить безопасный каталог Lampac.'; return 1; }
  backup_dir='/var/backups/lampac-nextgen'
  printf '\n  Будут сохранены конфигурация, аккаунты и постоянные данные из %s.\n' "$root"
  printf '  Архив будет содержать секреты (например passwd) и доступен только root: %s\n' "$backup_dir"
  if [[ "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" == active ]]; then
    was_active=1
    printf '  Для согласованной копии служба будет временно остановлена и затем запущена снова.\n'
  fi
  confirm_token BACKUP 'Введите BACKUP' || { info 'Резервное копирование отменено.'; return 1; }
  install -d -o root -g root -m 700 "$backup_dir" || { error 'Не удалось создать защищённый каталог резервных копий.'; return 1; }
  BACKUP_LIST_FILE="$(mktemp /tmp/lampac-setup-backup-list.XXXXXX)" || return 1
  trap setup_cleanup EXIT
  BACKUP_COMPLETE=0
  BACKUP_STOPPED=0
  for item in "${data_paths[@]}"; do
    if [[ "$item" == init.conf.backup.* ]]; then
      for path in "$root"/init.conf.backup.*; do [[ -e "$path" ]] && printf '%s\0' "${path#"$root"/}" >> "$BACKUP_LIST_FILE"; done
    elif [[ -e "$root/$item" || -L "$root/$item" ]]; then
      printf '%s\0' "$item" >> "$BACKUP_LIST_FILE"
    fi
  done
  local -a root_databases=("$root"/*.db "$root"/*.db-shm "$root"/*.db-wal)
  for path in "${root_databases[@]}"; do [[ -f "$path" ]] && printf '%s\0' "${path#"$root"/}" >> "$BACKUP_LIST_FILE"; done
  if [[ ! -s "$BACKUP_LIST_FILE" ]]; then setup_cleanup; trap - EXIT; error 'Пользовательские данные для резервного копирования не найдены.'; return 1; fi
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_ARCHIVE="$(mktemp --suffix=.tar.gz "$backup_dir/lampac-data-${timestamp}.XXXXXX")" || { setup_cleanup; trap - EXIT; return 1; }
  if (( was_active )); then
    BACKUP_STOPPED=1
    if ! systemctl stop "$SERVICE_NAME"; then
      setup_cleanup
      trap - EXIT
      error 'Не удалось остановить службу; резервная копия не создана.'
      return 1
    fi
  fi
  if ! tar -czf "$BACKUP_ARCHIVE" -C "$root" --null --files-from="$BACKUP_LIST_FILE" || [[ ! -s "$BACKUP_ARCHIVE" ]]; then
    setup_cleanup
    trap - EXIT
    error 'Не удалось создать архив пользовательских данных.'
    return 1
  fi
  chmod 600 "$BACKUP_ARCHIVE" || { setup_cleanup; trap - EXIT; error 'Не удалось защитить архив; незавершённая копия удалена.'; return 1; }
  BACKUP_COMPLETE=1
  setup_cleanup
  trap - EXIT
  info "Резервная копия создана: $BACKUP_ARCHIVE"
  if (( was_active )) && [[ "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" != active ]]; then
    error "Архив сохранён, но службу не удалось запустить автоматически: systemctl start $SERVICE_NAME"
    return 1
  fi
}

select_rollback_tag() {
  local current="$1" json tag number answer i
  local -a tags=() choices=()
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${UPSTREAM_REPOSITORY}/releases?per_page=100")" \
    || { error 'Не удалось получить список релизов GitHub.'; return 1; }
  mapfile -t tags < <(printf '%s' "$json" | jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name')
  for tag in "${tags[@]}"; do
    [[ "$tag" =~ ^v?[0-9]+([._+-][A-Za-z0-9.-]+|\.[0-9]+)*$ ]] || continue
    if version_tag_is_older "$tag" "$current"; then choices+=("$tag"); (( ${#choices[@]} >= 10 )) && break; fi
  done
  (( ${#choices[@]} > 0 )) || { error "Нет более ранних релизов; установлена версия $current."; return 1; }
  printf '\n  ─── Выберите версию для отката ───\n\n'
  for ((i = 0; i < ${#choices[@]}; i++)); do printf '    %d) %s\n' "$((i + 1))" "${choices[$i]}"; done
  printf '    0) Назад\n\n'
  while true; do
    printf '  Номер версии: '
    IFS= read -r answer </dev/tty || { printf '\n'; return 1; }
    case "$answer" in
      0) return 1 ;;
      ''|*[!0-9]*) error 'Введите номер из списка или 0.' ;;
      *) (( ${#answer} <= 3 )) || { error 'Слишком длинный ввод.'; continue; }
         number=$((10#$answer)); (( number >= 1 && number <= ${#choices[@]} )) || { error 'Такого номера нет.'; continue; }
         SELECTED_TAG="${choices[$((number - 1))]}"; return 0 ;;
    esac
  done
}

restore_service_unit() {
  local backup="$1" was_enabled="$2" was_active="$3" unit="/etc/systemd/system/$SERVICE_NAME"
  cp -a -- "$backup" "$unit" || return 1
  systemctl daemon-reload || return 1
  case "$was_enabled" in
    enabled) systemctl enable "$SERVICE_NAME" >/dev/null || return 1 ;;
    enabled-runtime) systemctl enable --runtime "$SERVICE_NAME" >/dev/null || return 1 ;;
  esac
  if (( was_active )); then systemctl start "$SERVICE_NAME" || return 1; fi
}

remove_installation() {
  local root unit="/etc/systemd/system/$SERVICE_NAME" unit_backup snapshot was_enabled was_active=0
  root="$(service_root)" || { error 'Не удалось определить безопасный каталог Lampac.'; return 1; }
  printf '\n  Будут остановлена служба %s и удалены каталог %s и команда %s. Учётная запись службы останется.\n' "$SERVICE_NAME" "$root" "$COMMAND_PATH"
  confirm_token REMOVE 'Введите REMOVE' || { info 'Удаление отменено.'; return 1; }
  confirm_token "$root" 'Введите полный путь каталога для подтверждения' || { info 'Удаление отменено.'; return 1; }
  [[ "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" != active ]] || was_active=1
  was_enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
  require_tools tar find install date mktemp || return 1
  unit_backup="$(mktemp /tmp/lampac-setup-unit.XXXXXX)" || return 1
  if ! cp -a -- "$unit" "$unit_backup"; then rm -f -- "$unit_backup"; error 'Не удалось сохранить резервную копию unit-файла; удаление отменено.'; return 1; fi
  UPDATE_SNAPSHOT=''
  UPDATE_SNAPSHOT_COMPLETE=0
  if ! create_installation_snapshot "$root" remove; then rm -f -- "$unit_backup"; return 1; fi
  snapshot="$UPDATE_SNAPSHOT"
  if ! systemctl stop "$SERVICE_NAME"; then rm -f -- "$unit_backup"; error 'Не удалось остановить службу; удаление отменено.'; return 1; fi
  trap 'abort_remove "$root" "$snapshot" "$unit_backup" "$was_enabled" "$was_active"' HUP INT TERM
  if ! systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || ! rm -f -- "$unit" || ! systemctl daemon-reload; then
    if restore_service_unit "$unit_backup" "$was_enabled" "$was_active"; then
      rm -f -- "$unit_backup"
      error 'Удаление отменено: systemd не принял изменение. Unit-файл и прежнее состояние службы восстановлены.'
    else
      error "Удаление прервано, автоматическое восстановление не удалось. Резервная копия unit сохранена: $unit_backup"
    fi
    trap - HUP INT TERM
    return 1
  fi
  if ! rm -rf -- "$root"; then
    if restore_installation_snapshot "$root" "$snapshot" && restore_service_unit "$unit_backup" "$was_enabled" "$was_active"; then
      rm -f -- "$unit_backup"
      error 'Удаление прервано: установка и unit-файл восстановлены из снимка.'
    else
      error "Удаление прервано, автоматическое восстановление не удалось. Снимки сохранены: $snapshot и $unit_backup"
    fi
    trap - HUP INT TERM
    return 1
  fi
  rm -f -- "$unit_backup"
  trap - HUP INT TERM
  if [[ -f "$COMMAND_PATH" ]] && grep -Fq '# Lampac NextGen setup command (managed by installer)' "$COMMAND_PATH"; then rm -f -- "$COMMAND_PATH"; fi
  info "Lampac NextGen удалён. Снимок удалённой установки: $snapshot"
}

service_action() {
  local action="$1"
  if (( EUID == 0 )); then systemctl "$action" "$SERVICE_NAME"
  elif command -v sudo >/dev/null 2>&1; then sudo systemctl "$action" "$SERVICE_NAME"
  else error 'Для управления службой нужны права администратора (sudo).'; return 1; fi
}

show_recent_logs() {
  if (( EUID == 0 )); then journalctl -u "$SERVICE_NAME" -n 50 --no-pager
  elif command -v sudo >/dev/null 2>&1; then sudo journalctl -u "$SERVICE_NAME" -n 50 --no-pager
  else error 'Для чтения журнала нужны права администратора (sudo).'; return 1; fi
}

setup_action() {
  local action="${1:-}" root current tag
  case "$action" in
    --update)
      (( $# == 1 )) || { error 'Лишние параметры обновления.'; return 2; }
      require_tools curl jq || return 1
      tag="$(latest_release_tag)" || return 1
      root="$(service_root)" || { error 'Не найдена подтверждённая установка Lampac.'; return 1; }
      current='N/A'; [[ ! -r "$root/version.txt" ]] || current="$(<"$root/version.txt")"
      if release_version_is_current "$tag" "$current"; then info "Lampac NextGen уже обновлён до версии ${tag#v}; обновление не требуется."; return 0; fi
      confirm_token UPDATE "Обновление до $tag" || { info 'Обновление отменено.'; return 1; }
      update_release "$tag" ;;
    --rollback)
      (( $# == 1 )) || { error 'Лишние параметры отката.'; return 2; }
      require_tools curl jq || return 1
      root="$(service_root)" || { error 'Не найдена подтверждённая установка Lampac.'; return 1; }
      current='N/A'; [[ ! -r "$root/version.txt" ]] || current="$(<"$root/version.txt")"
      [[ "$current" != N/A ]] || { error 'Текущая версия неизвестна; откат невозможен.'; return 1; }
      [[ "$current" =~ ^v?[0-9]+([._+-][A-Za-z0-9.-]+|\.[0-9]+)*$ ]] \
        || { error 'Записана некорректная текущая версия; откат остановлен.'; return 1; }
      select_rollback_tag "$current" || return 1
      tag="$SELECTED_TAG"
      confirm_token ROLLBACK "Откат ${current} → ${tag}" || { info 'Откат отменён.'; return 1; }
      update_release "$tag" ;;
    --backup)
      (( $# == 1 )) || { error 'Лишние параметры резервного копирования.'; return 2; }
      backup_user_data ;;
    --remove) (( $# == 1 )) || { error 'Лишние параметры удаления.'; return 2; }; remove_installation ;;
    *) error 'Неизвестное действие setup.'; return 2 ;;
  esac
}

setup_menu() {
  local answer state root port ip url version config_file
  [[ -t 0 && -t 1 ]] || { error 'lampac setup предназначен для интерактивного терминала.'; return 2; }
  trap 'printf "\nВыход по Ctrl+C. Уже начатую операцию отменить безопасно не всегда возможно.\n"; exit 130' INT
  while true; do
    root="$(service_root)" || root=/opt/lampac
    config_file="$root/init.conf"; [[ ! -e "$root/init.yaml" ]] || config_file="$root/init.yaml"
    state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    case "$state" in active) state='работает' ;; inactive) state='остановлена' ;; failed) state='ошибка' ;; *) state='неизвестно' ;; esac
    version='N/A'; [[ ! -r "$root/version.txt" ]] || { version="$(<"$root/version.txt")"; [[ -n "$version" ]] || version=N/A; }
    port=9118
    if [[ -e "$root/init.yaml" ]]; then port=''
    elif command -v jq >/dev/null 2>&1 && [[ -r "$root/init.conf" ]]; then port="$(jq -r '.listen.port // 9118' "$root/init.conf" 2>/dev/null || printf 9118)"; [[ "$port" =~ ^[0-9]{1,5}$ ]] || port=9118; fi
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; [[ -n "$ip" ]] || ip='<IP-сервера>'
    if [[ -n "$port" ]]; then url="http://${ip}:${port}"; else url='см. init.yaml (порт не определён)'; fi
    printf '\n  ██╗      █████╗ ███╗   ███╗██████╗  █████╗  ██████╗\n'
    printf '  ██║     ██╔══██╗████╗ ████║██╔══██╗██╔══██╗██╔════╝\n'
    printf '  ██║     ███████║██╔████╔██║██████╔╝███████║██║\n'
    printf '  ██║     ██╔══██║██║╚██╔╝██║██╔═══╝ ██╔══██║██║\n'
    printf '  ███████╗██║  ██║██║ ╚═╝ ██║██║     ██║  ██║╚██████╗\n'
    printf '  ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝     ╚═╝  ╚═╝ ╚═════╝\n'
    printf '                                          NextGen\n\n'
    printf '  Installed Version: %s\n  Setup Manager:     %s\n\n' "$version" "$SETUP_VERSION"
    printf '  ─── Lampac NextGen: меню управления службой ───\n\n'
    printf '  Каталог: %s\n  Состояние: %s\n  Config    %s\n' "$root" "$state" "$config_file"
    printf '  Service   systemctl status %s\n  Restart   systemctl restart %s\n  Logs      journalctl -u %s -f\n  URL       %s\n\n' "$SERVICE_NAME" "$SERVICE_NAME" "$SERVICE_NAME" "$url"
    printf '    1) Перезапустить Lampac\n'
    if [[ "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" == active ]]; then printf '    2) Остановить Lampac\n'; else printf '    2) Запустить Lampac\n'; fi
    printf '    3) Обновить до последней версии\n    4) Откатиться на более ранний релиз\n    5) Удалить Lampac NextGen\n    6) Показать последние 50 строк логов\n    7) Создать резервную копию пользовательских данных\n    0) Выйти\n\n  Выберите пункт: '
    if ! IFS= read -r answer; then printf '\n'; return 0; fi
    if (( ${#answer} > 16 )); then error 'Слишком длинный ввод.'; continue; fi
    case "$answer" in
      1) service_action restart || error 'Не удалось перезапустить службу.' ;;
      2) if [[ "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" == active ]]; then service_action stop || error 'Не удалось остановить службу.'; else service_action start || error 'Не удалось запустить службу.'; fi ;;
      3) run_admin --update || true ;;
      4) run_admin --rollback || true ;;
      5) run_admin --remove || true; [[ ! -f "$root/Core.dll" ]] && return 0 ;;
      6) show_recent_logs || error 'Не удалось прочитать журнал службы.' ;;
      7) run_admin --backup || true ;;
      0) return 0 ;;
      '') error 'Пустой ввод: выберите пункт от 1 до 7 или 0.' ;;
      *) error 'Неизвестный пункт: выберите пункт от 1 до 7 или 0.' ;;
    esac
  done
}

install_setup_command() {
  local source_path target="$COMMAND_PATH" temporary
  [[ "$(uname -s)" == Linux ]] || { error 'Установщик поддерживает только Linux.'; return 1; }
  command -v systemctl >/dev/null 2>&1 || { error 'systemd не найден.'; return 1; }
  source_path="$(readlink -f -- "${BASH_SOURCE[0]}")" || { error 'Не удалось определить файл установщика.'; return 1; }
  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || { error 'Для установки нужны права root или sudo.'; return 1; }
    exec sudo bash "$source_path"
  fi
  service_root >/dev/null || { error 'Не найдена подтверждённая нативная установка Lampac NextGen с lampac.service.'; return 1; }
  if { [[ -e "$target" ]] || [[ -L "$target" ]]; } \
    && { [[ -L "$target" ]] || ! grep -Fq '# Lampac NextGen setup command (managed by installer)' "$target"; }; then
    error "$target уже существует и не принадлежит установщику; файл не изменён."
    return 1
  fi
  install -d -o root -g root -m 755 /usr/local/bin || return 1
  temporary="$(mktemp /usr/local/bin/.lampac.XXXXXX)" || return 1
  if ! install -o root -g root -m 755 "$source_path" "$temporary" || ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    error 'Не удалось установить команду /usr/local/bin/lampac.'
    return 1
  fi
  printf 'Готово. Запустите: lampac setup\n'
}

case "${1:-}" in
  setup)
    shift
    if (( $# == 0 )); then setup_menu; exit $?; fi
    if (( EUID != 0 )); then
      command -v sudo >/dev/null 2>&1 || { error 'Для этого действия нужны права root или sudo.'; exit 1; }
      exec sudo "$COMMAND_PATH" setup "$@"
    fi
    setup_action "$@"
    exit $? ;;
  '')
    (( $# == 0 )) || { error 'Использование: bash install-lampac-setup.sh'; exit 2; }
    if [[ "$(readlink -f -- "$0" 2>/dev/null)" == "$COMMAND_PATH" ]]; then error 'Использование: lampac setup'; exit 2; fi
    install_setup_command
    exit $? ;;
  *) error 'Использование: bash install-lampac-setup.sh'; exit 2 ;;
esac
