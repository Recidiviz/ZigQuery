// C shim used by zigquery: analyzes GoogleSQL statements one at a time
// and returns each resolved AST as a serialized AnyResolvedNodeProto.
//
// Mirrors the analyzer configuration of Recidiviz/go-zetasqlite
// (internal/analyzer.go): same language features, supported statement kinds,
// QUALIFY reservable keyword, undeclared-parameter allowance, and parse
// location recording. The catalog arrives as a SimpleCatalogProto in protobuf
// JSON form so the caller never touches C++ object lifetimes.

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
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
#include "unicode/timezone.h"
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
    // `PRIMARY KEY ... NOT ENFORCED`, which is the only form BigQuery accepts:
    // there a primary key is optimizer metadata (join elimination), never a
    // uniqueness guarantee. Without this the analyzer rejects the syntax
    // outright, so the whole primary-key path below it was unreachable —
    // TableSpec.primary_key, its `PRIMARY KEY (...) WITHOUT ROWID` DDL
    // (internal/spec.zig) and the `primaryKey` catalog field were all dead for
    // BigQuery DDL.
    //
    // Note the asymmetry this introduces: SQLite enforces what BigQuery does
    // not, so a duplicate or NULL key that BigQuery accepts is rejected here.
    // That is the same trade the Go original makes, and it is the safe
    // direction for an emulator only insofar as the schema is honest; see
    // Db.storage_format_version for the format the key is persisted under.
    googlesql::FEATURE_UNENFORCED_PRIMARY_KEYS,
    googlesql::FEATURE_PARAMETERIZED_TYPES,
    googlesql::FEATURE_TABLESAMPLE,
    googlesql::FEATURE_TIMESTAMP_NANOS,
    googlesql::FEATURE_HAVING_IN_AGGREGATE,
    googlesql::FEATURE_NULL_HANDLING_MODIFIER_IN_AGGREGATE,
    googlesql::FEATURE_NULL_HANDLING_MODIFIER_IN_ANALYTIC,
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
    // GROUP BY GROUPING SETS and GROUP BY CUBE, both of which BigQuery
    // supports. Enabling this also changes how ROLLUP resolves: the legacy
    // flat ResolvedGroupingSet list gives way to a ResolvedRollup node
    // (query_resolver_helper.cc ReleaseGroupingSetsAndRollupList), which the
    // extractor expands. FEATURE_MULTI_GROUPING_SETS stays off on purpose:
    // it would allow a grouping element beside GROUPING SETS/ROLLUP/CUBE, and
    // BigQuery rejects that too, with the very message the analyzer gives when
    // the feature is disabled ("The GROUP BY clause only supports ROLLUP when
    // there are no other grouping elements").
    googlesql::FEATURE_GROUPING_SETS,
    // CBRT and the PI/PI_NUMERIC/PI_BIGNUMERIC constants, both of which
    // BigQuery exposes. PI's signatures carry SetDefinitionForInlining, so the
    // analyzer folds them to literals and no UDF is reachable for them; CBRT
    // resolves to an ordinary call that fn_math.zig answers.
    googlesql::FEATURE_CBRT_FUNCTIONS,
    googlesql::FEATURE_PI_FUNCTIONS,
    // RANGE<DATE|DATETIME|TIMESTAMP>. Gates three separate things: the RANGE
    // column type in DDL (resolver_stmt.cc), RANGE literals
    // (resolver_expr.cc), and every range builtin
    // (builtin_function_range.cc AddRequiredLanguageFeature).
    //
    // It does *not* gate TypeDeserializer, which is why enabling it is the
    // last step rather than the first: with the flag on and catalog.zig's
    // rangeType arm missing, `CREATE TABLE ... RANGE<DATE>` starts succeeding
    // and writes a catalog row whose TypeProto googlesql then rejects on every
    // subsequent statement, since the whole catalog is re-parsed per analyze.
    googlesql::FEATURE_RANGE_TYPE,
    // Pipe syntax: `FROM t |> WHERE x > 1 |> SELECT y`. The base feature covers
    // the operators that resolve into the ordinary scan nodes the transformer
    // already walks — WHERE, SELECT, EXTEND, SET, DROP, RENAME, AS, AGGREGATE,
    // ORDER BY, LIMIT/OFFSET, JOIN, DISTINCT, UNION and friends — so it is
    // syntax the resolver desugars rather than a new shape downstream.
    //
    // The operators that *do* introduce their own resolved nodes each have
    // their own feature and stay off until something handles them:
    // FEATURE_PIPE_ASSERT (ResolvedAssertScan), FEATURE_PIPE_STATIC_DESCRIBE,
    // FEATURE_PIPE_LOG, FEATURE_PIPE_FORK, FEATURE_PIPE_TEE, FEATURE_PIPE_WITH,
    // FEATURE_PIPE_EXPORT_DATA, FEATURE_PIPE_CREATE_TABLE, FEATURE_PIPE_INSERT
    // and FEATURE_PIPE_FINISH. Each of those is a clean "Pipe X not supported"
    // from the analyzer while its feature is off, not a surprise further down.
    googlesql::FEATURE_PIPES,
    // TYPEOF(expr) -> the type's name. No `zigquery_typeof` answers it and
    // none is needed: the type is a static property of the expression, so the
    // analyzer's rewriter has already resolved it by the time the extractor
    // runs. What arrives is a constant-true CASE whose taken branch is the
    // name as a literal —
    //
    //   CASE WHEN true THEN X'60494e543634'   -- "INT64"
    //        ELSE zigquery_cast(zigquery_is_null(x), ...) END
    //
    // with the untaken branch built from functions the engine already has, and
    // never evaluated because SQLite short-circuits CASE. It works over columns
    // and expressions, not only literals: TYPEOF(a + 1), TYPEOF(SUM(a)),
    // TYPEOF(arr) -> "ARRAY<INT64>" and TYPEOF(s) -> "STRUCT<f INT64>".
    googlesql::FEATURE_TYPEOF_FUNCTION,
    // GROUPING(expr) -> 1 when the row's grouping set rolled `expr` up, 0 when
    // it grouped by it. Verified in real BigQuery (bq CLI, 2026-08-04), which
    // has it and answers 0 for a grouped column that is NULL in the data — the
    // distinction the function exists for.
    //
    // The analyzer keeps these calls out of `aggregate_list` and in
    // ResolvedAggregateScanBase.grouping_call_list, so nothing runs at row
    // time: the answer is fixed per grouping set, and the transformer inlines
    // it per UNION branch (transformer/scan_aggregate.zig).
    googlesql::FEATURE_GROUPING_BUILTIN,
    // DATE_BUCKET / DATETIME_BUCKET / TIMESTAMP_BUCKET. All three are in real
    // BigQuery (bq CLI, 2026-08-04), which was also the source for every rule
    // the handlers enforce — the default 1950-01-01 origin, the floor toward
    // -infinity before it, which width parts each type takes, and the wording
    // of each refusal. See date_ops.bucket.
    googlesql::FEATURE_TIME_BUCKET_FUNCTIONS,
    // Struct fields by position: `s[OFFSET(0)]`, `s[ORDINAL(1)]`. In real
    // BigQuery (bq CLI, 2026-08-04), and the only way to reach a field whose
    // name is duplicated.
    //
    // Costs nothing downstream: the resolver normalizes OFFSET/ORDINAL to a
    // 0-based index and emits an ordinary ResolvedGetStructField
    // (resolver_expr.cc ResolveStructSubscriptElementAccess), the same node
    // `s.a` produces, so the extractor cannot tell the two spellings apart. It
    // also bounds-checks the index itself, which is why nothing at run time
    // has to.
    //
    // FEATURE_ANALYSIS_CONSTANT_STRUCT_POSITIONAL_ACCESSOR stays off, and that
    // is what makes `s[OFFSET(1+1)]` answer "Field element access is only
    // supported for literal integer positions" — BigQuery's own reply, because
    // BigQuery has that feature off too.
    googlesql::FEATURE_STRUCT_POSITIONAL_ACCESSOR,
    // JSON_SET / JSON_REMOVE / JSON_STRIP_NULLS / JSON_ARRAY_APPEND /
    // JSON_ARRAY_INSERT. All five are in real BigQuery (bq CLI, 2026-08-04),
    // which supplied every rule the handlers enforce — the auto-vivification
    // (`JSON_ARRAY_INSERT(JSON '{"a": null}', '$.a[2]', 10)` builds
    // `{"a":[null,null,10]}`), the each-element defaults, and the wording of
    // each refusal. See fn_json.zig.
    googlesql::FEATURE_JSON_MUTATOR_FUNCTIONS,
    // JSON_KEYS(json [, max_depth] [, mode]) and JSON_FLATTEN(json). Both are
    // in real BigQuery (bq CLI, 2026-08-04). The walk is a port of
    // public/functions/json.cc JsonKeysTreeWalker, whose rules BigQuery
    // confirms: only object descents spend depth, `mode` is one of "strict" /
    // "lax" / "lax recursive" (a space, not an underscore), and a key holding a
    // '.' comes back double-quoted so the dotted path stays unambiguous.
    googlesql::FEATURE_JSON_KEYS_FUNCTION,
    googlesql::FEATURE_JSON_FLATTEN_FUNCTION,
    // The EDIT_DISTANCE(BYTES, BYTES, max_distance => INT64) signature. The
    // STRING one is ungated (builtin_function_internal_3.cc:459) and already
    // resolved; BigQuery has both, and refuses to mix them —
    // EDIT_DISTANCE('abc', b'abc') is "Unable to coerce type BYTES to expected
    // type STRING". Checked with the bq CLI, 2026-08-04.
    googlesql::FEATURE_ENABLE_EDIT_DISTANCE_BYTES,
};

