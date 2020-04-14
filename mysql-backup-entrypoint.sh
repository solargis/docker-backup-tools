#!/bin/bash

if [ "$1" == '--headless' -a ! -z "$EMAIL_COMFIG" ]; then
  # TODO add support for cron run with email-process-output.js
  fail "Not implemeted yet"
fi

if [ "$1" == '--label' -o "$1" == '--labels' ]; then
  shift
  [ "$1" == '--labels' ] && export _label_outputs=on
  exec label-process-output -l %T "$0" "$@"
fi

. /opt/tools/load-environment

if [ -z "$CONTAINER" -a ! -z "$SERVICE" ]; then
  SERVICE_ID="$(docker service ps "$SERVICE" -qf desired-state=running)" || exit
  SERVICE_NODE="$(docker service ps "$SERVICE" -f desired-state=running --format {{.Node}})" || exit
  CURRENT_NODE="$(docker node ls | awk '$2=="*"{print $3}')" || exit
  CONTAINER="$(docker inspect "$SERVICE_ID" -f {{.Status.ContainerStatus.ContainerID}})" || exit
  [ "$SERVICE_NODE" != "$CURRENT_NODE" ] && export DOCKER_HOST="ssh://$SERVICE_NODE"
fi

[ -z "$CONTAINER" ] && fail "Missing required environment property CONTAINER or SERVICE"

docker exec -i "$CONTAINER" bash -e <<<'
[ ! -e ~/.my.cnf -a ! -z "$MYSQL_ROOT_PASSWORD" ] \
  && cat > ~/.my.cnf <<< "[client]
user=root
password=$MYSQL_ROOT_PASSWORD" \
  && chmod 0400 ~/.my.cnf
[ -e ~/.my.cnf ]
' || fail "Not found and can't create ~/.my.cnf on ${SERVICE:-$CONTAINER}."

source <(docker exec -i "$CONTAINER" bash <<< '
[ -z "$MYSQL_DATABASE" ] || printf "DATABASE='"'"'%s'"'"'\n" "$MYSQL_DATABASE"
[ -z "$REMOTE" ] || printf "export REMOTE='"'"'%s'"'"'\n" "$REMOTE"
[ -z "$REMOTE_PASSWORD" -a -r /run/secrets/remote_password ] && REMOTE_PASSWORD="$(cat /run/secrets/remote_password)"
[ -z "$REMOTE_PASSWORD" ] || printf "export REMOTE_PASSWORD='"'"'%s'"'"'\n" "$REMOTE_PASSWORD"
[ -z "$ENCRYPT_PASS" -a -r /run/secrets/encrypt_pass ] && ENCRYPT_PASS="$(cat /run/secrets/encrypt_pass)"
[ -z "$ENCRYPT_PASS" ] || printf "ENCRYPT_PASS='"'"'%s'"'"'\n" "$ENCRYPT_PASS"
')

[ -z "$REMOTE" -o -z "$REMOTE_PASSWORD" ] \
  && printf -v MSG "%s\nConnection should be stored in env \x1b[33m%s\x1b[0m and password in env \x1b[33m%s\x1b[0m or in \x1b[33m%s\x1b[0m" \
    "Missing remote configuration on target container/service or on this container!" \
    "REMOTE=<user>@<host>/<path>" "REMOTE_PASSWORD" "/run/secrets/remote_password" && fail

[ -z "$DATABASE" ] && fail "Unable to resovle databasse by env MYSQL_DATABASE on ${SERVICE:-$CONTAINER}"

case "$1" in
exec)
  shift; [ $# -eq 0 ] && set -- bash
  exec docker exec -it "$CONTAINER" "$@"
  ;;
status)
  docker exec -t "$CONTAINER" mysql -e "show tables;" "$DATABASE"
  ;;
backup)
  BASENAME="${DATABASE}_$(date +%F_%H-%M).mysql_backup.sql"
  info "Starting logical dump of database \x1b[36m$DATABASE\x1b[0m into file \x1b[36m$BASENAME\x1b[0m" 
  # TODO implement slave status diff (before and after stop)
  lp stop_slave docker exec "$CONTAINER" mysql -e "SHOW SLAVE STATUS\G STOP SLAVE;"
  lp mysqldump -s docker exec "$CONTAINER" mysqldump --complete-insert --routines "$DATABASE" > "/var/cache/backup/$BASENAME" || exit
  # TODO implement slave status diff (before and after start)
  lp start_slave docker exec "$CONTAINER" mysql -e "START SLAVE;"

  RAW_SIZE="$(stat --printf=%s "/var/cache/backup/$BASENAME")"
  printf "Dump size:  \x1b[35m%4s \x1b[36m %s\x1b[0m" \
    "$(ls -lh "/var/cache/backup/$BASENAME" | awk '{print $5}')" \
    "$BASENAME" | info
  
  lp compress xz -z "/var/cache/backup/$BASENAME" && BASENAME="$BASENAME.xz" || exit
  
  RATIO="$(stat --printf=%s "/var/cache/backup/$BASENAME" | awk -v base="$RAW_SIZE" '{print 100 * $1 / base}')"
  printf "Compressed: \x1b[35m%4s \x1b[36m %s \x1b[0m (ratio \x1b[35m%0.2f %%\x1b[0m)" \
    "$(ls -lh "/var/cache/backup/$BASENAME" | awk '{print $5}')" \
    "$BASENAME" "$RATIO" | info

  if [ ! -z "$ENCRYPT_PASS" ]; then
    [ -r "$ENCRYPT_PASS" ] && ENCRYPT_PASS="file:$ENCRYPT_PASS" || ENCRYPT_PASS="pass:$ENCRYPT_PASS"
    # https://wiki.openssl.org/index.php/Enc
    lp encrypt openssl enc -aes-256-cbc -e -pass "$ENCRYPT_PASS" -pbkdf2 -in "/var/cache/backup/$BASENAME" -out "/var/cache/backup/$BASENAME.enc" \
      && rm "/var/cache/backup/$BASENAME" && BASENAME="$BASENAME.enc" || exit

    RATIO="$(stat --printf=%s "/var/cache/backup/$BASENAME" | awk -v base="$RAW_SIZE" '{print 100 * $1 / base}')"
    printf "Encrypted:  \x1b[35m%4s \x1b[36m %s \x1b[0m (ratio \x1b[35m%0.2f %%\x1b[0m)" \
      "$(ls -lh "/var/cache/backup/$BASENAME" | awk '{print $5}')" \
      "$BASENAME" "$RATIO" | info
  fi

  BACKUP_PATH="$(date +%Y/%m-%B)"
  BACKUP_DIR="$MOUNTDIR/$BACKUP_PATH"
  remote || exit
  lp backup_dir mkdir -p "$BACKUP_DIR" \
    && info "Upload backup to \x1b[35m$REMOTE/$BACKUP_PATH/$BASENAME\x1b[0m" \
    && lp upload_backup scp "/var/cache/backup/$BASENAME" "$BACKUP_DIR/" \
    && rm "/var/cache/backup/$BASENAME" \
    && clean-up "$MOUNTDIR"
  remote -u
  info Done.
  ;;
restore)
  fail "TODO Not implemeted yet"
  ;;
*)
  [ -x ~/hooks/entrypoint ] && exec ~/hooks/entrypoint "$@" || exec "$@"
  ;;
esac
