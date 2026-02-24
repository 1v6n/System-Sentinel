FROM debian:bookworm-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get -o Acquire::Retries=5 -o Acquire::ForceIPv4=true update \
 && apt-get -o Acquire::Retries=5 -o Acquire::ForceIPv4=true install -y --no-install-recommends \
    build-essential \
    cmake \
    libmicrohttpd-dev \
    pkg-config \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Copy vendored Prometheus client first to maximize Docker layer cache
COPY lib/prometheus-client-c /app/lib/prometheus-client-c

# Ensure vendored Prometheus client has a VERSION file (required by its CMake)
RUN test -f /app/lib/prometheus-client-c/VERSION || echo "0.1.0" > /app/lib/prometheus-client-c/VERSION

# Build and install Prometheus client libraries (vendored)
RUN cmake -S /app/lib/prometheus-client-c/prom -B /tmp/build-prom -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
 && cmake --build /tmp/build-prom --config Release \
 && cmake --install /tmp/build-prom \
 && cmake -S /app/lib/prometheus-client-c/promhttp -B /tmp/build-promhttp -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
 && cmake --build /tmp/build-promhttp --config Release \
 && cmake --install /tmp/build-promhttp \
 && ldconfig

# Copy app sources separately (changing app code will not invalidate vendored lib build layers)
COPY CMakeLists.txt /app/CMakeLists.txt
COPY include /app/include
COPY src /app/src

# Build app
RUN rm -rf /app/build \
 && cmake -S /app -B /app/build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /app/build --config Release \
 && strip --strip-unneeded /app/build/SystemSentinel \
 && strip --strip-unneeded /usr/local/lib/libprom.so \
 && strip --strip-unneeded /usr/local/lib/libpromhttp.so \
 && ldd /app/build/SystemSentinel

FROM debian:bookworm-slim AS runtime

WORKDIR /app

# Install only runtime deps
RUN apt-get -o Acquire::Retries=5 -o Acquire::ForceIPv4=true update \
 && apt-get -o Acquire::Retries=5 -o Acquire::ForceIPv4=true install -y --no-install-recommends \
    libmicrohttpd12 \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Run app as non-root user
RUN groupadd -r systemsentinel \
 && useradd -r -g systemsentinel -d /app -s /usr/sbin/nologin systemsentinel

# Copy runtime artifacts from build stage
COPY --from=builder /app/build/SystemSentinel /app/SystemSentinel
COPY --from=builder /usr/local/lib/libprom.so* /usr/local/lib/
COPY --from=builder /usr/local/lib/libpromhttp.so* /usr/local/lib/

RUN ldconfig

EXPOSE 8000

USER systemsentinel

CMD ["/app/SystemSentinel"]
