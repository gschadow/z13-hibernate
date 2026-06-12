# Makefile for z13-hibernate
#
# make install   — copy files into place (as root); does NOT enable/start services
# make deploy    — install + enable services + apply PowerDevil lid policy (as root)
# make bootimage — rebuild initramfs + grub config (after initcpio/cmdline changes)
# make uninstall — remove installed files
#
# /etc/default/grub and /etc/mkinitcpio.conf are NOT touched by any target.
# See etc/default/grub.example and etc/mkinitcpio.conf.example for the parameters
# you need to merge into your system files by hand.

PREFIX  ?= /usr
DESTDIR ?=
# Desktop user whose PowerDevil config deploy adjusts (lid → Do nothing).
PDUSER  ?= gunther

.PHONY: install deploy bootimage uninstall

install:
	# Runtime library + helpers
	install -d $(DESTDIR)$(PREFIX)/lib/z13-hibernate
	install -m 644 src/common.sh                $(DESTDIR)$(PREFIX)/lib/z13-hibernate/common.sh
	install -m 755 src/gate-hook.sh             $(DESTDIR)$(PREFIX)/lib/z13-hibernate/gate-hook.sh
	install -m 755 src/post-resume-hook.sh      $(DESTDIR)$(PREFIX)/lib/z13-hibernate/post-resume-hook.sh
	install -m 755 src/s2idle-wakeup-config.sh  $(DESTDIR)$(PREFIX)/lib/z13-hibernate/s2idle-wakeup-config.sh
	install -m 755 src/cstate-hold.sh           $(DESTDIR)$(PREFIX)/lib/z13-hibernate/cstate-hold.sh
	install -m 755 src/lid-watch.sh             $(DESTDIR)$(PREFIX)/lib/z13-hibernate/lid-watch.sh

	# systemd-sleep hooks (ordering via numeric prefix)
	install -d $(DESTDIR)$(PREFIX)/lib/systemd/system-sleep
	install -m 755 src/hibernate-hook.sh       $(DESTDIR)$(PREFIX)/lib/systemd/system-sleep/05-hibernate-hook.sh
	install -m 755 src/resume-hook.sh          $(DESTDIR)$(PREFIX)/lib/systemd/system-sleep/95-resume-hook.sh
	install -m 755 src/s2idle-resume-fixup.sh  $(DESTDIR)$(PREFIX)/lib/systemd/system-sleep/50-s2idle-resume-fixup.sh

	# systemd drop-in configs (sleep policy + lid switch)
	install -d $(DESTDIR)/etc/systemd/sleep.conf.d
	install -m 644 etc/systemd/sleep.conf.d/z13-suspend-then-hibernate.conf \
	               $(DESTDIR)/etc/systemd/sleep.conf.d/z13-suspend-then-hibernate.conf
	install -d $(DESTDIR)/etc/systemd/logind.conf.d
	install -m 644 etc/systemd/logind.conf.d/z13-lid.conf \
	               $(DESTDIR)/etc/systemd/logind.conf.d/z13-lid.conf

	# systemd units
	install -d $(DESTDIR)$(PREFIX)/lib/systemd/system
	install -m 644 systemd/z13-hibernate-gate.service \
	               $(DESTDIR)$(PREFIX)/lib/systemd/system/z13-hibernate-gate.service
	install -d $(DESTDIR)$(PREFIX)/lib/systemd/system/systemd-hibernate.service.d
	install -m 644 systemd/systemd-hibernate.service.d/10-gate.conf \
	               $(DESTDIR)$(PREFIX)/lib/systemd/system/systemd-hibernate.service.d/10-gate.conf
	install -m 644 systemd/z13-hibernate-boot-cleanup.service \
	               $(DESTDIR)$(PREFIX)/lib/systemd/system/z13-hibernate-boot-cleanup.service
	install -m 644 systemd/z13-s2idle-wakeup.service \
	               $(DESTDIR)$(PREFIX)/lib/systemd/system/z13-s2idle-wakeup.service
	install -m 644 systemd/z13-lid-watch.service \
	               $(DESTDIR)$(PREFIX)/lib/systemd/system/z13-lid-watch.service

	# initcpio hook (two search paths: /etc and /usr/lib)
	install -d $(DESTDIR)/etc/initcpio/hooks $(DESTDIR)/etc/initcpio/install
	install -m 755 etc/initcpio/hooks/hib-resume-prep \
	               $(DESTDIR)/etc/initcpio/hooks/hib-resume-prep
	install -m 755 etc/initcpio/install/hib-resume-prep.install \
	               $(DESTDIR)/etc/initcpio/install/hib-resume-prep
	install -d $(DESTDIR)$(PREFIX)/lib/initcpio/hooks $(DESTDIR)$(PREFIX)/lib/initcpio/install
	install -m 755 etc/initcpio/hooks/hib-resume-prep \
	               $(DESTDIR)$(PREFIX)/lib/initcpio/hooks/hib-resume-prep
	install -m 755 etc/initcpio/install/hib-resume-prep.install \
	               $(DESTDIR)$(PREFIX)/lib/initcpio/install/hib-resume-prep

	@echo ""
	@echo "Files installed. Next steps:"
	@echo "  1. Merge etc/default/grub.example params into your /etc/default/grub"
	@echo "  2. Add 'hib-resume-prep' before 'sd-encrypt' in /etc/mkinitcpio.conf HOOKS"
	@echo "  3. Run: make deploy     (enables services, applies sleep + lid policy)"
	@echo "  4. Run: make bootimage  (rebuilds initramfs + grub config)"

