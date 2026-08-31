// See nanoarrow_shim.h for why this file exists.

#include "nanoarrow_shim.h"

#include <stdlib.h>
#include <string.h>

#include "nanoarrow/nanoarrow.h"
#include "nanoarrow/nanoarrow_ipc.h"

// nanoarrow reports through a caller-supplied ArrowError; the Zig side has no
// use for one per call, so failures land here and `zq_arrow_last_error` reads
// them back. Thread-local because the gRPC completion queue is one thread today
// but nothing in the design promises it stays that way.
static _Thread_local struct ArrowError zq_error;

const char* zq_arrow_last_error(void) { return zq_error.message; }

static void zq_set_error(const char* msg) {
  ArrowErrorSet(&zq_error, "%s", msg);
}

struct ZqArrowSchema {
  struct ArrowSchema schema;
  // The encapsulated IPC message from the last zq_arrow_encode_schema.
  struct ArrowBuffer encoded;
};

struct ZqArrowBuilder {
  struct ArrowSchema* schema;  // borrowed
  struct ArrowArray array;
  struct ArrowArrayView view;
  int view_ready;
  struct ArrowBuffer encoded;
};

// ---- paths ----

// nanoarrow's children are a flat array per node, so a path walk is a loop.
static struct ArrowSchema* schema_at(struct ArrowSchema* root, const int32_t* path,
                                     int32_t path_len) {
  struct ArrowSchema* node = root;
  for (int32_t i = 0; i < path_len; i++) {
    if (node->n_children <= path[i]) return NULL;
    node = node->children[path[i]];
    if (node == NULL) return NULL;
  }
  return node;
}

static struct ArrowArray* array_at(struct ArrowArray* root, const int32_t* path,
                                   int32_t path_len) {
  struct ArrowArray* node = root;
  for (int32_t i = 0; i < path_len; i++) {
    if (node->n_children <= path[i]) return NULL;
    node = node->children[path[i]];
    if (node == NULL) return NULL;
  }
  return node;
}

// ---- schema ----

ZqArrowSchema* zq_arrow_schema_new(int64_t n_children) {
  ZqArrowSchema* out = (ZqArrowSchema*)calloc(1, sizeof(ZqArrowSchema));
  if (out == NULL) return NULL;
  ArrowBufferInit(&out->encoded);
  ArrowSchemaInit(&out->schema);
  // SetTypeStruct rather than InitFromType + AllocateChildren: AllocateChildren
  // leaves each child with only `release` set, so a later ArrowSchemaSetType on
  // one would free a garbage `format` pointer. SetTypeStruct inits them.
  if (ArrowSchemaSetTypeStruct(&out->schema, n_children) != NANOARROW_OK) {
    zq_arrow_schema_free(out);
    return NULL;
  }
  return out;
}

void zq_arrow_schema_free(ZqArrowSchema* schema) {
  if (schema == NULL) return;
  if (schema->schema.release != NULL) schema->schema.release(&schema->schema);
  ArrowBufferReset(&schema->encoded);
  free(schema);
}

int zq_arrow_schema_set_type(ZqArrowSchema* schema, const int32_t* path,
                             int32_t path_len, int type, int64_t n_children) {
  struct ArrowSchema* node = schema_at(&schema->schema, path, path_len);
  if (node == NULL) {
    zq_set_error("schema path does not resolve");
    return EINVAL;
  }
  int code;
  switch (type) {
    case ZQ_ARROW_BOOL:
      code = ArrowSchemaSetType(node, NANOARROW_TYPE_BOOL);
      break;
    case ZQ_ARROW_INT64:
      code = ArrowSchemaSetType(node, NANOARROW_TYPE_INT64);
      break;
    case ZQ_ARROW_DOUBLE:
      code = ArrowSchemaSetType(node, NANOARROW_TYPE_DOUBLE);
      break;
    case ZQ_ARROW_STRING:
      code = ArrowSchemaSetType(node, NANOARROW_TYPE_STRING);
      break;
    case ZQ_ARROW_BINARY:
      code = ArrowSchemaSetType(node, NANOARROW_TYPE_BINARY);
      break;
    case ZQ_ARROW_DATE32:
      code = ArrowSchemaSetType(node, NANOARROW_TYPE_DATE32);
      break;
    case ZQ_ARROW_TIME64_US:
      code = ArrowSchemaSetTypeDateTime(node, NANOARROW_TYPE_TIME64,
                                        NANOARROW_TIME_UNIT_MICRO, NULL);
      break;
    case ZQ_ARROW_TIMESTAMP_US:
      // No timezone: this is DATETIME, and the absence of a zone is what
      // separates it from TIMESTAMP on the wire.
      code = ArrowSchemaSetTypeDateTime(node, NANOARROW_TYPE_TIMESTAMP,
                                        NANOARROW_TIME_UNIT_MICRO, NULL);
      break;
    case ZQ_ARROW_TIMESTAMP_US_UTC:
      code = ArrowSchemaSetTypeDateTime(node, NANOARROW_TYPE_TIMESTAMP,
                                        NANOARROW_TIME_UNIT_MICRO, "UTC");
      break;
    case ZQ_ARROW_INTERVAL_MONTH_DAY_NANO:
      code = ArrowSchemaSetType(node, NANOARROW_TYPE_INTERVAL_MONTH_DAY_NANO);
      break;
    case ZQ_ARROW_STRUCT:
      code = ArrowSchemaSetTypeStruct(node, n_children);
      break;
    case ZQ_ARROW_LIST:
      // SetType(LIST) allocates the single "item" child for us.
      code = ArrowSchemaSetType(node, NANOARROW_TYPE_LIST);
      break;
    default:
      zq_set_error("unsupported arrow type");
      return EINVAL;
  }
  if (code != NANOARROW_OK) zq_set_error("ArrowSchemaSetType failed");
  return code;
}

