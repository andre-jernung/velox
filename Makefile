# Velox - build rules
#
#   make            build build/velox (stripped AmigaOS executable)
#   make clean      remove build output
#   make size       show executable size against the budget

TOOLS   := tools/bin
NDK     := tools/ndk/Include_I
VASM    := $(TOOLS)/vasmm68k_mot
VLINK   := $(TOOLS)/vlink

# -x: undefined symbols are errors (catches typos instead of silently
#     creating external references)
ASFLAGS := -Fhunk -m68020 -quiet -x -I src -I $(NDK)
LDFLAGS := -bamigahunk -Bstatic -s -sc -sd

# Size budget for the executable, in bytes.
BUDGET  := 65536

SRCS    := $(wildcard src/*.s)
OBJS    := $(patsubst src/%.s,build/%.o,$(SRCS))
INCS    := $(wildcard src/*.i)
TARGET  := build/velox

.PHONY: all clean size

all: $(TARGET)

$(TARGET): $(OBJS)
	$(VLINK) $(LDFLAGS) -o $@ $^

build/%.o: src/%.s $(INCS) | build
	$(VASM) $(ASFLAGS) -o $@ $<

build:
	mkdir -p build

size: $(TARGET)
	@s=$$(stat -c %s $(TARGET)); echo "$(TARGET): $$s bytes ($$((s * 100 / $(BUDGET)))% of $(BUDGET) budget)"

clean:
	rm -rf build
