#include "MOBIBridge.h"
#include "../Vendor/libmobi/mobi.h"
#include <libxml/HTMLparser.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define READLE_TEXT_LIMIT (32 * 1024 * 1024)

typedef struct { char *data; size_t size; size_t capacity; int failed; } TextBuffer;

static void append(TextBuffer *buffer, const char *text) {
    if (buffer->failed || !text) return;
    size_t length = strlen(text);
    if (length > READLE_TEXT_LIMIT - buffer->size) { buffer->failed = 100; return; }
    size_t needed = buffer->size + length + 1;
    if (needed > buffer->capacity) {
        size_t capacity = needed > buffer->capacity * 2 ? needed : buffer->capacity * 2;
        char *grown = realloc(buffer->data, capacity);
        if (!grown) { buffer->failed = MOBI_MALLOC_FAILED; return; }
        buffer->data = grown; buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->size, text, length + 1);
    buffer->size += length;
}

static int tag(xmlNode *node, const char *name) { return xmlStrcasecmp(node->name, (const xmlChar *)name) == 0; }

// Traverse recovered HTML, including older MOBI markup with unclosed p/br tags.
static void extract(xmlNode *node, TextBuffer *buffer, char **heading, unsigned depth) {
    if (depth > 256) { buffer->failed = MOBI_DATA_CORRUPT; return; }
    for (; node && !buffer->failed; node = node->next) {
        if (node->type == XML_TEXT_NODE || node->type == XML_CDATA_SECTION_NODE) {
            append(buffer, (const char *)node->content); continue;
        }
        if (node->type != XML_ELEMENT_NODE) continue;
        if (tag(node, "head") || tag(node, "script") || tag(node, "style") || tag(node, "nav") || tag(node, "svg")) continue;
        int block = tag(node, "p") || tag(node, "div") || tag(node, "li") || tag(node, "blockquote") ||
            tag(node, "section") || tag(node, "article") || tag(node, "tr") || tag(node, "br") ||
            tag(node, "hr") || tag(node, "pagebreak") || tag(node, "mbp:pagebreak") ||
            tag(node, "h1") || tag(node, "h2") || tag(node, "h3") || tag(node, "h4") || tag(node, "h5") || tag(node, "h6");
        if (block) append(buffer, "\n");
        int isHeading = !*heading && (tag(node, "h1") || tag(node, "h2") || tag(node, "h3"));
        size_t start = buffer->size;
        extract(node->children, buffer, heading, depth + 1);
        if (isHeading && !*heading && !buffer->failed && buffer->size > start) {
            *heading = strndup(buffer->data + start, buffer->size - start);
            if (!*heading) buffer->failed = MOBI_MALLOC_FAILED;
        }
        if (block) append(buffer, "\n");
    }
}

void readle_mobi_free(ReadleMOBIBook *book) {
    if (!book) return;
    for (size_t i = 0; i < book->count; i++) { free(book->parts[i].heading); free(book->parts[i].text); }
    free(book->parts); free(book->title); free(book->author); free(book->cover); free(book);
}

ReadleMOBIBook *readle_mobi_load(const char *path, int *status) {
    *status = MOBI_INIT_FAILED;
    MOBIData *mobi = mobi_init();
    if (!mobi) return NULL;
    MOBIRawml *raw = NULL;
    ReadleMOBIBook *book = NULL;
    *status = mobi_load_filename(mobi, path);
    if (*status != MOBI_SUCCESS) goto cleanup;
    if (mobi_is_encrypted(mobi)) { *status = MOBI_FILE_ENCRYPTED; goto cleanup; }
    size_t maximum = mobi_get_text_maxsize(mobi);
    if (maximum == MOBI_NOTSET) { *status = MOBI_DATA_CORRUPT; goto cleanup; }
    if (maximum > READLE_TEXT_LIMIT) { *status = 100; goto cleanup; }
    raw = mobi_init_rawml(mobi);
    if (!raw) { *status = MOBI_MALLOC_FAILED; goto cleanup; }
    // Reconstruct KF8 fragments in reading order. Link/resource rewriting is unnecessary for text.
    *status = mobi_parse_rawml_opt(raw, mobi, false, false, false);
    if (*status != MOBI_SUCCESS) goto cleanup;
    book = calloc(1, sizeof(*book));
    if (!book) { *status = MOBI_MALLOC_FAILED; goto cleanup; }
    book->title = mobi_meta_get_title(mobi);
    book->author = mobi_meta_get_author(mobi);
    // The embedded cover: EXTH 201 gives its offset among the resource records.
    MOBIExthHeader *coverTag = mobi_get_exthrecord_by_tag(mobi, EXTH_COVEROFFSET);
    size_t firstResource = mobi_get_first_resource_record(mobi);
    if (coverTag && firstResource != MOBI_NOTSET) {
        uint32_t offset = mobi_decode_exthvalue(coverTag->data, coverTag->size);
        MOBIPdbRecord *record = mobi_get_record_by_seqnumber(mobi, firstResource + offset);
        if (record && record->data && record->size > 0 && record->size < 20000000) {
            book->cover = malloc(record->size);
            if (book->cover) { memcpy(book->cover, record->data, record->size); book->coverSize = record->size; }
        }
    }
    size_t total = 0;
    for (MOBIPart *part = raw->markup; part; part = part->next) {
        if (part->type != T_HTML || !part->size) continue;
        if (part->size > READLE_TEXT_LIMIT - total || book->count >= 3000) { *status = 100; goto cleanup; }
        total += part->size;
        htmlDocPtr doc = htmlReadMemory((const char *)part->data, (int)part->size, NULL, "UTF-8",
            HTML_PARSE_RECOVER | HTML_PARSE_NONET | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING | HTML_PARSE_COMPACT);
        if (!doc) { *status = MOBI_DATA_CORRUPT; goto cleanup; }
        TextBuffer buffer = {0};
        char *heading = NULL;
        extract(xmlDocGetRootElement(doc), &buffer, &heading, 0);
        xmlFreeDoc(doc);
        if (buffer.failed) { free(buffer.data); free(heading); *status = buffer.failed; goto cleanup; }
        if (!buffer.size) { free(buffer.data); free(heading); continue; }
        ReadleMOBIPart *parts = realloc(book->parts, (book->count + 1) * sizeof(*parts));
        if (!parts) { free(buffer.data); free(heading); *status = MOBI_MALLOC_FAILED; goto cleanup; }
        book->parts = parts;
        book->parts[book->count++] = (ReadleMOBIPart){ heading, buffer.data };
    }
cleanup:
    if (raw) mobi_free_rawml(raw);
    mobi_free(mobi);
    if (*status != MOBI_SUCCESS) { readle_mobi_free(book); return NULL; }
    return book;
}
