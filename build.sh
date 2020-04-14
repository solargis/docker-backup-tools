#!/bin/bash
TAG="${1:-solargis/backup:latest}"
docker build -t "$TAG" "$(dirname $0)"
