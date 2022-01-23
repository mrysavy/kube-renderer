.PHONY: tests

all: clean build tests

tests:
	test/bats/bin/bats test/test.bats

build:
	mkdir -p output
	cat src/kube-renderer.sh | sed 's/<KUBE_RENDERER_VERSION>/$(shell git describe)/' > output/kube-renderer.sh
	chmod +x output/kube-renderer.sh

clean:
	rm -rf output
