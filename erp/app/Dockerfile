# One image, three entrypoints (controller.py, agent.py, executor.py); the workload's
# identity and credentials, not its image, are what separate them.
FROM python:3.13-slim-bookworm@sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --require-hashes -r requirements.txt \
    && pip uninstall -y pip setuptools
COPY rules.py controller.py agent.py executor.py cli.py ./
USER 10001:10001
ENTRYPOINT ["python"]
