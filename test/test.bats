setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    mkdir -p tests-output
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

@test "fail when missing target" {
    run output/kube-renderer.sh tests/test-helmfile tests-output/test-helmfile
    assert_output 'TARGET must exists'
    assert_failure 1
}

@test "fail when nonempty target" {
    mkdir -p tests-output/test-helmfile-nonempty/nonempty
    run output/kube-renderer.sh tests/test-helmfile tests-output/test-helmfile-nonempty
    assert_output 'TARGET must be empty'
    assert_failure 1
}

@test "can render basic helmfile correctly" {
    mkdir tests-output/test-helmfile
    run output/kube-renderer.sh tests/test-helmfile tests-output/test-helmfile
    assert_success
    run diff -r tests-output/test-helmfile tests/sample-helmfile
    assert_success
}

@test "can render basic helm correctly" {
    mkdir tests-output/test-helm
    run output/kube-renderer.sh tests/test-helm tests-output/test-helm
    assert_success
    run diff -r tests-output/test-helm tests/sample-helm
    assert_success
}

@test "can render basic kustomize correctly" {
    mkdir tests-output/test-kustomize
    run output/kube-renderer.sh tests/test-kustomize tests-output/test-kustomize
    assert_success
    run diff -r tests-output/test-kustomize tests/sample-kustomize
    assert_success
}

@test "can render basic plain correctly" {
    mkdir tests-output/test-plain
    run output/kube-renderer.sh tests/test-plain tests-output/test-plain
    assert_success
    run diff -r tests-output/test-plain tests/sample-plain
    assert_success
}

@test "can render basic helm-kustomize correctly" {
    mkdir tests-output/test-helm-kustomize
    run output/kube-renderer.sh tests/test-helm-kustomize tests-output/test-helm-kustomize
    assert_success
    run diff -r tests-output/test-helm-kustomize tests/sample-helm-kustomize
    assert_success
}

@test "can render basic helm-postrenderer correctly" {
    mkdir tests-output/test-helm-postrenderer
    run output/kube-renderer.sh tests/test-helm-postrenderer tests-output/test-helm-postrenderer
    assert_success
    run diff -r tests-output/test-helm-postrenderer tests/sample-helm-postrenderer
    assert_success
}

@test "can render with helm-based output" {
    mkdir tests-output/test-output-helm
    run output/kube-renderer.sh tests/test-output-helm tests-output/test-output-helm
    assert_success
    run diff -r tests-output/test-output-helm tests/sample-output-helm
    assert_success
}

@test "can render with kustomize-based output" {
    mkdir tests-output/test-output-kustomize
    run output/kube-renderer.sh tests/test-output-kustomize tests-output/test-output-kustomize
    assert_success
    run diff -r tests-output/test-output-kustomize tests/sample-output-kustomize
    assert_success
}

@test "can render with yq-based output" {
    mkdir tests-output/test-output-yq
    run output/kube-renderer.sh tests/test-output-yq tests-output/test-output-yq
    assert_success
    run diff -r tests-output/test-output-yq tests/sample-output-yq
    assert_success
}

@test "can render with raw-based output" {
    mkdir tests-output/test-output-raw
    run output/kube-renderer.sh tests/test-output-raw tests-output/test-output-raw
    assert_success
    run diff -r tests-output/test-output-raw tests/sample-output-raw
    assert_success
}

@test "can render with yq-based output correctly" {
    mkdir tests-output/test-correct-yq
    run output/kube-renderer.sh tests/test-correct-yq tests-output/test-correct-yq
    assert_success
    run diff -r tests-output/test-correct-yq tests/sample-correct-yq
    assert_success
}

@test "can render setting namespace" {
    mkdir tests-output/test-set-ns
    run output/kube-renderer.sh tests/test-set-ns tests-output/test-set-ns
    assert_success
    run diff -r tests-output/test-set-ns tests/sample-set-ns
    assert_success
}

@test "can render all apps" {
    mkdir tests-output/test-all-apps
    run output/kube-renderer.sh tests/test-all-apps tests-output/test-all-apps
    assert_success
    run diff -r tests-output/test-all-apps tests/sample-all-apps
    assert_success
}

@test "can render allowed apps" {
    mkdir tests-output/test-allowed-apps
    run output/kube-renderer.sh tests/test-allowed-apps tests-output/test-allowed-apps
    assert_success
    run diff -r tests-output/test-allowed-apps tests/sample-allowed-apps
    assert_success
}

@test "merge correctly config with global" {
    mkdir tests-output/test-config-merge-with-global
    run output/kube-renderer.sh tests/test-config-merge-with-global tests-output/test-config-merge-with-global
    assert_success
    run diff -r tests-output/test-config-merge-with-global tests/sample-config-merge-with-global
    assert_success
}

@test "merge correctly config no global" {
    mkdir tests-output/test-config-merge-no-global
    run output/kube-renderer.sh tests/test-config-merge-no-global tests-output/test-config-merge-no-global
    assert_success
    run diff -r tests-output/test-config-merge-no-global tests/sample-config-merge-no-global
    assert_success
}

@test "render correctly when no config" {
    mkdir tests-output/test-noconfig
    run output/kube-renderer.sh tests/test-noconfig tests-output/test-noconfig
    assert_success
    run diff -r tests-output/test-noconfig tests/sample-noconfig
    assert_success
}

@test "support global values" {
    mkdir tests-output/test-global-values
    run output/kube-renderer.sh tests/test-global-values tests-output/test-global-values
    assert_success
    run diff -r tests-output/test-global-values tests/sample-global-values
    assert_success
}

@test "support bootstrap rendering" {
    mkdir tests-output/test-bootstrap
    run output/kube-renderer.sh tests/test-bootstrap tests-output/test-bootstrap
    assert_success
    run diff -r tests-output/test-bootstrap tests/sample-bootstrap
    assert_success
}

teardown() {
    rm -rf tests-output
}