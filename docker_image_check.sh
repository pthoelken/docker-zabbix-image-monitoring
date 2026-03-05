#!/bin/bash
# =============================================================================
# docker_image_check.sh
# Zabbix monitoring script: detects available Docker image updates
#
# Dependencies: docker, skopeo, jq
# Install:  apt install skopeo jq  |  yum install skopeo jq
#
# Place at:  /etc/zabbix/scripts/docker_image_check.sh
# Permissions: chmod 755 /etc/zabbix/scripts/docker_image_check.sh
#              chown root:zabbix /etc/zabbix/scripts/docker_image_check.sh
#
# The zabbix user needs docker access. Choose one option:
#   Option A (simple):  usermod -aG docker zabbix
#   Option B (safer):   add to /etc/sudoers.d/zabbix-docker:
#                       zabbix ALL=(root) NOPASSWD: /usr/bin/docker inspect *
#                       zabbix ALL=(root) NOPASSWD: /usr/bin/docker image inspect *
#                       zabbix ALL=(root) NOPASSWD: /usr/bin/docker ps
#                       zabbix ALL=(root) NOPASSWD: /usr/bin/docker info
#
# Return codes for docker.image.update:
#   0 = Up to date
#   1 = Update available
#   2 = Cannot check (locally built image or no RepoDigest)
#   3 = Error / Container not found
# =============================================================================

MODE="${1:-}"
CONTAINER="${2:-}"

DOCKER_BIN=$(command -v docker 2>/dev/null || echo "/usr/bin/docker")
SKOPEO_BIN=$(command -v skopeo 2>/dev/null || echo "/usr/bin/skopeo")
JQ_BIN=$(command -v jq 2>/dev/null || echo "/usr/bin/jq")

# -----------------------------------------------------------------------------
# Resolve a short image name to a fully-qualified reference for skopeo
# Examples:
#   nginx         -> docker.io/library/nginx:latest
#   user/img:tag  -> docker.io/user/img:tag
#   ghcr.io/u/i  -> ghcr.io/u/i  (unchanged)
# -----------------------------------------------------------------------------
resolve_image() {
    local image="$1"

    # Image pinned by digest - updates not meaningful
    if [[ "$image" == *@sha256:* ]]; then
        echo "__pinned__"
        return
    fi

    # Ensure tag is present
    if [[ "$image" != *:* ]]; then
        image="${image}:latest"
    fi

    local slashes
    slashes=$(echo "$image" | tr -cd '/' | wc -c)

    if [[ "$slashes" -eq 0 ]]; then
        # bare name: nginx:latest -> docker.io/library/nginx:latest
        echo "docker.io/library/${image}"
    elif [[ "$slashes" -eq 1 ]] && ! echo "$image" | grep -qP '^\w[\w.-]+\.\w+/'; then
        # user/image but no registry hostname: -> docker.io/user/image:tag
        echo "docker.io/${image}"
    else
        # already fully qualified: ghcr.io/..., registry.example.com/...
        echo "$image"
    fi
}

# -----------------------------------------------------------------------------
# LLD Discovery: outputs JSON array of running containers
# -----------------------------------------------------------------------------
cmd_discover() {
    local first=true
    local cid cname cimage

    echo -n '{"data":['

    while IFS='|' read -r cid cname cimage; do
        [[ -z "$cid" ]] && continue

        # Escape JSON-unsafe characters
        cname=$(printf '%s' "$cname" | sed 's/\\/\\\\/g; s/"/\\"/g')
        cimage=$(printf '%s' "$cimage" | sed 's/\\/\\\\/g; s/"/\\"/g')

        [[ "$first" == true ]] && first=false || echo -n ','
        printf '{"{#CONTAINER_ID}":"%s","{#CONTAINER_NAME}":"%s","{#CONTAINER_IMAGE}":"%s"}' \
            "$cid" "$cname" "$cimage"
    done < <("$DOCKER_BIN" ps --format '{{.ID}}|{{.Names}}|{{.Image}}' 2>/dev/null)

    echo ']}'
}

