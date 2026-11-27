# The sandbox runtime (lab 5): main.py is upstream's file byte for byte; requirements.in is
# upstream's package set, relocked (its lock was stale). The server on :8888 runs the
# broker's files; it holds no credential and, by policy, has no network.
FROM python:3.13-slim-bookworm@sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72
# Debian security fixes reach bookworm before the next python image does (CVE-2025-6020, libpam).
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 MPLBACKEND=Agg MPLCONFIGDIR=/tmp/matplotlib
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --require-hashes -r requirements.txt \
    && pip uninstall -y pip setuptools
COPY main.py .
# Recursive, as upstream: the broker writes the model's code to /app/main.py, the server's own
# filename (already loaded, so overwriting it changes nothing that runs).
RUN chown -R 1000:1000 /app
USER 1000:1000
EXPOSE 8888
ENTRYPOINT ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8888"]
