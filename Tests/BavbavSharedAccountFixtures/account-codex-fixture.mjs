#!/usr/bin/env node
// Strict stdio fixture for the restricted host worker. Never calls OpenAI.
import { createInterface } from 'node:readline';
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
const threads = new Set(), active = new Map();
let next = 0;
createInterface({ input: process.stdin }).on('line', line => {
  const query = JSON.parse(line), args = query.params ?? {};
  const reply = result => send({ id: query.id, result });
  const fail = message => send({ id: query.id, error: { code: -32000, message } });
  switch (query.method) {
    case 'initialize': reply({ codexHome: '/tmp/isolated-account-fixture', platformOs: 'macos', userAgent: 'Account Fixture' }); break;
    case 'initialized': break;
    case 'account/read': reply({ requiresOpenaiAuth: true, account: { type: 'chatgpt' } }); break;
    case 'model/list': reply({ data: [{ id: 'fixture-model', model: 'fixture-model', displayName: 'Fixture' }] }); break;
    case 'thread/list': reply({ data: [] }); break;
    case 'permissionProfile/list': reply({ data: [{ id: 'bavbav_account', allowed: true }] }); break;
    case 'thread/start': {
      const config = args.config;
      if (args.ephemeral !== true || args.permissions !== 'bavbav_account' || args.sandbox !== undefined
          || args.approvalPolicy !== 'never' || config?.['features.shell_tool'] !== false
          || config?.['features.apps'] !== false || config?.['web_search'] !== 'disabled'
          || !process.argv.includes('features.unified_exec=false')
          || !process.argv.includes('permissions.bavbav_account.network.enabled=false')
          || !process.argv.some(value => value.includes('permissions.bavbav_account.filesystem={":root"="deny"'))
          || !Array.isArray(args.dynamicTools) || args.dynamicTools.length
          || process.env.OPENAI_API_KEY || process.env.CODEX_API_KEY) {
        fail('Unsafe shared account thread.'); break;
      }
      const id = 'account-thread-' + ++next;
      threads.add(id);
      reply({ thread: { id, cwd: args.cwd, preview: '', createdAt: 1792500000, updatedAt: 1792500000,
        status: { type: 'idle' }, source: 'appServer', modelProvider: 'openai' } });
      break;
    }
    case 'turn/start': {
      const prompt = args.input?.[0]?.text;
      if (!threads.has(args.threadId) || args.permissions !== 'bavbav_account'
          || args.sandboxPolicy !== undefined || args.approvalPolicy !== 'never' || typeof prompt !== 'string') {
        fail('Unsafe shared account turn.'); break;
      }
      const turn = 'account-turn-' + ++next, thread = args.threadId;
      active.set(thread, turn);
      reply({ turn: { id: turn, status: 'inProgress' } });
      send({ method: 'turn/started', params: { threadId: thread, turn: { id: turn, status: 'inProgress' } } });
      if (prompt === 'ACCOUNT_HOLD') break;
      if (prompt === 'ACCOUNT_TOOL_REQUEST') {
        setTimeout(() => send({ id: 'unexpected-tool', method: 'item/commandExecution/requestApproval',
          params: { threadId: thread, turnId: turn } }), 40);
        break;
      }
      const answer = 'YANIT: ' + prompt;
      setTimeout(() => {
        if (active.get(thread) !== turn) return;
        send({ method: 'item/agentMessage/delta', params: { threadId: thread, turnId: turn, itemId: turn + '-message', delta: answer.slice(0, 5) } });
        send({ method: 'item/agentMessage/delta', params: { threadId: thread, turnId: turn, itemId: turn + '-message', delta: answer.slice(5) } });
        send({ method: 'item/completed', params: { threadId: thread, turnId: turn, item: { type: 'agentMessage', id: turn + '-message', text: answer } } });
        send({ method: 'turn/completed', params: { threadId: thread, turn: { id: turn, status: 'completed' } } });
        active.delete(thread);
      }, 80);
      break;
    }
    case 'turn/interrupt': {
      const turn = active.get(args.threadId);
      active.delete(args.threadId);
      reply({});
      if (turn) send({ method: 'turn/completed', params: { threadId: args.threadId, turn: { id: turn, status: 'interrupted' } } });
      break;
    }
    default: fail('Unsupported fixture RPC ' + query.method);
  }
});
process.stdin.on('end', () => process.exit(0));
