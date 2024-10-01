#!/bin/sh

./build.sh $1
podman push ubuntu-server-dev:$1 $(podman images --format='{{.Repository}}:{{.Tag}}' | grep localhost/ubuntu-server-dev | tr '\n' ' ' | sed 's;localhost/;ghcr.io/seagl/ubuntu-server-dev/;g')
