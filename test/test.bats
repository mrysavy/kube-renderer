setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    mkdir -p tests-output
}

run_common_test() {
    local name=$1; shift

    mkdir "tests-output/test-${name}"
    run output/kube-renderer.sh -d "tests/test-${name}" "tests-output/test-${name}"
    assert_success
    run diff -r "tests-output/test-${name}" "tests/sample-${name}"
    assert_success
}

@test "can run the script and print version info" {
    run output/kube-renderer.sh --version
    assert_success
}

@test "fail when missing required positional parameters" {
    run output/kube-renderer.sh
    assert_output 'SOURCE & TARGET arguments are required'
    assert_failure 1
}

@test "fail when missing target directory" {
    run output/kube-renderer.sh tests/NOT_EXISTS tests-output/NOT_EXISTS
    assert_output 'TARGET must exists'
    assert_failure 1
}

@test "fail when nonempty target directory" {
    mkdir -p tests-output/NONEMPTY/NONEMPTY
    run output/kube-renderer.sh tests/NONEMPTY tests-output/NONEMPTY
    assert_output 'TARGET must be empty'
    assert_failure 1
}

@test "not render while bad helm binary" {
    mkdir "tests-output/test-bad-helmbinary"
    run output/kube-renderer.sh "tests/test-bad-helmbinary" "tests-output/test-bad-helmbinary"
    assert_failure 2
    assert_output -p 'bad_helm3_binary: not found'
}

@test "can render with specified kube version" {
    run_common_test kube-version-ok
}

@test "not render when different kube version requirements" {
    mkdir "tests-output/test-kube-version-ko"
    run output/kube-renderer.sh "tests/test-kube-version-ko" "tests-output/test-kube-version-ko"
    assert_failure 1
    assert_output -p 'Error: chart requires kubeVersion: 1.16.0 which is incompatible with Kubernetes'
}

@test "can render plain manifests" {
    run_common_test render-plain
}

@test "can render kustomize overlays" {
    run_common_test render-kustomize
}

@test "can render helm charts" {
    run_common_test render-helm
}

@test "can render with plain output" {
    run_common_test output-plain
}

@test "can render with helm output" {
    run_common_test output-helm
}

@test "can render with kustomize output" {
    run_common_test output-kustomize
}

@test "can render with yq output" {
    run_common_test output-yq
}

@test "can render with comment output" {
    run_common_test output-comment
}

@test "can render with state values" {
    run_common_test state-values
}

@test "can render with yq output custom" {
    run_common_test output-yq-custom
}

@test "can render with bootstrap" {
    run_common_test bootstrap
}

@test "can render correctly helm with transformer also using hooks" {
    run_common_test helm-transformer-hooks
}

@test "can render with kustomize postrenderer" {
    run_common_test postrenderer-kustomize
}

@test "can render with releases merging" {
    run_common_test merge-releases
}

@test "can render multiple input files" {
    run_common_test multiple-inputs
}

@test "can render with layering" {
    run_common_test layering
}

@test "can render with release subdirs" {
    run_common_test release-subdir
}

@test "can render with/without crds" {
    run_common_test crd-output-helm
}

@test "can render with/without tests" {
    run_common_test helm-skip-tests
}

@test "can render with/without hooks" {
    run_common_test hook-output-helm
}

@test "can remove labels" {
    run_common_test remove-labels
}

teardown() {
    rm -rf tests-output
}