int zq_arrow_schema_set_decimal(ZqArrowSchema* schema, const int32_t* path,
                                int32_t path_len, int type, int32_t precision,
                                int32_t scale) {
  struct ArrowSchema* node = schema_at(&schema->schema, path, path_len);
  if (node == NULL) {
    zq_set_error("schema path does not resolve");
    return EINVAL;
  }
  enum ArrowType t =
      type == ZQ_ARROW_DECIMAL256 ? NANOARROW_TYPE_DECIMAL256 : NANOARROW_TYPE_DECIMAL128;
  int code = ArrowSchemaSetTypeDecimal(node, t, precision, scale);
  if (code != NANOARROW_OK) zq_set_error("ArrowSchemaSetTypeDecimal failed");
  return code;
}

int zq_arrow_schema_set_name(ZqArrowSchema* schema, const int32_t* path,
                             int32_t path_len, const char* name) {
  struct ArrowSchema* node = schema_at(&schema->schema, path, path_len);
  if (node == NULL) {
    zq_set_error("schema path does not resolve");
    return EINVAL;
  }
  int code = ArrowSchemaSetName(node, name);
  if (code != NANOARROW_OK) zq_set_error("ArrowSchemaSetName failed");
  return code;
}

int zq_arrow_schema_set_nullable(ZqArrowSchema* schema, const int32_t* path,
                                 int32_t path_len, int nullable) {
  struct ArrowSchema* node = schema_at(&schema->schema, path, path_len);
  if (node == NULL) {
    zq_set_error("schema path does not resolve");
    return EINVAL;
  }
  if (nullable) {
    node->flags |= ARROW_FLAG_NULLABLE;
  } else {
    node->flags &= ~ARROW_FLAG_NULLABLE;
  }
  return 0;
}

int zq_arrow_schema_add_metadata(ZqArrowSchema* schema, const int32_t* path,
                                 int32_t path_len, const char* key, const char* value) {
  struct ArrowSchema* node = schema_at(&schema->schema, path, path_len);
  if (node == NULL) {
    zq_set_error("schema path does not resolve");
    return EINVAL;
  }
  // Metadata is a packed buffer, so appending means rebuilding it from whatever
  // is already there.
  struct ArrowBuffer buf;
  ArrowBufferInit(&buf);
  int code = ArrowMetadataBuilderInit(&buf, node->metadata);
  if (code == NANOARROW_OK) {
    code = ArrowMetadataBuilderAppend(&buf, ArrowCharView(key), ArrowCharView(value));
  }
  if (code == NANOARROW_OK) {
    code = ArrowSchemaSetMetadata(node, (const char*)buf.data);
  }
  ArrowBufferReset(&buf);
  if (code != NANOARROW_OK) zq_set_error("ArrowSchemaSetMetadata failed");
  return code;
}

int zq_arrow_encode_schema(ZqArrowSchema* schema, const uint8_t** out,
                           int64_t* out_len) {
  struct ArrowIpcEncoder encoder;
  int code = ArrowIpcEncoderInit(&encoder);
  if (code != NANOARROW_OK) {
    zq_set_error("ArrowIpcEncoderInit failed");
    return code;
  }
  ArrowBufferReset(&schema->encoded);
  ArrowBufferInit(&schema->encoded);
  code = ArrowIpcEncoderEncodeSchema(&encoder, &schema->schema, &zq_error);
  if (code == NANOARROW_OK) {
    // encapsulate = 1: a standalone message, which is what the proto's bytes
    // field carries -- schema and batches travel separately, not as a stream.
    code = ArrowIpcEncoderFinalizeBuffer(&encoder, 1, &schema->encoded);
  }
  ArrowIpcEncoderReset(&encoder);
  if (code != NANOARROW_OK) return code;
  *out = schema->encoded.data;
  *out_len = schema->encoded.size_bytes;
  return 0;
}

