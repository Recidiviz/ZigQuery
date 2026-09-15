// A narrow C surface over nanoarrow, for the Storage Read API's ARROW format.
//
// Why this exists: translate-c cannot read nanoarrow's headers. Two of its
// `static inline` helpers translate to invalid Zig — an assignment to a cast in
// one, a `[3]c_uint` where a `c_uint` is expected in the other — and translate-c
// fails whole-header, so one bad inline declaration takes the entire API with
// it. Worse, the functions this encoder actually needs (`ArrowArrayAppend*`)
// are themselves `static inline`, so suppressing that header would remove the
// thing we came for.
//
// So the C stays in C, and Zig sees only the flat surface below. That is the
// same shape as //shim over the GoogleSQL analyzer: a narrow C ABI in front of
// a large C/C++ library, with all the struct layout knowledge on this side.
//
// Every function returns an errno-style int — 0 on success — matching
// nanoarrow's own convention, except where a pointer or void is the natural
// return. `zq_arrow_last_error` gives the message for the most recent failure
// on this thread.

#ifndef ZQ_NANOARROW_SHIM_H
#define ZQ_NANOARROW_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handles. Their layouts are nanoarrow's business, and keeping them
// behind pointers is what lets Zig avoid ever seeing an ArrowArrayView.
typedef struct ZqArrowSchema ZqArrowSchema;
typedef struct ZqArrowBuilder ZqArrowBuilder;

// The subset of nanoarrow's type enum this encoder emits. Deliberately not the
// whole of it: a value here is one the mapping recorded from BigQuery uses.
enum ZqArrowType {
  ZQ_ARROW_BOOL = 1,
  ZQ_ARROW_INT64,
  ZQ_ARROW_DOUBLE,
  ZQ_ARROW_STRING,
  ZQ_ARROW_BINARY,
  ZQ_ARROW_DATE32,
  ZQ_ARROW_TIME64_US,
  ZQ_ARROW_TIMESTAMP_US,      // no timezone -- DATETIME
  ZQ_ARROW_TIMESTAMP_US_UTC,  // tz=UTC -- TIMESTAMP
  ZQ_ARROW_INTERVAL_MONTH_DAY_NANO,
  ZQ_ARROW_DECIMAL128,
  ZQ_ARROW_DECIMAL256,
  ZQ_ARROW_STRUCT,
  ZQ_ARROW_LIST,
};

// The message for the most recent failure. Valid until the next shim call.
const char* zq_arrow_last_error(void);

// ---- schema ----

// A root struct schema with `n_children` fields, already typed -- the root
// needs no zq_arrow_schema_set_type, and calling one on it fails (its children
// are allocated, and nanoarrow refuses to allocate them twice).
// Freed by zq_arrow_schema_free.
ZqArrowSchema* zq_arrow_schema_new(int64_t n_children);
void zq_arrow_schema_free(ZqArrowSchema* schema);

// Addresses a node by path from the root: {} is the root, {2} its third child,
// {2,0} that child's first child. Returns NULL if the path does not resolve.
// A path rather than a cursor because the Zig side walks a `spec.Type` tree and
// already knows where it is.
int zq_arrow_schema_set_type(ZqArrowSchema* schema, const int32_t* path, int32_t path_len,
                             int type, int64_t n_children);

// precision/scale for DECIMAL128/DECIMAL256; ignored otherwise.
int zq_arrow_schema_set_decimal(ZqArrowSchema* schema, const int32_t* path,
                                int32_t path_len, int type, int32_t precision,
                                int32_t scale);

int zq_arrow_schema_set_name(ZqArrowSchema* schema, const int32_t* path,
                             int32_t path_len, const char* name);

int zq_arrow_schema_set_nullable(ZqArrowSchema* schema, const int32_t* path,
                                 int32_t path_len, int nullable);

