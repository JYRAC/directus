# vault ブロック（接続先、証明書）は、entrypoint.sh が、経路に合わせて作って、この前に付ける。

auto_auth {
  method {
    type = "token_file"
    config = {
      token_file_path = "/tmp/vault-token"
    }
  }
}

env_template "ADMIN_PASSWORD" {
  contents = "{{ with secret \"kv/data/secrets/directus/config\" }}{{ .Data.data.admin_password }}{{ end }}"
}

env_template "AUTH_CASDOOR_CLIENT_SECRET" {
  contents = "{{ with secret \"kv/data/secrets/directus/config\" }}{{ .Data.data.casdoor_client_secret }}{{ end }}"
}

env_template "DB_CONNECTION_STRING" {
  contents = "{{ with secret \"database/creds/directus\" }}postgresql://{{ .Data.username }}.kuajmlczxracqobxkzee:{{ .Data.password }}@aws-0-us-west-2.pooler.supabase.com:6543/postgres?sslmode=no-verify&options=-c%20search_path%3Ddirectus{{ end }}"
}

env_template "KEY" {
  contents = "{{ with secret \"kv/data/secrets/directus/config\" }}{{ .Data.data.key }}{{ end }}"
}

env_template "SECRET" {
  contents = "{{ with secret \"kv/data/secrets/directus/config\" }}{{ .Data.data.secret }}{{ end }}"
}

env_template "LICENSE_KEY" {
  contents = "{{ with secret \"kv/data/secrets/directus/config\" }}{{ .Data.data.license_key }}{{ end }}"
}

env_template "STORAGE_GDRIVE_KEY" {
  contents = "{{ with secret \"kv/data/secrets/shared/rclone-gdrive\" }}{{ .Data.data.access_key }}{{ end }}"
}

env_template "STORAGE_GDRIVE_SECRET" {
  contents = "{{ with secret \"kv/data/secrets/shared/rclone-gdrive\" }}{{ .Data.data.secret_key }}{{ end }}"
}

# ゲート専用の、読み取りだけのDB資格情報（Directus本体のロールとは別）。
# GATE_ で始まる環境変数は、ゲートが Directus の子プロセスには渡さない。
env_template "GATE_DB_USER" {
  contents = "{{ with secret \"database/creds/gate-reader\" }}{{ .Data.username }}.kuajmlczxracqobxkzee{{ end }}"
}

env_template "GATE_DB_PASSWORD" {
  contents = "{{ with secret \"database/creds/gate-reader\" }}{{ .Data.password }}{{ end }}"
}

# Directus本体（migrate して start）は、ゲートが起動する（Dockerfile の GATE_CHILD_CMD）。
# ゲートは、`env -u` を通して起動する。Agent が OpenBao に出るための設定（SOCKS5 のプロキシ、
# OpenBao 向けの BAO_*）を、ゲートと Directus に渡さないため。渡すと、Directus の外向きの通信
# （Casdoor、Supabase、rclone など）まで、NetBird の SOCKS5 に流れて、失敗する。
exec {
  command = [
    "/usr/bin/env",
    "-u", "HTTPS_PROXY", "-u", "HTTP_PROXY", "-u", "NO_PROXY",
    "-u", "https_proxy", "-u", "http_proxy", "-u", "no_proxy",
    "-u", "BAO_ADDR", "-u", "BAO_CACERT", "-u", "BAO_TLS_SERVER_NAME", "-u", "BAO_CLIENT_TIMEOUT",
    "/app/gate"
  ]
  restart_on_secret_changes = "always"
}
