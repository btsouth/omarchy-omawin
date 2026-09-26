import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fixtures, helper } from './helpers.mjs'

// Custom-compose mode (helpers/custom.sh): a throwaway HOME holding the
// config, the user's own compose, a sparse data.img in the directory that
// compose mounts on /storage, and a shared folder. Nothing here needs docker:
// the helpers only read and rewrite files, and the two that would run docker
// (vm.sh, connect.sh) are not exercised.
const GIB = 1024 ** 3

const COMPOSE = `services:
  windows:
    image: dockurr/windows
    container_name: "my-win"
    environment:
      VERSION: "11"
      RAM_SIZE: "6G"
      CPU_CORES: "4"
      DISK_SIZE: "64G"
      USERNAME: "bts"
      PASSWORD: "pa$$s\\"s" # quoted, with compose's $$ and an escaped quote
      TZ: America/Louisville
    volumes:
      - ./storage:/storage
      - "~/Shared Stuff:/shared:rw"
    stop_grace_period: 2m
`

function box(t, { compose = COMPOSE, config = 'COMPOSE_FILE=~/vm/compose.yaml\n', disk = 64 } = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-custom-'))
  t.after(() => fs.rmSync(home, { recursive: true, force: true }))
  fs.mkdirSync(path.join(home, 'vm/storage'), { recursive: true })
  fs.mkdirSync(path.join(home, 'Shared Stuff'))
  fs.mkdirSync(path.join(home, '.config/omawin'), { recursive: true })
  if (compose !== null) fs.writeFileSync(path.join(home, 'vm/compose.yaml'), compose, { mode: 0o640 })
  if (config !== null) fs.writeFileSync(path.join(home, '.config/omawin/config'), config)
  const image = path.join(home, 'vm/storage/data.img')
  if (disk > 0) {
    fs.writeFileSync(image, '')
    fs.truncateSync(image, disk * GIB)
  }
  // Only HOME and XDG_CONFIG_HOME point the helpers here; the Omarchy-mode
  // paths they would otherwise read are pointed at nothing.
  const env = {
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, '.config'),
    OMAWIN_CONFIG: path.join(home, '.config/omawin/config'),
    CREDENTIALS_FILE: path.join(home, 'no-credentials'),
    HOST_CORES: '8', HOST_RAM_GB: '32', FREE_GB: '412', TZ_NAME: 'UTC'
  }
  return { home, env, compose: path.join(home, 'vm/compose.yaml') }
}

function info(env) {
  const result = helper('custom.sh', ['info'], env)
  assert.equal(result.status, 0, result.err)
  return Object.fromEntries(result.out.split('\n').map(line => {
    const eq = line.indexOf('=')
    return [line.slice(0, eq), line.slice(eq + 1)]
  }))
}

test('info: no config is Omarchy mode, with its default paths', t => {
  const { home, env } = box(t, { config: null })
  assert.deepEqual(info(env), {
    mode: 'omarchy', config: path.join(home, '.config/omawin/config'), compose: '',
    container: 'omarchy-windows', storage: path.join(home, '.windows'),
    shared: path.join(home, 'Windows'), exists: '0', cores: '', ram: '', disk: ''
  })
})

test('info: the compose names the container, storage and shared folder', t => {
  const { home, env, compose } = box(t)
  assert.deepEqual(info(env), {
    mode: 'custom', config: path.join(home, '.config/omawin/config'), compose,
    container: 'my-win',
    // ./storage is relative to the compose, the way compose resolves it.
    storage: path.join(home, 'vm/storage'),
    shared: path.join(home, 'Shared Stuff'), exists: '1',
    // The shape the next start will use, off the environment block.
    cores: '4', ram: '6G', disk: '64G'
  })
})

test('info: a config naming a missing compose is still custom mode', t => {
  const { home, env } = box(t, { compose: null })
  const fields = info(env)
  assert.equal(fields.mode, 'custom')
  assert.equal(fields.compose, path.join(home, 'vm/compose.yaml'))
  assert.equal(fields.exists, '0')
})

test('vm-state: installed, disk and login come from the custom compose', t => {
  const { env } = box(t)
  const dir = path.join(fixtures, 'stopped')
  const result = helper('vm-state.sh', [], {
    ...env, PROC_ROOT: path.join(dir, 'proc'), SYS_ROOT: path.join(dir, 'sys'),
    DOCKER_STATE: 'active', WEB_CODE: '000'
  })
  assert.equal(result.out,
    'installed=1 docker=active pid= frozen= cores= ram= web=000 cid= started= disk=64G login=bts')
})

test('vm-state: a missing custom compose is not installed, whatever Omarchy has', t => {
  const { env } = box(t, { compose: null })
  const dir = path.join(fixtures, 'stopped')
  const result = helper('vm-state.sh', [], {
    ...env, PROC_ROOT: path.join(dir, 'proc'), SYS_ROOT: path.join(dir, 'sys'),
    COMPOSE_FILE: path.join(dir, 'docker-compose.yml'),
    CREDENTIALS_FILE: path.join(dir, 'credentials'),
    DOCKER_STATE: 'active', WEB_CODE: '000'
  })
  assert.match(result.out, /^installed=0 /)
})

test('credentials: username and password are the compose\'s, unescaped', t => {
  const { env } = box(t)
  assert.equal(helper('credentials.sh', ['username'], env).out, 'bts')
  assert.equal(helper('credentials.sh', ['password'], env).out, 'pa$s"s')
})

test('credentials: list-form environment and single quotes read too', t => {
  const { env } = box(t, {
    compose: "services:\n  w:\n    environment:\n      - USERNAME=alice\n      - 'PASSWORD=it''s here'\n"
  })
  assert.equal(helper('credentials.sh', ['username'], env).out, 'alice')
  assert.equal(helper('credentials.sh', ['password'], env).out, "it's here")
})

