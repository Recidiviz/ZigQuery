// C shim used by zetasqlite-zig: analyzes GoogleSQL statements one at a time
// and returns each resolved AST as a serialized AnyResolvedNodeProto.
//
// Mirrors the analyzer configuration of Recidiviz/go-zetasqlite
// (internal/analyzer.go): same language features, supported statement kinds,
// QUALIFY reservable keyword, undeclared-parameter allowance, and parse
// location recording. The catalog arrives as a SimpleCatalogProto in protobuf
// JSON form so the caller never touches C++ object lifetimes.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "re2/re2.h"
#include "unicode/errorcode.h"
#include "unicode/normalizer2.h"
#include "unicode/uchar.h"
#include "unicode/unistr.h"
#include "unicode/utf8.h"
#include "google/protobuf/util/json_util.h"
#include "googlesql/proto/simple_catalog.pb.h"
#include "googlesql/public/analyzer.h"
#include "googlesql/public/analyzer_options.h"
#include "googlesql/public/analyzer_output.h"
#include "googlesql/public/builtin_function_options.h"
#include "googlesql/public/function.h"
#include "googlesql/public/language_options.h"
#include "googlesql/public/parse_resume_location.h"
#include "googlesql/public/simple_catalog.h"
#include "googlesql/public/types/type_deserializer.h"
#include "googlesql/public/types/type_factory.h"
#include "googlesql/resolved_ast/resolved_ast.h"
#include "googlesql/resolved_ast/resolved_ast.pb.h"

