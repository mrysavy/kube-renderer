#!/usr/bin/env bash

################################################################################
##### kube-renderer version <KUBE_RENDERER_VERSION>
################################################################################
##### Author: Michal Rysavy
##### Licensed under GNU GENERAL PUBLIC LICENSE Version 3
################################################################################
##### Requirements:
##### * bash (required)
##### * helmfile (required)
##### * yq v4 (required)
##### * helm v3 (required)
##### * kustomize (required)
##### * gomplate (optional)
################################################################################

set -eu -o pipefail

function internal_helm() {
    local HELMBINARY=$1; shift;
    if [[ -z "${HELMBINARY}" ]]; then
        HELMBINARY=helm
    fi
    local TMPDIR=$1; shift;

    if [[ "version" == "$1" ]]; then
        exec "${HELMBINARY}" "$@"
    elif [[ "template" == "$1" ]]; then
        local HELMOUTPUTDIR; HELMOUTPUTDIR="$(echo "$@" | sed -E 's/.*--output-dir[=\ ](\S+).*/\1/')"
        local APP; APP="$(echo "$@" | sed -E 's/template(\ --\S+)*\ (\S+)\ .*/\2/')"

        local HELMSOURCEDIR; HELMSOURCEDIR="$(echo "$@" | sed -E 's/^.*template\ +'"${APP}"'\ +(\S+).*$/\1/')"

        local ARG_KUBE_VERSION=()
        if [[ -f "${TMPDIR}/source/kubeversion-${APP}" ]]; then
            ARG_KUBE_VERSION=("--kube-version" "$(cat "${TMPDIR}/source/kubeversion-${APP}")")
        elif [[ -f "${TMPDIR}/source/kubeversion" ]]; then
            ARG_KUBE_VERSION=("--kube-version" "$(cat "${TMPDIR}/source/kubeversion")")
        fi

        local ARGS=()
        if [[ -f "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" ]]; then
            local HOOKS; HOOKS=$(yq eval '.flags.hooks // false' "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml")
            if [[ ! "${HOOKS}" == "true" ]]; then
                ARGS+=("--no-hooks")
            fi
            local CRDS; CRDS=$(yq eval '.flags.crds == false | not' "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml")
            if [[ ! "${CRDS}" == "false" ]]; then
                ARGS+=("--include-crds")
            fi
        fi

        if [[ -n "${HELMOUTPUTDIR}" && "${HELMOUTPUTDIR}" =~ ^.*helmx\.[[:digit:]]+\.rendered$ ]]; then
            "${HELMBINARY}" "${ARG_KUBE_VERSION[@]}" "$@" "${ARGS[@]}"

            for FILE in $(find "${HELMOUTPUTDIR}/" -type f | sort | sed "s|^${HELMOUTPUTDIR}/||"); do
                sed -i "\|# Source: ${FILE}|{d;}" "${HELMOUTPUTDIR}/${FILE}"
            done
        else
            if yq eval -e 'select(.metadata.annotations."helm.sh/hook" != "*")' "${HELMSOURCEDIR}/files/templates/patched_resources.yaml" &>/dev/null && yq eval -e 'select(.metadata.annotations."helm.sh/hook" == "*")' "${HELMSOURCEDIR}/files/templates/patched_resources.yaml" &>/dev/null; then
                sed 's|files/templates/patched_resources.yaml|files/templates/patched_resources_res.yaml|'   "${HELMSOURCEDIR}/templates/patched_resources.yaml" > "${HELMSOURCEDIR}/templates/patched_resources_res.yaml"
                sed 's|files/templates/patched_resources.yaml|files/templates/patched_resources_hooks.yaml|' "${HELMSOURCEDIR}/templates/patched_resources.yaml" > "${HELMSOURCEDIR}/templates/patched_resources_hooks.yaml"

                mkdir \
                    "${HELMSOURCEDIR}/files/templates/patched_resources_temp_res" \
                    "${HELMSOURCEDIR}/files/templates/patched_resources_temp_hooks"

                # shellcheck disable=SC2016
                yq eval 'select(.metadata.annotations."helm.sh/hook" != "*")' -s '"'"${HELMSOURCEDIR}/files/templates/patched_resources_temp_res/"'"   + $index' "${HELMSOURCEDIR}/files/templates/patched_resources.yaml"
                # shellcheck disable=SC2016
                yq eval 'select(.metadata.annotations."helm.sh/hook" == "*")' -s '"'"${HELMSOURCEDIR}/files/templates/patched_resources_temp_hooks/"'" + $index' "${HELMSOURCEDIR}/files/templates/patched_resources.yaml"

                find "${HELMSOURCEDIR}/files/templates/patched_resources_temp_res/"   -type f -printf "%f\n" | sort -n | sed "s|^|${HELMSOURCEDIR}/files/templates/patched_resources_temp_res/|"   | xargs yq eval 'select(length!=0)' <(echo -n '') > "${HELMSOURCEDIR}/templates/patched_resources_res.yaml"
                find "${HELMSOURCEDIR}/files/templates/patched_resources_temp_hooks/" -type f -printf "%f\n" | sort -n | sed "s|^|${HELMSOURCEDIR}/files/templates/patched_resources_temp_hooks/|" | xargs yq eval 'select(length!=0)' <(echo -n '') > "${HELMSOURCEDIR}/templates/patched_resources_hooks.yaml"

                rm -f \
                    "${HELMSOURCEDIR}/templates/patched_resources.yaml" \
                    "${HELMSOURCEDIR}/files/templates/patched_resources.yaml"
                rm -rf \
                    "${HELMSOURCEDIR}/files/templates/patched_resources_temp_res" \
                    "${HELMSOURCEDIR}/files/templates/patched_resources_temp_hooks"
            fi

            exec "${HELMBINARY}" "${ARG_KUBE_VERSION[@]}" "$@" "${ARGS[@]}"
        fi
    else
        exec "${HELMBINARY}" "$@"
    fi
}

