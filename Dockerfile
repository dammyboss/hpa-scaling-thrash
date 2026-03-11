# ==========================================================
# Stage 1: Pre-cache container images using skopeo
# This runs during image BUILD when internet is available.
# The tar is copied into k3s's auto-import directory so it
# is available offline when CronJob pods start at eval time.
# ==========================================================
FROM quay.io/skopeo/stable:v1.21.0 AS image-fetcher

WORKDIR /images

RUN skopeo copy \
    docker://bitnami/kubectl:latest \
    docker-archive:kubectl-latest.tar:bitnami/kubectl:latest

RUN skopeo copy \
    docker://python:3.11-alpine \
    docker-archive:python-3.11-alpine.tar:python:3.11-alpine

# ==========================================================
# Stage 2: Final nebula-devops image with pre-cached images
# ==========================================================
FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.0.2

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024
ENV ALLOWED_NAMESPACES="bleater,bleater-env,default,kube-ops"

# Copy pre-cached images into k3s auto-import directory.
# k3s scans this directory on startup and loads images into
# containerd — no internet pull required at runtime.
COPY --from=image-fetcher /images/*.tar /var/lib/rancher/k3s/agent/images/
