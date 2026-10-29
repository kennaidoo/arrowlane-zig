FROM debian:bookworm-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl jq xz-utils \
 && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.17.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz \
 && curl -fsSL https://ziglang.org/download/index.json -o /tmp/zig-index.json \
 && expected="$(jq -r --arg version "${ZIG_VERSION}" '.[$version]["x86_64-linux"].shasum' /tmp/zig-index.json)" \
 && test -n "$expected" \
 && echo "${expected}  /tmp/zig.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/zig.tar.xz -C /opt \
 && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
COPY tools ./tools
COPY include ./include
COPY LICENSE ./

RUN --mount=type=cache,target=/src/.zig-cache \
    --mount=type=cache,target=/src/vendor \
    bash tools/fetch-zstd.sh \
 && zig build -Doptimize=ReleaseSafe -Dstrip=true -Dc-abi=false \
      -Dtarget=x86_64-linux-musl \
 && mkdir -p /out \
 && cp zig-out/bin/arrowlane-zig /out/arrowlane-zig

FROM scratch

COPY --from=build /out/arrowlane-zig /arrowlane-zig
USER 65532
ENTRYPOINT ["/arrowlane-zig"]
