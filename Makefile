POC_DIRS := \
	pocs/CVE-2026-52910 \
	pocs/CVE-2026-80521

.PHONY: all clean cve-2026-52910 cve-2026-80521

all: cve-2026-52910 cve-2026-80521

cve-2026-52910:
	$(MAKE) -C pocs/CVE-2026-52910

cve-2026-80521:
	$(MAKE) -C pocs/CVE-2026-80521

clean:
	@for directory in $(POC_DIRS); do \
		$(MAKE) -C "$$directory" clean; \
	done
