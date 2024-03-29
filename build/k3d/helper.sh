#!/usr/bin/env bash
#
set -Eeuo pipefail

main() {
    cmd="$1"
    shift 1

    case "$cmd" in
        setup)
            setup
        ;;
        teardown)
            teardown
        ;;
        load_images)
            load_images "$@"
        ;;
        helm_post_render)
            helm_post_render "$@"
        ;;
        *)
            log::error "Unexpected command '$cmd'."
            exit 1
        ;;
    esac
}

setup() {
    cluster_name="$("$YQ" e '.metadata.name' "$K3D_CONFIG")"

    # check if k3d cluster exists.
    if ! "$K3D" cluster get "$cluster_name" &> /dev/null; then
        log::info "Creating K3d cluster '${cluster_name}'"
        # setup localstorage
        localstorage="$HOME/.please-k8s/k3d/${cluster_name}/storage"
        mkdir -p "$localstorage"
        "$K3D" cluster create --config "$K3D_CONFIG" \
            --network "$cluster_name" \
            --volume "$localstorage:/var/lib/rancher/k3s/storage"
    fi

    log::success "K3d cluster '${cluster_name}' is available"
    "$K3D" kubeconfig merge --kubeconfig-merge-default "${cluster_name}" > /dev/null
    kubernetes_context="k3d-${cluster_name}"
    kubectl config use-context "${kubernetes_context}"
}

teardown() {
    cluster_name="$("$YQ" e '.metadata.name' "$K3D_CONFIG")"

    # check if k3d cluster exists.
    if ! "$K3D" cluster get "$cluster_name" &> /dev/null; then
        log::info "K3d cluster ${cluster_name} doesn't exist"
        exit 1
    fi

    "$K3D" cluster delete "$cluster_name"

    # cleanup localstorage
    localstorage="$HOME/.please-k8s/k3d/${cluster_name}/storage"
    rm -rf "$localstorage"
}

load_images() {
    local image_targets=("$@")
    image_targets+=(${IMAGE_TARGETS:-})

    if [ ${#image_targets[@]} -eq 0 ]; then
        log::info "No images to push."
        exit 0
    fi

    # get registry url from config
    local registry_name="$("$YQ" e '.registries.create.name' "$K3D_CONFIG")"
    if [ "$registry_name" == "null" ]; then
        log::warn "'.registries.create.name' not set in $K3D_CONFIG"
        return
    fi
    local registry_port="$("$YQ" e '.registries.create.hostPort' "$K3D_CONFIG")"
    if [ "$registry_port" == "null" ]; then
        log::warn "'.registries.create.hostPort' not set in $K3D_CONFIG"
        return
    fi

    local registry_url="$registry_name:$registry_port"
    log::info "Pushing ${#image_targets[@]} images..."
    push_targets=("${image_targets[@]/%/_push}")

    # '_push' targets should already be built as '_deploy' includes them as
    # data.
    plz::run_multi -a "$registry_url" "${push_targets[@]}"
}

helm_post_render() {
    export LOG_FILE="plz-out/log/helm_post_render.log"
    mkdir -p "$(dirname $LOG_FILE)"

    log::info "---"
    log::info "Executing helm_post_render..."

    if [ -z "${IMAGE_TARGETS:-}" ]; then
        log::warn "no images passed to update references for"
        local all_yaml="$(mktemp)"
        cat <&0 > "$all_yaml"
        # print out the modified yaml
        cat "$all_yaml"
        rm "$all_yaml"
        exit 0
    fi

    image_targets=($IMAGE_TARGETS)
    image_replace_targets=()
    for trgt in "${image_targets[@]}"; do
        pkg="$(echo "$trgt" | cut -f1 -d:)"
        name="$(echo "$trgt" | cut -f2 -d:)"
        image_replace_targets+=("${pkg}:_${name}#replace")
    done

    # get registry url from config
    local registry_name="$("$YQ" e '.registries.create.name' "$K3D_CONFIG")"
    if [ "$registry_name" == "null" ]; then
        log::warn "'.registries.create.name' not set in $K3D_CONFIG"
        return
    fi
    local registry_port="$("$YQ" e '.registries.create.hostPort' "$K3D_CONFIG")"
    if [ "$registry_port" == "null" ]; then
        log::warn "'.registries.create.hostPort' not set in $K3D_CONFIG"
        return
    fi

    local registry_url="$registry_name:$registry_port"

    local all_yaml="$(mktemp)"
    cat <&0 > "$all_yaml"

    for tool in "${image_replace_targets[@]}"; do
        log::info "running $tool $all_yaml $registry_url"
        >&2 plz::run "$tool" "$all_yaml" "$registry_url"
    done

    # print out the modified yaml
    cat "$all_yaml"
    rm "$all_yaml"
}

plz::run_multi() {
    args=("./pleasew" "run")
    # enable plain output and verbosity on CI builds
    if [[ "${CI:-}" == "true" ]]; then
        args+=("--plain_output" "--verbosity=2")
    fi

    # allow overriding parallel with sequential for slower machines.
    if [ -z "${PLZ_RUN_MODE:-}" ]; then
        PLZ_RUN_MODE="parallel"
    fi
    args+=("$PLZ_RUN_MODE")
    log::info "Executing ${args[*]} $*"
    "${args[@]}" "$@"
}

plz::run() {
    args=("./pleasew" "run")
    # enable plain output and verbosity on CI builds
    if [[ "${CI:-}" == "true" ]]; then
        args+=("--plain_output" "--verbosity=2")
    fi

    log::info "Executing ${args[*]} $*"
    "${args[@]}" "$@"
}

# define utils
log::info() {
    >&2 printf "💡 %s\n" "$@"
    if [ -n "${LOG_FILE:-}" ]; then
        printf "💡 %s\n" "$@" >> "$LOG_FILE"
    fi
}

log::warn() {
    >&2 printf "⚠️ %s\n" "$@"
    if [ -n "${LOG_FILE:-}" ]; then
        printf "⚠️ %s\n" "$@" >> "$LOG_FILE"
    fi
}

log::error() {
   >&2 printf "❌ %s\n" "$@"
   if [ -n "${LOG_FILE:-}" ]; then
        printf "❌ %s\n" "$@" >> "$LOG_FILE"
    fi
}

log::success() {
   >&2 printf "✅ %s\n" "$@"
   if [ -n "${LOG_FILE:-}" ]; then
        printf "✅ %s\n" "$@" >> "$LOG_FILE"
    fi
}

# exec main
main "$@"
