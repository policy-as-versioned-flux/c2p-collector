# Ticket 04 (real-estate): replaces fleet's build-C2P-from-source-every-run
# CronJob (ADR-0009's original "small glue we own, zero registry infra"
# tradeoff) with a real, prebuilt, digest-addressable image -- the run time
# cost (git clone + go build every 15 minutes, ~4 minutes observed) moves
# from every run to this one build.
FROM golang:1.26-alpine AS build
RUN apk add --no-cache git
WORKDIR /src
# Pinned per ADR-0009's pre-GA acceptance -- same version the fleet
# CronJob built from source.
RUN git clone --depth 1 --branch v2.0.0-rc.1 https://github.com/oscal-compass/compliance-to-policy-go.git .
RUN go build -o /out/c2pcli ./cmd/c2pcli && go build -o /out/kyverno-plugin ./cmd/kyverno-plugin

FROM alpine:3.20
RUN apk add --no-cache jq curl ca-certificates
ARG KUBECTL_VERSION=1.31.4
RUN set -eu; \
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); \
    curl -sSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; \
    curl -sSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"; \
    echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod +x /usr/local/bin/kubectl; \
    rm /tmp/kubectl.sha256
COPY --from=build /out/c2pcli /usr/local/bin/c2pcli
COPY --from=build /out/kyverno-plugin /usr/local/bin/kyverno-plugin
COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh
ENTRYPOINT ["/usr/local/bin/run.sh"]
