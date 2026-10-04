import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { helper } from './helpers.mjs'

// A fake /proc and /sys with one QEMU in a docker scope, and a sparse data.img
// with a known amount written to it.
function box(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omawin-usage-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const scope = '/system.slice/docker-' + 'ab'.repeat(32) + '.scope'
  fs.mkdirSync(path.join(dir, 'proc/4242'), { recursive: true })
  fs.writeFileSync(path.join(dir, 'proc/4242/cgroup'), '0::' + scope + '\n')
  const cgroup = path.join(dir, 'sys/fs/cgroup' + scope)
  fs.mkdirSync(cgroup, { recursive: true })
  fs.writeFileSync(path.join(cgroup, 'cpu.stat'),
    'usage_usec 8123456789\nuser_usec 7000000000\nsystem_usec 1123456789\n')
  // 64 GiB apparent, 1 MiB actually written.
  const image = path.join(dir, 'data.img')
  fs.writeFileSync(image, '')
  fs.truncateSync(image, 64 * 1024 ** 3)
  const fd = fs.openSync(image, 'r+')
  fs.writeSync(fd, Buffer.alloc(1024 * 1024, 1), 0, 1024 * 1024, 0)
  fs.closeSync(fd)
  return {
    dir, cgroup,
    env: { PROC_ROOT: path.join(dir, 'proc'), SYS_ROOT: path.join(dir, 'sys'), DATA_IMAGE: image }
  }
}

test('usage reads CPU time and the disk really used', t => {
  const { env } = box(t)
  const result = helper('usage.sh', ['4242'], env)
  assert.equal(result.status, 0, result.err)
  const fields = Object.fromEntries(result.out.split(' ').map(pair => pair.split('=')))
  assert.equal(fields.cpu, '8123456789')
  // At least the MiB written; far less than the 64 GiB it claims to be.
  assert.ok(Number(fields.used) >= 1024 * 1024, fields.used)
  assert.ok(Number(fields.used) < 64 * 1024 * 1024, fields.used)
})

test('without a pid, or with one that is not a container, only the disk is read', t => {
  const { dir, env } = box(t)
  assert.match(helper('usage.sh', [], env).out, /^cpu= used=[0-9]+$/)
  fs.writeFileSync(path.join(dir, 'proc/4242/cgroup'), '0::/user.slice/user-1000.slice\n')
  assert.match(helper('usage.sh', ['4242'], env).out, /^cpu= used=[0-9]+$/)
  // A pid that has gone away, and no image: every key still printed, empty.
  assert.equal(helper('usage.sh', ['9999'], { ...env, DATA_IMAGE: path.join(dir, 'nope') }).out,
    'cpu= used=')
})

test('readings that are not numbers are dropped, and a bad pid is refused', t => {
  const { cgroup, env } = box(t)
  fs.writeFileSync(path.join(cgroup, 'cpu.stat'), 'usage_usec -1\n')
  assert.match(helper('usage.sh', ['4242'], env).out, /^cpu= used=[0-9]+$/)
  const bad = helper('usage.sh', ['../1'], env)
  assert.equal(bad.status, 2)
  assert.match(bad.err, /usage: usage\.sh \[PID\]/)
})
