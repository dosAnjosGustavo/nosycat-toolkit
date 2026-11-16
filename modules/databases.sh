#!/usr/bin/env bash
# modules/databases.sh - databases and caches reachable from outside the box.
# shellcheck shell=bash

# port:name:process-regex
_DB_PORTS="3306:mysql/mariadb:mysqld|mariadbd
5432:postgresql:postgres
6379:redis:redis-server|valkey
27017:mongodb:mongod
11211:memcached:memcached
9200:elasticsearch:elasticsearch|opensearch
9300:elasticsearch-transport:-
5984:couchdb:couchdb
8086:influxdb:influxd"

mod_databases() {
  if ! collect_listeners; then
    skip DB-001 "database exposure" "neither ss nor netstat available"
    return 0
  fi
  local entry dport dname dre l proto host port proc scope seen=0
  local pub=() priv=() lo=()
  while IFS=: read -r dport dname dre; do
    [ -z "$dport" ] && continue
    local worst=""
    for l in "${LISTENERS[@]}"; do
      read -r proto host port proc <<<"$l"
      [ "$proto" = "tcp" ] || continue
      if [ "$port" != "$dport" ]; then
        # non-default port, matched by process name (root only)
        if [ "$proc" = "-" ] || ! printf '%s' "$proc" | grep -qE "^($dre)$"; then continue; fi
      fi
      scope="$(addr_scope "$host")"
      case "$scope" in
        any|public) worst="public:$host:$port" ;;
        private) [ "${worst%%:*}" = "public" ] || worst="private:$host:$port" ;;
        loopback) [ -z "$worst" ] && worst="loopback:$host:$port" ;;
      esac
    done
    [ -z "$worst" ] && continue
    seen=1
    entry="$dname on ${worst#*:}"
    case "${worst%%:*}" in
      public) pub+=("$entry") ;; private) priv+=("$entry") ;; *) lo+=("$entry") ;;
    esac
  done <<<"$_DB_PORTS"

  if [ "${#pub[@]}" -gt 0 ]; then
    fail DB-001 "database/cache listening on public interfaces: $(join ', ' "${pub[@]}")" "exposed Redis, MongoDB, Elasticsearch and MySQL are scanned and ransomed within hours" "bind to 127.0.0.1 (bind-address / listen_addresses / bind / net.bindIp) and firewall the port"
  elif [ "${#priv[@]}" -gt 0 ]; then
    warn DB-001 "database/cache on a private network address: $(join ', ' "${priv[@]}")" "reachable by every machine on the provider's private network/VPC" "restrict with the firewall to the app servers that need it"
  elif [ "$seen" -eq 1 ]; then
    ok DB-001 "databases bound to loopback only: $(join ', ' "${lo[@]}")" ""
  else
    ok DB-001 "no database/cache ports listening" ""
  fi

  # DB-002 Redis without authentication
  if have redis-cli && printf '%s\n' "${pub[@]}" "${priv[@]}" "${lo[@]}" | grep -q '^redis'; then
    if [ "$(q redis-cli -h 127.0.0.1 ping)" = "PONG" ]; then
      local sev=warn; [ "${#pub[@]}" -gt 0 ] && printf '%s\n' "${pub[@]}" | grep -q '^redis' && sev=fail
      "$sev" DB-002 "Redis answers without a password" "any process (or the internet, if exposed) can read data or write files via CONFIG SET" "set 'requirepass' or ACL users in redis.conf and restart redis"
    else
      ok DB-002 "Redis requires authentication" ""
    fi
  elif printf '%s\n' "${pub[@]}" "${priv[@]}" "${lo[@]}" | grep -q '^redis'; then
    skip DB-002 "Redis authentication" "redis detected but redis-cli is not installed"
  else
    skip DB-002 "Redis authentication" "redis not detected"
  fi
}
