# Velox - build rules
#
#   make            build build/velox (stripped AmigaOS executable)
#   make test       build build/vtest and run the headless tests (vamos)
#   make size       show executable size against the budget
#   make clean      remove build output

TOOLS   := tools/bin
NDK     := tools/ndk/Include_I
VASM    := $(TOOLS)/vasmm68k_mot
VLINK   := $(TOOLS)/vlink

# -x: undefined symbols are errors (catches typos instead of silently
#     creating external references)
# -opt-allbra: also resize branches written with an explicit .s/.w size
ASFLAGS := -Fhunk -m68020 -quiet -x -opt-allbra -I src -I $(NDK)
LDFLAGS := -bamigahunk -Bstatic -s -sc -sd

# Size budget for the executable, in bytes.
BUDGET  := 65536

CORE    := $(patsubst src/%.s,build/%.o,$(filter-out src/main.s,$(wildcard src/*.s)))
INCS    := $(wildcard src/*.i)
TARGET  := build/velox
VTEST   := build/vtest

.PHONY: all clean size test

all: $(TARGET)

$(TARGET): build/main.o $(CORE)
	$(VLINK) $(LDFLAGS) -o $@ $^

$(VTEST): build/vtest.o $(CORE)
	$(VLINK) -bamigahunk -Bstatic -sc -sd -o $@ $^

build/%.o: src/%.s $(INCS) | build
	$(VASM) $(ASFLAGS) -o $@ $<

build/vtest.o: test/vtest.s $(INCS) | build
	$(VASM) $(ASFLAGS) -o $@ $<

build:
	mkdir -p build

test: $(VTEST)
	test/unit.sh

size: $(TARGET)
	@s=$$(stat -c %s $(TARGET)); echo "$(TARGET): $$s bytes ($$((s * 100 / $(BUDGET)))% of $(BUDGET) budget)"

clean:
	rm -rf build
