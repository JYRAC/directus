vault {
  address = "https://openbao.jyrac.stki.org"
}

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

exec {
  command                   = ["/bin/sh", "-c", "node cli.js database migrate:latest && node cli.js start"]
  restart_on_secret_changes = "always"
}
