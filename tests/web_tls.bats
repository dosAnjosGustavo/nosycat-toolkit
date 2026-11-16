#!/usr/bin/env bats
# WEB-004 only looks at enabled web server config.

load helpers

setup() {
  load_nosycat
  fake_etc
  mkdir -p "$NOSY_ETC/nginx/sites-available" "$NOSY_ETC/nginx/sites-enabled" "$NOSY_ETC/nginx/conf.d"
  printf 'http { include /etc/nginx/conf.d/*.conf; include /etc/nginx/sites-enabled/*; }\n' >"$NOSY_ETC/nginx/nginx.conf"
  IS_ROOT=0
}

vhost() { printf 'server {\n  listen 443 ssl;\n  ssl_certificate %s;\n}\n' "$2" >"$1"; }

@test "expired cert in a disabled vhost (sites-available only) is not a FAIL" {
  vhost "$NOSY_ETC/nginx/sites-available/old" "$FIX/certs/expired.pem"
  vhost "$NOSY_ETC/nginx/sites-available/live" "$FIX/certs/valid.pem"
  ln -s ../sites-available/live "$NOSY_ETC/nginx/sites-enabled/live"
  nosy mod_web_tls
  assert_status WEB-004 OK
}

@test "expired cert in an enabled vhost is a FAIL" {
  vhost "$NOSY_ETC/nginx/sites-available/live" "$FIX/certs/expired.pem"
  ln -s ../sites-available/live "$NOSY_ETC/nginx/sites-enabled/live"
  nosy mod_web_tls
  assert_status WEB-004 FAIL
}

@test "conf.d is enabled config" {
  vhost "$NOSY_ETC/nginx/conf.d/app.conf" "\"$FIX/certs/expired.pem\""
  nosy mod_web_tls
  assert_status WEB-004 FAIL
}

@test "nginx -T output is preferred when available" {
  vhost "$NOSY_ETC/nginx/conf.d/app.conf" "$FIX/certs/expired.pem"
  vhost "$BATS_TEST_TMPDIR/nginx-T" "$FIX/certs/valid.pem"
  export NOSY_FX_NGINX_T="$BATS_TEST_TMPDIR/nginx-T"
  nosy mod_web_tls
  assert_status WEB-004 OK
}

@test "apache: sites-available is ignored, sites-enabled counts" {
  rm -rf "$NOSY_ETC/nginx"
  mkdir -p "$NOSY_ETC/apache2/sites-available" "$NOSY_ETC/apache2/sites-enabled"
  printf '<VirtualHost *:443>\n  SSLCertificateFile %s\n</VirtualHost>\n' "$FIX/certs/expired.pem" >"$NOSY_ETC/apache2/sites-available/default-ssl.conf"
  printf '<VirtualHost *:443>\n  SSLCertificateFile %s\n</VirtualHost>\n' "$FIX/certs/valid.pem" >"$NOSY_ETC/apache2/sites-enabled/site.conf"
  nosy mod_web_tls
  assert_status WEB-004 OK
}

@test "expired Let's Encrypt cert not used by enabled config is a WARN, not a FAIL" {
  mkdir -p "$NOSY_ETC/letsencrypt/live/old.example.com"
  cp "$FIX/certs/expired.pem" "$NOSY_ETC/letsencrypt/live/old.example.com/cert.pem"
  vhost "$NOSY_ETC/nginx/conf.d/app.conf" "$FIX/certs/valid.pem"
  nosy mod_web_tls
  assert_status WEB-004 WARN
  [[ "$(result_field WEB-004 TITLE)" == *"old.example.com"* ]]
}

@test "Let's Encrypt cert referenced by an enabled vhost keeps FAIL severity" {
  mkdir -p "$NOSY_ETC/letsencrypt/live/www.example.com"
  cp "$FIX/certs/expired.pem" "$NOSY_ETC/letsencrypt/live/www.example.com/fullchain.pem"
  cp "$FIX/certs/expired.pem" "$NOSY_ETC/letsencrypt/live/www.example.com/cert.pem"
  vhost "$NOSY_ETC/nginx/conf.d/app.conf" "/etc/letsencrypt/live/www.example.com/fullchain.pem"
  nosy mod_web_tls
  assert_status WEB-004 FAIL
}
