# Forwards all targets into the Flutter project.
.DEFAULT_GOAL := help

help %:
	$(MAKE) -C flutter_app $@
