CC = gcc
CFLAGS += -Wall -Wextra -O2 -g
TARGET = build/server
SRC = server.c

all: $(TARGET)

$(TARGET): $(SRC)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)
	@echo "Ready: $(TARGET)"

clean:
	rm -rf $(dir $(TARGET))

.PHONY: all clean
