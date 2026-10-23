# Everyday commands. ./build.sh does the work; these are shortcuts.

.PHONY: build release-build run release release-minor release-major

build:
	./build.sh

release-build:
	./build.sh release

run: build
	open build/Archidea.app

# Tag a release and push it; GitHub builds and publishes it (.github/workflows/release.yml).
#   make release              next patch version
#   make release-minor        next minor version
#   make release v=1.2.3      a given version
release:
	@scripts/release-tag.sh $(if $(v),$(v),$$(python3 scripts/changelog.py next patch))

release-minor:
	@scripts/release-tag.sh $$(python3 scripts/changelog.py next minor)

release-major:
	@scripts/release-tag.sh $$(python3 scripts/changelog.py next major)
