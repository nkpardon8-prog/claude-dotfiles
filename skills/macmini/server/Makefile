# macmini-server build + test entry points.
# stdlib-only; no external Go modules.

PKG          := macmini-server
MAIN         := ./cmd/macmini-server
DIST         := dist
GIT_SHA      := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
LDFLAGS      := -s -w -X $(PKG)/internal/config.Version=$(GIT_SHA)

.PHONY: build build-amd64 vet smoke clean

build:
	mkdir -p $(DIST)
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "$(LDFLAGS)" -o $(DIST)/macmini-server-darwin-arm64 $(MAIN)

build-amd64:
	mkdir -p $(DIST)
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "$(LDFLAGS)" -o $(DIST)/macmini-server-darwin-amd64 $(MAIN)

vet:
	go vet ./...
	@out=$$(gofmt -l .); if [ -n "$$out" ]; then echo "gofmt issues:"; echo "$$out"; exit 1; fi

smoke:
	@if [ -z "$$MACMINI_URL" ] || [ -z "$$MACMINI_TOKEN" ]; then \
		echo "MACMINI_URL and MACMINI_TOKEN must be set"; exit 2; \
	fi
	bash tests_smoke.sh

clean:
	rm -rf $(DIST)
