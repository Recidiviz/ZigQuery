---
paths:
  - "*.zig"
  - "*.zon"
---

# Code Style Rules

Apply `zig zen` principles:

* Communicate intent precisely.
* Edge cases matter.
* Favor reading code over writing code.
* Only one obvious way to do things.
* Runtime crashes are better than bugs.
* Compile errors are better than runtime crashes.
* Incremental improvements.
* Avoid local maximums.
* Reduce the amount one must remember.
* Focus on code rather than style.
* Resource allocation may fail; resource deallocation must succeed.
* Memory is a resource.
* Together we serve the users.

## Comment styles

* Never be self-referential with respect to code that may have existed in the past
    * Bad:
        * // Same table, same reason as in dateDiff: ISOWEEK is the Monday-started
          // It used to have its own arm computing Dec 31 of the ISO year plus
          // seven days per week number, which lands on an arbitrary weekday.
    * Better:
        * ISOWEEK: Monday-started week
* Be succinct and explicit
* Cite BigQuery sources (both vendored markdown files and doc urls) where applicable
    * When citing markdown source, link to anchor when possible i.e. // 'J': ISO day of the year (format-elements.md#format_elements_date_time)
* Do not duplicate expectations between tests and source code; tests are the truth, implementation gives brief name
    * i.e. for a 'J' time parser rune, the implementation comment should only say // 'J': ISO day of the year
* A comment must read the same the day it is written and ten years later
    * The test for the rule above: if it would need deleting once the change stops being
      news, do not write it. Catches the phrasings that dodge "used to" but still describe
      a diff — "as this did", "these were", "instead", "already", "before".
    * Bad:
        * // Anchoring on Jan 1 instead, as this did, lands a week early
    * Better:
        * // The Monday on or before January 4th
* Do not justify a refactor where it landed; that belongs in the commit message
    * Bad:
        * /// Passing them one by one meant six parameters on three functions that only ever forward them.
    * Better:
        * /// What every format element needs: destination, instant, UTC offset, target type.
* Cite the source instead of reproducing it
    * Quote neither the reference's prose nor BigQuery's output; name the file and anchor.
      Bare filename is the house style (`format-elements.md`), the vendored copy is under
      `third_party/googlesql/docs/`.
    * Bad:
        * // Strict, not a renderer: "If the JSON value isn't a string, an error is produced"
          // (json_functions.md), and BigQuery answers "The provided JSON input is not a string".
    * Better:
        * // STRING(JSON): JSON strings only; LAX_STRING is the renderer.
          // json_functions.md#string_for_json
* Provenance belongs on the expectation, not the implementation
    * A measurement date such as `(recidiviz-bigquery-sandbox, 2026-08-07)` is evidence for
      a *value*, so it goes in the .zon case beside that value. Dates in source rot.
* No emphasis markup, and no rhetorical contrast
    * `*appends*`, `**4th**`, "That is the opposite of…", "not a second spelling of" — prose
      styling, not documentation. State what is, not what it is not.
* Wrap at 100 columns, not narrower
    * That is ephor's limit (`max_line_length: 100` in ephor.json), and indentation counts
      toward it. Wrapping at 72 or 80 turns a two-line comment into three for no reason.
* State the rule, not the counter-examples
    * Bad:
        * // %H %I %l %s %X are clock elements; %z %Ez %Z carry a zone; %r is the
          // 12-hour time. None of them has a field in a DATE.
    * Better:
        * // Elements a DATE has no field for.
* Ephor enforces a 100 column maximum for line length; comments must be wrapped at 100, never wrap at 80 columns

The rules above apply to .zon spec comments too, with one exception: because tests are
the truth, a spec comment *should* carry the expected value and the reasoning that picks
it. It still may not narrate what the engine used to answer.