namespace {

// Ported verbatim from go-zetasqlite internal/analyzer.go `enabledFeatures`
// (Go LanguageFeatureFeatureX -> C++ FEATURE_X; the current googlesql tree
// dropped the V_1_1/V_1_2/V_1_3 prefixes).
constexpr googlesql::LanguageFeature kEnabledFeatures[] = {
    googlesql::FEATURE_ANALYTIC_FUNCTIONS,
    googlesql::FEATURE_NAMED_ARGUMENTS,
    googlesql::FEATURE_NUMERIC_TYPE,
    googlesql::FEATURE_BIGNUMERIC_TYPE,
    googlesql::FEATURE_DECIMAL_ALIAS,
    googlesql::FEATURE_CREATE_TABLE_NOT_NULL,
    googlesql::FEATURE_PARAMETERIZED_TYPES,
    googlesql::FEATURE_TABLESAMPLE,
    googlesql::FEATURE_TIMESTAMP_NANOS,
    googlesql::FEATURE_HAVING_IN_AGGREGATE,
    googlesql::FEATURE_NULL_HANDLING_MODIFIER_IN_AGGREGATE,
    googlesql::FEATURE_NULL_HANDLING_MODIFIER_IN_ANALYTIC,
    googlesql::FEATURE_ORDER_BY_COLLATE,
    googlesql::FEATURE_SELECT_STAR_EXCEPT_REPLACE,
    googlesql::FEATURE_SAFE_FUNCTION_CALL,
    googlesql::FEATURE_JSON_TYPE,
    googlesql::FEATURE_JSON_ARRAY_FUNCTIONS,
    googlesql::FEATURE_JSON_STRICT_NUMBER_PARSING,
    // JSON scalar accessors (INT64/FLOAT64/BOOL/STRING/JSON_TYPE) and the
    // TO_JSON/PARSE_JSON constructor family; the corpus (go-zetasqlite fork)
    // exercises these, so opt in to keep them resolvable.
    googlesql::FEATURE_JSON_VALUE_EXTRACTION_FUNCTIONS,
    googlesql::FEATURE_JSON_LAX_VALUE_EXTRACTION_FUNCTIONS,
    googlesql::FEATURE_JSON_CONSTRUCTOR_FUNCTIONS,
    googlesql::FEATURE_IS_DISTINCT,
    googlesql::FEATURE_FORMAT_IN_CAST,
    googlesql::FEATURE_DATE_ARITHMETICS,
    googlesql::FEATURE_ORDER_BY_IN_AGGREGATE,
    googlesql::FEATURE_LIMIT_IN_AGGREGATE,
    googlesql::FEATURE_DATE_TIME_CONSTRUCTORS,
    googlesql::FEATURE_EXTENDED_DATE_TIME_SIGNATURES,
    googlesql::FEATURE_CIVIL_TIME,
    googlesql::FEATURE_WEEK_WITH_WEEKDAY,
    googlesql::FEATURE_INTERVAL_TYPE,
    googlesql::FEATURE_GROUP_BY_ROLLUP,
    googlesql::FEATURE_NULLS_FIRST_LAST_IN_ORDER_BY,
    googlesql::FEATURE_QUALIFY,
    googlesql::FEATURE_ALLOW_DASHES_IN_TABLE_NAME,
    googlesql::FEATURE_GEOGRAPHY,
    googlesql::FEATURE_EXTENDED_GEOGRAPHY_PARSERS,
    googlesql::FEATURE_TEMPLATE_FUNCTIONS,
    googlesql::FEATURE_WITH_ON_SUBQUERY,
    googlesql::FEATURE_PIVOT,
    googlesql::FEATURE_UNPIVOT,
    googlesql::FEATURE_DML_UPDATE_WITH_JOIN,
    googlesql::FEATURE_OMIT_INSERT_COLUMN_LIST,
    googlesql::FEATURE_WITH_RECURSIVE,
    googlesql::FEATURE_GROUP_BY_ARRAY,
    googlesql::FEATURE_GROUP_BY_STRUCT,
    googlesql::FEATURE_CREATE_TABLE_PARTITION_BY,
    googlesql::FEATURE_CREATE_TABLE_CLUSTER_BY,
    // go-zetasql's analyzer exposed LAST_DAY (and other extended string/date
    // functions) implicitly; go-googlesql's newer revision gates them behind
    // FEATURE_ADDITIONAL_STRING_FUNCTIONS, so opt in to keep LAST_DAY resolvable.
    googlesql::FEATURE_ADDITIONAL_STRING_FUNCTIONS,
    // Mixed-type CONCAT (STRING || INT64 etc.) and the 4-arg
    // REGEXP_EXTRACT(value, regexp, position, occurrence) signature: both
    // implicit in go-googlesql's analyzer revision, feature-gated here.
    googlesql::FEATURE_CONCAT_MIXED_TYPES,
    googlesql::FEATURE_ALLOW_REGEXP_EXTRACT_OPTIONALS,
};

// Ported verbatim from internal/analyzer.go `supportedStatementKinds`.
const std::set<googlesql::ResolvedNodeKind> kSupportedStatementKinds = {
    googlesql::RESOLVED_BEGIN_STMT,
    googlesql::RESOLVED_COMMIT_STMT,
    googlesql::RESOLVED_MERGE_STMT,
    googlesql::RESOLVED_QUERY_STMT,
    googlesql::RESOLVED_INSERT_STMT,
    googlesql::RESOLVED_UPDATE_STMT,
    googlesql::RESOLVED_DELETE_STMT,
    googlesql::RESOLVED_DROP_STMT,
    googlesql::RESOLVED_TRUNCATE_STMT,
    googlesql::RESOLVED_CREATE_TABLE_STMT,
    googlesql::RESOLVED_CREATE_TABLE_AS_SELECT_STMT,
    googlesql::RESOLVED_CREATE_PROCEDURE_STMT,
    googlesql::RESOLVED_CREATE_FUNCTION_STMT,
    googlesql::RESOLVED_CREATE_TABLE_FUNCTION_STMT,
    googlesql::RESOLVED_CREATE_VIEW_STMT,
    googlesql::RESOLVED_DROP_FUNCTION_STMT,
    googlesql::RESOLVED_DROP_ROW_ACCESS_POLICY_STMT,
    googlesql::RESOLVED_CREATE_ROW_ACCESS_POLICY_STMT,
};

absl::Status BuildLanguageOptions(googlesql::LanguageOptions* lang) {
  lang->set_name_resolution_mode(googlesql::NAME_RESOLUTION_DEFAULT);
  lang->set_product_mode(googlesql::PRODUCT_INTERNAL);
  for (googlesql::LanguageFeature f : kEnabledFeatures) {
    lang->EnableLanguageFeature(f);
  }
  lang->SetSupportedStatementKinds(kSupportedStatementKinds);
  // Enable QUALIFY without WHERE. https://github.com/google/zetasql/issues/124
  return lang->EnableReservableKeyword("QUALIFY", /*reserved=*/true);
}

// Copies `payload` into a malloc'd NUL-terminated buffer.
uint8_t* CopyToMalloc(const std::string& payload) {
  auto* buf = static_cast<uint8_t*>(std::malloc(payload.size() + 1));
  std::memcpy(buf, payload.data(), payload.size());
  buf[payload.size()] = '\0';
  return buf;
}

char* ErrorToMalloc(const absl::Status& status) {
  return reinterpret_cast<char*>(CopyToMalloc(std::string(status.message())));
}

}  // namespace

