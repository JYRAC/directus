#!/bin/sh
set -e
umask 077

echo "[runtime] Node.js: $(node --version 2>/dev/null || echo unavailable)"

if [ -z "${OPENBAO_WRAPPED_TOKEN:-}" ]; then
  echo "OPENBAO_WRAPPED_TOKEN is not set" >&2
  exit 1
fi

# 接続先:
#   OPENBAO_NB_ADDR     OpenBao の NetBird 側の宛先。例 https://100.74.x.y:8210（IP 指定。名前は引けない）
#   NB_SETUP_KEY        NetBird の使い捨てキー（Actions がデプロイのたびに作って、Render に渡す）
NB_ADDR="${OPENBAO_NB_ADDR:-}"
NB_SNI="${OPENBAO_NB_SERVER_NAME:-openbao.netbird.cloud}"

export BAO_CLIENT_TIMEOUT=30s

VIA=""

# NetBird 経由: SOCKS5（127.0.0.1:1080）に通し、ピン留めした証明書で、この名前を確認する。
use_netbird() {
  export HTTPS_PROXY=socks5://127.0.0.1:1080 https_proxy=socks5://127.0.0.1:1080
  export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
  export BAO_CACERT=/etc/openbao/ca.crt
  export BAO_TLS_SERVER_NAME="$NB_SNI"
  export BAO_ADDR="$NB_ADDR"
  VIA=netbird
}

# OpenBao へは、NetBird 経由だけ（公開側は、閉じた）。接続できなければ、起動を止める。
if [ -z "$NB_ADDR" ] || [ -z "${NB_SETUP_KEY:-}" ]; then
  echo "NB: OPENBAO_NB_ADDR か NB_SETUP_KEY がありません。OpenBao の公開側は閉じたので、接続できません（デプロイのワークフローが、キーを作れたかを確認）" >&2
  exit 1
fi
if ! /netbird-up.sh; then
  echo "NB: NetBird に接続できませんでした。OpenBao の公開側は閉じたので、接続できません（NetBird のポリシー、OpenBao の起動、setup key を確認）" >&2
  exit 1
fi
NB_OK=1
use_netbird
# キーは、もう使わない。アプリ側の環境に残さない。
unset NB_SETUP_KEY

# rclone（S3）へは、NetBird 経由でだけ出る（rclone の公開側は閉じた）。Directus の S3 ドライバは SOCKS5 を話せないので、
# 127.0.0.1 の小さな転送（netbird-forward.js）で受けて、NetBird の SOCKS5 に流す。
# 全体を SOCKS5 に流すわけではない（Supabase などへの通信は、そのまま）。
# 転送は、つながるたびに宛先へ出るので、rclone の起動が遅れても、待たずに起動する。届くかどうかは、ログにだけ出す。
if [ "$NB_OK" = 1 ] && [ -n "${RCLONE_NB_ADDR:-}" ]; then
  node /netbird-forward.js &
  export STORAGE_GDRIVE_ENDPOINT="http://127.0.0.1:${RCLONE_LOCAL_PORT:-9000}"
  ( node /netbird-forward.js --check >&2 || echo "NB: rclone に NetBird 経由で届きません。ファイルの保存、取得ができません" >&2 ) &
  echo "RCLONE_VIA=netbird endpoint=$STORAGE_GDRIVE_ENDPOINT"
else
  echo "NB: NetBird に接続できないか、RCLONE_NB_ADDR が空です。rclone に届かないので、ファイルの保存、取得ができません" >&2
fi

# Casdoor（SSO）への、サーバー側の通信（トークンの交換と、ユーザー情報の取得）は、NetBird 経由で、Casdoor の内部口 A に出す。
#   CASDOOR_NB_ADDR  内部口 A の、NetBird の IP:ポート（Casdoor の固定ピアの IP:8443。IPv4 のみ。名前は引けない）
# Directus の OAuth2 ドライバは SOCKS5 を話せないので、netbird-forward.js（--name=casdoor）で受ける。
# 127.0.0.1 の間は平文で、NetBird の上は TLS 1.3。Casdoor の証明書は、/etc/openbao/ca.crt（ルート入りのバンドル）で、
# 名前 auth.jyrac.stki.org として検証する（検証は、切らない）。
# ブラウザが開く認可の URL（AUTH_CASDOOR_AUTHORIZE_URL）は、公開の URL のまま（利用者の通信なので、内部口を通さない）。
# ACCESS_URL と PROFILE_URL は、転送に向ける。転送が使えないとき（CASDOOR_NB_ADDR が空）は、
# SSO が使えない（公開側へは、戻らない。Casdoor の公開側は、IP 制限で、届かない）。
# いずれも AUTH_CASDOOR_DRIVER=oauth2 のときだけ使われる（openid のときは、無視される）。
CASDOOR_EP="http://127.0.0.1:${CASDOOR_LOCAL_PORT:-9001}"
if [ -n "${CASDOOR_NB_ADDR:-}" ]; then
  node /netbird-forward.js --name=casdoor &
  ( node /netbird-forward.js --name=casdoor --check >&2 || echo "NB: Casdoor の内部口に NetBird 経由で届きません。SSO のログインができません" >&2 ) &
  CASDOOR_VIA=netbird
else
  CASDOOR_VIA=none
  echo "NB: CASDOOR_NB_ADDR が空です。SSO のログインができません（Casdoor の公開側は、IP 制限で、届きません）" >&2
fi
export AUTH_CASDOOR_ACCESS_URL="$CASDOOR_EP/api/login/oauth/access_token"
export AUTH_CASDOOR_PROFILE_URL="$CASDOOR_EP/api/userinfo"
echo "CASDOOR_VIA=$CASDOOR_VIA endpoint=$CASDOOR_EP"

unwrap() {
  bao unwrap -field=token "$OPENBAO_WRAPPED_TOKEN" 2>/tmp/unwrap.err
}

REAL_TOKEN=$(unwrap) || REAL_TOKEN=""
if [ -z "$REAL_TOKEN" ]; then
  echo "NB: NetBird 経由の unwrap に失敗しました（公開側へは、戻りません）" >&2
  echo "unwrap failed: $(tail -n 3 /tmp/unwrap.err | tr '\n' ' ')" >&2
  exit 1
fi

printf '%s' "$REAL_TOKEN" > /tmp/vault-token
unset REAL_TOKEN OPENBAO_WRAPPED_TOKEN

# Agent の接続設定（vault ブロック）は、経路によって変わるので、ここで作って、agent.hcl の前に付ける。
{
  echo 'vault {'
  echo "  address = \"$BAO_ADDR\""
  if [ "$VIA" = "netbird" ]; then
    echo '  ca_cert         = "/etc/openbao/ca.crt"'
    echo "  tls_server_name = \"$NB_SNI\""
  fi
  echo '}'
  echo
  cat /etc/openbao/agent.hcl
} > /tmp/agent.hcl

echo "OPENBAO_VIA=$VIA addr=$BAO_ADDR"
exec bao agent -config=/tmp/agent.hcl