deploy: install
	systemctl daemon-reload
	systemctl enable z13-hibernate-gate.service
	systemctl enable z13-hibernate-boot-cleanup.service
	systemctl enable --now z13-s2idle-wakeup.service
	systemctl enable --now z13-lid-watch.service
	# PowerDevil must not act on the raw lid: z13-lid-watch owns it (3s
	# debounce; raw lid events race s2idle on this machine). 0 = Do nothing.
	-sudo -u $(PDUSER) kwriteconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key LidAction --notify 0
	-sudo -u $(PDUSER) kwriteconfig6 --file powerdevilrc --group Battery --group SuspendAndShutdown --key LidAction --notify 0
	-sudo -u $(PDUSER) kwriteconfig6 --file powerdevilrc --group LowBattery --group SuspendAndShutdown --key LidAction --notify 0
	@echo ""
	@echo "Services enabled. Sleep, lid, and PowerDevil lid policy applied."
	@echo "Run 'make bootimage' if the initcpio hook or kernel cmdline changed."
	@echo "NOTE: logind.conf changes take effect on next full reboot (do NOT restart logind live)"

bootimage:
	mkinitcpio -P
	grub-mkconfig -o /boot/grub/grub.cfg

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/lib/z13-hibernate/common.sh
	rm -f $(DESTDIR)$(PREFIX)/lib/z13-hibernate/gate-hook.sh
	rm -f $(DESTDIR)$(PREFIX)/lib/z13-hibernate/post-resume-hook.sh
	rm -f $(DESTDIR)$(PREFIX)/lib/z13-hibernate/s2idle-wakeup-config.sh
	rm -f $(DESTDIR)$(PREFIX)/lib/z13-hibernate/cstate-hold.sh
	rm -f $(DESTDIR)$(PREFIX)/lib/z13-hibernate/lid-watch.sh
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/system/z13-s2idle-wakeup.service
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/system/z13-lid-watch.service
	-rmdir $(DESTDIR)$(PREFIX)/lib/z13-hibernate 2>/dev/null || true
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/system-sleep/05-hibernate-hook.sh
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/system-sleep/95-resume-hook.sh
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/system-sleep/50-s2idle-resume-fixup.sh
	rm -f $(DESTDIR)/etc/systemd/sleep.conf.d/z13-suspend-then-hibernate.conf
	rm -f $(DESTDIR)/etc/systemd/logind.conf.d/z13-lid.conf
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/system/z13-hibernate-gate.service
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/system/systemd-hibernate.service.d/10-gate.conf
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/system/z13-hibernate-boot-cleanup.service
	rm -f $(DESTDIR)/etc/initcpio/hooks/hib-resume-prep
	rm -f $(DESTDIR)/etc/initcpio/install/hib-resume-prep
	rm -f $(DESTDIR)$(PREFIX)/lib/initcpio/hooks/hib-resume-prep
	rm -f $(DESTDIR)$(PREFIX)/lib/initcpio/install/hib-resume-prep
	@echo "Uninstalled. Your /etc/default/grub and /etc/mkinitcpio.conf were not touched."
