SHELL := /bin/sh
NAME ?= demo
SOURCES := main.c widget.c

.PHONY: all clean test
all: build/$(NAME)

build/$(NAME): $(SOURCES)
	$(CC) $(CFLAGS) -o $@ $^

test:
	@echo "running $(NAME)"

clean:
	rm -rf build
