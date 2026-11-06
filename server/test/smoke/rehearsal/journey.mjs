// The invited person's journey in a real browser (docs/multi-user-plan.md §7, PR 4), on a
// disposable local copy: Rails on 3001 with DATABASE_URL pointing at the copy, SPOTIFY_INGESTION_ENABLED=false,
// RUNOUT_PASSKEYS_ENABLED=true and APP_ORIGIN=http://localhost:5199; vite on 5199 proxying to it.
// Headless Chrome over CDP with a virtual authenticator. Prints PASS/FAIL lines and screenshots.
// usage: REHEARSAL_DIR=/tmp/rehearsal REHEARSAL_DB=runout_loved_check node journey.mjs
// Never run against the development or production database: it creates and deletes an account.
import { execSync, spawn } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
const D = process.env.REHEARSAL_DIR || process.cwd();
const DB = process.env.REHEARSAL_DB || 'runout_loved_check';
if (/development|railway|runout$/.test(DB)) throw new Error(`refusing to rehearse against ${DB}`);
mkdirSync(`${D}/shots`, { recursive: true });
const ORIGIN = 'http://localhost:5199';
const SERVER = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const CHRUBY = process.env.CHRUBY_SH || '/usr/local/share/chruby/chruby.sh';
const RAILS = `cd ${SERVER} && source ${CHRUBY} && chruby ruby-3.4.7 && set -a && . ./.env && set +a && export DATABASE_URL=postgresql://postgres@localhost/${DB} SPOTIFY_INGESTION_ENABLED=false RUNOUT_PASSKEYS_ENABLED=true APP_ORIGIN=http://localhost:5199 && bin/rails`;
const rails = (cmd) => execSync(`${RAILS} ${cmd} 2>/dev/null`, { encoding: 'utf8', shell: '/bin/zsh' }).trim();
const port = 9500 + (process.pid % 100);
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-gpu', '--hide-scrollbars', `--user-data-dir=${D}/chrome-${process.pid}`, `--remote-debugging-port=${port}`, '--window-size=1280,1100', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let version;
for (let i = 0; i < 50 && !version; i++) { await sleep(200); try { version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); } catch {} }
const ws = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0; const pending = new Map();
ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); } };
const send = (method, params = {}, sessionId) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params, ...(sessionId ? { sessionId } : {}) })); });

