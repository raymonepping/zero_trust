"use strict";

const { createLogger, format, transports } = require("winston");

const {
  combine,
  timestamp,
  colorize,
  printf,
  errors,
  json,
} = format;

const DEV = process.env.NODE_ENV !== "production";
const LOG_LEVEL = process.env.LOG_LEVEL || "info";
const CONTAINER_NAME = process.env.CONTAINER_NAME || "zero-trust-backend";

// ------------------------------------------------------------------
// Dev format (human-readable)
// ------------------------------------------------------------------
const devFormat = combine(
  colorize({ all: true }),
  timestamp({ format: "YYYY-MM-DD HH:mm:ss" }),
  errors({ stack: true }),
  printf(({ level, message, timestamp: ts, stack, ...meta }) => {
    const metaString =
      Object.keys(meta).length > 2
        ? `\n${JSON.stringify(meta, null, 2)}`
        : Object.keys(meta).length > 0
          ? ` ${JSON.stringify(meta)}`
          : "";

    return stack
      ? `${ts} [${level}] [${CONTAINER_NAME}] ${message}\n${stack}${metaString}`
      : `${ts} [${level}] [${CONTAINER_NAME}] ${message}${metaString}`;
  })
);

// ------------------------------------------------------------------
// Production format (JSON)
// ------------------------------------------------------------------
const prodFormat = combine(
  timestamp(),
  errors({ stack: true }),
  json()
);

// ------------------------------------------------------------------
// Logger
// ------------------------------------------------------------------
const logger = createLogger({
  level: LOG_LEVEL,
  format: DEV ? devFormat : prodFormat,
  transports: [new transports.Console()],
  exitOnError: false,
});

// ------------------------------------------------------------------
// Morgan stream
// ------------------------------------------------------------------
logger.stream = {
  write: (message) => logger.http(message.trimEnd()),
};

module.exports = logger;