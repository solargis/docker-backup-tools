#!/bin/bash

BACKUPS="/var/opt/gitlab/backups"

lp () { label-process-output -l "$@"; }
fail() { echo -e "\x1b[31;1mError:\x1b[0m" "$@" >&2; exit 1; }

BACKUP_CONTEXT=".backup-context.tar"

version() {
  case "$1" in
  -l|-r)
        CONTAINER="$(docker ps | awk -v name="$2" '$NF==name {print $1}')"
        [ -z "$CONTAINER" ] && fail "Container '$2' was not found!"
        IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")"
        [ "$1" == "-l" ] && echo "$IMAGE" | jq -Rr 'split(":")[1]' && exit 0
        IMG="$(echo "$IMAGE" | jq -Rr 'split(":")[0]')"
        LIST="$(curl -L -s "https://registry.hub.docker.com/v2/repositories/$IMG/tags?page_size=100" | jq -Mcr '.results[] | [.name, .images[0].digest]')"
        echo "$LIST" | jq -Mr --arg hash "$(echo "$LIST" | jq -Mr 'select(.[0]=="latest")[1]')" 'select(.[1]==$hash)[0] | select(test("^\\d+\\.\\d+\\.\\d+-ce\\b"))'
        ;;
  *)
    echo "Usage: $0 version [-l|-r]
      -l  - local version
      -r  - remote version on hub.docker.com";;
  esac
}

prepare-secret() {
  local SECRET="$(cat)"
  [ -f "$1" ] && [ "$(cat "$1")" == "$SECRET" ] || ( touch "$1" && chmod 0600 "$1" && cat > "$1" <<< "$SECRET" )
  [ "$(stat -c '0%a' "$1")" == '0400' ] || chmod 0400 "$1" || exit
  [ "$(cat "$1")" == "$SECRET" ] || fail "Error: Unable to prepare secret file '$1'!"
}

. /opt/tools/load-environment

prepare-secret ~/.ssh/.gitlab-secret <<< "$SECRETS_PASSWORD"

check-success() { local R="0"; while [ "$#" -gt 0 ]; do [ "$1" -gt "$R" ] && R="$1"; shift; done; return "$R"; }

case "$1" in
version)
  version "$2" "${3:-$CONTAINER}"
  ;;
test)
  apt-get update; apt-get install tree;
  for ((i=1;i<=5;i++)); do mkdir -p "test/data/group_$i"; for ((j=1;j<=9;j++)); do touch -d "$i years ago $j days" "test/data/group_$i/file_$j.dat"; done; ls -l "test/data/group_$i"; done;
  ;;
backup)
  CONTAINER_TAG="$("$0" version -l)"
  DOCKER_VERSION="$(docker version -f '{{.Server.Version}}')"
  lp dump-gitlab-config -s docker exec "$CONTAINER" gitlab-ctl show-config \
  | lp select-config-json -s node -e 'console.log(require("fs").readFileSync(0, "utf-8").match(/\n\{\n([\s\S]*)\n\}\n/m)[0].trim())' \
  | lp add-image-tad -s jq --arg imgTag "$CONTAINER_TAG" --arg docVer "$DOCKER_VERSION" 'setpath(["_backup", "docker"]; {imageTag: $imgTag, dockerVersion: $docVer})' \
  > gitlab-config.json
  check-success "${PIPESTATUS[@]}" || exit
  cat gitlab-config.json | lp inspect-version jq -Cc '.docker'

  lp purge-backups-dir rm -vfr "$BACKUPS"/*
  lp backup-gitlab docker exec -t "$CONTAINER" gitlab-backup create || exit
  [ "$(ls -l "$BACKUPS"/* | wc -l)" -ne 1 ] && echo "Error: Undexpected multiptle backup files:\n$(ls -lh "$BACKUPS"/*)" >&2 && exit
  BACKUP_NAME="$(basename "$BACKUPS"/*)"

  lp backup-secrets tar cf "$BACKUP_CONTEXT" -C /etc/gitlab gitlab.rb gitlab-secrets.json \
  && lp backup-config tar rf "$BACKUP_CONTEXT" gitlab-config.json \
  && lp compress-backup-context xz -z "$BACKUP_CONTEXT" \
  && lp encrypt-backup-context openssl enc -aes-256-cbc -e -pass file:/root/.ssh/.gitlab-secret -pbkdf2 -in "$BACKUP_CONTEXT.xz" -out "$BACKUP_CONTEXT.xz.enc" \
  && rm "$BACKUP_CONTEXT.xz" \
  && lp pack-backup tar rf "$BACKUPS/$BACKUP_NAME" "$BACKUP_CONTEXT.xz.enc" \
  && rm "$BACKUP_CONTEXT.xz.enc" || exit

  BACKUP_DIR="$MOUNTDIR/$(date +%Y/%m-%B)"
  remote mount || exit
  [ -d "$BACKUP_DIR" ] || lp mk-backup-dir mkdir -p "$BACKUP_DIR"
  lp push-backup scp "$BACKUPS/$BACKUP_NAME" "$BACKUP_DIR/$BACKUP_NAME" \
  && clean-up "$MOUNTDIR"
  remote umount
  ;;
restore)
  "$0" mount || exit
  lp find-backups -s find /mnt/backups -type f -name '*_gitlab_backup.tar' \
  | lp sort-backups -s xargs -d '\n' ls -t \
  | cat | lp limit-backups -s head -n "${2:-10}" \
  | while read; do
    ( lp extract-backup-context -s tar xOf "$REPLY" "$BACKUP_CONTEXT.xz.enc" \
      | lp decrypt-backup-context -s openssl enc -aes-256-cbc -d -pass file:/root/.ssh/.gitlab-secret -pbkdf2 \
      | lp get-config -s tar xJOf - gitlab-config.json || echo '{}' ) \
    | jq --arg archive "$REPLY" 'setpath(["_backup", "archive"]; $archive)'
  done | jq -s '[.[]|._backup+{gitlabURL:.gitlab["external-url"],pagesURL:.gitlab["pages-external-url"]}]'
  "$0" umount || exit
  ;;
*)
  [ -x ~/hooks/entrypoint ] && exec ~/hooks/entrypoint "$@" || exec "$@"
  ;;
esac
