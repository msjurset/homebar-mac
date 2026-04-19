APP_NAME := HomeBar
BUNDLE := $(APP_NAME).app
INSTALL_DIR := /Applications
SIGN_IDENTITY := HomeBar Dev

build:
	swift build -c release

icon:
	@test -f AppIcon.icns || swift scripts/generate-icon.swift

bundle: build icon
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources $(BUNDLE)/Contents/Frameworks
	command cp .build/release/HomeBar $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	install_name_tool -add_rpath @loader_path/../Frameworks $(BUNDLE)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true
	command cp Info.plist $(BUNDLE)/Contents/Info.plist
	@test -f AppIcon.icns && command cp AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns || true
	@test -d Resources && cp -R Resources/. $(BUNDLE)/Contents/Resources/ || true
	cp -R .build/arm64-apple-macosx/release/Sparkle.framework $(BUNDLE)/Contents/Frameworks/
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_IDENTITY)"; then \
		codesign --force --deep --sign "$(SIGN_IDENTITY)" $(BUNDLE); \
		echo "Signed with $(SIGN_IDENTITY)"; \
	else \
		codesign --force --deep --sign - $(BUNDLE); \
		echo "Ad-hoc signed (no '$(SIGN_IDENTITY)' cert found — run 'make cert' for a stable identity)"; \
	fi

cert:
	@echo "Creating self-signed code-signing certificate '$(SIGN_IDENTITY)'..."
	@printf '[req]\ndistinguished_name=dn\nx509_extensions=cs\nprompt=no\n[dn]\nCN=$(SIGN_IDENTITY)\n[cs]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n' > /tmp/homebar-cert.conf
	@openssl req -x509 -newkey rsa:2048 -noenc -keyout /tmp/homebar-dev.key -out /tmp/homebar-dev.crt -days 3650 -config /tmp/homebar-cert.conf 2>/dev/null
	@openssl pkcs12 -export -legacy -passout pass:homebardev -inkey /tmp/homebar-dev.key -in /tmp/homebar-dev.crt -out /tmp/homebar-dev.p12 2>/dev/null
	@security import /tmp/homebar-dev.p12 -k ~/Library/Keychains/login.keychain-db -P "homebardev" -T /usr/bin/codesign
	@rm -f /tmp/homebar-dev.key /tmp/homebar-dev.crt /tmp/homebar-dev.p12 /tmp/homebar-cert.conf
	@echo "Done. Grant trust: open Keychain Access > '$(SIGN_IDENTITY)' cert > Trust > Always Trust"
	@echo "Then run 'make deploy' — TCC and 1Password permissions will persist across rebuilds."

deploy: bundle
	pkill -9 -f "$(APP_NAME)" 2>/dev/null || true
	@sleep 1
	command rm -rf $(INSTALL_DIR)/$(BUNDLE)
	ditto $(BUNDLE) $(INSTALL_DIR)/$(BUNDLE)
	xattr -dr com.apple.quarantine $(INSTALL_DIR)/$(BUNDLE) 2>/dev/null || true
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(SIGN_IDENTITY)"; then \
		echo "Installed copy retains '$(SIGN_IDENTITY)' signature from bundle step"; \
	else \
		codesign --force --deep --sign - $(INSTALL_DIR)/$(BUNDLE); \
		echo "Ad-hoc signed (no '$(SIGN_IDENTITY)' cert found — run 'make cert' for a stable identity)"; \
	fi
	@rm -rf $(BUNDLE)
	@echo "Deployed to $(INSTALL_DIR)/$(BUNDLE)"
	open $(INSTALL_DIR)/$(BUNDLE)

clean:
	rm -rf .build $(BUNDLE)

test:
	swift test

release:
	@test -n "$(VERSION)" || (echo "Usage: make release VERSION=1.1.0" && exit 1)
	./scripts/release.sh $(VERSION)

.PHONY: build bundle icon cert deploy clean test release