// ---- reading a schema back ----

int64_t zq_arrow_schema_describe(ZqArrowSchema* schema, const int32_t* path,
                                 int32_t path_len, char* out, int64_t n) {
  struct ArrowSchema* node = schema_at(&schema->schema, path, path_len);
  if (node == NULL) {
    zq_set_error("schema path does not resolve");
    return -1;
  }
  return ArrowSchemaToString(node, out, n, 1);
}

int64_t zq_arrow_schema_metadata(ZqArrowSchema* schema, const int32_t* path,
                                 int32_t path_len, const char* key, char* out,
                                 int64_t n) {
  struct ArrowSchema* node = schema_at(&schema->schema, path, path_len);
  if (node == NULL) {
    zq_set_error("schema path does not resolve");
    return -1;
  }
  if (node->metadata == NULL) return -1;
  // GetValue leaves value_out alone when the key is absent, so a zero-length
  // seed is how "absent" is told from "present but empty".
  struct ArrowStringView value = {NULL, 0};
  if (ArrowMetadataGetValue(node->metadata, ArrowCharView(key), &value) != NANOARROW_OK) {
    return -1;
  }
  if (value.data == NULL) return -1;
  if (n > 0) {
    int64_t copied = value.size_bytes < n - 1 ? value.size_bytes : n - 1;
    memcpy(out, value.data, (size_t)copied);
    out[copied] = '\0';
  }
  return value.size_bytes;
}

int zq_arrow_schema_is_nullable(ZqArrowSchema* schema, const int32_t* path,
                                int32_t path_len) {
  struct ArrowSchema* node = schema_at(&schema->schema, path, path_len);
  if (node == NULL) {
    zq_set_error("schema path does not resolve");
    return -1;
  }
  return (node->flags & ARROW_FLAG_NULLABLE) != 0;
}

// ---- rows ----

ZqArrowBuilder* zq_arrow_builder_new(ZqArrowSchema* schema) {
  ZqArrowBuilder* b = (ZqArrowBuilder*)calloc(1, sizeof(ZqArrowBuilder));
  if (b == NULL) return NULL;
  b->schema = &schema->schema;
  ArrowBufferInit(&b->encoded);
  if (ArrowArrayInitFromSchema(&b->array, b->schema, &zq_error) != NANOARROW_OK ||
      ArrowArrayStartAppending(&b->array) != NANOARROW_OK) {
    free(b);
    return NULL;
  }
  return b;
}

void zq_arrow_builder_free(ZqArrowBuilder* b) {
  if (b == NULL) return;
  if (b->view_ready) ArrowArrayViewReset(&b->view);
  if (b->array.release != NULL) b->array.release(&b->array);
  ArrowBufferReset(&b->encoded);
  free(b);
}

#define ZQ_NODE(b, path, path_len)                     \
  struct ArrowArray* node = array_at(&(b)->array, path, path_len); \
  if (node == NULL) {                                  \
    zq_set_error("array path does not resolve");       \
    return EINVAL;                                     \
  }

int zq_arrow_append_null(ZqArrowBuilder* b, const int32_t* path, int32_t path_len) {
  ZQ_NODE(b, path, path_len);
  int code = ArrowArrayAppendNull(node, 1);
  if (code != NANOARROW_OK) zq_set_error("ArrowArrayAppendNull failed");
  return code;
}

int zq_arrow_append_int(ZqArrowBuilder* b, const int32_t* path, int32_t path_len,
                        int64_t v) {
  ZQ_NODE(b, path, path_len);
  int code = ArrowArrayAppendInt(node, v);
  if (code != NANOARROW_OK) zq_set_error("ArrowArrayAppendInt failed");
  return code;
}

int zq_arrow_append_double(ZqArrowBuilder* b, const int32_t* path, int32_t path_len,
                           double v) {
  ZQ_NODE(b, path, path_len);
  int code = ArrowArrayAppendDouble(node, v);
  if (code != NANOARROW_OK) zq_set_error("ArrowArrayAppendDouble failed");
  return code;
}

int zq_arrow_append_bytes(ZqArrowBuilder* b, const int32_t* path, int32_t path_len,
                          const uint8_t* data, int64_t len) {
  ZQ_NODE(b, path, path_len);
  struct ArrowBufferView view;
  view.data.as_uint8 = data;
  view.size_bytes = len;
  int code = ArrowArrayAppendBytes(node, view);
  if (code != NANOARROW_OK) zq_set_error("ArrowArrayAppendBytes failed");
  return code;
}

