# ==========================================================
# Stage 1: Pre-cache bitnami/kubectl using skopeo
# This runs during image BUILD when internet is available.
# The tar is copied into k3s's auto-import directory so it
# is available offline when CronJob pods start at eval time.
# ==========================================================
FROM quay.io/skopeo/stable:v1.21.0 AS image-fetcher

WORKDIR /images

RUN skopeo copy \
    docker://bitnami/kubectl:1.31.0 \
    docker-archive:bitnami-kubectl-1.31.0.tar:bitnami/kubectl:1.31.0

# ==========================================================
# Stage 2: Final nebula-devops image with pre-cached kubectl
# ==========================================================
FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.0.2

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024
ENV ALLOWED_NAMESPACES="bleater"

# Copy pre-cached image into k3s auto-import directory.
# k3s scans this directory on startup and loads images into
# containerd — no internet pull required at runtime.
COPY --from=image-fetcher /images/bitnami-kubectl-1.31.0.tar \
     /var/lib/rancher/k3s/agent/images/bitnami-kubectl-1.31.0.tar
