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
################################################################################

set -eu

function internal_helm {
    echo $@
}

function render {
    local RENDER_FILENAME_GENERATOR=
    local RENDER_FILENAME_PATTERN='(.metadata.namespace // "_cluster") + "/" + (.kind // "_unknown") + (("." + ((.apiVersion // "v1") | sub("^(?:(.*)/)?(?:v.*)$", "${1}"))) | sub("^\.$", "")) + "_" + (.metadata.name // "_unknown") + ".yaml"'
    if [[ -f "${SOURCE}/kube-renderer.yaml" ]]; then
        local RENDER_FILENAME_GENERATOR_CFG="$(yq eval '.render_filename_generator' "${SOURCE}/kube-renderer.yaml" | sed 's/null//')"
        local RENDER_FILENAME_PATTERN_CFG="$(yq eval '.render_filename_pattern' "${SOURCE}/kube-renderer.yaml" | sed 's/null//')"

        if [[ -n "${RENDER_FILENAME_GENERATOR_CFG}" ]]; then
            RENDER_FILENAME_GENERATOR="${RENDER_FILENAME_GENERATOR_CFG}"
        fi

        if [[ -n "${RENDER_FILENAME_PATTERN_CFG}" ]]; then
            RENDER_FILENAME_PATTERN="${RENDER_FILENAME_PATTERN_CFG}"
        fi
    fi

    local INPUT=
    if [[ -f "${SOURCE}/helmfile.yaml" ]]; then
        INPUT="-f ${SOURCE}/helmfile.yaml"
    elif [[ -d "${SOURCE}/helmfile.d" ]]; then
        INPUT="-f ${SOURCE}/helmfile.d"
    fi

    local VALUES=
    if [[ -f "${SOURCE}" ]]; then
        VALUES="--state-values-file ${VALUES}"
    fi

    local TMPDIR=$(mktemp -d /tmp/kube-renderer.XXXXXXXXXX)

    # Output to plain file lost information about helm release
    helmfile ${INPUT} ${VALUES} template --output-dir "${TMPDIR}/helmfile" --output-dir-template '{{ .OutputDir }}/{{ .Release.Name }}'

    for APP in $(find "${TMPDIR}/helmfile/" -mindepth 1 -maxdepth 1 -type d | sed "s|^${TMPDIR}/helmfile/||"); do
        mkdir -p "${TMPDIR}/kustomize/${APP}" "${TMPDIR}/kustomized/${APP}" "${TMPDIR}/final/${APP}"
        find ${TMPDIR}/helmfile/${APP}/ -type f | xargs yq eval '.' > "${TMPDIR}/kustomize/${APP}/resources.yaml"
        cat >${TMPDIR}/kustomize/${APP}/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- resources.yaml
EOF

        if [[ -z "${RENDER_FILENAME_GENERATOR}" ]]; then
            kustomize build "${TMPDIR}/kustomize/${APP}" > "${TMPDIR}/final/${APP}/${APP}.yaml"
        else
            kustomize build "${TMPDIR}/kustomize/${APP}" -o "${TMPDIR}/kustomized/${APP}/"

            if [[ "kustomize" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                cp -r "${TMPDIR}/kustomized/${APP}/"* "${TMPDIR}/final/${APP}/"
            elif [[ "yq" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                for FILE in $(find "${TMPDIR}/kustomized/${APP}/" -type f | sed "s|^${TMPDIR}/kustomized/${APP}/||"); do
                    NEWFILE=$(yq eval -N "${RENDER_FILENAME_PATTERN}" "${TMPDIR}/kustomized/${APP}/${FILE}")
                    mkdir -p "$(dirname ${TMPDIR}/final/${APP}/${NEWFILE})"
                    cp "${TMPDIR}/kustomized/${APP}/${FILE}" "${TMPDIR}/final/${APP}/${NEWFILE}"
                done
            fi
        fi
    done

    cp -r "${TMPDIR}/final/"* "${TARGET}/"
    rm -rf "${TMPDIR}"
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
            -V | --version )              version;                 exit;;
            -h | --help )                 usage;                   exit;;
            * )                           args+=("$1")             # others add to positional arguments
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
render
