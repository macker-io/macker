# Classic-builder smoke: common instructions + multi-stage.
# Each RUN boots a MicroVM — keep this file small on purpose.
#
#   ./.build/debug/macker build -t smoke:latest --build-arg GREETING=world examples/build-smoke
#   ./.build/debug/macker run --rm smoke:latest
#   ./.build/debug/macker inspect smoke:latest   # WorkingDir, Env, ExposedPorts, Volumes, StopSignal
#   ./.build/debug/macker build -t smoke:builder --target builder examples/build-smoke

ARG BASE=alpine:latest

FROM ${BASE} AS builder
ARG GREETING=hello
WORKDIR /work
COPY src/message.txt ./
RUN mkdir -p /out \
 && printf '%s\n' "${GREETING}" > /out/greet.txt \
 && cat message.txt >> /out/greet.txt

FROM ${BASE}
LABEL org.opencontainers.image.title="macker-build-smoke"
ARG GREETING=hello
ENV APP_HOME=/app \
    GREETING=${GREETING}
SHELL ["/bin/sh", "-c"]
WORKDIR ${APP_HOME}
COPY --from=builder /out/greet.txt /app/greet.txt
ADD assets/note.txt /app/note.txt
RUN printf 'built\n' > /app/marker.txt \
 && test ! -e /app/secret.txt
EXPOSE 8080
VOLUME /data
STOPSIGNAL SIGTERM
USER nobody
ENTRYPOINT ["/bin/cat"]
CMD ["/app/greet.txt", "/app/note.txt", "/app/marker.txt"]
