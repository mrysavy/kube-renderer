#!/usr/bin/env bash

################################################################################
##### kube-renderer version <KUBE_RENDERER_VERSION>
################################################################################
##### Author: Michal Rysavy
##### Licensed under GNU GENERAL PUBLIC LICENSE Version 3
################################################################################

set -eu

function render {
    if [[ -f "./input/helmfile.yaml" || -d "./input/helmfile.d" ]]; then
        render_helmfile
    elif [[ -f "./input/Chart.yaml" ]]; then
        if [[ -f "./input/post-renderer.sh" ]]; then
            render_helm_postrender
        elif [[ -f "./input/kustomization.yaml" ]]; then
            render_helm_kustomize
        else
            render_helm
        fi
    elif [[ -f "./input/kustomization.yaml" ]]; then
        render_kustomize
    else
        render_plain
    fi
}

function render_helmfile {
    local GLOBAL_OPTIONS=''
    if [[ -f "${GLOBAL}" ]]; then
        GLOBAL_OPTIONS+=" --state-values-file ../${GLOBAL}"
    fi

    local INPUT=./input/helmfile.yaml

    if [[ ! -f ./input/helmfile.yaml && -d ./input/helmfile.d ]]; then
        INPUT=./input/helmfile.d
    fi

    if [[ -n "${NAMESPACE}" ]]; then
       GLOBAL_OPTIONS+=" -n ${NAMESPACE}"
    fi

    if [[ -n "${OUTPUT}" && "${OUTPUT}" == 'HELM' ]]; then
        helmfile -f "${INPUT}" ${GLOBAL_OPTIONS} template --output-dir ./output/ --output-dir-template '{{ .OutputDir }}/{{ .Release.Name }}'
    else
        helmfile -f "${INPUT}" ${GLOBAL_OPTIONS} template > "./output/${APP}.yaml"
    fi
}

function render_helm {
    cp -pr input input_gomplate

    if [[ -f "${GLOBAL}" ]]; then
        if [[ -f './input/values.yaml' ]]; then
            gomplate -c .=<(yq eval '{ "values": . }' ${GLOBAL})?type=application/yaml -f ./input/values.yaml -o ./input_gomplate/values.yaml
        fi
    fi

    local OPTIONS='--repository-config <(echo)'

    if [[ -n "${NAMESPACE}" ]]; then
        OPTIONS+=" --namespace ${NAMESPACE}"
    fi

    helm --repository-config <(echo) dependency update ./input_gomplate
    if [[ -n "${OUTPUT}" && "${OUTPUT}" == 'HELM' ]]; then
        helm template ${OPTIONS} "${APP}" ./input_gomplate --output-dir ./output/
    else
        helm template ${OPTIONS} "${APP}" ./input_gomplate > "output/${APP}.yaml"
    fi
}

function render_helm_postrender {
    local OPTIONS='--repository-config <(echo)'

    if [[ -n "${NAMESPACE}" ]]; then
        OPTIONS+=" --namespace ${NAMESPACE}"
    fi

    chmod +x ./input/post-renderer.sh

    helm --repository-config <(echo) dependency update ./input
    if [[ -n "${OUTPUT}" && "${OUTPUT}" == 'HELM' ]]; then
        helm ${OPTIONS} template "${APP}" ./input --post-renderer ./input/post-renderer.sh --output-dir ./output/
    else
        helm ${OPTIONS} template "${APP}" ./input --post-renderer ./input/post-renderer.sh > "./output/${APP}.yaml"
    fi
}

function render_helm_kustomize {
    local OPTIONS='--repository-config <(echo)'

    if [[ -n "${NAMESPACE}" ]]; then
        OPTIONS+=" --namespace ${NAMESPACE}"
    fi

    yq -i eval '(.resources[] | select(. == "<HELM>")) = "helm.yaml"' ./input/kustomization.yaml

    cat >./input/post-renderer.sh <<EOF
#!/bin/sh -e
set -eu
cat <&0 > ./input/helm.yaml
kustomize build ./input
EOF
    chmod +x ./input/post-renderer.sh

    helm --repository-config <(echo) dependency update ./input
    if [[ -n "${OUTPUT}" && "${OUTPUT}" == 'HELM' ]]; then
        helm ${OPTIONS} template "${APP}" ./input --post-renderer ./input/post-renderer.sh --output-dir ./output/
    else
        helm ${OPTIONS} template "${APP}" ./input --post-renderer ./input/post-renderer.sh > "./output/${APP}.yaml"
    fi
}

