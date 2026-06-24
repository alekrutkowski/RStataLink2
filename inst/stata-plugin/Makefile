# Build the RStataLink2 Stata plugin on Unix-alikes.
# This Makefile is normally called by ../../configure during R package source
# installation. It can also be run manually from this directory.

UNAME_S := $(shell uname -s)
CC ?= cc
CFLAGS ?= -O2 -std=c11
CPPFLAGS ?=
NNG_CFLAGS ?= $(shell pkg-config --cflags nng 2>/dev/null)
NNG_LIBS ?= $(shell pkg-config --libs nng 2>/dev/null || echo -lnng)
TARGET ?= rslng__plugin.plugin

ifeq ($(UNAME_S),Darwin)
  STATA_SYSTEM = APPLEMAC
  PLUGIN_CFLAGS =
  PLUGIN_LDFLAGS = -bundle
else
  STATA_SYSTEM = OPUNIX
  PLUGIN_CFLAGS = -fPIC
  PLUGIN_LDFLAGS = -shared
endif

.PHONY: all clean fetch-spi

all: $(TARGET)

fetch-spi:
	Rscript fetch-stata-spi.R .

$(TARGET): stplugin.c stplugin.h rslng_plugin.c
	$(CC) $(CFLAGS) $(CPPFLAGS) $(PLUGIN_CFLAGS) $(NNG_CFLAGS) -DSYSTEM=$(STATA_SYSTEM) $(PLUGIN_LDFLAGS) stplugin.c rslng_plugin.c -o $@ $(NNG_LIBS)

clean:
	rm -f $(TARGET) *.o *.plugin.x86_64 *.plugin.arm64
