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

        local ARG_KUBE_VERSION=
        if [[ -f "${TMPDIR}/source/kubeversion-${APP}" ]]; then
            ARG_KUBE_VERSION="--kube-version $(cat ${TMPDIR}/source/kubeversion-${APP})"
        elif [[ -f "${TMPDIR}/source/kubeversion" ]]; then
            ARG_KUBE_VERSION="--kube-version $(cat ${TMPDIR}/source/kubeversion)"
        fi

        local ARG_NO_HOOKS=
        if [[ -f "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" ]]; then
            local NO_HOOKS=$(yq eval '.flags[] | select(. == "nohooks")' "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml")
            if [[ -n "${NO_HOOKS}" ]]; then
                ARG_NO_HOOKS="--no-hooks"
            fi
        fi

        if [[ -n "${HELMOUTPUTDIR}" && "${HELMOUTPUTDIR}" =~ ^.*helmx\.[[:digit:]]+\.rendered$ ]]; then
            "${HELMBINARY}" ${ARG_KUBE_VERSION} "$@" ${ARG_NO_HOOKS}

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

                yq eval 'select(.metadata.annotations."helm.sh/hook" != "*")' -s '"'"${HELMSOURCEDIR}/files/templates/patched_resources_temp_res/"'"   + $index' "${HELMSOURCEDIR}/files/templates/patched_resources.yaml"
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

            exec "${HELMBINARY}" ${ARG_KUBE_VERSION} "$@" ${ARG_NO_HOOKS}
        fi
    else
        exec "${HELMBINARY}" "$@"
    fi
}

