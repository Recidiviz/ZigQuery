"""Launches the emulator for tests, either as a Docker container or a local binary.

By default the emulator runs from its published Docker image through
testcontainers, the same way downstream users consume it. Setting
BIGQUERY_EMULATOR_BINARY to a zigquery-server executable runs that binary as a
subprocess instead, which needs no Docker daemon and no Linux build — the
usual way to run this suite on a development machine:

    zig build dist -Drelease=true -Dshim-dylib=... -Dshim-static-obj=... \\
        --prefix zig-out/dist
    BIGQUERY_EMULATOR_BINARY=../../zig-out/dist/bin/zigquery-server uv run pytest
"""
import os
import subprocess
import tempfile
import time
from typing import IO

from testcontainers.core.container import DockerContainer
from testcontainers.core.wait_strategies import LogMessageWaitStrategy

BQ_EMULATOR_PROJECT_ID = "bigquery-emulator-test"

# Both launch modes gate readiness on this line. The server prints it only
# after both the REST and gRPC listeners are bound.
READY_LOG_LINE = "REST server listening at 0.0.0.0"


def get_pytest_worker_id() -> int:
    """Retrieves the worker number from the appropriate environment variable
    https://github.com/pytest-dev/pytest-xdist#identifying-the-worker-process-during-a-test
    """
    return int(os.environ.get("PYTEST_XDIST_WORKER", "gw0")[2:])


def get_bq_emulator_port() -> int:
    """Returns the port for the BigQuery emulator that the current environment should
    use. If we are running outside the context of pytest, we assume there is only one
    emulator running at the default port. Otherwise, the port number is variable to
    avoid interference between tests running in parallel.
    """
    # This port is arbitrarily chosen
    port = 60050
    if not (pytest_worker_id := get_pytest_worker_id()):
        return port

    return port + pytest_worker_id


def get_bq_emulator_grpc_port() -> int:
    """Returns the port for the BigQuery emulator that the current environment should
    use. If we are running outside the context of pytest, we assume there is only one
    emulator running at the default port. Otherwise, the port number is variable to
    avoid interference between tests running in parallel.
    """
    # This port is arbitrarily chosen
    port = 61050
    if not (pytest_worker_id := get_pytest_worker_id()):
        return port

    return port + pytest_worker_id


EMULATOR_IMAGE_REPOSITORY = os.getenv(
    "BIGQUERY_EMULATOR_REPOSITORY", "ghcr.io/recidiviz/zigquery-emulator"
)
EMULATOR_VERSION = os.getenv("BIGQUERY_EMULATOR_VERSION", "latest")
EMULATOR_IMAGE = f"{EMULATOR_IMAGE_REPOSITORY}:{EMULATOR_VERSION}"

EMULATOR_BINARY = os.getenv("BIGQUERY_EMULATOR_BINARY")


def _emulator_args(port: int, grpc_port: int, data_from_json: str | None) -> list[str]:
    args = [
        f"--project={BQ_EMULATOR_PROJECT_ID}",
        "--log-level=info",
        "--database=:memory:",
        f"--port={port}",
        f"--grpc-port={grpc_port}",
    ]
    if data_from_json:
        args.append(f"--data-from-json={data_from_json}")
    return args