// Deliberately absent, because BigQuery does not have them. Each was enabled,
// measured, and reverted; the engine emulates BigQuery, and accepting a query
// production would refuse is the one failure direction an emulator must not
// have — you would get a green local run and a broken deploy.
//
// Checked against real BigQuery (bq CLI, 2026-08-04), which answers:
//
//   FEATURE_ARRAY_ZIP               "Function not found: ARRAY_ZIP"
//   FEATURE_INLINE_LAMBDA_ARGUMENT  "Function not found: ARRAY_TRANSFORM"
//                                   "Function not found: ARRAY_FILTER"
//   FEATURE_PIPE_IF                 "Pipe IF not supported"
//   FEATURE_ORDER_BY_COLLATE        "COLLATE is not supported"
//
// The first three work here when enabled — ARRAY_ZIP resolves through the
// rewriter with correct PAD/TRUNCATE/STRICT modes and field naming, and lambdas
// inline — so those are scope decisions, not gaps. The spec corpus keeps the
// cases and asserts the refusal (`.expect_error`), so the day BigQuery grows any
// of them the fixture says so rather than going quiet.
//
// FEATURE_ORDER_BY_COLLATE is a different animal, and the reason it was removed
// rather than never added: it was inherited from go-zetasqlite's feature list
// and it did not merely widen what we accept, it made us answer wrongly.
// `ORDER BY x COLLATE 'und:ci'` parsed, and then the collation was dropped on
// the floor and the rows came back in raw memcomparable byte order —
// ['a','Z','b'] sorted to Z,a,b where BigQuery refuses the syntax outright. No
// spec case and no corpus case used it, which is precisely why nothing caught
// it. COLLATE() the *function* is unaffected: BigQuery has it, this engine does
// not answer it, and it stays in the ledger as a gap (see
// docs/SPEC_UNSUPPORTED.md).
//
// FEATURE_PIPES and FEATURE_TYPEOF_FUNCTION above were checked the same way and
// *are* in BigQuery, which is why they stayed.

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

