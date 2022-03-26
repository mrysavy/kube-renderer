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
    if [[ "${DEBUG_MODE}" == "true" ]]; then
        set -x
    fi

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
        local FIX_HOOKS=""
        if [[ -f "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml" ]]; then
            local HOOKS; HOOKS=$(yq eval '.flags.hooks // false' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")
            if [[ ! "${HOOKS}" == "true" ]]; then
                ARGS+=("--no-hooks")
            fi
            local CRDS; CRDS=$(yq eval '.flags.crds == false | not' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")
            if [[ ! "${CRDS}" == "false" ]]; then
                ARGS+=("--include-crds")
            fi
            local TESTS; TESTS=$(yq eval '.flags.tests // false' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")
            if [[ ! "${TESTS}" == "true" ]]; then
                ARGS+=("--skip-tests")
            fi
            FIX_HOOKS=$(yq eval '.flags.fixhooks // false' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")
        fi

        if [[ -n "${HELMOUTPUTDIR}" && "${HELMOUTPUTDIR}" =~ ^.*helmx\.[[:digit:]]+\.rendered$ ]]; then
            "${HELMBINARY}" "${ARG_KUBE_VERSION[@]}" "$@" "${ARGS[@]}"

            for FILE in $(find "${HELMOUTPUTDIR}/" -type f | sort | sed "s|^${HELMOUTPUTDIR}/||"); do
                sed -i "\|# Source: ${FILE}|{d;}" "${HELMOUTPUTDIR}/${FILE}"
            done; unset FILE
        else
            if [[ "${FIX_HOOKS}" == "true" ]] && yq eval -e 'select(.metadata.annotations."helm.sh/hook" != "*")' "${HELMSOURCEDIR}/files/templates/patched_resources.yaml" &>/dev/null && yq eval -e 'select(.metadata.annotations."helm.sh/hook" == "*")' "${HELMSOURCEDIR}/files/templates/patched_resources.yaml" &>/dev/null; then
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

    local ARGS=()
    local ARGS_TMPL=()
    local HELMBINARY; HELMBINARY="$(yq eval '.helmBinary // ""' "${TMPDIR}/source/helmfile.yaml")"

    # shellcheck disable=SC2016
    local RENDER_FILENAME_PATTERN_BASE='
        .".kube-renderer".crds  = .kind + "~" + (.apiVersion // "" | sub("(.*)/.*", "$1"))                                                       | .".kube-renderer".crds  |= (sub("^(?:(CustomResourceDefinition~apiextensions.k8s.io)|.*)$", "$1")                | sub(".+", "/crds"))  |
        .".kube-renderer".tests = (.metadata.annotations."helm.sh/hook" // "")                                                                   | .".kube-renderer".tests |= (sub("^(?:(test)|.*)$", "$1")                                                         | sub(".+", "/tests")) |
        .".kube-renderer".hooks = ((.metadata.annotations."helm.sh/hook" // "") + (.metadata.annotations."argocd.argoproj.io/hook" // ""))       | .".kube-renderer".hooks |= (sub("test", "")                                                                      | sub(".+", "/hooks")) |
        .".kube-renderer".rbac  = .kind + "~" + (.apiVersion // "" | sub("(.*)/.*", "$1"))                                                       | .".kube-renderer".rbac  |= (sub("^(?:((?:ClusterRoleBinding|ClusterRole)~rbac.authorization.k8s.io)|.*)$", "$1") | sub(".+", "/rbac"))  |
        (.metadata.namespace // "_cluster") +
        .".kube-renderer".crds +
        .".kube-renderer".tests +
        .".kube-renderer".hooks +
        .".kube-renderer".rbac +
        "/" +
        (.kind // "_unknown") +
        (("." + ((.apiVersion // "v1") | sub("^(?:(.*)/)?(?:v.*)$", "${1}"))) | sub("^\.$", "")) +
        "_" +
        (.metadata.name // "_unknown") +
        ".yaml"
    '
    # shellcheck disable=SC2016
    local RENDER_FILENAME_PATTERN_COMMENT='head_comment | capture("(?sm)^.*^Kuberenderer: (?P<kuberenderer>.*?$).*$") | .kuberenderer'

    if [[ "${DEBUG_MODE}" == "true" ]]; then
      ARGS+=("--debug")
      ARGS_TMPL+=("--skip-cleanup")
      ARGS_GMPL+=("--verbose")
    else
      ARGS+=("--quiet")
    fi

    if [[ -n "${SELECTOR}" ]]; then
        ARGS+=("--selector" "${SELECTOR}")
    fi

    local SKIP_DEPS; SKIP_DEPS=()
    if [[ -n "${LOCAL_HELM_CACHE}" ]]; then
        SKIP_DEPS=("--skip-deps")
    fi

    cat > "${TMPDIR}/helm-internal" <<EOF
#!/usr/bin/env bash
exec "$(readlink -f "$0")" --internal-helm "${HELMBINARY}" "${TMPDIR}" "\$@"
EOF
    chmod +x "${TMPDIR}/helm-internal"

    mkdir -p "${TMPDIR}/helmfile-values"
    yq eval 'del(.helmfiles) | del(.releases)' "${TMPDIR}/source/helmfile.yaml" > "${TMPDIR}/source/helmfile-gomplate.yaml"         # Neccessary to be same directory (source) because of paths inside helmfile
    CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify/values"     helmfile -f "${TMPDIR}/source/helmfile.yaml"           "${ARGS[@]}" --helm-binary "${TMPDIR}/helm-internal" write-values --output-file-template "${TMPDIR}/helmfile-values/app-{{ .Release.Name }}.yaml" "${SKIP_DEPS[@]}"
    CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify/build"      helmfile -f "${TMPDIR}/source/helmfile.yaml"           "${ARGS[@]}" --helm-binary "${TMPDIR}/helm-internal" build --embed-values > "${TMPDIR}/helmfile-values/globals.yaml"
    CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify/gomplate"   helmfile -f "${TMPDIR}/source/helmfile-gomplate.yaml"  "${ARGS[@]}" --helm-binary "${TMPDIR}/helm-internal" --allow-no-matching-release build --embed-values 2>/dev/null > "${TMPDIR}/helmfile-values/globals-gomplate.yaml"
    CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify/list"       helmfile -f "${TMPDIR}/source/helmfile.yaml"           "${ARGS[@]}" --helm-binary "${TMPDIR}/helm-internal" list --keep-temp-dir --output json | yq -PM > "${TMPDIR}/helmfile-values/list.yaml"
    yq eval '.releases[]' -s '"'"${TMPDIR}/helmfile-values/app-"'" + .name + "-metadata.yaml"' "${TMPDIR}/helmfile-values/globals.yaml"
    # shellcheck disable=SC2016
    yq eval -N '.releases // ""' "${TMPDIR}/helmfile-values/globals.yaml" > "${TMPDIR}/helmfile-values/releases.yaml"

    yq eval '.renderedvalues | del(.".*")'        "${TMPDIR}/helmfile-values/globals-gomplate.yaml" | sed 's/^null$/{}/; /^---$/ {d;}' > "${TMPDIR}/helmfile-values/gomplate-values.yaml"
    yq eval '.renderedvalues | .".kube-renderer"' "${TMPDIR}/helmfile-values/globals-gomplate.yaml" | sed 's/^null$/{}/; /^---$/ {d;}' > "${TMPDIR}/helmfile-values/gomplate-kuberenderer.yaml"

    # shellcheck disable=SC2016
    yq eval-all -N -s '"'"${TMPDIR}/helmfile-values/global-"'" + $index' "${TMPDIR}/helmfile-values/globals.yaml"

    for GLOBAL in $(find "${TMPDIR}/helmfile-values/" -name 'global-*.yml' -printf "%f\n" | sort -V); do
        for APP in $(yq eval '.releases[].name' "${TMPDIR}/helmfile-values/${GLOBAL}"); do
            # shellcheck disable=SC2016
            yq eval-all '((select(fileIndex == 0) | .renderedvalues) * select(fileIndex == 1)) | del(.".*")'        "${TMPDIR}/helmfile-values/${GLOBAL}" "${TMPDIR}/helmfile-values/app-${APP}.yaml" | sed 's/^null$/{}/' | yq eval-all '. as $item ireduce ({}; . * $item)' | sed '/^---$/ {d;}' > "${TMPDIR}/helmfile-values/app-${APP}-values.yaml"
            # shellcheck disable=SC2016
            yq eval-all '((select(fileIndex == 0) | .renderedvalues) * select(fileIndex == 1)) | .".kube-renderer"' "${TMPDIR}/helmfile-values/${GLOBAL}" "${TMPDIR}/helmfile-values/app-${APP}.yaml" | sed 's/^null$/{}/' | yq eval-all '. as $item ireduce ({}; . * $item)' | sed '/^---$/ {d;}' > "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml"
        done; unset APP
    done; unset GLOBAL

    declare -A RELEASES
    declare -A DIRS
    for GLOBAL in $(find "${TMPDIR}/helmfile-values/" -name 'global-*.yml' -printf "%f\n" | sort -V); do
        local HELMFILE_DIR; HELMFILE_DIR=$(yq eval '.renderedvalues.".kube-renderer".helmfile_dir // ""' "${TMPDIR}/helmfile-values/${GLOBAL}")
        if [[ -z "${HELMFILE_DIR}" ]]; then
            HELMFILE_DIR="."
        fi

        for APP in $(yq eval '.releases[].name' "${TMPDIR}/helmfile-values/${GLOBAL}"); do
            local TARGET_RELEASE; TARGET_RELEASE=$(yq eval '.target_release // ""' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")
            if [[ -z "${TARGET_RELEASE}" ]]; then
                TARGET_RELEASE="${APP}"

                local TARGET_DIR; TARGET_DIR=$(yq eval '.target_dir // ""' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")
                if [[ -z "${TARGET_DIR}" ]]; then
                    TARGET_DIR="${TARGET_RELEASE}"
                fi
                DIRS["${APP}"]="${HELMFILE_DIR}/${TARGET_DIR}"
                echo "${APP}: ${HELMFILE_DIR}/${TARGET_DIR}" >> "${TMPDIR}/helmfile-values/mapping-dirs.yaml"
            fi
            RELEASES["${APP}"]="${TARGET_RELEASE}"
            echo "${APP}: ${TARGET_RELEASE}" >> "${TMPDIR}/helmfile-values/mapping-releases.yaml"
        done; unset APP
    done; unset GLOBAL

    # Output to single plain stdout lost information about helm release
    helmfile -f "${TMPDIR}/source/helmfile.yaml" "${ARGS[@]}" --helm-binary "${TMPDIR}/helm-internal" template "${ARGS_TMPL[@]}" --skip-deps --output-dir "${TMPDIR}/helmfile" --output-dir-template '{{ .OutputDir }}/{{ .Release.Name }}'

    for APP in "${!RELEASES[@]}"; do
        if [[ -n "${SELECTOR}" && ! -d "${TMPDIR}/helmfile/${APP}" ]]; then
            continue
        fi

        mkdir -p "${TMPDIR}/merged/${APP}" "${TMPDIR}/postrendered/${APP}" "${TMPDIR}/combined/${APP}" "${TMPDIR}/labelsremoved/${APP}" "${TMPDIR}/final/${APP}"
        find "${TMPDIR}/helmfile/${APP}/" -type f | sort | xargs yq eval 'select(length!=0)' > "${TMPDIR}/merged/${APP}/resources.yaml"

        local POSTRENDERER_TYPE; POSTRENDERER_TYPE=$(yq eval '.helm_postrenderer.type // ""' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")
        case "${POSTRENDERER_TYPE}" in
            "kustomize" ) postrender_kustomize "${APP}";;
            * ) cp "${TMPDIR}/merged/${APP}/resources.yaml" "${TMPDIR}/postrendered/${APP}/resources.yaml"
        esac

        if [[ ! -f "${TMPDIR}/combined/${APP}/resources.yaml" ]]; then
            cp "${TMPDIR}/postrendered/${APP}/resources.yaml" "${TMPDIR}/combined/${APP}/resources.yaml"
        else
            yq eval-all --inplace "${TMPDIR}/combined/${APP}/resources.yaml" "${TMPDIR}/postrendered/${APP}/resources.yaml"
        fi

        local REMOVE_LABELS; REMOVE_LABELS=$(yq eval '.remove_labels[] // ""' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")
        cp "${TMPDIR}/combined/${APP}/resources.yaml" "${TMPDIR}/labelsremoved/${APP}/resources.yaml"
        for LABEL in ${REMOVE_LABELS}; do
            yq eval --inplace 'del(.metadata.labels."'"${LABEL}"'") | del(.spec.template.metadata.labels."'"${LABEL}"'")' "${TMPDIR}/labelsremoved/${APP}/resources.yaml"
        done; unset LABEL

        local RENDER_FILENAME_GENERATOR=
        local RENDER_FILENAME_GENERATOR_CFG; RENDER_FILENAME_GENERATOR_CFG="$(yq eval '.render_filename_generator // ""' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")"
        if [[ -n "${RENDER_FILENAME_GENERATOR_CFG}" ]]; then
            RENDER_FILENAME_GENERATOR="${RENDER_FILENAME_GENERATOR_CFG}"
        fi

        if [[ -n "${RENDER_FILENAME_GENERATOR}" ]]; then
            if [[ "kustomize" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                cat > "${TMPDIR}/labelsremoved/${APP}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- resources.yaml
EOF
                kustomize build "${TMPDIR}/labelsremoved/${APP}" -o "${TMPDIR}/final/${APP}/"
            elif [[ "yq" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                local RENDER_FILENAME_PATTERN=
                RENDER_FILENAME_PATTERN="${RENDER_FILENAME_PATTERN_BASE}"
                local RENDER_FILENAME_PATTERN_CFG; RENDER_FILENAME_PATTERN_CFG="$(yq eval '.render_filename_pattern // ""' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")"
                if [[ -n "${RENDER_FILENAME_PATTERN_CFG}" ]]; then
                    RENDER_FILENAME_PATTERN="${RENDER_FILENAME_PATTERN_CFG}"
                fi

                mkdir -p "${TMPDIR}/splitted/${APP}"
                # shellcheck disable=SC2016
                yq eval -N -s '("'"${TMPDIR}/splitted/${APP}/"'"'' + $index) + ".yaml"' "${TMPDIR}/labelsremoved/${APP}/resources.yaml"
                for FILE in $(find "${TMPDIR}/splitted/${APP}/" -type f -printf "%f\n" | sort -V); do
                    local NEWFILE; NEWFILE=$(yq eval -N "${RENDER_FILENAME_PATTERN}" "${TMPDIR}/splitted/${APP}/${FILE}")
                    mkdir -p "$(dirname "${TMPDIR}/final/${APP}/${NEWFILE}")"
                    touch "${TMPDIR}/final/${APP}/${NEWFILE}"
                    yq eval -i '.' "${TMPDIR}/final/${APP}/${NEWFILE}" "${TMPDIR}/splitted/${APP}/${FILE}"
                done; unset FILE
            elif [[ "comment" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                local RENDER_FILENAME_PATTERN=
                RENDER_FILENAME_PATTERN="${RENDER_FILENAME_PATTERN_COMMENT}"
                local RENDER_FILENAME_PATTERN_CFG; RENDER_FILENAME_PATTERN_CFG="$(yq eval '.render_filename_pattern // ""' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml")"
                if [[ -n "${RENDER_FILENAME_PATTERN_CFG}" ]]; then
                    RENDER_FILENAME_PATTERN="${RENDER_FILENAME_PATTERN_CFG}"
                fi

                mkdir -p "${TMPDIR}/splitted/${APP}"
                # shellcheck disable=SC2016
                yq eval -N -s '("'"${TMPDIR}/splitted/${APP}/"'"'' + $index) + ".yaml"' "${TMPDIR}/labelsremoved/${APP}/resources.yaml"
                for FILE in $(find "${TMPDIR}/splitted/${APP}/" -type f -printf "%f\n" | sort -V); do
                    local NEWFILE; NEWFILE=$(yq eval -N "${RENDER_FILENAME_PATTERN}" "${TMPDIR}/splitted/${APP}/${FILE}")
                    mkdir -p "$(dirname "${TMPDIR}/final/${APP}/${NEWFILE}")"
                    touch "${TMPDIR}/final/${APP}/${NEWFILE}"
                    yq eval -i '.' "${TMPDIR}/final/${APP}/${NEWFILE}" "${TMPDIR}/splitted/${APP}/${FILE}"
                done; unset FILE
            elif [[ "helm" == "${RENDER_FILENAME_GENERATOR}" ]]; then
                mkdir -p "${TMPDIR}/splitted/${APP}" "${TMPDIR}/reconstructed/${APP}"
                # shellcheck disable=SC2016
                yq eval -N -s '("'"${TMPDIR}/splitted/${APP}/"'"'' + $index) + ".yaml"' "${TMPDIR}/labelsremoved/${APP}/resources.yaml"
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
                done; unset FILE

                cp -r "${TMPDIR}/reconstructed/${APP}/"* "${TMPDIR}/final/${APP}/"
            fi
        else
            cp -r "${TMPDIR}/labelsremoved/${APP}/resources.yaml" "${TMPDIR}/final/${APP}/${APP}.yaml"
        fi
    done; unset APP

    mkdir -p "${TMPDIR}/bootstrap/" "${TMPDIR}/bootstrap-template/"
    yq eval '.bootstrap_template // ""' "${TMPDIR}/helmfile-values/gomplate-kuberenderer.yaml" > "${TMPDIR}/bootstrap-template/bootstrap-template"

    local BOOTSTRAPS=()
    if [[ -s "${TMPDIR}/bootstrap-template/bootstrap-template" ]]; then
        # shellcheck disable=SC2016
        gomplate "${ARGS_GMPL[@]}" \
            -c .=<(yq eval-all '. as $item ireduce ({}; . * $item )' \
                <(yq eval '{ "StateValues": . }' "${TMPDIR}/helmfile-values/gomplate-values.yaml") \
                <(yq eval '{ "Releases": . }'    "${TMPDIR}/helmfile-values/releases.yaml") \
                <(yq eval '{ "Metadata": . }'    "${TMPDIR}/helmfile-values/gomplate-kuberenderer.yaml") \
                <(yq eval '{ "ReleasesMap": . }' "${TMPDIR}/helmfile-values/mapping-releases.yaml") \
                <(yq eval '{ "DirsMap": . }'     "${TMPDIR}/helmfile-values/mapping-dirs.yaml") \
                )?type=application/yaml -f "${TMPDIR}/bootstrap-template/bootstrap-template" -o "${TMPDIR}/bootstrap-template/bootstrap-template.yaml"

        # shellcheck disable=SC2016
        local PATTERN; PATTERN='head_comment | capture("(?sm)^.*^Bootstrap: (?P<bootstrap>.*?$).*$") | .bootstrap'

        # shellcheck disable=SC2016
        yq eval -N -s '("'"${TMPDIR}/bootstrap/"'"'' + $index) + ".yaml"' "${TMPDIR}/bootstrap-template/bootstrap-template.yaml"
        for FILE in $(find "${TMPDIR}/bootstrap/" -type f -printf "%f\n" | sort -V); do
            local NEWFILE; NEWFILE=$(yq eval -N "${PATTERN}" "${TMPDIR}/bootstrap/${FILE}")
            if [[ -n "${NEWFILE}" ]]; then
                BOOTSTRAPS+=("${NEWFILE%/*}")
                mkdir -p "$(dirname "${TMPDIR}/final/${NEWFILE}")"
                touch "${TMPDIR}/final/${NEWFILE}"
                yq eval -i '.' "${TMPDIR}/final/${NEWFILE}" "${TMPDIR}/bootstrap/${FILE}"
            fi
        done; unset FILE
    fi

    for APP in "${!RELEASES[@]}"; do
        local TARGET_RELEASE=${RELEASES["${APP}"]}
        local TARGET_DIR=${DIRS["${TARGET_RELEASE}"]}
        mkdir -p "${TARGET}/${TARGET_DIR}"
        cp -r "${TMPDIR}/final/${APP}/"* "${TARGET}/${TARGET_DIR}/"
    done; unset APP

    for BOOTSTRAP in "${BOOTSTRAPS[@]}"; do
        mkdir -p "${TARGET}/${BOOTSTRAP}"
        cp -r "${TMPDIR}/final/${BOOTSTRAP}/"* "${TARGET}/${BOOTSTRAP}/"
    done; unset APP
}

function postrender_kustomize {
    local APP=$1; shift

    yq eval '.helm_postrenderer.data' "${TMPDIR}/helmfile-values/app-${APP}-kuberenderer.yaml" | yq eval '(.resources[] | select(. == "<HELM>")) = "'"${TMPDIR}/merged/${APP}/resources.yaml"'"' - > "${TMPDIR}/merged/${APP}/kustomization.yaml"
    kustomize build "${TMPDIR}/merged/${APP}" > "${TMPDIR}/postrendered/${APP}/resources.yaml"
}


function usage {
    echo "usage: kube-renderer.sh SOURCE TARGET [-Vh] [-l <selector>] [-d]"
    echo "   ";
    echo "  -d | --debug             : Dobug mode";
    echo "  -l | --selector          : Partial render based on helmfile selector";
    echo "  -c | --local-helm-cache  : Use local helm cache";
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
            -d | --debug )                DEBUG_MODE="true";             ;;
            -l | --selector )             SELECTOR="$2";                 shift;;
            -c | --local-helm-cache )     LOCAL_HELM_CACHE="true";       ;;
            -V | --version )              version;                       exit;;
            -h | --help )                 usage;                         exit;;
            --internal-helm )             shift; internal_helm "$@";     exit;;
            * )                           args+=("$1")                  # others add to positional arguments
        esac
        shift
    done

    # set defaults
    if [[ -z "${DEBUG_MODE}" ]]; then
      DEBUG_MODE="";
    fi
    if [[ -z "${SELECTOR}" ]]; then
      SELECTOR="";
    fi
    if [[ -z "${LOCAL_HELM_CACHE}" ]]; then
      LOCAL_HELM_CACHE="";
    fi

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
if [[ "${DEBUG_MODE}" == "true" ]]; then
    export DEBUG_MODE
    set -x
fi

TMPDIR=$(mktemp -d /tmp/kube-renderer.XXXXXXXXXX)
if [[ "${DEBUG_MODE}" != "true" ]]; then
    trap 'rm -rf -- "$TMPDIR"' EXIT
fi
mkdir "${TMPDIR}/helmfile-temp" "${TMPDIR}/helmfile-temp-chartify"
export HELMFILE_TEMPDIR="${TMPDIR}/helmfile-temp"
export CHARTIFY_TEMPDIR="${TMPDIR}/helmfile-temp-chartify"
if [[ -z "${LOCAL_HELM_CACHE}" ]]; then
    export HELM_CACHE_HOME="${TMPDIR}/helmhome"
    export HELM_CONFIG_HOME="${TMPDIR}/helmhome"
    export HELM_DATA_HOME="${TMPDIR}/helmhome"
    export XDG_CACHE_HOME="${TMPDIR}/cache"
fi

render
