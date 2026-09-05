# s3disk — build, test and package.

BINARY      := s3disk
VERSION     ?= $(shell git describe --tags --always --dirty 2>/dev/null || cat VERSION 2>/dev/null || echo dev)
PREFIX      ?= /usr/local
IMAGE       ?= s3disk
PLATFORMS   ?= linux/amd64,linux/arm64
GO          ?= go
GOFLAGS     := -buildvcs=false -trimpath
LDFLAGS     := -s -w -X main.version=$(VERSION)

.PHONY: all build install uninstall clean test vet fmt lint image image-agent image-multiarch image-oci dist e2e minio help

all: build ## build the binary

build: ## build bin/s3disk
	CGO_ENABLED=0 $(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o bin/$(BINARY) ./cmd/$(BINARY)

install: build ## install to $(PREFIX)/bin and register the mount(8) helper
	install -Dm755 bin/$(BINARY) $(DESTDIR)$(PREFIX)/bin/$(BINARY)
	ln -sf $(PREFIX)/bin/$(BINARY) $(DESTDIR)/sbin/mount.$(BINARY)
	install -Dm644 packaging/s3disk@.service $(DESTDIR)/etc/systemd/system/s3disk@.service

uninstall: ## remove an installed s3disk
	rm -f $(DESTDIR)$(PREFIX)/bin/$(BINARY) $(DESTDIR)/sbin/mount.$(BINARY) \
	      $(DESTDIR)/etc/systemd/system/s3disk@.service

test: ## run unit tests
	$(GO) test $(GOFLAGS) -race ./...

vet: ## run go vet
	$(GO) vet $(GOFLAGS) ./...

fmt: ## format the source
	gofmt -w cmd internal

e2e: build ## run the end-to-end suite against a local MinIO
	./test/e2e.sh

minio: ## start a throwaway MinIO for the e2e suite
	docker run -d --rm --name s3disk-minio -p 9000:9000 \
	  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
	  minio/minio server /data

image: ## build the container image
	docker build -f docker/Dockerfile -t $(IMAGE):$(VERSION) -t $(IMAGE):latest \
	  --build-arg VERSION=$(VERSION) .

image-agent: ## build the agent workspace image
	docker build -f examples/agent.Dockerfile -t $(IMAGE)-agent:$(VERSION) -t $(IMAGE)-agent:latest \
	  --build-arg VERSION=$(VERSION) .

image-multiarch: ## build and push a multi-architecture image (needs buildx)
	docker buildx build -f docker/Dockerfile --platform $(PLATFORMS) \
	  -t $(IMAGE):$(VERSION) -t $(IMAGE):latest --build-arg VERSION=$(VERSION) --push .

image-oci: ## build a multi-architecture image into a local OCI archive (no registry)
	docker buildx build -f docker/Dockerfile --platform $(PLATFORMS) \
	  -t $(IMAGE):$(VERSION) --build-arg VERSION=$(VERSION) \
	  --output type=oci,dest=dist/$(IMAGE)-$(VERSION)-oci.tar .

dist: image ## produce a loadable image tarball for hosts without a registry
	@mkdir -p dist
	docker save $(IMAGE):$(VERSION) | gzip > dist/$(IMAGE)-$(VERSION)-docker.tar.gz
	@echo "  dist/$(IMAGE)-$(VERSION)-docker.tar.gz  ($$(du -h dist/$(IMAGE)-$(VERSION)-docker.tar.gz | cut -f1))"
	@echo "  install on the target host with:  docker load < <file>"

clean: ## remove build output
	rm -rf bin dist

help: ## list targets
	@grep -hE '^[a-z0-9-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