function render {
    cp -r "${SOURCE}" "${TMPDIR}/source"

    local INPUT=
    local HELMBINARY=
    if [[ -f "${SOURCE}/helmfile.yaml" ]]; then
        INPUT="-f ${TMPDIR}/source/helmfile.yaml"
        HELMBINARY="$(yq eval '.helmBinary' "${TMPDIR}/source/helmfile.yaml" | sed 's/null//')"
    elif [[ -d "${SOURCE}/helmfile.d" ]]; then
        INPUT="-f ${TMPDIR}/source/helmfile.d"
    fi

    cat > "${TMPDIR}/helm-internal" <<EOF
#!/usr/bin/env bash
exec "$(readlink -f "$0")" --internal-helm "${HELMBINARY}" "${TMPDIR}" "\$@"
EOF
    chmod +x "${TMPDIR}/helm-internal"

    local STATE_VALUES=
    if [[ -f "${TMPDIR}/source/values.yaml" ]]; then
        STATE_VALUES="--state-values-file ./values.yaml"

        while IFS= read -r -d '' FILE; do
            gomplate -c .=<(yq eval '{ "Values": . }' "${TMPDIR}/source/values.yaml" </dev/zero)?type=application/yaml -f "${FILE}" -o "${FILE%.tmpl}"    # newer yq version consumes stdin even when input file is specified
            rm "${FILE}"
        done < <(find "${TMPDIR}/source" -type f -name '*.tmpl' -print0)
    fi

    mkdir -p "${TMPDIR}/helmfile-values"
    CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify/values"  helmfile ${INPUT} ${STATE_VALUES} --helm-binary "${TMPDIR}/helm-internal" write-values --output-file-template "${TMPDIR}/helmfile-values/{{ .Release.Name }}.yaml"
    CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify/build"   helmfile ${INPUT} ${STATE_VALUES} --helm-binary "${TMPDIR}/helm-internal" build | yq eval '.releases[]' -s '"'"${TMPDIR}/helmfile-values/"'" + .name + "-metadata.yaml"'
    CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify/global"  helmfile ${INPUT} ${STATE_VALUES} --helm-binary "${TMPDIR}/helm-internal" build --embed-values > "${TMPDIR}/helmfile-values/global.yaml"
    rm -rf "${TMPDIR}/helmfile-temp-chartify"

    for APP in $(yq eval '.releases[].name' "${TMPDIR}/helmfile-values/global.yaml"); do
        yq eval-all '((select(fileIndex == 0) | .renderedvalues) * select(fileIndex == 1)) | del(.".kube-renderer")' "${TMPDIR}/helmfile-values/global.yaml" "${TMPDIR}/helmfile-values/${APP}.yaml" | sed 's/^null$//' > "${TMPDIR}/helmfile-values/${APP}-values.yaml"
        yq eval-all '((select(fileIndex == 0) | .renderedvalues) * select(fileIndex == 1)) | .".kube-renderer"'      "${TMPDIR}/helmfile-values/global.yaml" "${TMPDIR}/helmfile-values/${APP}.yaml" | sed 's/^null$//' > "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml"
    done

    local RENDER_FILENAME_GENERATOR=
    local RENDER_FILENAME_PATTERN='(.metadata.namespace // "_cluster") + "/" + (.kind // "_unknown") + (("." + ((.apiVersion // "v1") | sub("^(?:(.*)/)?(?:v.*)$", "${1}"))) | sub("^\.$", "")) + "_" + (.metadata.name // "_unknown") + ".yaml"'
    local RENDER_FILENAME_GENERATOR_CFG="$(yq eval '.render_filename_generator' "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | sed 's/null//')"
    local RENDER_FILENAME_PATTERN_CFG="$(yq eval '.render_filename_pattern' "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | sed 's/null//')"

    if [[ -n "${RENDER_FILENAME_GENERATOR_CFG}" ]]; then
        RENDER_FILENAME_GENERATOR="${RENDER_FILENAME_GENERATOR_CFG}"
    fi

    if [[ -n "${RENDER_FILENAME_PATTERN_CFG}" ]]; then
        RENDER_FILENAME_PATTERN="${RENDER_FILENAME_PATTERN_CFG}"
    fi

    # Output to single plain stdout lost information about helm release
    helmfile ${INPUT} ${STATE_VALUES} --helm-binary "${TMPDIR}/helm-internal" template --include-crds --output-dir "${TMPDIR}/helmfile" --output-dir-template '{{ .OutputDir }}/{{ .Release.Name }}'

    for APP in $(yq eval '.releases[].name' "${TMPDIR}/helmfile-values/global.yaml"); do
        local TARGET_RELEASE=$(yq eval ".target_release" "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | sed 's/null//')
        if [[ -z "${TARGET_RELEASE}" ]]; then
            TARGET_RELEASE="${APP}"
        fi

        mkdir -p "${TMPDIR}/merged/${APP}" "${TMPDIR}/postrendered/${APP}" "${TMPDIR}/combined/${TARGET_RELEASE}" "${TMPDIR}/final/${TARGET_RELEASE}"
        find "${TMPDIR}/helmfile/${APP}/" -type f | sort | xargs yq eval 'select(length!=0)' > "${TMPDIR}/merged/${APP}/resources.yaml"

        local POSTRENDERER_TYPE=$(yq eval ".helm_postrenderer.type" "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | sed 's/null//')
        case "${POSTRENDERER_TYPE}" in
            "kustomize" ) postrender_kustomize "${APP}";;
            * ) cp "${TMPDIR}/merged/${APP}/resources.yaml" "${TMPDIR}/postrendered/${APP}/resources.yaml"
        esac

        if [[ ! -f "${TMPDIR}/combined/${TARGET_RELEASE}/resources.yaml" ]]; then
            cp "${TMPDIR}/postrendered/${APP}/resources.yaml" "${TMPDIR}/combined/${TARGET_RELEASE}/resources.yaml"
        else
            yq eval "${TMPDIR}/combined/${TARGET_RELEASE}/resources.yaml" "${TMPDIR}/postrendered/${APP}/resources.yaml" > "${TMPDIR}/combined/${TARGET_RELEASE}/resources.yaml.tmp"
            mv "${TMPDIR}/combined/${TARGET_RELEASE}/resources.yaml.tmp" "${TMPDIR}/combined/${TARGET_RELEASE}/resources.yaml"
        fi
    done

    for TARGET_RELEASE in "${TMPDIR}/combined/"*; do
        TARGET_RELEASE="${TARGET_RELEASE#${TMPDIR}/combined/}"
        if [[ -n "${RENDER_FILENAME_GENERATOR}" ]]; then
            if [[ "kustomize" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                cat > "${TMPDIR}/combined/${TARGET_RELEASE}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- resources.yaml
EOF
                kustomize build "${TMPDIR}/combined/${TARGET_RELEASE}" -o "${TMPDIR}/final/${TARGET_RELEASE}/"
            elif [[ "yq" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                mkdir -p "${TMPDIR}/splitted/${TARGET_RELEASE}"
                yq eval -N -s '("'"${TMPDIR}/splitted/${TARGET_RELEASE}/"'"'' + $index) + ".yaml"' "${TMPDIR}/combined/${TARGET_RELEASE}/resources.yaml"
                for FILE in $(find "${TMPDIR}/splitted/${TARGET_RELEASE}/" -type f -printf "%f\n" | sort); do
                    local NEWFILE; NEWFILE=$(yq eval -N "${RENDER_FILENAME_PATTERN}" "${TMPDIR}/splitted/${TARGET_RELEASE}/${FILE}")
                    mkdir -p "$(dirname "${TMPDIR}/final/${TARGET_RELEASE}/${NEWFILE}")"
                    touch "${TMPDIR}/final/${TARGET_RELEASE}/${NEWFILE}"
                    yq eval -i '.' "${TMPDIR}/final/${TARGET_RELEASE}/${NEWFILE}" "${TMPDIR}/splitted/${TARGET_RELEASE}/${FILE}"
                done
            elif [[ "helm" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                mkdir -p "${TMPDIR}/splitted/${TARGET_RELEASE}" "${TMPDIR}/reconstructed/${TARGET_RELEASE}"
                yq eval -N -s '("'"${TMPDIR}/splitted/${TARGET_RELEASE}/"'"'' + $index) + ".yaml"' "${TMPDIR}/combined/${TARGET_RELEASE}/resources.yaml"
                for FILE in $(find "${TMPDIR}/splitted/${TARGET_RELEASE}/" -name '*.yaml.yml' -printf "%f\n" | sort -n); do
                    FILE="${TMPDIR}/splitted/${TARGET_RELEASE}/${FILE}"
                    local RECONSTRUCTED; RECONSTRUCTED="$(grep -m1 '# Source' "${FILE}" | sed 's/# Source: //')"
                    if [[ -n "${RECONSTRUCTED}" ]]; then
                        mkdir -p "$(dirname "${TMPDIR}/reconstructed/${TARGET_RELEASE}/${RECONSTRUCTED}")"
                        touch "${TMPDIR}/reconstructed/${TARGET_RELEASE}/${RECONSTRUCTED}"
                        yq eval -i '.' "${TMPDIR}/reconstructed/${TARGET_RELEASE}/${RECONSTRUCTED}" "${FILE}"
                    else
                        local NEWFILE="${FILE#${TMPDIR}/splitted/${TARGET_RELEASE}/}"; NEWFILE="${TMPDIR}/reconstructed/${TARGET_RELEASE}/${NEWFILE%.yml}"
                        cp "${FILE}" "${NEWFILE}"
                    fi
                done

                cp -r "${TMPDIR}/reconstructed/${TARGET_RELEASE}/"* "${TMPDIR}/final/${TARGET_RELEASE}/"
            fi
        else
            cp -r "${TMPDIR}/combined/${TARGET_RELEASE}/resources.yaml" "${TMPDIR}/final/${TARGET_RELEASE}/${TARGET_RELEASE}.yaml"
        fi
    done

    cp -r "${TMPDIR}/final/"* "${TARGET}/"
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

    for APP in $(yq eval '.releases[].name' "${TMPDIR}/helmfile-values/global.yaml"); do
        local TARGET_RELEASE=$(yq eval ".target_release" "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml" | sed 's/null//')
        if [[ -z "${TARGET_RELEASE}" ]]; then
            TARGET_RELEASE="${APP}"
        fi

        if [[ "${TARGET_RELEASE}" == "${APP}" ]]; then
            gomplate \
                -c .=<(yq eval-all '. as $item ireduce ({}; . * $item )' \
                    <(yq eval    '{ "Metadata": . }'     "${TMPDIR}/helmfile-values/${APP}-metadata.yaml.yml") \
                    <(yq eval    '{ "Values": . }'       "${TMPDIR}/helmfile-values/${APP}-values.yaml") \
                    <(yq eval -n '{ "Global": {} }') \
                    <(yq eval    '{ "Kuberenderer": . }' "${TMPDIR}/helmfile-values/${APP}-kuberenderer.yaml") \
                    )?type=application/yaml -f "${SOURCE}/bootstrap.yaml" -o "${TMPDIR}/bootstrap/${APP}.yaml"
        fi
    done

    gomplate \
        -c .=<(yq eval-all '. as $item ireduce ({}; . * $item )' \
            <(yq eval -n '{ "Metadata": { "name": "bootstrap" } }') \
            <(yq eval -n '{ "Values": {} }') \
            <(yq eval    '{ "Global": {} }' "${TMPDIR}/helmfile-values/global.yaml") \
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
