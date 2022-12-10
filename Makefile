DOCKERFILES=$(shell find * -type f -name \*.Dockerfile)
NAMES=$(subst /,\:,$(subst .Dockerfile,,$(DOCKERFILES)))
REGISTRY?=docker.io
ACCOUNT?=jkitching
IMAGES=$(addprefix $(subst :,\:,$(REGISTRY)/$(ACCOUNT))/,$(NAMES))

.PHONY: all build forcebuild pull push run $(NAMES) $(IMAGES)

all: $(NAMES)

build: ;@:

forcebuild: ;@:

pull: ;@:

push: ;@:

run: ;@:

$(NAMES): %: $(REGISTRY)/$(ACCOUNT)/%
ifeq (build,$(filter build,$(MAKECMDGOALS)))
	docker build -t $< -f $@.Dockerfile .
endif
ifeq (forcebuild,$(filter forcebuild,$(MAKECMDGOALS)))
	docker build --no-cache -t $< -f $@.Dockerfile .
endif
ifeq (pull,$(filter pull,$(MAKECMDGOALS)))
	docker pull $<
endif
	@docker inspect $< >/dev/null || \
		( echo "$@ does not exist: use build or pull" && exit 1 )
	docker image tag $< $@
ifeq (push,$(filter push,$(MAKECMDGOALS)))
	docker push $<
endif
ifeq (run,$(filter run,$(MAKECMDGOALS)))
	docker run --rm -it $< /bin/bash
endif
