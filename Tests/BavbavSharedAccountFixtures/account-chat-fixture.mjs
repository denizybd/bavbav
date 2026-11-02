// Test-only paired devices and the actual packaged broker over localhost Noise.
// No public discovery, production pairing, credentials or cloud requests.
import { createInterface } from 'node:readline';
import { mkdtempSync, rmSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { isAbsolute, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomBytes } from 'node:crypto';

const selected = process.env.BAVBAV_SHARED_ACCOUNT_ENGINE;
if (!selected || !isAbsolute(selected)) throw Error('Select an absolute packaged Workspace engine for this fixture.');
const engine = realpathSync(selected);
const moduleAt = name => pathToFileURL(join(engine, 'src', name)).href;
const [{ WorkspaceStore }, { PeerService }, { AccountChat }, { startRelayServer }] = await Promise.all([
  import(moduleAt('store.mjs')), import(moduleAt('peer.mjs')),
  import(moduleAt('account-chat.mjs')), import(moduleAt('relay.mjs')),
]);
const root = mkdtempSync(join(tmpdir(), 'account-native-fixture-'));
const deniz = new WorkspaceStore(join(root, 'deniz')), emir = new WorkspaceStore(join(root, 'emir'));
deniz.completePairing(emir.joinWorkspace(deniz.createWorkspace('deniz')));
const peers = [new PeerService(deniz, { internet: false }), new PeerService(emir, { internet: false })];
const accounts = { deniz: new AccountChat(deniz, peers[0]), emir: new AccountChat(emir, peers[1]) };
const token = randomBytes(32).toString('hex'), relay = await startRelayServer(token);
await Promise.all(peers.map(peer => peer.start()));
for (const peer of peers) peer.useRelay({ url: `ws://127.0.0.1:${relay.port}/connect`, token, allowLoopback: true });
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
send({ type: 'ready' });
createInterface({ input: process.stdin }).on('line', line => {
  let query;
  try {
    query = JSON.parse(line);
    const broker = accounts[query.role];
    if (!broker) throw Error('Unknown fixture role.');
    const methods = {
      accountState: () => broker.status(), accountHeartbeat: args => broker.heartbeat(args),
      accountSend: args => broker.submit(args), accountTake: args => broker.take(args),
      accountReply: args => broker.reply(args), accountPoll: args => broker.poll(args.after),
      accountCancel: args => broker.cancel(args.id),
    };
    if (!methods[query.method]) throw Error('Unknown account fixture method.');
    send({ id: query.id, result: methods[query.method](query.args) });
  } catch (error) { send({ id: query?.id, error: error.message }); }
});
let closing = false;
async function close() {
  if (closing) return;
  closing = true;
  Object.values(accounts).forEach(broker => broker.close());
  await Promise.all(peers.map(peer => peer.stop()));
  await relay.close();
  rmSync(root, { recursive: true, force: true });
  process.exit(0);
}
process.stdin.on('end', close);
process.on('SIGTERM', close);
process.on('SIGINT', close);
