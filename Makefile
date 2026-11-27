# The drivers as DKMS modules for Armbian's own kernel (current or edge, rockchip64), with
# the overlays, udev rule and blacklist, as a package. On the board, with git, dkms,
# device-tree-compiler and the headers:
#
#   sudo make install     # builds the package and installs it; reboot after, for the overlays
#   sudo make uninstall
#   make deb              # out/orangepi5pro-vendor-drivers_<version>_all.deb
#
# The sources come from our patches alone (tools/dkms-src.sh, into $(OUT)/src/); overlays/
# is generated from dt/ and committed (mise run overlays).

NAME := orangepi5pro-vendor-drivers
PACKAGES := rk-vcodec rga3 rknpu
ifndef VERSION
VERSION := $(shell tools/version.sh)
endif
OUT ?= out
root := $(abspath $(OUT))/deb
deb := $(abspath $(OUT))/$(NAME)_$(VERSION)_all.deb
dtbos := $(patsubst overlays/%.dts,$(OUT)/dtbo/%.dtbo,$(wildcard overlays/*.dts))
overlays := $(notdir $(basename $(dtbos)))

.PHONY: all src deb install uninstall

all: src $(dtbos)

src:
	tools/dkms-src.sh $(abspath $(OUT))/src

$(OUT)/dtbo/%.dtbo: overlays/%.dts
	@mkdir -p $(@D)
	dtc -q -@ -I dts -O dtb -o $@ $<

deb: src $(dtbos)
	rm -rf $(root)
	$(foreach p,$(PACKAGES),\
		install -d $(root)/usr/src/$(p)-$(VERSION) && \
		cp -R $(OUT)/src/$(p)/. $(root)/usr/src/$(p)-$(VERSION)/ && \
		sed -e 's/@PACKAGE@/$(p)/' -e 's/@MODULE@/$(subst -,_,$(p))/' -e 's/@VERSION@/$(VERSION)/' \
			dkms/dkms.conf.in > $(root)/usr/src/$(p)-$(VERSION)/dkms.conf &&) true
	install -D -m 644 udev/60-rockchip-vendor.rules $(root)/usr/lib/udev/rules.d/60-rockchip-vendor.rules
	install -D -m 644 dkms/modprobe.conf $(root)/usr/lib/modprobe.d/$(NAME).conf
	install -d $(root)/boot/overlay-user $(root)/DEBIAN
	install -m 644 $(dtbos) $(root)/boot/overlay-user/
	$(foreach f,control postinst prerm,\
		sed -e 's/@VERSION@/$(VERSION)/' -e 's/@PACKAGES@/$(PACKAGES)/' -e 's/@OVERLAYS@/$(overlays)/' \
			dkms/debian/$(f) > $(root)/DEBIAN/$(f) &&) true
	chmod 755 $(root)/DEBIAN/postinst $(root)/DEBIAN/prerm
	dpkg-deb --root-owner-group -Zxz --build $(root) $(deb)
	rm -rf $(root)

install: deb
	apt-get install -y --reinstall $(deb)

uninstall:
	apt-get remove -y $(NAME)