int zq_arrow_append_decimal(ZqArrowBuilder* b, const int32_t* path, int32_t path_len,
                            int bits, const uint8_t* le) {
  ZQ_NODE(b, path, path_len);
  struct ArrowDecimal dec;
  ArrowDecimalInit(&dec, bits, 0, 0);
  // The words are little-endian two's complement, which is nanoarrow's own
  // in-memory form -- and the opposite of what Avro's decimal wants.
  ArrowDecimalSetBytes(&dec, le);
  int code = ArrowArrayAppendDecimal(node, &dec);
  if (code != NANOARROW_OK) zq_set_error("ArrowArrayAppendDecimal failed");
  return code;
}

int zq_arrow_append_interval(ZqArrowBuilder* b, const int32_t* path, int32_t path_len,
                             int32_t months, int32_t days, int64_t nanos) {
  ZQ_NODE(b, path, path_len);
  struct ArrowInterval iv;
  ArrowIntervalInit(&iv, NANOARROW_TYPE_INTERVAL_MONTH_DAY_NANO);
  iv.months = months;
  iv.days = days;
  iv.ns = nanos;
  int code = ArrowArrayAppendInterval(node, &iv);
  if (code != NANOARROW_OK) zq_set_error("ArrowArrayAppendInterval failed");
  return code;
}

int zq_arrow_append_finish_element(ZqArrowBuilder* b, const int32_t* path,
                                   int32_t path_len) {
  ZQ_NODE(b, path, path_len);
  int code = ArrowArrayFinishElement(node);
  if (code != NANOARROW_OK) zq_set_error("ArrowArrayFinishElement failed");
  return code;
}

int64_t zq_arrow_builder_len(ZqArrowBuilder* b) { return b->array.length; }

// NANOARROW_MAX_FIXED_BUFFERS is the bound nanoarrow's own append loop uses, so
// walking to it is as safe here as it is there; a buffer a type does not have
// is simply empty.
static int64_t array_bytes(struct ArrowArray* a) {
  int64_t total = 0;
  for (int i = 0; i < NANOARROW_MAX_FIXED_BUFFERS; i++) {
    struct ArrowBuffer* buf = ArrowArrayBuffer(a, i);
    if (buf != NULL) total += buf->size_bytes;
  }
  for (int64_t i = 0; i < a->n_children; i++) total += array_bytes(a->children[i]);
  return total;
}

int64_t zq_arrow_builder_bytes(ZqArrowBuilder* b) { return array_bytes(&b->array); }

int zq_arrow_encode_batch(ZqArrowBuilder* b, const uint8_t** out, int64_t* out_len) {
  int code = ArrowArrayFinishBuildingDefault(&b->array, &zq_error);
  if (code != NANOARROW_OK) return code;

  code = ArrowArrayViewInitFromSchema(&b->view, b->schema, &zq_error);
  if (code != NANOARROW_OK) return code;
  b->view_ready = 1;
  code = ArrowArrayViewSetArray(&b->view, &b->array, &zq_error);
  if (code != NANOARROW_OK) return code;

  struct ArrowIpcEncoder encoder;
  code = ArrowIpcEncoderInit(&encoder);
  if (code != NANOARROW_OK) {
    zq_set_error("ArrowIpcEncoderInit failed");
    return code;
  }
  ArrowBufferReset(&b->encoded);
  ArrowBufferInit(&b->encoded);

  // Header and body go to different buffers and are joined header-first.
  // FinalizeBuffer appends, so encoding the body into the same buffer would put
  // it in front of its own header -- a message every reader rejects, and the
  // reason nanoarrow's own writer keeps two buffers here too.
  struct ArrowBuffer body;
  ArrowBufferInit(&body);
  code = ArrowIpcEncoderEncodeSimpleRecordBatch(&encoder, &b->view, &body, &zq_error);
  if (code == NANOARROW_OK) {
    // encapsulate = 1: continuation marker, header size and padding, which is
    // what the proto's bytes field carries -- schema and batches travel
    // separately, not as a stream. Neither of the two calls below reports
    // through an ArrowError, so they get their own message.
    code = ArrowIpcEncoderFinalizeBuffer(&encoder, 1, &b->encoded);
    if (code == NANOARROW_OK && body.size_bytes > 0) {
      code = ArrowBufferAppend(&b->encoded, body.data, body.size_bytes);
    }
    if (code != NANOARROW_OK) zq_set_error("assembling the record batch message failed");
  }
  ArrowBufferReset(&body);
  ArrowIpcEncoderReset(&encoder);
  if (code != NANOARROW_OK) return code;
  *out = b->encoded.data;
  *out_len = b->encoded.size_bytes;
  return 0;
}
