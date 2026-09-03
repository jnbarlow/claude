#!/usr/bin/env node
/**
 * MCP Invocation Helper — allows bash scripts to invoke LTM MCP tools programmatically.
 * Handles the EPIPE issue by properly managing stdio with the MCP server process.
 *
 * Usage:
 *   CLAUDE_MCP_TOOL=ltm_recall_by_text CLAUDE_MCP_PARAMS='{"query":"test"}' node mcp-invoke.js
 */

const { spawn } = require('child_process');
const path = require('path');

// Resolve MCP server path from CLAUDE_PLUGIN_ROOT environment variable.
const PLUGIN_ROOT = process.env.CLAUDE_PLUGIN_ROOT || '';
const MCP_SERVER_PATH = path.join(PLUGIN_ROOT, 'mcp-server', 'dist', 'index.js');

async function invokeMcpTool(toolName, params) {
  return new Promise((resolve, reject) => {
    // Spawn with stdio: inherit stderr (for logs), pipe stdin/stdout for JSON-RPC.
    const mcpProcess = spawn('node', [MCP_SERVER_PATH], {
      stdio: ['pipe', 'pipe', process.stderr.fd]
    });

    let buffer = '';
    let requestId = 1;
    let timeoutId = null;

    // Handle stdout from MCP server.
    mcpProcess.stdout.on('data', (data) => {
      buffer += data.toString();

      try {
        const lines = buffer.split('\n');
        // Keep incomplete line in buffer.
        buffer = lines.pop() || '';

        for (const line of lines) {
          if (!line.trim()) continue;
          handleMessage(JSON.parse(line));
        }
      } catch (e) {
        // Incomplete JSON, wait for more data.
      }
    });

    mcpProcess.stderr.on('data', (data) => {
      // Ignore stderr to avoid EPIPE issues with console.log during bootstrap.
    });

    mcpProcess.on('close', (code) => {
      if (timeoutId) clearTimeout(timeoutId);
      if (!buffer.includes('"result"')) {
        reject(new Error(`MCP server exited with code ${code}`));
      }
    });

    mcpProcess.on('error', (err) => {
      if (timeoutId) clearTimeout(timeoutId);
      reject(new Error(`Failed to start MCP server: ${err.message}`));
    });

    function handleMessage(message) {
      // Handle initialize request.
      if (message.method === 'initialize') {
        sendMessage({
          jsonrpc: '2.0',
          id: message.id,
          result: {
            protocolVersion: '2024-11-05',
            capabilities: {},
            serverInfo: { name: 'ltm-hooks', version: '1.0.0' }
          }
        });

        sendMessage({
          jsonrpc: '2.0',
          method: 'notifications/initialized'
        });
        return;
      }

      // Handle tool response.
      if (message.id === requestId && message.result) {
        if (timeoutId) clearTimeout(timeoutId);
        mcpProcess.kill();
        resolve(message.result);
      }

      // Handle error.
      if (message.error) {
        if (timeoutId) clearTimeout(timeoutId);
        mcpProcess.kill();
        reject(new Error(`MCP error: ${message.error.message || JSON.stringify(message.error)}`));
      }
    }

    function sendMessage(msg) {
      try {
        mcpProcess.stdin.write(JSON.stringify(msg) + '\n');
      } catch (e) {
        // Ignore write errors.
      }
    }

    // Wait for server to initialize, then send tool call.
    setTimeout(() => {
      requestId++;
      sendMessage({
        jsonrpc: '2.0',
        id: requestId,
        method: 'tools/call',
        params: {
          name: toolName,
          arguments: params || {}
        }
      });

      // Timeout after 10 seconds.
      timeoutId = setTimeout(() => {
        mcpProcess.kill();
        reject(new Error('MCP tool call timed out'));
      }, 10000);
    }, 2000);
  });
}

async function main() {
  const toolName = process.env.CLAUDE_MCP_TOOL;
  let paramsStr = process.env.CLAUDE_MCP_PARAMS || '{}';

  if (!toolName) {
    console.error('Error: CLAUDE_MCP_TOOL environment variable not set.');
    process.exit(1);
  }

  let params;
  try {
    params = JSON.parse(paramsStr);
  } catch (e) {
    console.error(`Error parsing CLAUDE_MCP_PARAMS: ${e.message}`);
    process.exit(1);
  }

  try {
    const result = await invokeMcpTool(toolName, params);

    if (result.content && result.content.length > 0) {
      const text = result.content.map(c => c.text || '').join('\n');
      console.log(text);
    } else {
      console.log(JSON.stringify(result));
    }
  } catch (err) {
    console.error(`Error invoking tool: ${err.message}`);
    process.exit(1);
  }
}

main().catch(err => {
  console.error('Unexpected error:', err.message);
  process.exit(1);
});