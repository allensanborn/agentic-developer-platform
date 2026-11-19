# The workshop's code-execution broker (lab 5): server.py, query.py, sandbox_runner.py and
# chart_cache.py are upstream's files byte for byte. It reads orders from DynamoDB (floci,
# via AWS_ENDPOINT_URL) and runs model-written code in a claimed gVisor sandbox.
FROM python:3.13-slim-bookworm@sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --require-hashes -r requirements.txt \
    && pip uninstall -y pip setuptools
COPY server.py query.py sandbox_runner.py chart_cache.py ./
USER 10001:10001
ENTRYPOINT ["python", "server.py"]
