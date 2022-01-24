#!/bin/sh -e
set -eu
yq eval '.metadata.labels.postrender="test"' -