// One key/value pair of field metadata, appended. BigQuery uses
// "ARROW:extension:name" for DATETIME/JSON/GEOGRAPHY/INTERVAL and a plain
// "google:sqlType" for RANGE, so both spellings go through here.
int zq_arrow_schema_add_metadata(ZqArrowSchema* schema, const int32_t* path,
                                 int32_t path_len, const char* key, const char* value);

// The encapsulated IPC schema message. The bytes belong to the schema handle
// and live until the next call to this function on it.
int zq_arrow_encode_schema(ZqArrowSchema* schema, const uint8_t** out, int64_t* out_len);

// ---- reading a schema back, for tests ----
//
// Every setter above is write-only, which would leave a test with nothing to
// assert but "no error". These two read the built tree back so the recorded
// mapping can be checked field by field without a flatbuffer decoder in the
// loop. Both return the number of characters the answer needs -- the usual
// snprintf contract -- and write at most `n - 1` of them plus a terminator.

// nanoarrow's own rendering of the node at `path`, children included:
// "struct<start: date32[day], end: date32[day]>".
int64_t zq_arrow_schema_describe(ZqArrowSchema* schema, const int32_t* path,
                                 int32_t path_len, char* out, int64_t n);

// The metadata value for `key`, or -1 when the node carries no such key --
// which is different from a key whose value is empty.
int64_t zq_arrow_schema_metadata(ZqArrowSchema* schema, const int32_t* path,
                                 int32_t path_len, const char* key, char* out,
                                 int64_t n);

// Whether the node at `path` is nullable, or -1 if the path does not resolve.
int zq_arrow_schema_is_nullable(ZqArrowSchema* schema, const int32_t* path,
                                int32_t path_len);

// ---- rows ----

// A builder over `schema`, which must outlive it.
ZqArrowBuilder* zq_arrow_builder_new(ZqArrowSchema* schema);
void zq_arrow_builder_free(ZqArrowBuilder* builder);

// Appends one value to the node at `path`. For a leaf that is the value; for a
// STRUCT or LIST, `zq_arrow_append_finish_element` closes the element after its
// children have been appended.
int zq_arrow_append_null(ZqArrowBuilder* b, const int32_t* path, int32_t path_len);
int zq_arrow_append_int(ZqArrowBuilder* b, const int32_t* path, int32_t path_len,
                        int64_t v);
int zq_arrow_append_double(ZqArrowBuilder* b, const int32_t* path, int32_t path_len,
                           double v);
int zq_arrow_append_bytes(ZqArrowBuilder* b, const int32_t* path, int32_t path_len,
                          const uint8_t* data, int64_t len);
// `le` is the unscaled value as 16 or 32 bytes of little-endian two's
// complement, which is how nanoarrow's decimal wants it -- note this is the
// opposite order from Avro's big-endian decimal.
int zq_arrow_append_decimal(ZqArrowBuilder* b, const int32_t* path, int32_t path_len,
                            int bits, const uint8_t* le);
int zq_arrow_append_interval(ZqArrowBuilder* b, const int32_t* path, int32_t path_len,
                             int32_t months, int32_t days, int64_t nanos);
int zq_arrow_append_finish_element(ZqArrowBuilder* b, const int32_t* path,
                                   int32_t path_len);

// How many rows have been appended to the root.
int64_t zq_arrow_builder_len(ZqArrowBuilder* b);

// How many bytes those rows currently occupy, summed over every buffer in the
// tree. Not the encoded size -- there is no header or padding in it yet -- but
// it tracks the encoded size closely enough to decide when to flush a batch,
// which is the only thing it is for. Arrow gives no cheaper answer: a columnar
// builder has no size until its buffers are asked.
int64_t zq_arrow_builder_bytes(ZqArrowBuilder* b);

// The encapsulated IPC record batch for everything appended so far. The bytes
// belong to the builder and live until the next call on it. After this the
// builder is spent; make a new one for the next batch.
int zq_arrow_encode_batch(ZqArrowBuilder* b, const uint8_t** out, int64_t* out_len);

#ifdef __cplusplus
}
#endif

#endif  // ZQ_NANOARROW_SHIM_H
