"""Copy jobs, driven through the client a caller actually uses.

`jobs.insert` with a `configuration.copy` is reachable only as a job: there is no SQL form and
no synchronous endpoint. What a Zig test cannot reach is where a failure surfaces -- the client
submits the job, then waits on it, and the two raise in different places. docs/adr/0001.
"""

from google.api_core import exceptions
from google.cloud import bigquery
from google.cloud.bigquery import CopyJobConfig, SchemaField

from utils.big_query_emulator_test_case import (
    BigQueryAddress,
    BigQueryEmulatorTestCase,
)

_DATASET = "copy_jobs"
_SCHEMA = [SchemaField("a", "INTEGER"), SchemaField("b", "STRING")]


class TestCopyJobs(BigQueryEmulatorTestCase):
    """Copy jobs through google-cloud-bigquery."""

    def _name(self, table_id: str) -> str:
        return f"{self.project_id}.{_DATASET}.{table_id}"

    def _make_table(
        self,
        table_id: str,
        rows: list[dict] | None = None,
        schema: list[SchemaField] | None = None,
    ) -> BigQueryAddress:
        address = BigQueryAddress(dataset_id=_DATASET, table_id=table_id)
        self.create_mock_table(address, schema=schema or _SCHEMA)
        if rows:
            self.load_rows_into_table(address, rows)
        return address

    def _rows_in(self, table_id: str) -> list[dict]:
        job = self.client.query(f"SELECT a, b FROM `{self._name(table_id)}` ORDER BY a")
        return [{"a": row["a"], "b": row["b"]} for row in job.result()]

    def test_copy_creates_the_destination(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}, {"a": 2, "b": "y"}])

        job = self.client.copy_table(self._name("source"), self._name("destination"))
        job.result()

        self.assertIsNone(job.error_result)
        self.assertEqual("DONE", job.state)
        self.assertEqual(
            [{"a": 1, "b": "x"}, {"a": 2, "b": "y"}],
            self._rows_in("destination"),
        )

    def test_the_job_reports_what_it_copied(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}, {"a": 2, "b": "y"}])

        job = self.client.copy_table(self._name("source"), self._name("destination"))
        job.result()

        # (recidiviz-bigquery-sandbox, 2026-09-21): the service fills operationType in on a job
        # that succeeds, and reports copiedRows as an int64-as-string.
        self.assertEqual("COPY", job.configuration.operation_type)
        statistics = job._properties["statistics"]["copy"]
        self.assertEqual("2", statistics["copiedRows"])

    def test_a_disposition_the_client_omitted_is_not_reported(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])

        job = self.client.copy_table(self._name("source"), self._name("destination"))
        job.result()

        # (recidiviz-bigquery-sandbox, 2026-09-21): an omitted disposition is absent from the
        # echoed configuration, rather than filled in with the value the job behaved as.
        self.assertIsNone(job.write_disposition)
        self.assertIsNone(job.create_disposition)

    def test_the_default_disposition_refuses_a_destination_holding_rows(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])
        self._make_table("destination", rows=[{"a": 9, "b": "kept"}])

        # No job_config at all, which is the most common call and lands on WRITE_EMPTY.
        job = self.client.copy_table(self._name("source"), self._name("destination"))
        with self.assertRaises(exceptions.GoogleAPICallError):
            job.result()

        # The submission succeeded; the failure belongs to the job.
        self.assertEqual("duplicate", job.error_result["reason"])
        self.assertIn("Already Exists", job.error_result["message"])
        self.assertEqual([{"a": 9, "b": "kept"}], self._rows_in("destination"))

    def test_write_empty_accepts_a_destination_that_exists_and_is_empty(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])
        self._make_table("destination")

        job = self.client.copy_table(
            self._name("source"),
            self._name("destination"),
            job_config=CopyJobConfig(write_disposition="WRITE_EMPTY"),
        )
        job.result()

        self.assertIsNone(job.error_result)
        self.assertEqual([{"a": 1, "b": "x"}], self._rows_in("destination"))

    def test_write_append_adds_to_the_destination(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])
        self._make_table("destination", rows=[{"a": 9, "b": "kept"}])

        job = self.client.copy_table(
            self._name("source"),
            self._name("destination"),
            job_config=CopyJobConfig(write_disposition="WRITE_APPEND"),
        )
        job.result()

        self.assertEqual(
            [{"a": 1, "b": "x"}, {"a": 9, "b": "kept"}],
            self._rows_in("destination"),
        )

    def test_write_truncate_replaces_the_destination(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])
        self._make_table("destination", rows=[{"a": 9, "b": "gone"}])

        job = self.client.copy_table(
            self._name("source"),
            self._name("destination"),
            job_config=CopyJobConfig(write_disposition="WRITE_TRUNCATE"),
        )
        job.result()

        self.assertEqual([{"a": 1, "b": "x"}], self._rows_in("destination"))

    def test_create_never_requires_the_destination_to_exist(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])

        job = self.client.copy_table(
            self._name("source"),
            self._name("absent"),
            job_config=CopyJobConfig(create_disposition="CREATE_NEVER"),
        )
        with self.assertRaises(exceptions.GoogleAPICallError):
            job.result()

        self.assertEqual("notFound", job.error_result["reason"])
        self.assertFalse(
            self.table_exists(BigQueryAddress(dataset_id=_DATASET, table_id="absent"))
        )

    def test_several_sources_concatenate_into_one_destination(self) -> None:
        self._make_table("first", rows=[{"a": 1, "b": "x"}])
        self._make_table("second", rows=[{"a": 2, "b": "y"}])

        job = self.client.copy_table(
            [self._name("first"), self._name("second")],
            self._name("destination"),
        )
        job.result()

        # `sources` reads sourceTables, falling back to sourceTable: the plural form the
        # client sent has to come back plural for it to see both.
        self.assertEqual(["first", "second"], [source.table_id for source in job.sources])
        self.assertEqual(
            [{"a": 1, "b": "x"}, {"a": 2, "b": "y"}],
            self._rows_in("destination"),
        )

    def test_sources_whose_schemas_disagree_are_refused(self) -> None:
        self._make_table("first", rows=[{"a": 1, "b": "x"}])
        self._make_table(
            "second",
            schema=[SchemaField("a", "STRING"), SchemaField("b", "STRING")],
            rows=[{"a": "not an integer", "b": "y"}],
        )

        job = self.client.copy_table(
            [self._name("first"), self._name("second")],
            self._name("destination"),
        )
        with self.assertRaises(exceptions.GoogleAPICallError):
            job.result()

        self.assertEqual("invalid", job.error_result["reason"])
        self.assertIn("Incompatible table schemata", job.error_result["message"])
        # A mismatch on any source leaves the destination uncreated.
        self.assertFalse(
            self.table_exists(BigQueryAddress(dataset_id=_DATASET, table_id="destination"))
        )

    def test_an_append_the_destination_cannot_take_is_refused(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])
        self._make_table(
            "destination",
            schema=[SchemaField("a", "INTEGER")],
            rows=[{"a": 9}],
        )

        job = self.client.copy_table(
            self._name("source"),
            self._name("destination"),
            job_config=CopyJobConfig(write_disposition="WRITE_APPEND"),
        )
        with self.assertRaises(exceptions.GoogleAPICallError):
            job.result()

        self.assertEqual("invalid", job.error_result["reason"])
        self.assertIn("Provided Schema does not match", job.error_result["message"])

    def test_a_source_that_is_not_there_fails_when_the_job_is_submitted(self) -> None:
        self._make_table("destination")

        # (recidiviz-bigquery-sandbox, 2026-09-24): a missing source is settled before the job
        # exists, so this raises here rather than at result().
        with self.assertRaises(exceptions.NotFound):
            self.client.copy_table(self._name("absent"), self._name("destination"))

    def test_a_dataset_that_is_not_there_fails_when_the_job_is_submitted(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])

        with self.assertRaises(exceptions.NotFound):
            self.client.copy_table(
                self._name("source"),
                f"{self.project_id}.no_such_dataset.destination",
            )

    def test_a_view_cannot_be_a_source(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])
        self.client.query(
            f"CREATE VIEW `{self._name('a_view')}` AS SELECT a, b FROM `{self._name('source')}`"
        ).result()

        job = self.client.copy_table(self._name("a_view"), self._name("destination"))
        with self.assertRaises(exceptions.GoogleAPICallError):
            job.result()

        self.assertEqual("invalid", job.error_result["reason"])
        self.assertIn("is currently a VIEW", job.error_result["message"])

    def test_an_operation_type_the_emulator_cannot_honour_is_refused(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])

        config = CopyJobConfig()
        config.operation_type = "SNAPSHOT"
        with self.assertRaises(exceptions.BadRequest):
            self.client.copy_table(
                self._name("source"),
                self._name("destination"),
                job_config=config,
            )

    def test_a_copy_job_is_replayable_and_is_not_a_query_job(self) -> None:
        self._make_table("source", rows=[{"a": 1, "b": "x"}])

        job = self.client.copy_table(self._name("source"), self._name("destination"))
        job.result()

        # jobs.get is what the client polls for a copy job.
        replayed = self.client.get_job(job.job_id)
        self.assertIsInstance(replayed, bigquery.CopyJob)
        self.assertEqual("DONE", replayed.state)