// BigQuery's INT64 aliases. data-types.md#integer_types
//
// SimpleCatalog::FindType consults these named types before the simple-type
// name table, which spells only INT64. Registered once per freshly built catalog.
// AddType raises on a duplicate name.
void AddBigQueryTypeAliases(googlesql::SimpleCatalog* catalog) {
  for (const char* name :
       {"INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "BYTEINT"}) {
    catalog->AddType(name, googlesql::types::Int64Type());
  }
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
  // Query-parameter type text -> resolved type, cached for this connection.
  // Saves a type-grammar parse per statement, and bounds the TypeFactory:
  // it interns array types but allocates a fresh StructType on every
  // MakeStructType, so a connection re-declaring the same struct parameter
  // would otherwise accumulate one per statement for its whole lifetime.
  std::map<std::string, const googlesql::Type*> declared_types;
};

// Declares query-parameter types on `options` from the parallel arrays the
// caller passed across the FFI. `names[i]` is null for a positional entry;
// `types[i]` is GoogleSQL type text ("STRING", "ARRAY<STRING>").
//
// Best-effort by design: a type text this build cannot resolve is left to the
// analyzer's own inference rather than failing the query. Inference is what
// every parameter got before declarations existed, so a client naming a type
// we do not model is never worse off than one naming none.
//
// `memo` may be null (the stateless entry point owns a local TypeFactory, so
// there is nothing to cache across).
void DeclareQueryParameters(
    googlesql::AnalyzerOptions* options, const googlesql::LanguageOptions& lang,
    googlesql::Catalog* catalog, googlesql::TypeFactory* type_factory,
    const char* const* names, const char* const* types, size_t count,
    std::map<std::string, const googlesql::Type*>* memo) {
  if (count == 0 || types == nullptr) return;

  // Resolve against a pristine options object: AnalyzeType validates the
  // options it is handed, and `options` is mid-mutation here.
  const googlesql::AnalyzerOptions type_options(lang);

  std::vector<const googlesql::Type*> resolved(count, nullptr);
  size_t resolved_count = 0;
  for (size_t i = 0; i < count; ++i) {
    if (types[i] == nullptr || types[i][0] == '\0') continue;
    const std::string text(types[i]);

    if (memo != nullptr) {
      auto it = memo->find(text);
      if (it != memo->end()) {
        resolved[i] = it->second;
        ++resolved_count;
        continue;
      }
    }

    const googlesql::Type* type = nullptr;
    if (!googlesql::AnalyzeType(text, type_options, catalog, type_factory,
                                &type)
             .ok() ||
        type == nullptr || !type->IsSupportedType(lang)) {
      continue;
    }
    if (memo != nullptr) (*memo)[text] = type;
    resolved[i] = type;
    ++resolved_count;
  }
  if (resolved_count == 0) return;

  if (options->parameter_mode() == googlesql::PARAMETER_POSITIONAL) {
    // All or nothing. Declaring even one positional type means turning
    // undeclared inference off for the whole statement — AnalyzerOptions
    // rejects the two together — which would then reject every `?` left
    // undeclared. Partial declaration is strictly worse than none.
    if (resolved_count != count) return;
    options->set_allow_undeclared_parameters(false);
    for (const googlesql::Type* type : resolved) {
      if (!options->AddPositionalQueryParameter(type).ok()) {
        // Unreachable: every entry was pre-checked above. Undo rather than
        // analyze against a half-declared list.
        options->clear_positional_query_parameters();
        options->set_allow_undeclared_parameters(true);
        return;
      }
    }
    return;
  }

  // Named mode. Declared types and undeclared inference coexist by design:
  // the resolver looks a name up in query_parameters() first and only falls
  // through to an untyped INT64 when it is absent. So a name that failed to
  // resolve, and any parameter the client did not send at all, behave exactly
  // as they did before.
  for (size_t i = 0; i < count; ++i) {
    if (resolved[i] == nullptr) continue;
    if (names == nullptr || names[i] == nullptr || names[i][0] == '\0') continue;
    // Errors only on a duplicate name, where the first declaration wins.
    // Not worth failing a query over.
    (void)options->AddQueryParameter(names[i], resolved[i]);
  }
}

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
      "zigquery", &handle->type_factory);
  AddBigQueryTypeAliases(handle->catalog.get());
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

