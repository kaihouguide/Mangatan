FROM python:3.12-slim
WORKDIR /app/ocr-server
RUN pip install --no-cache-dir uv
COPY ocr-server/pyproject.toml ocr-server/uv.lock ./
RUN uv sync --frozen --no-dev
COPY ocr-server/ .
EXPOSE 3000
CMD ["uv", "run", "server.py"]
