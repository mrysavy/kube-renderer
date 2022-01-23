#!/bin/env /bin/bash

################################################################################
##### kube-renderer version <KUBE_RENDERER_VERSION>
################################################################################

set -eu

function render {
    if [[ -f "./input/helmfile.yaml" ]]; then
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
    cd input
    if [[ -n "${OUTPUT}" && "${OUTPUT}" == 'HELM' ]]; then
        helmfile template --output-dir ../output/ --output-dir-template '{{ .OutputDir }}/{{ .Release.Name }}'
    else
        helmfile template > "../output/${APP}.yaml"
    fi
}

function render_helm {
    helm --repository-config <(echo) dependency update ./input
    if [[ -n "${OUTPUT}" && "${OUTPUT}" == 'HELM' ]]; then
        helm --repository-config <(echo) template "${APP}" ./input --output-dir ./output/
    else
        helm --repository-config <(echo) template "${APP}" ./input > "output/${APP}.yaml"
    fi
}

function render_helm_postrender {
    chmod +x ./input/post-renderer.sh

    helm --repository-config <(echo) dependency update ./input
    if [[ -n "${OUTPUT}" && "${OUTPUT}" == 'HELM' ]]; then
        helm --repository-config <(echo) template "${APP}" ./input --post-renderer ./input/post-renderer.sh --output-dir ./output/
    else
        helm --repository-config <(echo) template "${APP}" ./input --post-renderer ./input/post-renderer.sh > "output/${APP}.yaml"
    fi
}

function render_helm_kustomize {
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
        helm --repository-config <(echo) template "${APP}" ./input --post-renderer ./input/post-renderer.sh --output-dir ./output/
    else
        helm --repository-config <(echo) template "${APP}" ./input --post-renderer ./input/post-renderer.sh > "output/${APP}.yaml"
    fi
}

function render_kustomize {
    local OPTIONS='--enable-helm'

    kustomize build ${OPTIONS} ./input -o "./output/${APP}.yaml"
}

function render_plain {
    cp -pr input/* output/
    rm -f output/kube-renderer.yaml
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

SRCDIR=$(readlink -f ${SOURCE})
ROOTDIR=$(pwd)
CONFIG=kube-renderer.yaml

TGTDIR=$(readlink -f ${TARGET})

TMPDIR=$(mktemp -d /tmp/kube-renderer.XXXXXXXXXX)
for APP in $(find "${SOURCE}" -mindepth 1 -maxdepth 1 -type d ! -name '.*'); do
    APP=${APP#${SOURCE}/}
    cd "${ROOTDIR}"

    if [[ -f "${SOURCE}/${APP}/${CONFIG}" ]]; then
        if yq eval -e '.ignore | select(. == "true")' "${SOURCE}/${APP}/${CONFIG}" &>/dev/null; then
            continue
        else
            OUTPUT=$(yq eval '.output' "${SOURCE}/${APP}/${CONFIG}" 2>/dev/null | sed 's/null//')
            OUTPUT=${OUTPUT:-""}

            mkdir -p "${TMPDIR}/${APP}"
            cp -pr "${SRCDIR}/${APP}" "${TMPDIR}/${APP}/input"
            mkdir "${TMPDIR}/${APP}/output"

            cd "${TMPDIR}/${APP}"
            render

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
    fi
done

rm -rf "${TMPDIR}"
