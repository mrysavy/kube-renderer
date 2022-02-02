setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    mkdir -p tests-output
}

run_common_test() {
    local name=$1; shift

    mkdir "tests-output/test-${name}"
    run output/kube-renderer.sh "tests/test-${name}" "tests-output/test-${name}"
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

@test "can render with state values" {
    run_common_test state-values
}

@test "can render with gomplate" {
    run_common_test gomplate
}

teardown() {
    rm -rf tests-output
}