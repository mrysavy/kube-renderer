SUITE:='.*'

.PHONY: tests

all: clean build tests_all
suite: clean build tests

tests_all:
	test/bats/bin/bats test/test.bats

tests:
	test/bats/bin/bats test/test.bats -f $(SUITE)

build:
	mkdir -p output
	cat src/kube-renderer.sh | sed 's/<KUBE_RENDERER_VERSION>/$(shell git describe --tags)/' > output/kube-renderer.sh
	chmod +x output/kube-renderer.sh

clean:
	rm -rf output
