FROM python:3.12.10-alpine3.21
ARG APP_VERSION=v1
ENV APP_VERSION=${APP_VERSION} PYTHONUNBUFFERED=1
WORKDIR /app
COPY server.py index.html ./
RUN adduser -D -u 10001 appuser
USER 10001
EXPOSE 8000
CMD ["python", "server.py"]
