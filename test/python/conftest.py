"""Pytest fixtures for BigQuery emulator testing.

This module provides pytest fixtures for testing with the BigQuery emulator.
Fixtures support parallel testing with pytest-xdist through automatic port allocation.
"""
import grpc
import pytest
from google.api_core.client_options import ClientOptions
from google.auth import credentials
from google.cloud import bigquery
from google.cloud.bigquery_storage_v1 import BigQueryReadClient
from google.cloud.bigquery_storage_v1.services.big_query_read.transports import (
    BigQueryReadGrpcTransport,
)
from unittest.mock import patch

from utils.big_query_emulator_container import (
    BQ_EMULATOR_PROJECT_ID,
    create_emulator,
)
from utils.big_query_emulator_test_case import RESUMABLE_RETRYABLE_WITHOUT_500

# Tests this emulator does not pass yet, by node ID prefix. Strict: a test that
# starts passing fails the run until its entry is removed, so this list cannot
# go stale in the permissive direction.
KNOWN_FAILURES: dict[str, str] = {}


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    for item in items:
        for prefix, reason in KNOWN_FAILURES.items():
            if item.nodeid.startswith(prefix):
                item.add_marker(pytest.mark.xfail(reason=reason, strict=True))


@pytest.fixture(scope="class")
def bq_emulator():
    """Pytest fixture for BigQuery emulator with class scope.

    Starts a BigQuery emulator container that lives for the duration of the test class.
    The container is automatically cleaned up after all tests in the class complete.

    Yields:
        BigQueryEmulator: Running emulator instance

    Example:
        >>> class TestMyQueries:
        ...     def test_simple_query(self, bq_emulator, bq_client):
        ...         result = list(bq_client.query("SELECT 1 AS col"))
        ...         assert result[0]["col"] == 1
    """
    with create_emulator() as emulator:
        yield emulator


@pytest.fixture(scope="class")
def bq_client(bq_emulator):
    """Pytest fixture providing configured BigQuery client.

    Creates a BigQuery client configured to connect to the emulator.
    The client is patched to fail fast on 500 errors instead of retrying infinitely.

    Args:
        bq_emulator: The bq_emulator fixture

    Yields:
        bigquery.Client: Configured BigQuery client

    Example:
        >>> def test_query(bq_client):
        ...     df = bq_client.query("SELECT 1 AS col").to_dataframe()
        ...     assert df.shape == (1, 1)
    """
    # Patch retry logic to fail fast on 500 errors
    def _fail_500(original_error):
        from google.api_core.exceptions import GoogleAPICallError
        from http import HTTPStatus
        if original_error.code == HTTPStatus.INTERNAL_SERVER_ERROR:
            raise RuntimeError(
                "The BigQueryEmulator has failed with a 500 status code. "
                f"Original error message: {original_error.message}"
            )
        raise original_error

    with patch("google.cloud.bigquery.retry._should_retry", _fail_500), patch(
        "google.resumable_media.common.RETRYABLE", RESUMABLE_RETRYABLE_WITHOUT_500
    ):
        client = bigquery.Client(
            project=BQ_EMULATOR_PROJECT_ID,
            client_options=ClientOptions(
                api_endpoint=bq_emulator.get_connection_url()
            ),
            credentials=credentials.AnonymousCredentials(),
        )
        yield client


@pytest.fixture(scope="function")
def bq_storage_client(bq_emulator):
    """Pytest fixture providing configured BigQuery Storage client.

    Creates a BigQuery Storage client configured to connect to the emulator's
    gRPC endpoint for reading data using the Storage API.

    Args:
        bq_emulator: The bq_emulator fixture

    Yields:
        BigQueryReadClient: Configured BigQuery Storage client

    Example:
        >>> def test_storage_read(bq_storage_client, bq_client):
        ...     # Create table and load data using bq_client
        ...     # Then read using Storage API
        ...     session = bq_storage_client.create_read_session(...)
    """
    channel = grpc.insecure_channel(bq_emulator.get_grpc_endpoint())
    transport = BigQueryReadGrpcTransport(channel=channel)
    client = BigQueryReadClient(
        transport=transport,
        client_options={
            "api_endpoint": bq_emulator.get_grpc_endpoint(),
        },
    )
    yield client
    channel.close()


@pytest.fixture(scope="function", autouse=False)
def clean_emulator_data(bq_client):
    """Pytest fixture that cleans up emulator data after each test.

    This fixture automatically wipes all datasets and tables from the emulator
    after the test completes. Use this when you want to ensure a clean state
    between tests.

    Args:
        bq_client: The BigQuery client fixture

    Example:
        >>> @pytest.mark.usefixtures("clean_emulator_data")
        ... def test_with_cleanup(bq_client):
        ...     # Data will be cleaned up after this test
        ...     bq_client.create_dataset("test_dataset")
    """
    yield
    # Cleanup after test
    from concurrent import futures
    from google.api_core import retry
    from google.api_core.exceptions import GoogleAPICallError
    from http import HTTPStatus

    def _fail_500_predicate(original_error: GoogleAPICallError) -> None:
        if original_error.code == HTTPStatus.INTERNAL_SERVER_ERROR:
            raise RuntimeError(
                f"Emulator failed with 500: {original_error.message}"
            )
        raise original_error

    _fail_500_retry = retry.Retry(predicate=_fail_500_predicate)

    with futures.ThreadPoolExecutor(max_workers=64) as executor:
        to_delete = [
            executor.submit(
                bq_client.delete_dataset,
                dataset_list_item.dataset_id,
                delete_contents=True,
                not_found_ok=True,
                retry=_fail_500_retry
            )
            for dataset_list_item in bq_client.list_datasets()
        ]

    for future in futures.as_completed(to_delete):
        future.result()