extern "C" {

// ---------------------------------------------------------------------------
// Persistent catalog handle.
//
// GoogleSQL_AnalyzeNextStatement below is stateless: it rebuilds a
// TypeFactory and a SimpleCatalog from `catalog_json`, and re-adds every
// builtin function, on every call. That keeps the FFI free of C++ object
// lifetimes, but it makes analysis cost O(catalog) per statement — loading a
// few thousand tables one CREATE at a time becomes quadratic, minutes where
// the Go binding (which holds a live SimpleCatalog) takes seconds.
//
// A handle keeps the TypeFactory, the builtins and the accumulated catalog
// alive across calls, and tables are merged in incrementally.
//
// THREADING: a handle carries mutable state and is NOT internally
// synchronized. One handle per connection, used from one thread at a time.
// The stateless entry point remains available and remains reentrant.
// ---------------------------------------------------------------------------

namespace {

struct CatalogHandle {
  googlesql::LanguageOptions lang;
  googlesql::TypeFactory type_factory;
  std::unique_ptr<googlesql::SimpleCatalog> catalog;
};

// Merges `proto`'s tables and sub-catalogs into `into`, recursively.
// Entries already present are left alone, so re-sending a table is harmless.
absl::Status MergeCatalogProto(const googlesql::SimpleCatalogProto& proto,
                               googlesql::SimpleCatalog* into,
                               googlesql::TypeFactory* type_factory) {
  const googlesql::TypeDeserializer deserializer(type_factory);

  for (const googlesql::SimpleTableProto& tp : proto.table()) {
    // A table registered under an alias carries name_in_catalog; that is the
    // name it resolves under.
    const std::string& registered =
        tp.has_name_in_catalog() ? tp.name_in_catalog() : tp.name();

    const googlesql::Table* existing = nullptr;
    absl::Status lookup = into->GetTable(registered, &existing);
    if (lookup.ok() && existing != nullptr) continue;

    auto table = googlesql::SimpleTable::Deserialize(tp, deserializer);
    if (!table.ok()) return table.status();
    into->AddOwnedTableIfNotPresent(registered, std::move(table).value());
  }

  // Custom functions (the emulator seeds a few, and CREATE FUNCTION adds
  // more). Without these the handle would silently lack them.
  for (const googlesql::FunctionProto& fp : proto.custom_function()) {
    const std::string registered =
        fp.name_path_size() > 0 ? fp.name_path(fp.name_path_size() - 1) : "";
    if (registered.empty()) continue;

    const googlesql::Function* existing = nullptr;
    absl::Status lookup = into->GetFunction(registered, &existing);
    if (lookup.ok() && existing != nullptr) continue;

    auto fn = googlesql::Function::Deserialize(fp, deserializer);
    if (!fn.ok()) return fn.status();
    into->AddOwnedFunction(registered, std::move(fn).value());
  }

  for (const googlesql::SimpleCatalogProto& cp : proto.catalog()) {
    googlesql::Catalog* found = nullptr;
    absl::Status lookup = into->GetCatalog(cp.name(), &found);
    googlesql::SimpleCatalog* sub = nullptr;
    if (lookup.ok() && found != nullptr) {
      sub = static_cast<googlesql::SimpleCatalog*>(found);
    } else {
      sub = into->MakeOwnedSimpleCatalog(cp.name());
    }
    absl::Status merged = MergeCatalogProto(cp, sub, type_factory);
    if (!merged.ok()) return merged;
  }
  return absl::OkStatus();
}

// Removes every table registered under `name` from `cat` and, recursively,
// from its sub-catalogs.
//
// The single-argument RemoveTables also deallocates the owned tables. That is
// safe here because the merge above deserializes a distinct SimpleTable per
// proto entry, so a table registered under several names owns a separate
// object for each.
int RemoveTableEverywhere(googlesql::SimpleCatalog* cat, absl::string_view name) {
  int removed = cat->RemoveTables(
      [&](const googlesql::Table* t) { return t->Name() == name; });
  for (googlesql::Catalog* sub : cat->catalogs()) {
    auto* simple = dynamic_cast<googlesql::SimpleCatalog*>(sub);
    if (simple != nullptr) removed += RemoveTableEverywhere(simple, name);
  }
  return removed;
}

}  // namespace

// Removes a table from the handle's catalog by its canonical name.
//
// Without this, a removal could only be expressed by discarding the handle
// and re-pushing the entire catalog — which makes every DROP cost O(catalog).
// The emulator drops and recreates a table on every view materialization, so
// that quickly dominates.
//
// Returns 0 always (removing something absent is not an error); *out_error is
// set only on a null handle.
int GoogleSQL_CatalogRemoveTable(void* handle_ptr, const char* name,
                                 char** out_error) {
  *out_error = nullptr;
  auto* handle = static_cast<CatalogHandle*>(handle_ptr);
  if (handle == nullptr || name == nullptr) {
    *out_error =
        ErrorToMalloc(absl::InvalidArgumentError("null catalog handle or name"));
    return 1;
  }
  RemoveTableEverywhere(handle->catalog.get(), name);
  return 0;
}

// Creates a catalog handle holding the builtin functions. Returns nullptr and
// sets *out_error on failure. Destroy with GoogleSQL_CatalogDestroy.
void* GoogleSQL_CatalogCreate(char** out_error) {
  *out_error = nullptr;
  auto handle = std::make_unique<CatalogHandle>();
  if (absl::Status s = BuildLanguageOptions(&handle->lang); !s.ok()) {
    *out_error = ErrorToMalloc(s);
    return nullptr;
  }
  handle->catalog = std::make_unique<googlesql::SimpleCatalog>(
      "zetasqlite", &handle->type_factory);
  handle->catalog->AddBuiltinFunctions(
      googlesql::BuiltinFunctionOptions(handle->lang));
  return handle.release();
}

void GoogleSQL_CatalogDestroy(void* handle) {
  delete static_cast<CatalogHandle*>(handle);
}

// Merges a SimpleCatalogProto (protobuf JSON) into the handle's catalog.
// Only new entries are added, so callers may send either a delta or the whole
// catalog. Returns 0 on success, 1 with *out_error on failure.
int GoogleSQL_CatalogAddTables(void* handle_ptr, const char* catalog_json,
                               char** out_error) {
  *out_error = nullptr;
  auto* handle = static_cast<CatalogHandle*>(handle_ptr);
  if (handle == nullptr || catalog_json == nullptr ||
      catalog_json[0] == '\0' || std::strcmp(catalog_json, "{}") == 0) {
    return 0;
  }

  googlesql::SimpleCatalogProto proto;
  auto json_status =
      google::protobuf::util::JsonStringToMessage(catalog_json, &proto);
  if (!json_status.ok()) {
    *out_error = ErrorToMalloc(absl::InvalidArgumentError(
        std::string("bad catalog_json: ") + std::string(json_status.message())));
    return 1;
  }

  absl::Status merged =
      MergeCatalogProto(proto, handle->catalog.get(), &handle->type_factory);
  if (!merged.ok()) {
    *out_error = ErrorToMalloc(merged);
    return 1;
  }
  return 0;
}

// Same contract as GoogleSQL_AnalyzeNextStatement, but analyzes against a
// handle's persistent catalog instead of rebuilding one from JSON.
int GoogleSQL_AnalyzeNextStatementWithCatalog(
    void* handle_ptr, const char* sql, size_t* resume_offset,
    const char* options_json, uint8_t** out_proto, size_t* out_len,
    int* out_is_end, char** out_error) {
  *out_proto = nullptr;
  *out_len = 0;
  *out_is_end = 0;
  *out_error = nullptr;

  auto* handle = static_cast<CatalogHandle*>(handle_ptr);
  if (handle == nullptr) {
    *out_error = ErrorToMalloc(absl::InvalidArgumentError("null catalog handle"));
    return 1;
  }

  googlesql::AnalyzerOptions options(handle->lang);
  // Undeclared parameters stay on for both modes. GoogleSQL does reject the
  // combination with *declared* positional parameters, but this port never
  // declares any — it relies on inference — so turning undeclared mode off
  // for positional queries just makes them fail with "Query parameter number
  // 1 is not defined". The corpus covers exactly that.
  //
  // Properly supporting Recidiviz/bigquery-emulator#69 means declaring
  // positional parameter types via AddPositionalQueryParameter, using types
  // inferred from the bound values; until then undeclared mode is what makes
  // positional parameters work at all.
  options.set_allow_undeclared_parameters(true);
  if (options_json != nullptr &&
      std::strstr(options_json, "positional") != nullptr) {
    options.set_parameter_mode(googlesql::PARAMETER_POSITIONAL);
  }
  options.set_parse_location_record_type(
      googlesql::PARSE_LOCATION_RECORD_FULL_NODE_SCOPE);

  googlesql::ParseResumeLocation location =
      googlesql::ParseResumeLocation::FromStringView(sql);
  location.set_byte_position(static_cast<int>(*resume_offset));

  std::unique_ptr<const googlesql::AnalyzerOutput> output;
  bool at_end_of_input = false;
  absl::Status status = googlesql::AnalyzeNextStatement(
      &location, options, handle->catalog.get(), &handle->type_factory,
      &output, &at_end_of_input);
  if (!status.ok()) {
    *out_error = ErrorToMalloc(status);
    return 1;
  }

  googlesql::Type::FileDescriptorSetMap fdset_map;
  googlesql::AnyResolvedNodeProto proto;
  status = output->resolved_statement()->SaveTo(&fdset_map, &proto);
  if (!status.ok()) {
    *out_error = ErrorToMalloc(status);
    return 1;
  }

  const std::string payload = proto.SerializeAsString();
  *out_proto = CopyToMalloc(payload);
  *out_len = payload.size();
  *resume_offset = static_cast<size_t>(location.byte_position());
  *out_is_end = at_end_of_input ? 1 : 0;
  return 0;
}

// Analyzes the next statement of `sql` starting at *resume_offset (bytes).
//
// catalog_json: SimpleCatalogProto in protobuf JSON form; "" or "{}" gives a
//   catalog with only the builtin functions.
// options_json: `{"parameter_mode":"positional"}` selects positional (`?`)
//   parameters; "" or "{}" keeps the default named (`@name`) mode.
//
// Returns 0 on success: *out_proto/*out_len hold a malloc'd serialized
// AnyResolvedNodeProto, *resume_offset is advanced past the statement, and
// *out_is_end is nonzero when the input is exhausted.
// Returns 1 on error: *out_error holds a malloc'd NUL-terminated message.
// Free all returned buffers with GoogleSQL_Free.
int GoogleSQL_AnalyzeNextStatement(const char* sql, size_t* resume_offset,
                                   const char* catalog_json,
                                   const char* options_json, uint8_t** out_proto,
                                   size_t* out_len, int* out_is_end,
                                   char** out_error) {
  *out_proto = nullptr;
  *out_len = 0;
  *out_is_end = 0;
  *out_error = nullptr;

  googlesql::LanguageOptions lang;
  if (absl::Status s = BuildLanguageOptions(&lang); !s.ok()) {
    *out_error = ErrorToMalloc(s);
    return 1;
  }

  googlesql::AnalyzerOptions options(lang);
  // options_json carries the parameter mode: `{"parameter_mode":"positional"}`
  // selects positional (`?`) parameters; anything else keeps the default
  // named (`@name`) mode. Mirrors the Go analyzer's getParameterMode +
  // SetParameterMode, which scans the query text for `?` vs `@name`.
  // See the note in the handle variant on undeclared parameters.
  options.set_allow_undeclared_parameters(true);
  if (options_json != nullptr &&
      std::strstr(options_json, "positional") != nullptr) {
    options.set_parameter_mode(googlesql::PARAMETER_POSITIONAL);
  }
  options.set_parse_location_record_type(
      googlesql::PARSE_LOCATION_RECORD_FULL_NODE_SCOPE);

  googlesql::TypeFactory type_factory;

  // Build the catalog: deserialize the caller's tables/functions when given,
  // then add the feature-gated builtin functions (matching the Go analyzer's
  // AddBuiltinFunctionsAndTypes(BuiltinFunctionOptions{LanguageOptions})).
  std::unique_ptr<googlesql::SimpleCatalog> catalog;
  if (catalog_json != nullptr && catalog_json[0] != '\0' &&
      std::strcmp(catalog_json, "{}") != 0) {
    googlesql::SimpleCatalogProto catalog_proto;
    auto json_status = google::protobuf::util::JsonStringToMessage(
        catalog_json, &catalog_proto);
    if (!json_status.ok()) {
      *out_error = ErrorToMalloc(absl::InvalidArgumentError(
          std::string("bad catalog_json: ") +
          std::string(json_status.message())));
      return 1;
    }
    auto deserialized = googlesql::SimpleCatalog::Deserialize(
        catalog_proto, /*pools=*/{}, &type_factory,
        /*extended_type_deserializer=*/nullptr);
    if (!deserialized.ok()) {
      *out_error = ErrorToMalloc(deserialized.status());
      return 1;
    }
    catalog = std::move(deserialized).value();
  } else {
    catalog = std::make_unique<googlesql::SimpleCatalog>("catalog",
                                                         &type_factory);
  }
  catalog->AddBuiltinFunctions(googlesql::BuiltinFunctionOptions(lang));

  googlesql::ParseResumeLocation location =
      googlesql::ParseResumeLocation::FromStringView(sql);
  location.set_byte_position(static_cast<int>(*resume_offset));

  std::unique_ptr<const googlesql::AnalyzerOutput> output;
  bool at_end_of_input = false;
  absl::Status status = googlesql::AnalyzeNextStatement(
      &location, options, catalog.get(), &type_factory, &output,
      &at_end_of_input);
  if (!status.ok()) {
    *out_error = ErrorToMalloc(status);
    return 1;
  }

  googlesql::Type::FileDescriptorSetMap fdset_map;
  googlesql::AnyResolvedNodeProto proto;
  status = output->resolved_statement()->SaveTo(&fdset_map, &proto);
  if (!status.ok()) {
    *out_error = ErrorToMalloc(status);
    return 1;
  }

  const std::string payload = proto.SerializeAsString();
  *out_proto = CopyToMalloc(payload);
  *out_len = payload.size();
  *resume_offset = static_cast<size_t>(location.byte_position());
  *out_is_end = at_end_of_input ? 1 : 0;
  return 0;
}

// ---------------------------------------------------------------------------
// RE2 surface for zetasqlite-zig's REGEXP_* functions (Go uses the RE2-syntax
// `regexp` package; RE2 is already linked transitively via the analyzer).
// ---------------------------------------------------------------------------

// Finds non-overlapping matches of `pat` in `subj`, searching from byte
// `startpos`, up to `max_matches`. For each match writes 2*(ngroups+1) ints
// into `out_offsets`: [wholeStart,wholeEnd, g1Start,g1End, ...] as absolute
// byte offsets into subj; a non-participating group is (-1,-1).
//
// Call once with max_matches==0 to compile-and-probe: it returns *out_ngroups
// (capture-group count) and reports a compile error, writing nothing.
//
// Returns 0 on success, 1 on pattern-compile error (*out_err malloc'd).
int GoogleSQL_RegexpFind(const char* pat, int patlen, const char* subj,
                         int subjlen, int startpos, int max_matches,
                         int* out_offsets, int cap, int* out_nmatches,
                         int* out_ngroups, char** out_err) {
  *out_err = nullptr;
  *out_nmatches = 0;
  *out_ngroups = 0;
  RE2 re(absl::string_view(pat, patlen));
  if (!re.ok()) {
    *out_err = reinterpret_cast<char*>(CopyToMalloc(re.error()));
    return 1;
  }
  const int ngroups = re.NumberOfCapturingGroups();
  *out_ngroups = ngroups;
  const int nsub = ngroups + 1;
  std::vector<absl::string_view> sub(nsub);
  absl::string_view text(subj, subjlen);
  int pos = startpos < 0 ? 0 : startpos;
  int found = 0;
  while (found < max_matches && pos <= subjlen) {
    if (!re.Match(text, static_cast<size_t>(pos),
                  static_cast<size_t>(subjlen), RE2::UNANCHORED, sub.data(),
                  nsub)) {
      break;
    }
    if ((found + 1) * nsub * 2 > cap) break;  // no room for this match
    const int base = found * nsub * 2;
    int mstart = 0, mend = 0;
    for (int i = 0; i < nsub; i++) {
      if (sub[i].data() == nullptr) {
        out_offsets[base + i * 2] = -1;
        out_offsets[base + i * 2 + 1] = -1;
      } else {
        const int s = static_cast<int>(sub[i].data() - subj);
        const int e = s + static_cast<int>(sub[i].size());
        out_offsets[base + i * 2] = s;
        out_offsets[base + i * 2 + 1] = e;
        if (i == 0) {
          mstart = s;
          mend = e;
        }
      }
    }
    found++;
    pos = (mend == mstart) ? mend + 1 : mend;  // advance past empty match
  }
  *out_nmatches = found;
  return 0;
}

// RE2::GlobalReplace with \1-style rewrites (BigQuery/RE2 share the syntax).
// Result may contain embedded NULs; length is reported via *out_len.
int GoogleSQL_RegexpReplace(const char* pat, int patlen, const char* subj,
                            int subjlen, const char* rewrite, int rwlen,
                            char** out, int* out_len, char** out_err) {
  *out_err = nullptr;
  *out = nullptr;
  *out_len = 0;
  RE2 re(absl::string_view(pat, patlen));
  if (!re.ok()) {
    *out_err = reinterpret_cast<char*>(CopyToMalloc(re.error()));
    return 1;
  }
  std::string s(subj, subjlen);
  RE2::GlobalReplace(&s, re, absl::string_view(rewrite, rwlen));
  *out_len = static_cast<int>(s.size());
  *out = reinterpret_cast<char*>(CopyToMalloc(s));
  return 0;
}

// ---------------------------------------------------------------------------
// ICU surface for NORMALIZE / case mapping (Go uses x/text/unicode/norm and
// strings.To{Upper,Lower}; ICU is already linked transitively).
// ---------------------------------------------------------------------------

// mode: "NFC" / "NFD" / "NFKC" / "NFKD". Input/output are UTF-8.
int GoogleSQL_Normalize(const char* mode, const char* in, int inlen, char** out,
                        int* out_len, char** out_err) {
  *out_err = nullptr;
  *out = nullptr;
  *out_len = 0;
  icu::ErrorCode ec;
  const icu::Normalizer2* norm = nullptr;
  if (std::strcmp(mode, "NFC") == 0) {
    norm = icu::Normalizer2::getNFCInstance(ec);
  } else if (std::strcmp(mode, "NFD") == 0) {
    norm = icu::Normalizer2::getNFDInstance(ec);
  } else if (std::strcmp(mode, "NFKC") == 0) {
    norm = icu::Normalizer2::getNFKCInstance(ec);
  } else if (std::strcmp(mode, "NFKD") == 0) {
    norm = icu::Normalizer2::getNFKDInstance(ec);
  } else {
    *out_err = reinterpret_cast<char*>(
        CopyToMalloc(std::string("unexpected normalize mode ") + mode));
    return 1;
  }
  if (ec.isFailure() || norm == nullptr) {
    *out_err = reinterpret_cast<char*>(
        CopyToMalloc(std::string("normalizer unavailable")));
    return 1;
  }
  icu::UnicodeString us = icu::UnicodeString::fromUTF8(
      absl::string_view(in, inlen));
  icu::UnicodeString normalized = norm->normalize(us, ec);
  if (ec.isFailure()) {
    *out_err = reinterpret_cast<char*>(CopyToMalloc(std::string("normalize failed")));
    return 1;
  }
  std::string result;
  normalized.toUTF8String(result);
  *out_len = static_cast<int>(result.size());
  *out = reinterpret_cast<char*>(CopyToMalloc(result));
  return 0;
}

// op: 0=upper, 1=lower. Simple (per-code-point) case mapping, matching Go's
// strings.To{Upper,Lower} (unicode.To{Upper,Lower}). Input/output UTF-8.
int GoogleSQL_CaseMap(int op, const char* in, int inlen, char** out,
                      int* out_len) {
  std::string result;
  result.reserve(inlen + 4);
  int32_t i = 0;
  while (i < inlen) {
    UChar32 c;
    U8_NEXT(reinterpret_cast<const uint8_t*>(in), i, inlen, c);
    if (c < 0) c = 0xFFFD;  // malformed -> replacement
    UChar32 mapped = (op == 0) ? u_toupper(c) : u_tolower(c);
    uint8_t buf[4];
    int32_t off = 0;
    UBool err = false;
    U8_APPEND(buf, off, 4, mapped, err);
    result.append(reinterpret_cast<char*>(buf), off);
  }
  *out_len = static_cast<int>(result.size());
  *out = reinterpret_cast<char*>(CopyToMalloc(result));
  return 0;
}

void GoogleSQL_Free(void* p) { std::free(p); }

}  // extern "C"
