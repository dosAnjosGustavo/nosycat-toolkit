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

  # DB-002 Redis without authentication, probed on the address it listens on
  _db_redis_auth
}

# _redis_target -> "scope host port" of the most exposed Redis listener, or nothing.
_redis_target() {
  local l proto host port proc scope best="" rank=0 r
  for l in "${LISTENERS[@]}"; do
    read -r proto host port proc <<<"$l"
    [ "$proto" = "tcp" ] || continue
    if [ "$port" != "6379" ]; then
      [ "$proc" = "-" ] && continue
      printf '%s' "$proc" | grep -qE '^(redis-server|valkey-server|valkey)$' || continue
    fi
    scope="$(addr_scope "$host")"
    case "$scope" in any|public) r=3 ;; private) r=2 ;; *) r=1 ;; esac
    if [ "$r" -gt "$rank" ]; then rank="$r"; best="$scope $host $port"; fi
  done
  printf '%s' "$best"
}

_db_redis_auth() {
  local target scope host port cli="" reply rc
  target="$(_redis_target)"
  if [ -z "$target" ]; then skip DB-002 "Redis authentication" "redis not detected"; return; fi
  read -r scope host port <<<"$target"
  # A wildcard bind also answers on loopback; use the matching family.
  case "$host" in 0.0.0.0|'*'|'') host="127.0.0.1" ;; ::) host="::1" ;; esac
  if have redis-cli; then cli="redis-cli"; elif have valkey-cli; then cli="valkey-cli"; fi
  if [ -z "$cli" ]; then
    skip DB-002 "Redis authentication" "redis detected on $host:$port but redis-cli is not installed"
    return
  fi
  # Ignore any REDISCLI_AUTH in the caller's environment: we want the anonymous answer.
  reply="$(t "$NOSY_TIMEOUT" env -u REDISCLI_AUTH "$cli" -h "$host" -p "$port" ping 2>&1)"; rc=$?
  reply="$(printf '%s' "$reply" | head -n1)"
  case "$reply" in
    PONG)
      if [ "$scope" = "any" ] || [ "$scope" = "public" ]; then
        fail DB-002 "Redis on $host:$port answers without a password" "Redis listens on a public interface: anyone can read data or write files via CONFIG SET" "set 'requirepass' or ACL users in redis.conf, bind 127.0.0.1, and restart redis"
      else
        warn DB-002 "Redis on $host:$port answers without a password" "any local process (or host on the private network) can read data or write files via CONFIG SET" "set 'requirepass' or ACL users in redis.conf and restart redis"
      fi ;;
    *NOAUTH*|*noauth*)
      ok DB-002 "Redis on $host:$port requires authentication" "" ;;
    *DENIED*)
      warn DB-002 "Redis on $host:$port has no password (protected mode is blocking us)" "protected mode only refuses non-loopback clients while no password is set; turning it off or binding elsewhere exposes the data" "set 'requirepass' or ACL users in redis.conf and restart redis" ;;
    *)
      local why="no reply"
      [ "$rc" -eq 124 ] && why="timed out"
      [ -n "$reply" ] && why="$reply"
      skip DB-002 "Redis authentication" "could not connect to $host:$port ($why); cannot tell whether auth is required" ;;
  esac
}
