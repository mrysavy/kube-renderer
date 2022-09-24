SUITE:='.*'

.PHONY: tests

all: shellcheck clean build tests
suite: clean build tests_partial

tests:
	@test/bats/bin/bats --show-output-of-passing-tests --verbose-run -T test/test.bats

tests_partial:
	@test/bats/bin/bats -T test/test.bats -f $(SUITE)

build:
	@mkdir -p output
	@cat src/kube-renderer.sh | sed 's/<KUBE_RENDERER_VERSION>/$(shell git describe --tags)/' > output/kube-renderer.sh
	@chmod +x output/kube-renderer.sh

shellcheck:
	@shellcheck src/kube-renderer.sh

clean:
	@rm -rf output
