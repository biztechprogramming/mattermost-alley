PLUGIN_ID      = com.biztechprogramming.upload-policy
PLUGIN_VERSION = 0.2.0
BUNDLE_NAME    = $(PLUGIN_ID)-$(PLUGIN_VERSION)

.PHONY: all build dist clean

all: dist

build:
	mkdir -p server/dist
	cd server && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
		go build -trimpath -ldflags "-s -w" -o dist/plugin-linux-amd64 .

dist: build
	rm -rf dist-bundle
	mkdir -p dist-bundle/$(PLUGIN_ID)/server/dist
	cp plugin.json dist-bundle/$(PLUGIN_ID)/plugin.json
	cp server/dist/plugin-linux-amd64 dist-bundle/$(PLUGIN_ID)/server/dist/plugin-linux-amd64
	cd dist-bundle && tar -czf ../$(BUNDLE_NAME).tar.gz $(PLUGIN_ID)
	@echo
	@echo "Built $(BUNDLE_NAME).tar.gz"
	@ls -lh $(BUNDLE_NAME).tar.gz

clean:
	rm -rf dist-bundle server/dist *.tar.gz