test('credentials write: rewrites PASSWORD only, needs no shape, keeps a backup', t => {
  const { env, compose } = box(t)
  const secret = 'new $pw "quoted" \\ back=slash'
  const result = helper('credentials.sh', ['write'], env, secret + '\n')
  assert.equal(result.status, 0, result.err)
  assert.equal(result.out, 'ok')
  assert.equal(helper('credentials.sh', ['password'], env).out, secret)
  const before = COMPOSE.split('\n')
  const after = fs.readFileSync(compose, 'utf8').split('\n')
  const changed = after.filter((line, i) => line !== before[i])
  assert.deepEqual(changed, ['      PASSWORD: "new $$pw \\"quoted\\" \\\\ back=slash"'])
  assert.equal(fs.readFileSync(compose + '.omawin.bak', 'utf8'), COMPOSE)
  assert.equal(fs.statSync(compose).mode & 0o777, 0o640)
  // The Omarchy credentials file is not this mode's business.
  assert.equal(fs.existsSync(env.CREDENTIALS_FILE), false)
})

test('credentials write: the password rule still applies', t => {
  const { env, compose } = box(t)
  const result = helper('credentials.sh', ['write'], env, '\n')
  assert.equal(result.status, 2)
  assert.match(result.err, /1 to 64 printable/)
  assert.equal(fs.readFileSync(compose, 'utf8'), COMPOSE)
})

test('tune limits: disk, free space and login where the compose keeps them', t => {
  const { env } = box(t)
  assert.equal(helper('tune.sh', ['limits'], env).out, 'cores=8 ram=32 free=412 disk=64G login=bts')
})

test('tune apply: writes RAM_SIZE, CPU_CORES and DISK_SIZE, nothing else', t => {
  const { env, compose } = box(t)
  const dry = helper('tune.sh', ['apply', '--cores', '6', '--ram', '8G', '--disk', '96G'],
    { ...env, TUNE_DRY_RUN: '1' })
  assert.equal(dry.out, 'RAM_SIZE=8G\nCPU_CORES=6\nDISK_SIZE=96G\nok')
  assert.equal(fs.readFileSync(compose, 'utf8'), COMPOSE)

  const result = helper('tune.sh', ['apply', '--cores', '6', '--ram', '8G', '--disk', '96G'], env)
  assert.equal(result.status, 0, result.err)
  assert.equal(fs.readFileSync(compose, 'utf8'), COMPOSE
    .replace('RAM_SIZE: "6G"', 'RAM_SIZE: "8G"')
    .replace('CPU_CORES: "4"', 'CPU_CORES: "6"')
    .replace('DISK_SIZE: "64G"', 'DISK_SIZE: "96G"'))
})

test('tune apply: the guards hold in custom mode too', t => {
  const { env, compose } = box(t)
  const shrink = helper('tune.sh', ['apply', '--cores', '4', '--ram', '6G', '--disk', '32G'], env)
  assert.equal(shrink.status, 2)
  assert.match(shrink.err, /cannot shrink/)
  const greedy = helper('tune.sh', ['apply', '--cores', '9', '--ram', '6G', '--disk', '64G'], env)
  assert.equal(greedy.status, 2)
  assert.equal(fs.readFileSync(compose, 'utf8'), COMPOSE)
})

test('tune apply: only the growth needs free space in custom mode', t => {
  const { env } = box(t)
  const tight = { ...env, FREE_GB: '20', TUNE_DRY_RUN: '1' }
  // Same disk, different RAM: no room needed at all (the wizard would want 74).
  assert.equal(helper('tune.sh', ['apply', '--cores', '4', '--ram', '8G', '--disk', '64G'], tight).status, 0)
  // 64 → 72 needs 8 + 10 = 18.
  assert.equal(helper('tune.sh', ['apply', '--cores', '4', '--ram', '8G', '--disk', '72G'], tight).status, 0)
  const big = helper('tune.sh', ['apply', '--cores', '4', '--ram', '8G', '--disk', '96G'], tight)
  assert.equal(big.status, 2)
  assert.match(big.err, /96G needs 42 GB free/)
})

test('set: only the four keys omawin owns, and only ones already there', t => {
  const { env, compose } = box(t)
  const other = helper('custom.sh', ['set'], env, 'VERSION=10\n')
  assert.equal(other.status, 2)
  assert.match(other.err, /not a key omawin writes: VERSION/)

  const { env: env2, compose: compose2 } = box(t, {
    compose: 'services:\n  w:\n    environment:\n      USERNAME: "a"\n'
  })
  const missing = helper('custom.sh', ['set'], env2, 'RAM_SIZE=8G\n')
  assert.equal(missing.status, 1)
  assert.match(missing.err, /RAM_SIZE is not set in the environment block/)
  assert.equal(fs.existsSync(compose2 + '.omawin.bak'), false)
  assert.equal(fs.readFileSync(compose, 'utf8'), COMPOSE)
})

test('set: refuses outside custom mode', t => {
  const { env } = box(t, { config: null })
  const result = helper('custom.sh', ['set'], env, 'RAM_SIZE=8G\n')
  assert.equal(result.status, 2)
  assert.match(result.err, /not in custom-compose mode/)
})

test('set: a key under another block is left alone', t => {
  const compose = 'services:\n  w:\n    labels:\n      RAM_SIZE: "label"\n    environment:\n      RAM_SIZE: "4G"\n'
  const { env, compose: file } = box(t, { compose })
  assert.equal(helper('custom.sh', ['set'], env, 'RAM_SIZE=8G\n').status, 0)
  assert.equal(fs.readFileSync(file, 'utf8'), compose.replace('"4G"', '"8G"'))
})