// Same contract as GoogleSQL_AnalyzeNextStatementWithCatalog, plus query
// parameter type declarations.
//
// param_names / param_types are parallel arrays of param_count entries.
// param_types[i] is GoogleSQL type text ("STRING", "ARRAY<STRING>"), resolved
// through AnalyzeType against this handle's catalog. In named mode
// param_names[i] names the parameter; a null or empty entry is skipped. In
// positional mode names are ignored and the entries declare positions
// 1..param_count in order. param_count == 0 is exactly the old behaviour:
// nothing is declared and every parameter is inferred.
int GoogleSQL_AnalyzeNextStatementWithCatalogParams(
    void* handle_ptr, const char* sql, size_t* resume_offset,
    const char* options_json, const char* const* param_names,
    const char* const* param_types, size_t param_count, uint8_t** out_proto,
    size_t* out_len, int* out_is_end, char** out_error) {
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
  // Undeclared parameters stay on unless positional types are actually
  // declared below, which is the one combination GoogleSQL rejects. Leaving
  // it on is what lets a parameter the caller said nothing about still
  // resolve by inference, exactly as every parameter did before declarations
  // existed.
  options.set_allow_undeclared_parameters(true);
  if (options_json != nullptr &&
      std::strstr(options_json, "positional") != nullptr) {
    options.set_parameter_mode(googlesql::PARAMETER_POSITIONAL);
  }
  DeclareQueryParameters(&options, handle->lang, handle->catalog.get(),
                         &handle->type_factory, param_names, param_types,
                         param_count, &handle->declared_types);
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

// Same contract as GoogleSQL_AnalyzeNextStatement, but analyzes against a
// handle's persistent catalog instead of rebuilding one from JSON.
int GoogleSQL_AnalyzeNextStatementWithCatalog(
    void* handle_ptr, const char* sql, size_t* resume_offset,
    const char* options_json, uint8_t** out_proto, size_t* out_len,
    int* out_is_end, char** out_error) {
  return GoogleSQL_AnalyzeNextStatementWithCatalogParams(
      handle_ptr, sql, resume_offset, options_json, /*param_names=*/nullptr,
      /*param_types=*/nullptr, /*param_count=*/0, out_proto, out_len,
      out_is_end, out_error);
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
int GoogleSQL_AnalyzeNextStatementParams(
    const char* sql, size_t* resume_offset, const char* catalog_json,
    const char* options_json, const char* const* param_names,
    const char* const* param_types, size_t param_count, uint8_t** out_proto,
    size_t* out_len, int* out_is_end, char** out_error) {
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

  // GoogleSQL_AnalyzeNextStatementParams builds a new catalog per call
  // its Types and Builtins must be registered
  AddBigQueryTypeAliases(catalog.get());
  catalog->AddBuiltinFunctions(googlesql::BuiltinFunctionOptions(lang));

  // After the catalog exists: resolving type text can reach named types.
  // No memo — this TypeFactory dies with the call.
  DeclareQueryParameters(&options, lang, catalog.get(), &type_factory,
                         param_names, param_types, param_count,
                         /*memo=*/nullptr);

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

int GoogleSQL_AnalyzeNextStatement(const char* sql, size_t* resume_offset,
                                   const char* catalog_json,
                                   const char* options_json, uint8_t** out_proto,
                                   size_t* out_len, int* out_is_end,
                                   char** out_error) {
  return GoogleSQL_AnalyzeNextStatementParams(
      sql, resume_offset, catalog_json, options_json, /*param_names=*/nullptr,
      /*param_types=*/nullptr, /*param_count=*/0, out_proto, out_len,
      out_is_end, out_error);
}

// ---------------------------------------------------------------------------
// RE2 surface for zigquery's REGEXP_* functions (Go uses the RE2-syntax
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

// ---------------------------------------------------------------------------
// ICU surface for named-timezone offset resolution (zoneOffsetSeconds in
// time_util.zig; ICU's tzdata is already linked in via icudata).
// ---------------------------------------------------------------------------

namespace {

// getCanonicalID + createTimeZone (alias lookup plus a fresh heap object)
// cost far more per call than getOffset's own transition-table search
// (`zig build tz-bench` measures the gap). Cached per thread, keyed on the
// caller's exact zone spelling rather than the canonical name, so no
// synchronization is needed: every connection in this engine is
// single-threaded end to end. Every getOffset call below still runs fresh
// against the real instant, so DST is never at risk — only the zone
// resolution is memoized, not the offset.
struct TimeZoneCacheEntry {
  std::string zone;
  std::unique_ptr<icu::TimeZone> tz;
};
constexpr size_t kTimeZoneCacheCapacity = 16;
thread_local std::vector<TimeZoneCacheEntry> g_tz_cache;

// Resolved icu::TimeZone for `zone`, from the thread-local cache if present;
// canonicalizes and constructs (then caches) on a miss. Null if `zone` is not
// a recognized ID.
icu::TimeZone* ResolveTimeZone(absl::string_view zone) {
  for (size_t i = 0; i < g_tz_cache.size(); ++i) {
    if (g_tz_cache[i].zone == zone) {
      // Move the hit to the back so eviction below takes the actual
      // least-recently-used entry, not just the oldest inserted one.
      if (i + 1 != g_tz_cache.size()) {
        std::rotate(g_tz_cache.begin() + i, g_tz_cache.begin() + i + 1,
                    g_tz_cache.end());
      }
      return g_tz_cache.back().tz.get();
    }
  }

  icu::UnicodeString id = icu::UnicodeString::fromUTF8(zone);
  icu::UnicodeString canonical;
  icu::ErrorCode ec;
  icu::TimeZone::getCanonicalID(id, canonical, ec);
  if (ec.isFailure()) return nullptr;

  std::unique_ptr<icu::TimeZone> tz(icu::TimeZone::createTimeZone(canonical));
  icu::TimeZone* raw = tz.get();
  if (g_tz_cache.size() >= kTimeZoneCacheCapacity) {
    g_tz_cache.erase(g_tz_cache.begin());
  }
  g_tz_cache.push_back({std::string(zone), std::move(tz)});
  return raw;
}

}  // namespace

// zone: an IANA/Olson ID ("America/Chicago") or ICU custom ID ("GMT-08:00").
// date_millis: a UTC instant, milliseconds since epoch. Writes the zone's
// total offset (raw + DST) in seconds east of UTC to *out_offset_seconds.
// Returns 0 on success; 1 if `zone` is not a recognized ID.
int GoogleSQL_TimeZoneOffsetSeconds(const char* zone, int zonelen,
                                     int64_t date_millis,
                                     int32_t* out_offset_seconds,
                                     char** out_err) {
  *out_err = nullptr;
  *out_offset_seconds = 0;
  icu::TimeZone* tz = ResolveTimeZone(absl::string_view(zone, zonelen));
  if (tz == nullptr) {
    *out_err = reinterpret_cast<char*>(CopyToMalloc(
        std::string("invalid time zone: ") + std::string(zone, zonelen)));
    return 1;
  }
  int32_t raw_offset = 0, dst_offset = 0;
  icu::ErrorCode offset_ec;
  tz->getOffset(static_cast<UDate>(date_millis), /*local=*/false, raw_offset,
                dst_offset, offset_ec);
  if (offset_ec.isFailure()) {
    *out_err = reinterpret_cast<char*>(
        CopyToMalloc(std::string("time zone offset lookup failed")));
    return 1;
  }
  *out_offset_seconds = (raw_offset + dst_offset) / 1000;
  return 0;
}

void GoogleSQL_Free(void* p) { std::free(p); }

}  // extern "C"