function render {
    cp -r "${SOURCE}" "${TMPDIR}/source"

    local INPUT=()
    local HELMBINARY=
    if [[ -f "${SOURCE}/helmfile.yaml" ]]; then
        INPUT=("-f" "${TMPDIR}/source/helmfile.yaml")
        HELMBINARY="$(yq eval '.helmBinary' "${TMPDIR}/source/helmfile.yaml" | sed 's/null//')"
    elif [[ -d "${SOURCE}/helmfile.d" ]]; then
        INPUT=("-f" "${TMPDIR}/source/helmfile.d")
    fi

    cat > "${TMPDIR}/helm-internal" <<EOF
#!/usr/bin/env bash
exec "$(readlink -f "$0")" --internal-helm "${HELMBINARY}" "${TMPDIR}" "\$@"
EOF
    chmod +x "${TMPDIR}/helm-internal"

    local STATE_VALUES=()
    if [[ -f "${TMPDIR}/source/values.yaml" ]]; then
        STATE_VALUES=("--state-values-file" "./values.yaml")

        while IFS= read -r -d '' FILE; do
            gomplate -c .=<(yq eval '{ "StateValues": . }' "${TMPDIR}/source/values.yaml" </dev/zero)?type=application/yaml -f "${FILE}" -o "${FILE%.tmpl}"    # newer yq version consumes stdin even when input file is specified
            rm "${FILE}"
        done < <(find "${TMPDIR}/source" -type f -name '*.tmpl' -print0)
    fi

    mkdir -p "${TMPDIR}/helmfile-values"
    CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify/values"  helmfile "${INPUT[@]}" "${STATE_VALUES[@]}" --helm-binary "${TMPDIR}/helm-internal" write-values --output-file-template "${TMPDIR}/helmfile-values/{{ .Release.Name }}.yaml"
    CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify/build"   helmfile "${INPUT[@]}" "${STATE_VALUES[@]}" --helm-binary "${TMPDIR}/helm-internal" build | yq eval '.releases[]' -s '"'"${TMPDIR}/helmfile-values/"'" + .name + "-metadata.yaml"'
    CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify/global"  helmfile "${INPUT[@]}" "${STATE_VALUES[@]}" --helm-binary "${TMPDIR}/helm-internal" build --embed-values > "${TMPDIR}/helmfile-values/globals.yaml"
    rm -rf "${TMPDIR}/helmfile-temp-chartify"

    # shellcheck disable=SC2016
    yq eval-all -N -s '"'"${TMPDIR}/helmfile-values/global-"'" + $index' "${TMPDIR}/helmfile-values/globals.yaml"

    for GLOBAL in $(find "${TMPDIR}/helmfile-values/" -name 'global-*.yml' -printf "%f\n" | sort -V); do
        for APP in $(yq eval '.releases[].name' "${TMPDIR}/helmfile-values/${GLOBAL}"); do
            # shellcheck disable=SC2016
            yq eval-all '((select(fileIndex == 0) | .renderedvalues) * select(fileIndex == 1)) | del(.".*")'        "${TMPDIR}/helmfile-values/${GLOBAL}" "${TMPDIR}/helmfile-values/${APP}.yaml" | sed 's/^null$/{}/' | yq eval-all '. as $item ireduce ({}; . * $item)' | sed '/^---$/ {d;}' > "${TMPDIR}/helmfile-values/${APP}-values.yaml"
            # shellcheck disable=SC2016
            yq eval-all '((select(fileIndex == 0) | .renderedvalues) * select(fileIndex == 1)) | .".kube-renderer"' "${TMPDIR}/helmfile-values/${GLOBAL}" "${TMPDIR}/helmfile-values/${APP}.yaml" | sed 's/^null$/{}/' | yq eval-all '. as $item ireduce ({}; . * $item)' | sed '/^---$/ {d;}' > "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml"
        done
    done

    local RENDER_FILENAME_GENERATOR=
    # shellcheck disable=SC2016
    local RENDER_FILENAME_PATTERN='(.metadata.namespace // "_cluster") + "/" + (.kind // "_unknown") + (("." + ((.apiVersion // "v1") | sub("^(?:(.*)/)?(?:v.*)$", "${1}"))) | sub("^\.$", "")) + "_" + (.metadata.name // "_unknown") + ".yaml"'
    local RENDER_FILENAME_GENERATOR_CFG; RENDER_FILENAME_GENERATOR_CFG="$(yq eval '.render_filename_generator' "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | sed 's/null//')"
    local RENDER_FILENAME_PATTERN_CFG; RENDER_FILENAME_PATTERN_CFG="$(yq eval '.render_filename_pattern' "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | sed 's/null//')"

    if [[ -n "${RENDER_FILENAME_GENERATOR_CFG}" ]]; then
        RENDER_FILENAME_GENERATOR="${RENDER_FILENAME_GENERATOR_CFG}"
    fi

    if [[ -n "${RENDER_FILENAME_PATTERN_CFG}" ]]; then
        RENDER_FILENAME_PATTERN="${RENDER_FILENAME_PATTERN_CFG}"
    fi

    # Output to single plain stdout lost information about helm release
    helmfile "${INPUT[@]}" "${STATE_VALUES[@]}" --helm-binary "${TMPDIR}/helm-internal" template --output-dir "${TMPDIR}/helmfile" --output-dir-template '{{ .OutputDir }}/{{ .Release.Name }}'

    declare -A RELEASES
    declare -A DIRS
    for GLOBAL in $(find "${TMPDIR}/helmfile-values/" -name 'global-*.yml' -printf "%f\n" | sort -V); do
        local HELMFILE_DIR; HELMFILE_DIR=$(yq eval '.renderedvalues.".kube-renderer".helmfile_dir' "${TMPDIR}/helmfile-values/${GLOBAL}" | sed 's/null//')
        if [[ -z "${HELMFILE_DIR}" ]]; then
            HELMFILE_DIR="."
        fi

        for APP in $(yq eval '.releases[].name' "${TMPDIR}/helmfile-values/${GLOBAL}"); do
            local TARGET_RELEASE; TARGET_RELEASE=$(yq eval ".target_release" "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | sed 's/null//')
            if [[ -z "${TARGET_RELEASE}" ]]; then
                TARGET_RELEASE="${APP}"

                local TARGET_DIR; TARGET_DIR=$(yq eval ".target_dir" "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | sed 's/null//')
                if [[ -z "${TARGET_DIR}" ]]; then
                    TARGET_DIR="${TARGET_RELEASE}"
                fi
                DIRS["${APP}"]="${HELMFILE_DIR}/${TARGET_DIR}"
            fi
            RELEASES["${APP}"]="${TARGET_RELEASE}"

            mkdir -p "${TMPDIR}/merged/${APP}" "${TMPDIR}/postrendered/${APP}" "${TMPDIR}/combined/${APP}" "${TMPDIR}/final/${APP}"
            find "${TMPDIR}/helmfile/${APP}/" -type f | sort | xargs yq eval 'select(length!=0)' > "${TMPDIR}/merged/${APP}/resources.yaml"

            local POSTRENDERER_TYPE; POSTRENDERER_TYPE=$(yq eval ".helm_postrenderer.type" "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | sed 's/null//')
            case "${POSTRENDERER_TYPE}" in
                "kustomize" ) postrender_kustomize "${APP}";;
                * ) cp "${TMPDIR}/merged/${APP}/resources.yaml" "${TMPDIR}/postrendered/${APP}/resources.yaml"
            esac

            if [[ ! -f "${TMPDIR}/combined/${APP}/resources.yaml" ]]; then
                cp "${TMPDIR}/postrendered/${APP}/resources.yaml" "${TMPDIR}/combined/${APP}/resources.yaml"
            else
                yq eval "${TMPDIR}/combined/${APP}/resources.yaml" "${TMPDIR}/postrendered/${APP}/resources.yaml" > "${TMPDIR}/combined/${APP}/resources.yaml.tmp"
                mv "${TMPDIR}/combined/${APP}/resources.yaml.tmp" "${TMPDIR}/combined/${APP}/resources.yaml"
            fi
        done
    done

    for APP in "${!RELEASES[@]}"; do
        APP="${APP#${TMPDIR}/combined/}"
        if [[ -n "${RENDER_FILENAME_GENERATOR}" ]]; then
            if [[ "kustomize" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                cat > "${TMPDIR}/combined/${APP}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- resources.yaml
EOF
                kustomize build "${TMPDIR}/combined/${APP}" -o "${TMPDIR}/final/${APP}/"
            elif [[ "yq" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                mkdir -p "${TMPDIR}/splitted/${APP}"
                # shellcheck disable=SC2016
                yq eval -N -s '("'"${TMPDIR}/splitted/${APP}/"'"'' + $index) + ".yaml"' "${TMPDIR}/combined/${APP}/resources.yaml"
                for FILE in $(find "${TMPDIR}/splitted/${APP}/" -type f -printf "%f\n" | sort); do
                    local NEWFILE; NEWFILE=$(yq eval -N "${RENDER_FILENAME_PATTERN}" "${TMPDIR}/splitted/${APP}/${FILE}")
                    mkdir -p "$(dirname "${TMPDIR}/final/${APP}/${NEWFILE}")"
                    touch "${TMPDIR}/final/${APP}/${NEWFILE}"
                    yq eval -i '.' "${TMPDIR}/final/${APP}/${NEWFILE}" "${TMPDIR}/splitted/${APP}/${FILE}"
                done
            elif [[ "helm" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                mkdir -p "${TMPDIR}/splitted/${APP}" "${TMPDIR}/reconstructed/${APP}"
                # shellcheck disable=SC2016
                yq eval -N -s '("'"${TMPDIR}/splitted/${APP}/"'"'' + $index) + ".yaml"' "${TMPDIR}/combined/${APP}/resources.yaml"
                for FILE in $(find "${TMPDIR}/splitted/${APP}/" -name '*.yaml.yml' -printf "%f\n" | sort -n); do
                    FILE="${TMPDIR}/splitted/${APP}/${FILE}"
                    local RECONSTRUCTED; RECONSTRUCTED="$(grep -m1 '# Source' "${FILE}" | sed 's/# Source: //')"
                    if [[ -n "${RECONSTRUCTED}" ]]; then
                        mkdir -p "$(dirname "${TMPDIR}/reconstructed/${APP}/${RECONSTRUCTED}")"
                        touch "${TMPDIR}/reconstructed/${APP}/${RECONSTRUCTED}"
                        yq eval -i '.' "${TMPDIR}/reconstructed/${APP}/${RECONSTRUCTED}" "${FILE}"
                    else
                        local NEWFILE="${FILE#${TMPDIR}/splitted/${APP}/}"; NEWFILE="${TMPDIR}/reconstructed/${APP}/${NEWFILE%.yml}"
                        cp "${FILE}" "${NEWFILE}"
                    fi
                done

                cp -r "${TMPDIR}/reconstructed/${APP}/"* "${TMPDIR}/final/${APP}/"
            fi
        else
            cp -r "${TMPDIR}/combined/${APP}/resources.yaml" "${TMPDIR}/final/${APP}/${APP}.yaml"
        fi
    done

    for APP in "${!RELEASES[@]}"; do
        local TARGET_RELEASE=${RELEASES["${APP}"]}
        local TARGET_DIR=${DIRS["${TARGET_RELEASE}"]}
        mkdir -p "${TARGET}/${TARGET_DIR}"
        cp -r "${TMPDIR}/final/${APP}/"* "${TARGET}/${TARGET_DIR}/"
    done

    if [[ -f "${SOURCE}/bootstrap.yaml" ]]; then
        bootstrap
        cp -r "${TMPDIR}/bootstrap" "${TARGET}/bootstrap"
    fi
}

function postrender_kustomize {
    local APP=$1; shift

    yq eval '.helm_postrenderer.data' "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | yq eval '(.resources[] | select(. == "<HELM>")) = "'"${TMPDIR}/merged/${APP}/resources.yaml"'"' - > "${TMPDIR}/merged/${APP}/kustomization.yaml"
    kustomize build "${TMPDIR}/merged/${APP}" > "${TMPDIR}/postrendered/${APP}/resources.yaml"
}

function bootstrap() {
    mkdir -p "${TMPDIR}/bootstrap"

    for GLOBAL in $(find "${TMPDIR}/helmfile-values/" -name 'global-*.yml' -printf "%f\n" | sort -V); do
        for APP in $(yq eval '.releases[].name' "${TMPDIR}/helmfile-values/${GLOBAL}"); do
            local TARGET_RELEASE=${RELEASES["${APP}"]}
            local TARGET_DIR=${DIRS["${TARGET_RELEASE}"]}

            mkdir -p "$(dirname "${TMPDIR}/bootstrap/${TARGET_DIR}")"

            if [[ "${TARGET_RELEASE}" == "${APP}" ]]; then
                # shellcheck disable=SC2016
                gomplate \
                    -c .=<(yq eval-all '. as $item ireduce ({}; . * $item )' \
                        <(yq eval    '{ "Metadata": . }'     "${TMPDIR}/helmfile-values/${APP}-metadata.yaml.yml") \
                        <(yq eval    '{ "Values": . }'       "${TMPDIR}/helmfile-values/${APP}-values.yaml") \
                        <(yq eval    '{ "Kuberenderer": . }' "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml") \
                        )?type=application/yaml -f "${SOURCE}/bootstrap.yaml" -o "${TMPDIR}/bootstrap/${TARGET_DIR}.yaml"
            fi
        done
    done

    # shellcheck disable=SC2016
    gomplate \
        -c .=<(yq eval-all '. as $item ireduce ({}; . * $item )' \
            <(yq eval -n '{ "Metadata": { "name": "bootstrap" } }') \
            <(yq eval -n '{ "Values": {} }') \
            <(yq eval -n '{ "Kuberenderer": {} }') \
            )?type=application/yaml -f "${SOURCE}/bootstrap.yaml" -o "${TMPDIR}/bootstrap/bootstrap.yaml"
}

function usage {
    echo "usage: kube-renderer.sh SOURCE TARGET [-Vh]"
    echo "   ";
    echo "  -V | --version           : Print version info";
    echo "  -h | --help              : This message";
}

function version {
    echo "<KUBE_RENDERER_VERSION>"
}

function parse_args {
    # positional arguments
    args=()

    # named arguments
    set +u
    while [ "$1" != "" ]; do
        case "$1" in
            -V | --version )              version;                       exit;;
            -h | --help )                 usage;                         exit;;
            --internal-helm )             shift; internal_helm "$@";     exit;;
            * )                           args+=("$1")                  # others add to positional arguments
        esac
        shift
    done

    # restore positional arguments
    set -- "${args[@]}"

    SOURCE="${args[0]}"
    TARGET="${args[1]}"
    set -u

    # validity check
    if [[ -z "${SOURCE}" || -z "${TARGET}" ]]; then
        echo "SOURCE & TARGET arguments are required"
        exit 1;
    fi

    if [[ ! -d "${TARGET}" ]]; then
        echo "TARGET must exists"
        exit 1;
    fi

    if [[ -n $(find "${TARGET}" -mindepth 1) ]]; then
        echo "TARGET must be empty"
        exit 1;
    fi
}

parse_args "$@"

TMPDIR=$(mktemp -d /tmp/kube-renderer.XXXXXXXXXX)
trap 'rm -rf -- "$TMPDIR"' EXIT
mkdir "${TMPDIR}/helmfile-temp" "${TMPDIR}/helmfile-temp-chartify"
export HELMFILE_TEMPDIR="${TMPDIR}/helmfile-temp"
export CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify"

render
