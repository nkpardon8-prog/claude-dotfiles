SHELL := /bin/bash

GIT_SHA := $(shell git -C $(HOME)/.claude-dotfiles rev-parse --short HEAD 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.Version=$(GIT_SHA)

.PHONY: build build-amd64 vet install test

build:
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/macmini-client-darwin-arm64 ./cmd/macmini-client

build-amd64:
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/macmini-client-darwin-amd64 ./cmd/macmini-client

vet:
	go vet ./...
	gofmt -l . | (! grep .)

test:
	go test ./...

install:
	sudo cp dist/macmini-client-darwin-$$(uname -m | sed 's/x86_64/amd64/') /usr/local/bin/macmini-client && sudo chmod 755 /usr/local/bin/macmini-client
