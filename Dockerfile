# whisper-engine — imágenes Docker.
#   cpu       whisper.cpp solo CPU (cualquier x86_64)
#   openvino  whisper.cpp + OpenVINO para iGPU Intel (INTEL_RUNTIME=current|legacy)
#   tools     conversión de modelos a OpenVINO IR (se usa una vez y se descarta)
ARG WHISPER_REF=v1.9.4
ARG OPENVINO_URL=https://storage.openvinotoolkit.org/repositories/openvino/packages/2025.4/linux/openvino_toolkit_ubuntu24_2025.4.0.20398.8fdad55727d_x86_64.tgz

# ---------------------------------------------------------------- deps de Node
FROM node:20-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --no-audit --no-fund

# ---------------------------------------------------------------- whisper.cpp
FROM ubuntu:24.04 AS src
ARG WHISPER_REF
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git build-essential cmake curl \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${WHISPER_REF} https://github.com/ggml-org/whisper.cpp.git /whisper.cpp

FROM src AS build-cpu
RUN cmake -S /whisper.cpp -B /build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
 && cmake --build /build -j"$(nproc)" --target whisper-cli

FROM src AS openvino-sdk
ARG OPENVINO_URL
RUN curl -fsSL -o /tmp/ov.tgz "${OPENVINO_URL}" \
 && curl -fsSL -o /tmp/ov.tgz.sha256 "${OPENVINO_URL}.sha256" \
 && cd /tmp && echo "$(awk '{print $1}' ov.tgz.sha256)  ov.tgz" | sha256sum -c --quiet \
 && mkdir -p /opt/intel && tar -xzf /tmp/ov.tgz -C /opt/intel \
 && mv /opt/intel/openvino_toolkit_* /opt/intel/openvino && rm /tmp/ov.tgz*

FROM openvino-sdk AS build-openvino
RUN bash -c 'source /opt/intel/openvino/setupvars.sh \
 && cmake -S /whisper.cpp -B /build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DWHISPER_OPENVINO=1 \
 && cmake --build /build -j"$(nproc)" --target whisper-cli'

# ---------------------------------------------------------------- runtime común
FROM ubuntu:24.04 AS runtime
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home --home-dir /home/engine engine \
 && mkdir -p /models /jobs && chown engine:engine /models /jobs
COPY --from=node:20-bookworm-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=src /whisper.cpp/models/download-ggml-model.sh /usr/local/bin/download-ggml-model.sh
COPY --from=src /whisper.cpp/samples/jfk.wav /usr/local/share/whisper/jfk.wav
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
ENV PORT=8080 HOST=0.0.0.0 \
    WHISPER_BIN=/usr/local/bin/whisper-cli \
    MODELS_DIR=/models VAD_MODEL=/models/ggml-silero-v5.1.2.bin JOBS_DIR=/jobs \
    WHISPER_MODELS=small
EXPOSE 8080
VOLUME ["/models", "/jobs"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=5m \
  CMD curl -fsS http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

FROM runtime AS cpu
COPY --from=build-cpu /build/bin/whisper-cli /usr/local/bin/whisper-cli
ENV WHISPER_DEVICE=cpu
USER engine

FROM runtime AS openvino
ARG INTEL_RUNTIME=current
# Runtime OpenCL de Intel: "current" (Gen12+/Xe/Arc) desde Ubuntu; "legacy" es la
# última rama con soporte Gen9–Gen11 (Skylake..Ice Lake, ej. HD 630).
RUN set -eux; apt-get update; \
    apt-get install -y --no-install-recommends ocl-icd-libopencl1 libtbb12 libpugixml1v5; \
    if [ "$INTEL_RUNTIME" = legacy ]; then \
      mkdir /tmp/neo && cd /tmp/neo; \
      for u in \
        https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.24/intel-igc-core_1.0.17537.24_amd64.deb \
        https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.24/intel-igc-opencl_1.0.17537.24_amd64.deb \
        https://github.com/intel/compute-runtime/releases/download/24.35.30872.36/intel-opencl-icd-legacy1_24.35.30872.36_amd64.deb \
        https://github.com/intel/compute-runtime/releases/download/24.35.30872.36/intel-level-zero-gpu-legacy1_1.5.30872.36_amd64.deb \
        https://github.com/intel/compute-runtime/releases/download/24.35.30872.36/libigdgmm12_22.5.0_amd64.deb; \
      do curl -fsSLO "$u"; done; \
      apt-get install -y --no-install-recommends ./*.deb; cd /; rm -rf /tmp/neo; \
    else \
      apt-get install -y --no-install-recommends intel-opencl-icd; \
    fi; \
    rm -rf /var/lib/apt/lists/*
COPY --from=openvino-sdk /opt/intel/openvino/setupvars.sh /opt/intel/openvino/setupvars.sh
COPY --from=openvino-sdk /opt/intel/openvino/runtime /opt/intel/openvino/runtime
COPY --from=build-openvino /build/bin/whisper-cli /usr/local/bin/whisper-cli
ENV WHISPER_DEVICE=auto
USER engine

# ---------------------------------------------------------------- tools
FROM python:3.12-slim AS tools
COPY --from=src /whisper.cpp/models/convert-whisper-to-openvino.py /tools/
RUN pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cpu \
      torch openai-whisper openvino onnxscript
COPY docker/convert.sh /usr/local/bin/convert
WORKDIR /tools
ENTRYPOINT ["/usr/local/bin/convert"]
