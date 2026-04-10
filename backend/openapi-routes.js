"use strict";

const { Router } = require("express");
const openapiSpec = require("./openapi.json");

const router = Router();

router.get("/openapi.json", (_req, res) => {
  res.json(openapiSpec);
});

router.get("/docs", (_req, res) => {
  res.type("html").send(`<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Zero Trust Workshop API Docs</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css" />
    <style>
      :root {
        --bg: #0f172a;
        --bg-soft: #111827;
        --panel: #ffffff;
        --panel-soft: #f8fafc;
        --border: #d7e0ea;
        --text: #0f172a;
        --text-soft: #334155;
        --muted: #64748b;
        --blue: #2563eb;
        --green: #15803d;
        --orange: #c2410c;
        --red: #b91c1c;
      }

      *, *::before, *::after { box-sizing: inherit; }
      html { box-sizing: border-box; overflow-y: scroll; background: var(--bg); }
      body {
        margin: 0;
        background:
          linear-gradient(180deg, #0f172a 0%, #111827 100%);
        color: var(--text);
      }

      .swagger-ui {
        color: var(--text);
      }

      .swagger-ui .topbar {
        display: none;
      }

      .swagger-ui .scheme-container {
        background: var(--panel);
        box-shadow: 0 10px 30px rgba(15, 23, 42, 0.08);
        border-bottom: 1px solid var(--border);
        padding: 14px 0;
      }

      .swagger-ui .information-container,
      .swagger-ui .wrapper {
        max-width: 1180px;
      }

      .swagger-ui .info {
        margin: 28px 0;
      }

      .swagger-ui .info .title,
      .swagger-ui .info p,
      .swagger-ui .info li,
      .swagger-ui .info a,
      .swagger-ui .info .base-url {
        color: #e5eefb;
      }

      .swagger-ui .info a {
        text-decoration: underline;
      }

      .swagger-ui .opblock-tag,
      .swagger-ui .opblock .opblock-summary-description,
      .swagger-ui .opblock-description-wrapper p,
      .swagger-ui .opblock-external-docs-wrapper p,
      .swagger-ui .responses-inner h4,
      .swagger-ui .responses-inner h5,
      .swagger-ui .response-col_status,
      .swagger-ui .response-col_description,
      .swagger-ui .tab li,
      .swagger-ui .model-title,
      .swagger-ui .parameter__name,
      .swagger-ui .parameter__type,
      .swagger-ui .parameter__deprecated,
      .swagger-ui .prop-type,
      .swagger-ui .prop-format,
      .swagger-ui section.models h4,
      .swagger-ui section.models h5,
      .swagger-ui .btn,
      .swagger-ui label,
      .swagger-ui select,
      .swagger-ui .servers-title,
      .swagger-ui .server-url,
      .swagger-ui .server-description {
        color: var(--text);
      }

      .swagger-ui .opblock-tag {
        border-bottom: 1px solid rgba(148, 163, 184, 0.22);
      }

      .swagger-ui .opblock {
        background: var(--panel);
        border-width: 1px;
        border-radius: 8px;
        box-shadow: 0 6px 20px rgba(15, 23, 42, 0.06);
      }

      .swagger-ui .opblock .opblock-summary {
        border-color: rgba(148, 163, 184, 0.24);
      }

      .swagger-ui .opblock.opblock-get {
        border-color: rgba(37, 99, 235, 0.35);
        background: #eff6ff;
      }

      .swagger-ui .opblock.opblock-post {
        border-color: rgba(21, 128, 61, 0.35);
        background: #f0fdf4;
      }

      .swagger-ui .opblock.opblock-put {
        border-color: rgba(194, 65, 12, 0.35);
        background: #fff7ed;
      }

      .swagger-ui .opblock.opblock-delete {
        border-color: rgba(185, 28, 28, 0.35);
        background: #fef2f2;
      }

      .swagger-ui .opblock.opblock-get .opblock-summary-method {
        background: var(--blue);
      }

      .swagger-ui .opblock.opblock-post .opblock-summary-method {
        background: var(--green);
      }

      .swagger-ui .opblock.opblock-put .opblock-summary-method {
        background: var(--orange);
      }

      .swagger-ui .opblock.opblock-delete .opblock-summary-method {
        background: var(--red);
      }

      .swagger-ui .opblock-summary-path,
      .swagger-ui .opblock-summary-description {
        color: var(--text);
      }

      .swagger-ui .responses-table .response-col_status {
        color: var(--text);
      }

      .swagger-ui .responses-table td,
      .swagger-ui .responses-table th {
        color: var(--text-soft);
      }

      .swagger-ui .model-box,
      .swagger-ui section.models,
      .swagger-ui .model-container,
      .swagger-ui .body-param__example,
      .swagger-ui .highlight-code,
      .swagger-ui .microlight,
      .swagger-ui .renderedMarkdown code,
      .swagger-ui textarea,
      .swagger-ui input[type=text],
      .swagger-ui input[type=password],
      .swagger-ui input[type=search],
      .swagger-ui input[type=email],
      .swagger-ui input[type=url],
      .swagger-ui select {
        background: var(--panel-soft);
        color: var(--text);
        border-color: var(--border);
      }

      .swagger-ui section.models {
        border: 1px solid rgba(148, 163, 184, 0.2);
      }

      .swagger-ui section.models .model-container {
        background: transparent;
      }

      .swagger-ui .model-toggle:after {
        background: none;
      }

      .swagger-ui .model,
      .swagger-ui .model-box-control,
      .swagger-ui .models-control,
      .swagger-ui .models-jump-to-path,
      .swagger-ui .response-control-media-type__accept-message {
        color: var(--text);
      }

      .swagger-ui .btn.authorize {
        color: var(--green);
        border-color: rgba(21, 128, 61, 0.35);
        background: #f0fdf4;
      }

      .swagger-ui .btn.execute {
        background: var(--blue);
        border-color: var(--blue);
        color: #fff;
      }

      .swagger-ui .btn.cancel {
        background: #fff;
        color: var(--text);
        border-color: var(--border);
      }

      .swagger-ui .markdown p,
      .swagger-ui .markdown pre,
      .swagger-ui .renderedMarkdown p,
      .swagger-ui .renderedMarkdown li,
      .swagger-ui .renderedMarkdown table,
      .swagger-ui .renderedMarkdown tr,
      .swagger-ui .renderedMarkdown td {
        color: var(--text-soft);
      }

      .swagger-ui .copy-to-clipboard,
      .swagger-ui svg {
        fill: currentColor;
      }
    </style>
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
    <script>
      window.ui = SwaggerUIBundle({
        url: "/openapi.json",
        dom_id: "#swagger-ui",
        deepLinking: true,
        docExpansion: "list",
        displayRequestDuration: true
      });
    </script>
  </body>
</html>`);
});

module.exports = router;
