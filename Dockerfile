# Go製IPゲートをビルド
#   gate.go（ゲートと監視）、policy.go（許可リストの読み込み）、rules.go（公開読み取りの例外）を、
#   Goモジュールとしてビルドする。go.sum は、ビルド時に pgx の版から作る
#   （Goのチェックサムデータベースで改ざんを検証）。pgx の版を上げるときは PGX_VERSION を書き換える。
FROM golang:1.27-alpine AS gate-build
# 依存の pgx が、より新しいGoを求める場合に、必要な版を自動で取得する
ENV GOTOOLCHAIN=auto \
    CGO_ENABLED=0
ARG PGX_VERSION=v5.9.2
WORKDIR /src
COPY gate.go policy.go rules.go ./
RUN go mod init gate && \
    go get github.com/jackc/pgx/v5@${PGX_VERSION} && \
    go mod tidy && \
    go build -trimpath -ldflags="-s -w" -o /out/gate .

# NetBird クライアントを取得
FROM alpine:3.24 AS netbird-download
ARG NETBIRD_VERSION=0.81.5
RUN apk add --no-cache curl && \
    curl -fsSL -o /tmp/netbird.tar.gz \
      "https://github.com/netbirdio/netbird/releases/download/v${NETBIRD_VERSION}/netbird_${NETBIRD_VERSION}_linux_amd64.tar.gz" && \
    mkdir -p /tmp/netbird-bin && \
    tar -xzf /tmp/netbird.tar.gz -C /tmp/netbird-bin netbird

FROM directus/directus:12.6.1

USER root

ARG BAO_VERSION=2.7.2
RUN apk add --no-cache curl && \
    curl -fsSL -o /tmp/bao.tar.gz \
      "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/openbao_${BAO_VERSION}_linux_amd64.tar.gz" && \
    mkdir -p /tmp/bao-extract && \
    tar -xzf /tmp/bao.tar.gz -C /tmp/bao-extract && \
    mv /tmp/bao-extract/bao /usr/local/bin/bao && \
    chmod +x /usr/local/bin/bao && \
    rm -rf /tmp/bao.tar.gz /tmp/bao-extract

COPY --from=netbird-download /tmp/netbird-bin/netbird /usr/local/bin/netbird
COPY --from=gate-build /out/gate /app/gate

# NetBird は非 root（node）で動かす。状態ファイルの置き場を、node が書けるようにしておく。
# NetBird の実行確認もここで行う。
RUN mkdir -p /var/lib/netbird /var/log/netbird && \
    chown node:node /var/lib/netbird /var/log/netbird && \
    chmod +x /usr/local/bin/netbird /app/gate && \
    /usr/local/bin/netbird version

# ゲートが起動するアプリ（Directus）。秘密ではないので、コードと一緒に版管理する。
#   Directus は、ゲートの内側（127.0.0.1:3457）だけで待ち受ける。公開ポート（$PORT）はゲートが受ける。
#   migrate は、コンテナごとに1回だけ（Agent が資格情報の更新で再起動するときは、省略して、起動を短くする）。
#   GATE_WAIT_READY_SEC: Directus が応答するまで、ゲートは公開ポートを開かない（Render が、準備前に切り替えない）。
ENV GATE_CHILD_CMD='["/bin/sh","-c","[ -f /tmp/.migrated ] || { node cli.js database migrate:latest && touch /tmp/.migrated || exit 1; }; exec node cli.js start"]' \
    GATE_CHILD_ENV='PORT=3457,HOST=127.0.0.1' \
    GATE_UPSTREAM=127.0.0.1:3457 \
    GATE_UPSTREAM_HEALTH_PATH=/server/ping \
    GATE_WAIT_READY_SEC=600

# OpenBao の NetBird 向け証明書
COPY openbao/ca.crt /etc/openbao/ca.crt
COPY openbao/agent.hcl /etc/openbao/agent.hcl
COPY openbao/entrypoint.sh /entrypoint.sh
COPY openbao/netbird-up.sh /netbird-up.sh
# rclone の証明書（公開情報）。netbird-forward.js が、rclone との TLS を、この証明書だけに固定する
COPY openbao/rclone-ca.crt /etc/openbao/rclone-ca.crt
COPY openbao/netbird-forward.js /netbird-forward.js
RUN sed -i 's/\r$//' /entrypoint.sh /netbird-up.sh && chmod +x /entrypoint.sh /netbird-up.sh

USER node

ENTRYPOINT ["/entrypoint.sh"]