let failures = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? `  [${String(detail).slice(0, 160)}]` : ''}`); if (!ok) failures++; };
const finish = () => { console.log(`FAILS=${failures}`); ws.close(); chrome.kill(); process.exit(failures ? 1 : 0); };
process.on('uncaughtException', (e) => { console.log(`FAIL script error: ${e.message}`); failures++; finish(); });

async function browser(theme) {
  const { result: { browserContextId } } = await send('Target.createBrowserContext');
  const { result: { targetId } } = await send('Target.createTarget', { url: 'about:blank', browserContextId });
  const { result: { sessionId: s } } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Page.enable', {}, s); await send('Runtime.enable', {}, s); await send('Network.enable', {}, s);
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 1100, deviceScaleFactor: 1, mobile: false }, s);
  if (theme) await send('Page.addScriptToEvaluateOnNewDocument', { source: `try { localStorage.setItem('runout:theme', ${JSON.stringify(theme)}); } catch (e) {}` }, s);
  await send('WebAuthn.enable', {}, s);
  const authenticatorId = (await send('WebAuthn.addVirtualAuthenticator', { options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } }, s)).result.authenticatorId;
  const b = {
    eval: async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }, s)).result.result?.value,
    text: async () => b.eval('document.body.innerText'),
    url: async () => b.eval('location.pathname + location.search'),
    waitFor: async (expr, ms = 25000) => { const end = Date.now() + ms; let v; while (Date.now() < end) { v = await b.eval(expr); if (v) return v; await sleep(300); } return v; },
    waitText: (needle, ms) => b.waitFor(`document.body.innerText.includes(${JSON.stringify(needle)})`, ms),
    waitAny: (needles, ms) => b.waitFor(`(() => { const t = document.body.innerText; return ${JSON.stringify(needles)}.find((n) => t.includes(n)) || false; })()`, ms),
    go: async (path, needle) => { await send('Page.navigate', { url: path.startsWith('http') ? path : `${ORIGIN}${path}` }, s); await sleep(500); if (needle) return b.waitText(needle); },
    click: async (label, nth = 0) => {
      const ok = await b.eval(`(() => { const els = [...document.querySelectorAll('button, a')].filter((e) => e.textContent.trim() === ${JSON.stringify(label)}); const el = els[${nth}]; if (!el) return false; el.click(); return true; })()`);
      await sleep(300); return ok;
    },
    clickSel: async (selector) => { const ok = await b.eval(`(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return false; el.click(); return true; })()`); await sleep(300); return ok; },
    typeByLabel: async (labelText, text) => { const ok = await b.eval(`(() => { const l = [...document.querySelectorAll('label')].find((x) => x.textContent.includes(${JSON.stringify(labelText)})); const i = l && (document.getElementById(l.htmlFor) || l.querySelector('input')); if (!i) return false; i.focus(); return true; })()`); if (ok) await send('Input.insertText', { text }, s); await sleep(200); return ok; },
    type: async (selector, text) => { const ok = await b.eval(`(() => { const i = document.querySelector(${JSON.stringify(selector)}); if (!i) return false; i.focus(); return true; })()`); if (ok) await send('Input.insertText', { text }, s); await sleep(200); return ok; },
    shot: async (file) => { const r = await send('Page.captureScreenshot', { format: 'png' }, s); writeFileSync(`${D}/shots/${file}`, Buffer.from(r.result.data, 'base64')); },
    api: async (path) => JSON.parse(await b.eval(`fetch('/api${path}', { credentials: 'include', headers: { Accept: 'application/json' } }).then((r) => r.text())`) || 'null'),
    credentials: async () => (await send('WebAuthn.getCredentials', { authenticatorId }, s)).result.credentials,
    codesOnScreen: async () => b.eval(`[...document.querySelectorAll('[aria-label="Your recovery codes"] li')].map((li) => li.textContent.trim())`),
    signOutViaMenu: async () => {
      await b.waitFor(`!!document.querySelector('button[aria-label^="Account,"]')`, 8000);
      if (!(await b.clickSel('button[aria-label^="Account,"]'))) return false;
      const item = await b.waitFor(`(() => { const el = [...document.querySelectorAll('[role="menu"] [role="menuitem"]')].find((e) => e.textContent.includes('Sign out')); if (!el) return false; el.click(); return true; })()`, 8000);
      if (!item) return false;
      return !!(await b.waitAny(['Sign in with a passkey', 'Sign in to see your listening']));
    },
    useCode: async (code) => {
      await b.go('/overview?period=all', 'Use a recovery code instead');
      await b.click('Use a recovery code instead');
      await b.type('input[aria-label="Recovery code"]', code);
      await b.click('Use code');
      return b.waitAny(['You signed in with a recovery code', 'isn’t valid', 'Too many attempts']);
    },
  };
  return b;
}

const counts = () => JSON.parse(rails(`runner 'puts({ users: User.pluck(:display_name).sort, scrobbles: Scrobble.count, loved: LovedTrack.count, sessions: Session.count, passkeys: WebauthnCredential.count, sources: ListeningSource.count, links: SignInLink.count }.to_json)'`));
rails(`runner 'User.where(display_name: "Dana").destroy_all'`); // a leftover from an interrupted run
const before = counts();
console.log(`BEFORE ${JSON.stringify(before)}`);

// 1. Invitation (the operator's task) opened in a fresh browser.
const invite = rails(`"auth:invite_link[Dana,America/Los_Angeles]"`);
const link = invite.match(/http:\/\/localhost:5199\/api\/auth\/link\/[A-Za-z0-9_-]{43}/)?.[0];
check('invitation link printed by the task', !!link, invite.split('\n')[0]);
const B = await browser();
await B.go(link);
check('the link lands on /welcome, signed in', await B.waitText('Welcome to Runout, Dana.') && (await B.url()).startsWith('/welcome'), await B.url());
let session = await B.api('/session');
check('no passkey, no codes, no Last.fm yet', session.methods.passkeys === 0 && session.methods.recoveryCodes === 0 && session.methods.lastfm === false, JSON.stringify(session.methods));
await B.shot('01-welcome.png');
await B.go('/overview?period=all');
check('every page returns to /welcome until a passkey exists', await B.waitFor('location.pathname === "/welcome"', 8000), await B.url());

// 2. Passkey, then the recovery codes shown once.
await B.waitText('A name for this passkey');
check('passkey name field', await B.type('section[aria-labelledby="ob-passkey"] input', 'Rehearsal phone'));
await B.click('Add a passkey');
check('the first passkey brings 10 codes', (await B.waitFor(`document.querySelectorAll('[aria-label="Your recovery codes"] li').length`)) === 10);
const codes = await B.codesOnScreen();
check('the virtual authenticator holds the credential', (await B.credentials()).length === 1);
await B.shot('02-codes.png');
await B.click('I’ve saved them');
check('the source step offers Spotify and a skip', await B.waitText('Connect Spotify') && await B.waitText('Skip for now'));
check('the Recently Played gap is stated', (await B.text()).includes('sometimes misses one'));
await B.shot('03-source.png');
await B.click('Skip for now');
check('the Overview opens, empty', await B.waitAny(['No listening history is stored yet', 'Sign in to see']) === 'No listening history is stored yet' && await B.waitFor('location.pathname === "/overview"', 8000), await B.url());
check('the sidebar shows Dana without Last.fm', (await B.text()).includes('Dana') && (await B.text()).includes('Last.fm not connected'));
await B.shot('04-empty-overview.png');
session = await B.api('/session');
check('session: 1 passkey, 10 codes', session.methods.passkeys === 1 && session.methods.recoveryCodes === 10, JSON.stringify(session.methods));
const stored = await B.api('/import');
check('History: nothing stored, Last.fm panels hidden', stored.stored.plays === 0);

// 3. Returning: sign out from the account menu, sign in with the passkey.
const signedOut = await B.signOutViaMenu();
await B.shot('05-signed-out.png');
check('sign out from the account menu', signedOut, `${await B.url()} | session=${JSON.stringify((await B.api('/session')).signedIn)} | ${(await B.text()).slice(0, 140).replace(/\n/g, ' ')}`);
await B.click('Sign in with a passkey');
check('the passkey signs Dana back in', await B.waitAny(['Welcome to Runout', 'No listening history is stored yet']) === 'No listening history is stored yet', (await B.text()).slice(0, 120).replace(/\n/g, ' '));
await sleep(1500);
check('…and lands on the Overview, not /welcome', (await B.url()).startsWith('/overview'), await B.url());
await B.go('/settings#account', 'Signed-in browsers');
check('Settings shows the passkey with a last-used time and 10 of 10 codes', await B.waitText('Rehearsal phone') && (await B.text()).includes('10 of 10'));
await B.shot('06-settings-account.png');

// 4. Returning with a recovery code.
await B.signOutViaMenu();
check('a recovery code signs in once', (await B.useCode(codes[0])) === 'You signed in with a recovery code');
check('9 of 10 remain', await B.waitText('9 of 10'));
await B.signOutViaMenu();
check('the used code is refused', (await B.useCode(codes[0])) === 'isn’t valid');
check('another code signs in', (await B.useCode(codes[1])) === 'You signed in with a recovery code');

// 5. Deletion, by name.
await B.go('/settings#account', 'Delete account');
check('deletion asks for the name', await B.typeByLabel('Type your name', 'Dana'));
await B.click('Delete account');
check('the account and its data are deleted', await B.waitText('Your Runout account and its data were deleted.'));
await B.shot('07-deleted.png');
const after = counts();
console.log(`AFTER ${JSON.stringify(after)}`);
check('the owner’s copy is exactly as before (plays, loved, passkeys, sources)', after.scrobbles === before.scrobbles && after.loved === before.loved && after.passkeys === before.passkeys && after.sources === before.sources && after.users.join() === before.users.join(), `${JSON.stringify(before)} → ${JSON.stringify(after)}`);
check('no trace of Dana', !after.users.includes('Dana'));

// 6. The welcome page in Cotton Candy, for the owner's eye.
const link2 = rails(`"auth:invite_link[Dana,America/Los_Angeles]"`).match(/http:\/\/localhost:5199\/api\/auth\/link\/[A-Za-z0-9_-]{43}/)?.[0];
const C = await browser('cotton-candy');
await C.go(link2);
await C.waitText('Welcome to Runout, Dana.');
await C.shot('08-welcome-cotton-candy.png');
rails(`runner 'User.find_by(display_name: "Dana")&.destroy!'`);
const final = counts();
check('the unfinished second invitation is removed; the copy is as before', final.users.join() === before.users.join() && final.scrobbles === before.scrobbles, JSON.stringify(final));
finish();
