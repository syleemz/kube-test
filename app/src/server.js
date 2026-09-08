'use strict';

const express = require('express');
const pino = require('pino');
const { randomUUID } = require('node:crypto');

// stdout JSON 한 줄: {level, time, msg, ...fields}
const log = pino({
  base: null, // pid/hostname 제거
  formatters: { level: (label) => ({ level: label }) }, // level 을 문자열로("info"/"error")
  timestamp: pino.stdTimeFunctions.isoTime,
});

const app = express();
const PORT = Number(process.env.PORT) || 3000;

app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  req.trace_id = req.get('x-trace-id') || randomUUID();
  res.on('finish', () => {
    const latency_ms = Math.round(Number(process.hrtime.bigint() - start) / 1e4) / 100;
    const fields = {
      method: req.method,
      path: req.path,
      status: res.statusCode,
      latency_ms,
      trace_id: req.trace_id,
    };
    if (res.statusCode >= 500) log.error(fields, 'request failed');
    else log.info(fields, 'request completed');
  });
  next();
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.get('/work', async (req, res) => {
  const ms = Math.min(Math.max(Number(req.query.ms) || 100, 0), 10000);
  await new Promise((r) => setTimeout(r, ms));
  res.json({ worked_ms: ms, trace_id: req.trace_id });
});

app.get('/error', (req, res) => {
  res.status(500).json({ error: 'intentional failure', trace_id: req.trace_id });
});

app.listen(PORT, () => {
  log.info({ port: PORT }, 'sample-app started');
});

if (process.env.HEARTBEAT === 'true') {
  setInterval(() => log.info({ msg: 'heartbeat' }), 1000);
}
