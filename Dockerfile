# Go製IPゲートをビルド
#   gate.go（ゲートと監視）、policy.go（許可リストの読み込み）、rules.go（公開読み取りの例外）を、
#   Goモジュールとしてビルドする。go.sum は、ビルド時に pgx の版から作る
#   （Goのチェックサムデータベースで改ざんを検証）。pgx の版を上げるときは PGX_VERSION を書き換える。
FROM golang:1.24-alpine AS gate-build
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

FROM directus/directus:12.5.1

USER root

ARG BAO_VERSION=2.7.0
RUN apk add --no-cache curl && \
    curl -fsSL -o /tmp/bao.tar.gz \
      "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/openbao_${BAO_VERSION}_linux_amd64.tar.gz" && \
    mkdir -p /tmp/bao-extract && \
    tar -xzf /tmp/bao.tar.gz -C /tmp/bao-extract && \
    mv /tmp/bao-extract/bao /usr/local/bin/bao && \
    chmod +x /usr/local/bin/bao && \
    rm -rf /tmp/bao.tar.gz /tmp/bao-extract

COPY --from=gate-build /out/gate /app/gate
RUN chmod +x /app/gate

# ゲートが起動するアプリ（Directus）。秘密ではないので、コードと一緒に版管理する。
#   Directus は、ゲートの内側（127.0.0.1:3457）だけで待ち受ける。公開ポート（$PORT）はゲートが受ける。
#   migrate は、コンテナごとに1回だけ（Agent が資格情報の更新で再起動するときは、省略して、起動を短くする）。
#   GATE_WAIT_READY_SEC: Directus が応答するまで、ゲートは公開ポートを開かない（Render が、準備前に切り替えない）。
ENV GATE_CHILD_CMD='["/bin/sh","-c","[ -f /tmp/.migrated ] || { node cli.js database migrate:latest && touch /tmp/.migrated || exit 1; }; exec node cli.js start"]' \
    GATE_CHILD_ENV='PORT=3457,HOST=127.0.0.1' \
    GATE_UPSTREAM=127.0.0.1:3457 \
    GATE_UPSTREAM_HEALTH_PATH=/server/ping \
    GATE_WAIT_READY_SEC=600

COPY openbao/agent.hcl /etc/openbao/agent.hcl
COPY openbao/entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

USER node

ENTRYPOINT ["/entrypoint.sh"]