# -----------------------------------------------------------------------------
# Check if a newer image is available for a running container
# Returns: 0 (up to date) | 1 (update available) | 2 (cannot check) | 3 (error)
# -----------------------------------------------------------------------------
cmd_check_update() {
    local container="$1"
    local image full_image local_digest remote_digest

    # Get the image reference the container is using
    image=$("$DOCKER_BIN" inspect --format '{{.Config.Image}}' "$container" 2>/dev/null)
    if [[ -z "$image" ]]; then
        echo "3"
        return
    fi

    # Resolve to fully-qualified name
    full_image=$(resolve_image "$image")

    # Pinned by digest -> no updates possible, report as up to date
    if [[ "$full_image" == "__pinned__" ]]; then
        echo "0"
        return
    fi

    # Get locally stored digest from RepoDigests
    # RepoDigests contains "registry/image@sha256:DIGEST" entries
    local repo_digest_raw
    repo_digest_raw=$("$DOCKER_BIN" image inspect "$image" \
        --format '{{json .RepoDigests}}' 2>/dev/null | \
        "$JQ_BIN" -r '.[0] // empty' 2>/dev/null)

    if [[ -z "$repo_digest_raw" ]]; then
        # No RepoDigest = locally built image or never pulled from registry
        echo "2"
        return
    fi

    local_digest=$(echo "$repo_digest_raw" | cut -d'@' -f2)

    # Get the current digest from the remote registry via skopeo
    # skopeo does not pull the image - it only reads the manifest
    remote_digest=$("$SKOPEO_BIN" inspect "docker://${full_image}" 2>/dev/null | \
        "$JQ_BIN" -r '.Digest // empty' 2>/dev/null)

    if [[ -z "$remote_digest" ]]; then
        # Could not reach registry (network issue, auth required, image gone)
        echo "2"
        return
    fi

    if [[ "$local_digest" == "$remote_digest" ]]; then
        echo "0"
    else
        echo "1"
    fi
}

# -----------------------------------------------------------------------------
# Return the image reference string for a container
# -----------------------------------------------------------------------------
cmd_get_image() {
    local container="$1"
    local image
    image=$("$DOCKER_BIN" inspect --format '{{.Config.Image}}' "$container" 2>/dev/null)
    echo "${image:-unknown}"
}

# -----------------------------------------------------------------------------
# Return the locally stored digest (sha256:...) for a container's image
# -----------------------------------------------------------------------------
cmd_get_digest() {
    local container="$1"
    local image repo_digest

    image=$("$DOCKER_BIN" inspect --format '{{.Config.Image}}' "$container" 2>/dev/null)
    [[ -z "$image" ]] && echo "unknown" && return

    repo_digest=$("$DOCKER_BIN" image inspect "$image" \
        --format '{{json .RepoDigests}}' 2>/dev/null | \
        "$JQ_BIN" -r '.[0] // empty' 2>/dev/null)

    if [[ -n "$repo_digest" ]]; then
        echo "$repo_digest" | cut -d'@' -f2
    else
        echo "no-digest"
    fi
}

# -----------------------------------------------------------------------------
# Check if Docker daemon is reachable
# -----------------------------------------------------------------------------
cmd_daemon_status() {
    "$DOCKER_BIN" info > /dev/null 2>&1 && echo "1" || echo "0"
}

# -----------------------------------------------------------------------------
# Main dispatcher
# -----------------------------------------------------------------------------
case "$MODE" in
    discover)       cmd_discover ;;
    check_update)   cmd_check_update "$CONTAINER" ;;
    get_image)      cmd_get_image "$CONTAINER" ;;
    get_digest)     cmd_get_digest "$CONTAINER" ;;
    daemon_status)  cmd_daemon_status ;;
    *)
        echo "Usage: $0 {discover|check_update|get_image|get_digest|daemon_status} [container_name]"
        exit 1
        ;;
esac
