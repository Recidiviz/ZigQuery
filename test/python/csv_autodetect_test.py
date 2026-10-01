"""Tests for CSV schema autodetection."""
import io
from datetime import date

from google.cloud import bigquery

from utils.big_query_emulator_container import BQ_EMULATOR_PROJECT_ID
from utils.big_query_emulator_test_case import (
    BigQueryAddress,
    BigQueryEmulatorTestCase,
)


class TestCSVAutodetect(BigQueryEmulatorTestCase):
    """Tests CSV schema autodetection capabilities."""

    def _get_table_ref(
        self, dataset_id: str, table_id: str
    ) -> bigquery.TableReference:
        """Create a table reference using the non-deprecated API."""
        return bigquery.TableReference(
            bigquery.DatasetReference(BQ_EMULATOR_PROJECT_ID, dataset_id),
            table_id,
        )

    def test_autodetect_basic_types(self) -> None:
        """Test that basic types are correctly detected from CSV."""
        csv_data = """name,age,score,active
Alice,30,95.5,true
Bob,25,88.0,false
"""
        self.client.create_dataset("test_dataset")
        table_ref = self._get_table_ref("test_dataset", "test_table")

        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=0,
            autodetect=True,
        )

        load_job = self.client.load_table_from_file(
            io.StringIO(csv_data),
            table_ref,
            job_config=job_config,
        )
        load_job.result()

        # Verify schema was detected
        table = self.client.get_table(table_ref)
        schema_dict = {f.name: f.field_type for f in table.schema}

        self.assertEqual(schema_dict["name"], "STRING")
        self.assertEqual(schema_dict["age"], "INTEGER")
        self.assertEqual(schema_dict["score"], "FLOAT")
        self.assertEqual(schema_dict["active"], "BOOL")

        # Verify data was loaded correctly
        self.run_query_test(
            f"SELECT name, age, score, active FROM `{BQ_EMULATOR_PROJECT_ID}.test_dataset.test_table` ORDER BY name",
            expected_result=[
                {"name": "Alice", "age": 30, "score": 95.5, "active": True},
                {"name": "Bob", "age": 25, "score": 88.0, "active": False},
            ],
        )

    def test_autodetect_date_iso_format(self) -> None:
        """Test ISO date format detection (YYYY-MM-DD)."""
        csv_data = """event,event_date
Birthday,2024-01-15
Anniversary,2024-12-31
"""
        self.client.create_dataset("test_dataset")
        table_ref = self._get_table_ref("test_dataset", "test_table")

        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=0,
            autodetect=True,
        )

        load_job = self.client.load_table_from_file(
            io.StringIO(csv_data),
            table_ref,
            job_config=job_config,
        )
        load_job.result()

        # Verify schema
        table = self.client.get_table(table_ref)
        schema_dict = {f.name: f.field_type for f in table.schema}
        self.assertEqual(schema_dict["event_date"], "DATE")

        # Verify data
        self.run_query_test(
            f"SELECT event, event_date FROM `{BQ_EMULATOR_PROJECT_ID}.test_dataset.test_table` ORDER BY event",
            expected_result=[
                {"event": "Anniversary", "event_date": date(2024, 12, 31)},
                {"event": "Birthday", "event_date": date(2024, 1, 15)},
            ],
        )

    def test_autodetect_date_uk_format_becomes_string(self) -> None:
        """Test UK date format (DD/MM/YYYY) is not auto-detected as DATE.

        BigQuery only supports ISO 8601 format (YYYY-MM-DD) for DATE auto-detection.
        UK format dates are treated as STRING.
        """
        csv_data = """event,event_date
Birthday,15/01/2024
Anniversary,31/12/2024
"""
        self.client.create_dataset("test_dataset")
        table_ref = self._get_table_ref("test_dataset", "test_table")

        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=0,
            autodetect=True,
        )

        load_job = self.client.load_table_from_file(
            io.StringIO(csv_data),
            table_ref,
            job_config=job_config,
        )
        load_job.result()

        # Verify schema - UK format becomes STRING, not DATE
        table = self.client.get_table(table_ref)
        schema_dict = {f.name: f.field_type for f in table.schema}
        self.assertEqual(schema_dict["event_date"], "STRING")

        # Verify data - kept as string values
        self.run_query_test(
            f"SELECT event, event_date FROM `{BQ_EMULATOR_PROJECT_ID}.test_dataset.test_table` ORDER BY event",
            expected_result=[
                {"event": "Anniversary", "event_date": "31/12/2024"},
                {"event": "Birthday", "event_date": "15/01/2024"},
            ],
        )

    def test_autodetect_handles_nulls(self) -> None:
        """Test that NULL values don't break type detection."""
        csv_data = """id,value,name
1,100,Alice
2,,Bob
3,null,Charlie
4,200,
"""
        self.client.create_dataset("test_dataset")
        table_ref = self._get_table_ref("test_dataset", "test_table")

        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=0,
            autodetect=True,
        )

        load_job = self.client.load_table_from_file(
            io.StringIO(csv_data),
            table_ref,
            job_config=job_config,
        )
        load_job.result()

        # Verify schema - INTEGER type should be detected despite nulls
        table = self.client.get_table(table_ref)
        schema_dict = {f.name: f.field_type for f in table.schema}
        self.assertEqual(schema_dict["id"], "INTEGER")
        self.assertEqual(schema_dict["value"], "INTEGER")
        self.assertEqual(schema_dict["name"], "STRING")

        # Verify data with nulls
        self.run_query_test(
            f"SELECT id, value, name FROM `{BQ_EMULATOR_PROJECT_ID}.test_dataset.test_table` ORDER BY id",
            expected_result=[
                {"id": 1, "value": 100, "name": "Alice"},
                {"id": 2, "value": None, "name": "Bob"},
                {"id": 3, "value": None, "name": "Charlie"},
                {"id": 4, "value": 200, "name": None},
            ],
        )

    def test_autodetect_boolean_variants(self) -> None:
        """Test various boolean value formats."""
        csv_data = """id,flag1,flag2,flag3
1,true,yes,Y
2,false,no,N
"""
        self.client.create_dataset("test_dataset")
        table_ref = self._get_table_ref("test_dataset", "test_table")

        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=0,
            autodetect=True,
        )

        load_job = self.client.load_table_from_file(
            io.StringIO(csv_data),
            table_ref,
            job_config=job_config,
        )
        load_job.result()

        # Verify schema
        table = self.client.get_table(table_ref)
        schema_dict = {f.name: f.field_type for f in table.schema}
        self.assertEqual(schema_dict["flag1"], "BOOL")
        self.assertEqual(schema_dict["flag2"], "BOOL")
        self.assertEqual(schema_dict["flag3"], "BOOL")

        # Verify data - all should be converted to true/false
        self.run_query_test(
            f"SELECT id, flag1, flag2, flag3 FROM `{BQ_EMULATOR_PROJECT_ID}.test_dataset.test_table` ORDER BY id",
            expected_result=[
                {"id": 1, "flag1": True, "flag2": True, "flag3": True},
                {"id": 2, "flag1": False, "flag2": False, "flag3": False},
            ],
        )

    def test_autodetect_mixed_types_fallback_to_string(self) -> None:
        """Test that mixed types fall back to STRING."""
        csv_data = """id,mixed_col
1,100
2,hello
3,200
"""
        self.client.create_dataset("test_dataset")
        table_ref = self._get_table_ref("test_dataset", "test_table")

        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=0,
            autodetect=True,
        )

        load_job = self.client.load_table_from_file(
            io.StringIO(csv_data),
            table_ref,
            job_config=job_config,
        )
        load_job.result()

        # Verify schema - mixed column should be STRING
        table = self.client.get_table(table_ref)
        schema_dict = {f.name: f.field_type for f in table.schema}
        self.assertEqual(schema_dict["mixed_col"], "STRING")

    def test_autodetect_with_existing_table(self) -> None:
        """Test that autodetect works with an existing table schema."""
        # First create the table with explicit schema
        address = BigQueryAddress(dataset_id="test_dataset", table_id="test_table")
        self.create_mock_table(
            address,
            schema=[
                bigquery.SchemaField("name", "STRING"),
                bigquery.SchemaField("value", "INTEGER"),
            ],
        )

        # Load CSV data - should use existing schema, not autodetect
        csv_data = """name,value
Alice,100
Bob,200
"""
        table_ref = self._get_table_ref("test_dataset", "test_table")

        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=0,
            autodetect=True,  # Should be ignored since table exists
        )

        load_job = self.client.load_table_from_file(
            io.StringIO(csv_data),
            table_ref,
            job_config=job_config,
        )
        load_job.result()

        # Verify data was loaded
        self.run_query_test(
            f"SELECT name, value FROM `{BQ_EMULATOR_PROJECT_ID}.test_dataset.test_table` ORDER BY name",
            expected_result=[
                {"name": "Alice", "value": 100},
                {"name": "Bob", "value": 200},
            ],
        )

    def test_autodetect_all_null_column(self) -> None:
        """Test that columns with all NULL values default to STRING."""
        csv_data = """id,empty_col
1,
2,null
3,
"""
        self.client.create_dataset("test_dataset")
        table_ref = self._get_table_ref("test_dataset", "test_table")

        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=0,
            autodetect=True,
        )

        load_job = self.client.load_table_from_file(
            io.StringIO(csv_data),
            table_ref,
            job_config=job_config,
        )
        load_job.result()

        # Verify schema - all-null column should be STRING
        table = self.client.get_table(table_ref)
        schema_dict = {f.name: f.field_type for f in table.schema}
        self.assertEqual(schema_dict["empty_col"], "STRING")
