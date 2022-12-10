DOCKERFILES=$(shell find * -type f -name \*Dockerfile)
NAMES=$(subst /,\:,$(subst .Dockerfile,,$(DOCKERFILES)))
REGISTRY?=docker.io
ACCOUNT?=jkitching
IMAGES=$(addprefix $(subst :,\:,$(REGISTRY)/$(ACCOUNT))/,$(NAMES))

.PHONY: all push pull run $(NAMES) $(IMAGES)

all: $(NAMES)

push: ;@:

pull: ;@:

run: ;@:

$(NAMES): %: $(REGISTRY)/$(ACCOUNT)/%
ifeq (push,$(filter push,$(MAKECMDGOALS)))
	docker push $<
endif
ifeq (run,$(filter run,$(MAKECMDGOALS)))
	docker run --rm -it $< /bin/bash
endif

$(IMAGES): %:
ifeq (pull,$(filter pull,$(MAKECMDGOALS)))
	docker pull $@
else
	docker build -t $@ -f $(subst :,/,$(subst $(REGISTRY)/$(ACCOUNT)/,,$@)).Dockerfile .
endif
