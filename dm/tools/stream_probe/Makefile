include ../../mac/min_os.mk
CFLAGS=-O1 -g -Wall -fobjc-arc -mmacosx-version-min=$(MACOS_MIN)

stream_probe: stream_probe.m ../../host/stream_proto.h ../../mac/min_os.mk
	clang $(CFLAGS) -o $@ stream_probe.m -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo

clean:
	rm -rf stream_probe stream_probe.dSYM

.PHONY: clean
