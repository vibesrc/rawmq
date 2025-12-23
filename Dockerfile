# Build stage
FROM alpine:3.21 AS builder

ARG ZIG_VERSION=0.14.0

RUN apk add --no-cache curl xz

WORKDIR /deps
RUN curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-$(uname -m)-${ZIG_VERSION}.tar.xz" -o zig.tar.xz && \
    tar -xJf zig.tar.xz && \
    mv zig-linux-$(uname -m)-${ZIG_VERSION} /usr/local/zig && \
    rm zig.tar.xz

ENV PATH="/usr/local/zig:${PATH}"

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

RUN zig build -Doptimize=ReleaseFast

# Runtime stage
FROM alpine:3.21

WORKDIR /app
COPY --from=builder /src/bin/rawmq /app/rawmq
COPY rawmq.toml.example /app/rawmq.toml.example

EXPOSE 1883
ENTRYPOINT ["/app/rawmq"]
