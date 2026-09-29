# llama-server for Qwen3.8-Flash-Next with MTP (NextN) speculative decoding.
#
# Stock ggml-org/llama.cpp has no qwen4exp MTP graph and cannot load the shared
# MTP sidecar (upstream PR #28243 is still open). Unsloth's prebuilt Vulkan
# binaries carry that support, so overlay them on the upstream Vulkan image to
# keep its Mesa/RADV runtime. Drop this once #28243 lands in the upstream image.
#
# Build (tag is referenced from configuration.nix):
#   docker build -t llama-server-unsloth:b11160-mix-a6922cc hosts/liltig/llama-server
FROM ghcr.io/ggml-org/llama.cpp:server-vulkan

ADD --checksum=sha256:86e00367060c785dbf0e5def2fcfbbe7f48eaf2a3eaf11fe26a22c84252dbe1d \
    https://github.com/unslothai/llama.cpp/releases/download/b11160-mix-a6922cc/app-b11160-mix-a6922cc-linux-x64-vulkan.tar.gz \
    /tmp/unsloth.tar.gz

RUN mkdir -p /opt/unsloth \
 && tar xzf /tmp/unsloth.tar.gz -C /opt/unsloth \
 && rm /tmp/unsloth.tar.gz

ENV LD_LIBRARY_PATH=/opt/unsloth
ENTRYPOINT ["/opt/unsloth/llama-server"]
