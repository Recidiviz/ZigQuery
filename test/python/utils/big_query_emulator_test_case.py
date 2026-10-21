"""An implementation of TestCase that can be used for tests that talk to the BigQuery emulator."""
import attr
import os
import tempfile
import unittest
from concurrent import futures
from http import HTTPStatus
from typing import Any, Dict, Iterable, List
from unittest.mock import patch

import grpc
import numpy
import pandas as pd
import requests
from google.api_core import retry
from google.api_core.client_options import ClientOptions
from google.api_core.exceptions import GoogleAPICallError, from_http_response, InternalServerError
from google.auth import credentials
from google.cloud import bigquery, exceptions
from google.cloud.bigquery import TableReference, DatasetReference
from google.cloud.bigquery_storage_v1 import BigQueryReadClient
from google.cloud.bigquery_storage_v1.services.big_query_read.transports import (
    BigQueryReadGrpcTransport,
)
from google.resumable_media import common as resumable_media_common
from pandas_gbq import read_gbq as og_read_gbq

from utils.big_query_emulator_container import (
    BQ_EMULATOR_PROJECT_ID,
    BigQueryEmulator,
    create_emulator,
)


@attr.s(frozen=True, kw_only=True, order=True)
class BigQueryAddress:
    """Represents the (dataset_id, table_id) address of a BigQuery view or table."""

    dataset_id: str = attr.ib()
    table_id: str = attr.ib()

    @classmethod
    def from_str(cls, address_str: str) -> "BigQueryAddress":
        """Converts a string in the format 'dataset.table' to BigQueryAddress."""
        parts = address_str.split(".")
        if len(parts) != 2 or not all(parts):
            raise ValueError("Input must be in the format 'dataset.table'.")
        return cls(dataset_id=parts[0], table_id=parts[1])

    def to_str(self) -> str:
        return f"{self.dataset_id}.{self.table_id}"

def _fail_500(original_error: GoogleAPICallError) -> None:
    """The BigQuery client retries when it receives a 500 from google.
    However, using the emulator means we end up in an infinite try loop.
    This function is used to mock the underlying error response and
    fails if it is a 500 response.
    """
    if getattr(original_error, "code", None) == HTTPStatus.INTERNAL_SERVER_ERROR:
        raise RuntimeError(
            "The BigQueryEmulator has failed with a 500 status code. "
            "To investigate: set the class attribute "
            "show_emulator_logs_on_failure=True, re-run, and then check emulator's logs. "
            f"Original error message: {original_error.message}"
        )
    raise original_error


_fail_500_retry = retry.Retry(predicate=_fail_500)

# Uploads (load_table_from_file) retry through google-resumable-media, which
# _fail_500 does not reach: left alone, every 500 there costs ~65s of backoff.
RESUMABLE_RETRYABLE_WITHOUT_500 = tuple(
    code
    for code in resumable_media_common.RETRYABLE
    if code != HTTPStatus.INTERNAL_SERVER_ERROR
)