class BigQueryEmulatorContainer(DockerContainer):
    """Testcontainers implementation for BigQuery emulator.

    This class provides a testcontainers-based wrapper for managing BigQuery
    emulator containers in tests. It supports:
    - Automatic port allocation for parallel testing with pytest-xdist
    - Volume mounting for loading test data
    - Built-in wait strategies for container readiness
    - Automatic cleanup

    Example:
        >>> with BigQueryEmulatorContainer() as emulator:
        ...     client = bigquery.Client(
        ...         project=BQ_EMULATOR_PROJECT_ID,
        ...         client_options=ClientOptions(
        ...             api_endpoint=emulator.get_connection_url()
        ...         ),
        ...         credentials=credentials.AnonymousCredentials(),
        ...     )
        ...     # Use client for testing
    """

    def __init__(
        self,
        image: str | None = None,
        port: int | None = None,
        grpc_port: int | None = None,
        input_schema_json_path: str | None = None,
        **kwargs
    ):
        """Initialize BigQuery emulator container.

        Args:
            image: Docker image to use. Defaults to value from environment variables
                   BIGQUERY_EMULATOR_REPOSITORY and BIGQUERY_EMULATOR_VERSION.
            port: HTTP port to expose. Defaults to port based on pytest worker ID.
            grpc_port: gRPC port to expose. Defaults to port based on pytest worker ID.
            input_schema_json_path: Optional path to JSON file containing schema data
                                   to load on startup.
            **kwargs: Additional arguments to pass to DockerContainer.
        """
        image = image or EMULATOR_IMAGE
        super().__init__(image, **kwargs)

        self.port = port or get_bq_emulator_port()
        self.grpc_port = grpc_port or get_bq_emulator_grpc_port()
        self.input_schema_json_path = input_schema_json_path

        # Configure ports - bind container ports to host ports
        self.with_bind_ports(self.port, self.port)
        self.with_bind_ports(self.grpc_port, self.grpc_port)

        # Handle volume mounting for test data
        data_from_json = None
        if input_schema_json_path:
            data_from_json = f"/fixtures/{os.path.basename(input_schema_json_path)}"
            self.with_volume_mapping(
                os.path.dirname(input_schema_json_path),
                "/fixtures",
                mode="rw"
            )

        # The image's ENTRYPOINT is the server, so the command is its flags alone.
        self.with_command(_emulator_args(self.port, self.grpc_port, data_from_json))

        self.waiting_for = LogMessageWaitStrategy(READY_LOG_LINE)

    def get_connection_url(self) -> str:
        """Get the HTTP connection URL for the emulator.

        Returns:
            URL string (e.g., "http://0.0.0.0:60050")
        """
        return f"http://0.0.0.0:{self.port}"

    def get_grpc_endpoint(self) -> str:
        """Get the gRPC endpoint for the emulator.

        Returns:
            Endpoint string (e.g., "localhost:61050")
        """
        return f"localhost:{self.grpc_port}"


class BigQueryEmulatorProcess:
    """Runs a local emulator binary with the same interface as BigQueryEmulatorContainer."""

    def __init__(
        self,
        binary: str,
        port: int | None = None,
        grpc_port: int | None = None,
        input_schema_json_path: str | None = None,
        startup_timeout_seconds: float = 30.0,
    ):
        self.binary = binary
        self.port = port or get_bq_emulator_port()
        self.grpc_port = grpc_port or get_bq_emulator_grpc_port()
        self.input_schema_json_path = input_schema_json_path
        self.startup_timeout_seconds = startup_timeout_seconds
        self._process: subprocess.Popen[bytes] | None = None
        # Files rather than pipes: nothing drains a pipe while the tests run,
        # and a full one would block the server on its next write.
        self._stdout = tempfile.TemporaryFile()
        self._stderr = tempfile.TemporaryFile()

    def start(self) -> "BigQueryEmulatorProcess":
        self._process = subprocess.Popen(
            [self.binary, *_emulator_args(self.port, self.grpc_port, self.input_schema_json_path)],
            stdout=self._stdout,
            stderr=self._stderr,
        )
        deadline = time.monotonic() + self.startup_timeout_seconds
        while time.monotonic() < deadline:
            stdout, stderr = self.get_logs()
            if READY_LOG_LINE.encode() in stdout:
                return self
            if self._process.poll() is not None:
                raise RuntimeError(
                    f"{self.binary} exited with status {self._process.returncode} "
                    f"before becoming ready:\n{stdout.decode()}{stderr.decode()}"
                )
            time.sleep(0.05)
        self.stop()
        raise TimeoutError(
            f"{self.binary} did not log {READY_LOG_LINE!r} within "
            f"{self.startup_timeout_seconds}s"
        )

    def stop(self) -> None:
        if self._process is not None and self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait()
        self._process = None

    def get_logs(self) -> tuple[bytes, bytes]:
        """Returns (stdout, stderr), matching DockerContainer.get_logs."""
        return self._read(self._stdout), self._read(self._stderr)

    @staticmethod
    def _read(f: IO[bytes]) -> bytes:
        f.flush()
        f.seek(0)
        return f.read()

    def get_connection_url(self) -> str:
        return f"http://0.0.0.0:{self.port}"

    def get_grpc_endpoint(self) -> str:
        return f"localhost:{self.grpc_port}"

    def __enter__(self) -> "BigQueryEmulatorProcess":
        return self.start()

    def __exit__(self, *exc: object) -> None:
        self.stop()


BigQueryEmulator = BigQueryEmulatorContainer | BigQueryEmulatorProcess


def create_emulator(input_schema_json_path: str | None = None) -> BigQueryEmulator:
    """The emulator for this environment: the local binary when
    BIGQUERY_EMULATOR_BINARY is set, the Docker image otherwise."""
    if EMULATOR_BINARY:
        return BigQueryEmulatorProcess(
            EMULATOR_BINARY, input_schema_json_path=input_schema_json_path
        )
    return BigQueryEmulatorContainer(input_schema_json_path=input_schema_json_path)