function render_kustomize {
    cp -pr input input_gomplate

    if [[ -f "${GLOBAL}" ]]; then
        if [[ -d './input' ]]; then
            gomplate -c .=<(yq eval '{ "values": . }' ${GLOBAL})?type=application/yaml --input-dir ./input --output-dir ./input_gomplate
        fi
    fi

    local OPTIONS='--enable-helm'

    cd ./input_gomplate
    if [[ -n "${NAMESPACE}" ]]; then
        kustomize edit set namespace "${NAMESPACE}"
    fi

    kustomize build ${OPTIONS} . -o "../output/${APP}.yaml"
}

function render_plain {
    if [[ -n "${NAMESPACE}" ]]; then
        find ./input -type f | sort | xargs -r -L1 yq eval ".metadata.namespace = \"${NAMESPACE}\"" -i
    fi

    if [[ -n "${OUTPUT}" && "${OUTPUT}" == 'RAW' ]]; then
        cp -pr input/* output/
    else
        find ./input -type f | sort | xargs -r yq eval '.' > "./output/${APP}.yaml"
    fi
}

function kustomize_output {
    cat >./output/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ${APP}.yaml
EOF

kustomize build ./output -o ./output_kustomized
}

function yq_output {
    yq eval-all '[.metadata.namespace // "_global"] | unique | join ";"' "./output/${APP}.yaml" | tr -d '\n' | xargs -d';' -r -I'{}' mkdir ./output_yq/{}
    yq eval -N -s '"./output_yq/" + (.metadata.namespace // "_global") + "/" + (.kind // "_unknown") + (("." + ((.apiVersion // "v1") | sub("^(?:(.*)/)?(?:v.*)$", "${1}"))) | sub("^\.$", "")) + "_" + (.metadata.name // "_unknown") + ".yaml"' "./output/${APP}.yaml"

    for FILE in $(find ./output_yq/ -name '*.yaml.yml'); do
        mv "${FILE}" "${FILE%.yml}"
    done
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

ROOTDIR=$(pwd)
CONFIG=kube-renderer.yaml
GLOBAL=values.yaml

TGTDIR=$(readlink -f ${TARGET})
TMPDIR=$(mktemp -d /tmp/kube-renderer.XXXXXXXXXX)

if [[ -f "${SOURCE}/${CONFIG}" ]]; then
    for APP in $(find "${SOURCE}" -mindepth 1 -maxdepth 1 -type d ! -name '.*'); do
        APP=${APP#${SOURCE}/}

        cd "${ROOTDIR}"

        if [[ "null" != "$(yq eval '._apps' "${SOURCE}/${CONFIG}" 2>/dev/null)" && "${APP}" != "$(yq eval "._apps[] | select(. == \"${APP}\")" "${SOURCE}/${CONFIG}" 2>/dev/null)" ]]; then
            continue
        else
            mkdir -p "${TMPDIR}/${APP}"

            yq eval ". *+ { \"_global\": {} } *+ { \"${APP}\": {} } | ._global *+ .${APP}" "${SOURCE}/${CONFIG}" > "${TMPDIR}/${APP}/config"

            OUTPUT=$(yq eval '.output' "${TMPDIR}/${APP}/config" 2>/dev/null | sed 's/null//')
            OUTPUT=${OUTPUT:-""}

            NAMESPACE=$(yq eval '.namespace' "${TMPDIR}/${APP}/config" 2>/dev/null | sed 's/null//')
            NAMESPACE=${NAMESPACE:-""}

            cp -pr "${SOURCE}/${APP}" "${TMPDIR}/${APP}/input"
            mkdir "${TMPDIR}/${APP}/output"

            if [[ -f "${SOURCE}/${GLOBAL}" ]]; then
                cp "${SOURCE}/${GLOBAL}" "${TMPDIR}/${APP}/${GLOBAL}"
            fi

            cd "${TMPDIR}/${APP}"
            render
            cd "${TMPDIR}/${APP}"

            if [[ -n "${OUTPUT}" && "${OUTPUT}" == 'KUSTOMIZE' ]]; then
                mkdir "${TMPDIR}/${APP}/output_kustomized"
                kustomize_output
                cp -pr "${TMPDIR}/${APP}/output_kustomized" "${TGTDIR}/${APP}"
            elif [[ -n "${OUTPUT}" && "${OUTPUT}" == 'YQ' ]]; then
                mkdir "${TMPDIR}/${APP}/output_yq"
                yq_output
                cp -pr "${TMPDIR}/${APP}/output_yq" "${TGTDIR}/${APP}"
            else
                cp -pr "${TMPDIR}/${APP}/output" "${TGTDIR}/${APP}"
            fi
        fi
    done
fi

rm -rf "${TMPDIR}"