class BigQueryEmulatorTestCase(unittest.TestCase):
    """An implementation of TestCase that can be used for tests that talk to the
    BigQuery emulator.

    This class now uses testcontainers internally for container management while
    maintaining backward compatibility with existing tests.
    """

    project_id = BQ_EMULATOR_PROJECT_ID

    emulator: BigQueryEmulator

    # Deletes all tables / views in the emulator after each test
    # Subclasses can choose to override this as it may not always be necessary
    wipe_emulator_data_on_teardown = True

    # Subclasses can override this to prevent rebuilding of input JSON
    input_json_schema_path: str | None = None

    # Subclasses can override this to keep the input file when debugging tests
    delete_json_input_schema_on_teardown = True

    # If the test failed, output the emulator logs prior to exiting
    show_emulator_logs_on_failure = False

    @classmethod
    def setUpClass(cls) -> None:
        cls.emulator = create_emulator(
            input_schema_json_path=cls.input_json_schema_path
        )
        cls.emulator.start()

    def setUp(self) -> None:
        self.bq_error_handling_patcher = patch(
            "google.cloud.bigquery.retry._should_retry", _fail_500
        )
        self.bq_error_handling_patcher.start()
        self.resumable_error_handling_patcher = patch(
            "google.resumable_media.common.RETRYABLE",
            RESUMABLE_RETRYABLE_WITHOUT_500,
        )
        self.resumable_error_handling_patcher.start()
        self.client = bigquery.Client(
            project=BQ_EMULATOR_PROJECT_ID,
            client_options=ClientOptions(
                api_endpoint=self.emulator.get_connection_url()
            ),
            credentials=credentials.AnonymousCredentials(),

        )
        self.read_gbq_patcher = patch(
            "pandas_gbq.read_gbq",
            self._read_gbq_with_emulator,
        )
        self.read_gbq_patcher.start()
        self.to_gbq_patcher = patch(
            "pandas_gbq.to_gbq",
            self._fail_to_gbq_call,
        )
        self.to_gbq_patcher.start()

        # Patch BigQuery Client to always create a new emulator storage client
        def _create_bqstorage_client() -> Any:
            channel = grpc.insecure_channel(self.emulator.get_grpc_endpoint())
            transport = BigQueryReadGrpcTransport(channel=channel)
            return BigQueryReadClient(
                transport=transport,
                client_options={
                    "api_endpoint": self.emulator.get_grpc_endpoint(),
                },
            )

        self.bqstorage_patcher = patch.object(
            bigquery.Client,
            "_ensure_bqstorage_client",
            side_effect=_create_bqstorage_client,
        )
        self.bqstorage_patcher.start()

    def tearDown(self) -> None:
        if self.wipe_emulator_data_on_teardown:
            self._wipe_emulator_data()
        self.bq_error_handling_patcher.stop()
        self.resumable_error_handling_patcher.stop()
        self.read_gbq_patcher.stop()
        self.to_gbq_patcher.stop()
        self.bqstorage_patcher.stop()

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.show_emulator_logs_on_failure:
            logs = cls.emulator.get_logs()
            print(logs)

        cls.emulator.stop()

        if cls.input_json_schema_path and cls.delete_json_input_schema_on_teardown:
            os.remove(cls.input_json_schema_path)

    def query(self, query: str) -> pd.DataFrame:
        return self.client.query(
            query=query,
            retry=_fail_500_retry,
        ).to_dataframe()

    def _read_gbq_with_emulator(self, *args, **kwargs):  # type: ignore
        return og_read_gbq(
            *args,
            **kwargs,
            bigquery_client=self.client,
        )

    def _fail_to_gbq_call(self, *args, **kwargs):  # type: ignore
        raise RuntimeError(
            "Writing to the emulator from pandas is not currently supported."
        )

    def _clear_emulator_table_data(self) -> None:
        """Clears the data out of emulator tables but does not delete any tables."""
        with futures.ThreadPoolExecutor(max_workers=64) as executor:
            to_delete = [
                executor.submit(
                    self.client.query(f"TRUNCATE TABLE `{dataset_list_item.dataset_id}`.`dataset_list_item.table_id`")
                    for dataset_list_item in self.client.list_datasets()
                    for table_list_item in self.client.list_tables(
                        dataset_list_item.dataset_id
                    )
                )
            ]

        for future in futures.as_completed(to_delete):
            future.result()

    def _wipe_emulator_data(self) -> None:
        """Fully deletes all tables and datasets loaded into the emulator."""
        with futures.ThreadPoolExecutor(max_workers=64) as executor:
            to_delete = [
                executor.submit(
                    self.client.delete_dataset,
                    dataset_list_item.dataset_id,
                    delete_contents=True,
                    not_found_ok=True,
                    retry=_fail_500_retry
                )
                for dataset_list_item in self.client.list_datasets()
            ]

        for future in futures.as_completed(to_delete):
            future.result()

    def run_query_test(
            self,
            query_str: str,
            expected_result: Iterable[Dict[str, Any]],
            enforce_order: bool = True,
            **kwargs
    ) -> None:
        query_job = self.client.query(query=query_str, **kwargs)
        contents = list({key: row.get(key) for key in row.keys()} for row in query_job.result())
        if enforce_order:
            self.assertEqual(expected_result, contents)
        else:
            self.assertSetEqual(
                {frozenset(expected.items()) for expected in expected_result},
                {frozenset(actual.items()) for actual in contents},
            )


    def _table_ref_for_address(self, address: BigQueryAddress) -> TableReference:
        return TableReference(
            dataset_ref=DatasetReference(project=self.project_id, dataset_id=address.dataset_id),
            table_id=address.table_id
        )

    def table_exists(self, address: BigQueryAddress) -> bool:
        table_ref = self._table_ref_for_address(address)

        try:
            self.client.get_table(table_ref)
            return True
        except exceptions.NotFound:
            return False

    def create_mock_table(
            self,
            address: BigQueryAddress,
            schema: List[bigquery.SchemaField],
            check_exists: bool | None = True,
            create_dataset: bool | None = True,
    ) -> None:
        if create_dataset:
            self.client.create_dataset(address.dataset_id, exists_ok=True, retry=_fail_500_retry)

        if check_exists and self.table_exists(address):
            raise ValueError(
                f"Table [{address}] already exists. Test cleanup not working properly."
            )

        table = bigquery.Table(table_ref=self._table_ref_for_address(address), schema=schema)

        return self.client.create_table(table=table, exists_ok=check_exists, retry=_fail_500_retry)

    def load_rows_into_table(
            self,
            address: BigQueryAddress,
            data: List[Dict[str, Any]],
    ) -> None:
        return self.client.insert_rows(
            self.client.get_table(self._table_ref_for_address(address)),
            data,
            retry=_fail_500_retry
        )
