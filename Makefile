# Glorbo Makefile — thin wrapper over the canonical `mix` verbs.
#
# `make` (no target) builds the Burrito linux_x86_64 release and
# materialises `./glorbo` in the project root pointing at the fresh
# binary, matching `mix glorbo.build_local` exactly. Distros that want
# a vendored binary file in-tree should run `make build-real`.

MIX        ?= mix
TARGET     := burrito_out/glorbo_linux_x86_64
SYMLINK    := glorbo

.PHONY: help build build-real clean clean-burrito test precommit format credo \
        serve up down doctor migrate setup

# Default — match the workflow most contributors use.
build: $(TARGET)
	@ln -sfn $(TARGET) $(SYMLINK)
	@printf '✓ ./%s -> %s\n' "$(SYMLINK)" "$(TARGET)"

# Burrito release. The mix task clears `~/.local/share/.burrito` first
# so config changes propagate; declared as a real file target so
# downstream rules can depend on it without forcing a rebuild every
# invocation.
$(TARGET):
	$(MIX) glorbo.build_local

# Materialise a real binary at `./glorbo` (copy, not symlink). Useful
# when shipping the project root to a tarball / container that doesn't
# preserve symlinks.
build-real: $(TARGET)
	cp -f $(TARGET) $(SYMLINK)
	@printf '✓ ./%s (real binary, %s)\n' "$(SYMLINK)" "$$(stat -c '%s bytes' $(SYMLINK))"

# Common dev verbs. Mirror the flow already in CLAUDE.md so muscle
# memory works whether you type `mix` or `make`.
test:
	$(MIX) test

precommit:
	$(MIX) precommit

format:
	$(MIX) format

credo:
	$(MIX) credo --strict

setup:
	$(MIX) setup

# Lifecycle wrappers — operate on the symlinked binary so they exercise
# the same code path operators run.
serve: build
	./$(SYMLINK) serve

up: build
	./$(SYMLINK) up

down:
	./$(SYMLINK) down

doctor: build
	./$(SYMLINK) doctor

migrate: build
	./$(SYMLINK) migrate

clean:
	rm -rf _build deps/.compile.* $(SYMLINK)

clean-burrito:
	rm -rf burrito_out $(SYMLINK)
	rm -rf $(HOME)/.local/share/.burrito

help:
	@printf 'Glorbo Make targets:\n'
	@printf '  build           Build burrito linux_x86_64 + symlink ./glorbo (default)\n'
	@printf '  build-real      Build + COPY (not symlink) the binary to ./glorbo\n'
	@printf '  test            mix test\n'
	@printf '  precommit       mix precommit (compile-warn / format / credo / docs / test)\n'
	@printf '  format          mix format\n'
	@printf '  credo           mix credo --strict\n'
	@printf '  setup           mix setup (deps + db + esbuild)\n'
	@printf '  serve|up|down   Run the local binary\n'
	@printf '  doctor          ./glorbo doctor\n'
	@printf '  migrate         ./glorbo migrate\n'
	@printf '  clean           Drop _build + ./glorbo symlink\n'
	@printf '  clean-burrito   Drop burrito_out, the symlink, and ~/.local/share/.burrito\n'
