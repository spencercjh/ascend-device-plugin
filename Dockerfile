# syntax=docker/dockerfile:1.7
ARG GO_IMAGE=golang:1.24-bookworm
ARG RUST_IMAGE=rust:1-bookworm
ARG BASE_IMAGE=ubuntu:20.04

FROM $GO_IMAGE AS go-build

ARG GOPROXY=https://proxy.golang.org,direct
ARG VERSION=unknown
ENV GOPROXY=${GOPROXY}
WORKDIR /build

COPY go.mod go.sum ./
COPY mind-cluster/component/ascend-common/go.mod ./mind-cluster/component/ascend-common/go.mod
COPY mind-cluster/component/npu-exporter/go.mod ./mind-cluster/component/npu-exporter/go.mod
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make all

FROM $RUST_IMAGE AS vnpu-build

ARG ASCEND_TOOLKIT_LIB_DIR=/usr/local/Ascend/ascend-toolkit/latest/lib64
ENV LD_LIBRARY_PATH=${ASCEND_TOOLKIT_LIB_DIR}:${LD_LIBRARY_PATH}
WORKDIR /build/libvnpu
COPY libvnpu ./
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/libvnpu/target \
    --mount=type=bind,source=${ASCEND_TOOLKIT_LIB_DIR},target=${ASCEND_TOOLKIT_LIB_DIR},readonly \
    test -f "${ASCEND_TOOLKIT_LIB_DIR}/libruntime.so" \
    || (echo "missing ${ASCEND_TOOLKIT_LIB_DIR}/libruntime.so; build must run on a machine with Ascend CANN toolkit installed" >&2; exit 1) \
    && cargo build --release \
    && mkdir -p /out \
    && cp target/release/limiter /out/limiter \
    && cp target/release/libvnpu.so /out/libvnpu.so \
    && printf '/hami-vnpu-core/libvnpu.so\n' > /out/ld.so.preload

FROM $BASE_IMAGE

ENV LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common
COPY --from=go-build /build/ascend-device-plugin /usr/local/bin/ascend-device-plugin
COPY --from=vnpu-build /out/ /usr/local/hami-vnpu-core-assets/

ENTRYPOINT ["ascend-device-plugin"]
