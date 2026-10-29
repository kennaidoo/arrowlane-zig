FROM debian:bookworm-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq xz-utils \
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
RUN bash tools/fetch-zstd.sh \
 && zig build -Doptimize=ReleaseSafe

FROM debian:bookworm-slim

RUN useradd --uid 65532 --no-create-home bench
COPY --from=build /src/zig-out/bin/arrowlane-zig /usr/local/bin/arrowlane-zig
USER 65532

ENTRYPOINT ["/usr/local/bin/arrowlane-zig"]
