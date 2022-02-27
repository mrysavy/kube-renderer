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

    if [[ "version" == "$1" ]]; then
        exec "${HELMBINARY}" "$@"
    elif [[ "template" == "$1" ]]; then
        local HELMOUTPUTDIR; HELMOUTPUTDIR="$(echo "$@" | sed -E 's/.*--output-dir[=\ ](\S+).*/\1/')"
        if [[ -n "${HELMOUTPUTDIR}" && "${HELMOUTPUTDIR}" =~ ^.*helmx\.[[:digit:]]+\.rendered$ ]]; then
            "${HELMBINARY}" "$@"

            for FILE in $(find "${HELMOUTPUTDIR}/" -type f | sort | sed "s|^${HELMOUTPUTDIR}/||"); do
                sed -i "\|# Source: ${FILE}|{d;}" "${HELMOUTPUTDIR}/${FILE}"
            done
        else
            exec "${HELMBINARY}" "$@"
        fi
    else
        exec "${HELMBINARY}" "$@"
    fi
}

function render {
    local RENDER_FILENAME_GENERATOR=
    local RENDER_FILENAME_PATTERN; RENDER_FILENAME_PATTERN='(.metadata.namespace // "_cluster") + "/" + (.kind // "_unknown") + (("." + ((.apiVersion // "v1") | sub("^(?:(.*)/)?(?:v.*)$", "${1}"))) | sub("^\.$", "")) + "_" + (.metadata.name // "_unknown") + ".yaml"'
    if [[ -f "${SOURCE}/kube-renderer.yaml" ]]; then
        local RENDER_FILENAME_GENERATOR_CFG; RENDER_FILENAME_GENERATOR_CFG="$(yq eval '.render_filename_generator' "${SOURCE}/kube-renderer.yaml" | sed 's/null//')"
        local RENDER_FILENAME_PATTERN_CFG; RENDER_FILENAME_PATTERN_CFG="$(yq eval '.render_filename_pattern' "${SOURCE}/kube-renderer.yaml" | sed 's/null//')"

        if [[ -n "${RENDER_FILENAME_GENERATOR_CFG}" ]]; then
            RENDER_FILENAME_GENERATOR="${RENDER_FILENAME_GENERATOR_CFG}"
        fi

        if [[ -n "${RENDER_FILENAME_PATTERN_CFG}" ]]; then
            RENDER_FILENAME_PATTERN="${RENDER_FILENAME_PATTERN_CFG}"
        fi
    fi

    local TMPDIR; TMPDIR=$(mktemp -d /tmp/kube-renderer.XXXXXXXXXX)
    cp -r "${SOURCE}" "${TMPDIR}/source"

    local INPUT=
    local HELMBINARY=
    if [[ -f "${SOURCE}/helmfile.yaml" ]]; then
        INPUT="-f ${TMPDIR}/source/helmfile.yaml"
        HELMBINARY="$(yq eval '.helmBinary' "${TMPDIR}/source/helmfile.yaml" | sed 's/null//')"
    elif [[ -d "${SOURCE}/helmfile.d" ]]; then
        INPUT="-f ${TMPDIR}/source/helmfile.d"
    fi

    local STATE_VALUES=
    if [[ -f "${TMPDIR}/source/values.yaml" ]]; then
        STATE_VALUES="--state-values-file ./values.yaml"

        while IFS= read -r -d '' FILE; do
            gomplate -c .=<(yq eval '{ "Values": . }' "${TMPDIR}/source/values.yaml" </dev/zero)?type=application/yaml -f "${FILE}" -o "${FILE%.gotmpl}"    # newer yq version consumes stdin even when input file is specified
            rm "${FILE}"
        done < <(find "${TMPDIR}/source" -type f -name '*.gotmpl' -print0)
    fi

    cat > "${TMPDIR}/helm-internal" <<EOF
#!/usr/bin/env bash
exec "$(readlink -f "$0")" --internal-helm "${HELMBINARY}" "\$@"
EOF
    chmod +x "${TMPDIR}/helm-internal"

    # Output to plain file lost information about helm release
    helmfile ${INPUT} ${STATE_VALUES} --helm-binary "${TMPDIR}/helm-internal" template --include-crds --output-dir "${TMPDIR}/helmfile" --output-dir-template '{{ .OutputDir }}/{{ .Release.Name }}'

    for APP in $(find "${TMPDIR}/helmfile/" -mindepth 1 -maxdepth 1 -type d | sed "s|^${TMPDIR}/helmfile/||"); do
        mkdir -p "${TMPDIR}/merged/${APP}" "${TMPDIR}/final/${APP}"
        find "${TMPDIR}/helmfile/${APP}/" -type f | sort | xargs yq eval 'select(length!=0)' > "${TMPDIR}/merged/${APP}/resources.yaml"

        if [[ -n "${RENDER_FILENAME_GENERATOR}" ]]; then
            if [[ "kustomize" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                cat > "${TMPDIR}/merged/${APP}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- resources.yaml
EOF
                kustomize build "${TMPDIR}/merged/${APP}" -o "${TMPDIR}/final/${APP}/"
            elif [[ "yq" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                mkdir -p "${TMPDIR}/splitted/${APP}"
                yq eval -N -s '("'"${TMPDIR}/splitted/${APP}/"'"'' + $index) + ".yaml"' "${TMPDIR}/merged/${APP}/resources.yaml"
                for FILE in $(find "${TMPDIR}/splitted/${APP}/" -type f | sort | sed "s|^${TMPDIR}/splitted/${APP}/||"); do
                    local NEWFILE; NEWFILE=$(yq eval -N "${RENDER_FILENAME_PATTERN}" "${TMPDIR}/splitted/${APP}/${FILE}")
                    mkdir -p "$(dirname "${TMPDIR}/final/${APP}/${NEWFILE}")"
                    touch "${TMPDIR}/final/${APP}/${NEWFILE}"
                    yq eval -i '.' "${TMPDIR}/final/${APP}/${NEWFILE}" "${TMPDIR}/splitted/${APP}/${FILE}"
                done
            elif [[ "helm" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                mkdir -p "${TMPDIR}/splitted/${APP}" "${TMPDIR}/reconstructed/${APP}"
                yq eval -N -s '("'"${TMPDIR}/splitted/${APP}/"'"'' + $index) + ".yaml"' "${TMPDIR}/merged/${APP}/resources.yaml"
                for FILE in $(find "${TMPDIR}/splitted/${APP}/" -name '*.yaml.yml' | sort -n); do
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
            cp -r "${TMPDIR}/merged/${APP}/resources.yaml" "${TMPDIR}/final/${APP}/${APP}.yaml"
        fi
    done

    cp -r "${TMPDIR}/final/"* "${TARGET}/"
    if [[ -f "${SOURCE}/bootstrap.yaml" ]]; then
        bootstrap
        cp -r "${TMPDIR}/bootstrap" "${TARGET}/bootstrap"
    fi
    rm -rf "${TMPDIR}"
}

function bootstrap() {
    local INPUT=
    if [[ -f "${SOURCE}/helmfile.yaml" ]]; then
        INPUT="-f ${TMPDIR}/source/helmfile.yaml"
    elif [[ -d "${SOURCE}/helmfile.d" ]]; then
        INPUT="-f ${TMPDIR}/source/helmfile.d"
    fi

    mkdir -p "${TMPDIR}/bootstrap" "${TMPDIR}/bootstrap-values"
    helmfile ${INPUT} write-values --output-file-template "${TMPDIR}/bootstrap-values/{{ .Release.Name }}.yaml"

    yq eval -n '{ "Metadata": { "release": "bootstrap" } }' > "${TMPDIR}/bootstrap-values/bootstrap-metadata.yaml"
    for APP in $(find "${TMPDIR}/final/" -mindepth 1 -maxdepth 1 -type d | sed "s|^${TMPDIR}/final/||"); do
        yq eval -n '{ "Metadata": { "release": "'${APP}'" } }' > "${TMPDIR}/bootstrap-values/${APP}-metadata.yaml"
        gomplate -c .=<(yq eval-all 'select(fileIndex == 0) * { "Values": select(fileIndex == 1) }' "${TMPDIR}/bootstrap-values/${APP}-metadata.yaml" "${TMPDIR}/bootstrap-values/${APP}.yaml")?type=application/yaml -f "${SOURCE}/bootstrap.yaml" -o "${TMPDIR}/bootstrap/${APP}.yaml"
    done

    gomplate -c .="${TMPDIR}/bootstrap-values/bootstrap-metadata.yaml" -f "${SOURCE}/bootstrap.yaml" -o "${TMPDIR}/bootstrap/bootstrap.yaml"
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
render
