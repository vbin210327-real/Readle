#ifndef READLE_MOBI_BRIDGE_H
#define READLE_MOBI_BRIDGE_H
#include <stddef.h>

typedef struct { char *heading; char *text; } ReadleMOBIPart;
typedef struct {
    char *title;
    char *author;
    size_t count;
    ReadleMOBIPart *parts;
    unsigned char *cover;
    size_t coverSize;
} ReadleMOBIBook;

// Returns owned UTF-8 text. Status 5 means encrypted, 100 means too large.
ReadleMOBIBook *readle_mobi_load(const char *path, int *status);
void readle_mobi_free(ReadleMOBIBook *book);
#endif
