import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { spawn } from 'node:child_process'
import test from 'node:test'
import { watchChild, stopChild } from './ci-child-process.mjs'

test('normal close is already settled before cleanup', async () => {
  const state = watchChild(spawn(process.execPath, ['-e', 'process.exit(0)']))
  await state.wait
  assert.equal(state.code, 0)
  assert.equal(state.signal, null)
  await stopChild(state)
})

test('signal close is settled even while exitCode is null', async () => {
  const state = watchChild(spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)']))
  try {
    await stopChild(state, 1000)
    assert.equal(state.settled, true)
    assert.notEqual(state.signal, null)
  } finally {
    if (!state.settled) {
      state.child.kill('SIGKILL')
      await state.wait
    }
  }
})

test('ignored SIGTERM escalates and waits for close', async () => {
  const child = new EventEmitter()
  child.pid = 123
  const signals = []
  child.kill = signal => {
    signals.push(signal)
    if (signal === 'SIGKILL') setTimeout(() => child.emit('close', null, 'SIGKILL'), 1)
    return true
  }
  const state = watchChild(child)
  await stopChild(state, 1)
  assert.deepEqual(signals, ['SIGTERM', 'SIGKILL'])
  assert.equal(state.signal, 'SIGKILL')
})

test('spawn error settles without an unhandled error event', async () => {
  const child = new EventEmitter()
  child.kill = () => true
  const state = watchChild(child)
  const failure = new Error('spawn failed')
  child.emit('error', failure)
  await state.wait
  assert.equal(state.error, failure)
  await stopChild(state)
})

test('kill error does not claim a live child has exited', async () => {
  const child = new EventEmitter()
  child.pid = 456
  const failure = new Error('kill denied')
  child.kill = () => { child.emit('error', failure); return false }
  const state = watchChild(child)
  await assert.rejects(stopChild(state, 1), /kill denied/)
  assert.equal(state.exited, false)
  assert.equal(state.closed, false)
  assert.equal(state.settled, false)
  child.emit('exit', null, 'SIGTERM')
  child.emit('close', null, 'SIGTERM')
  await state.wait
})

test('exit before close waits for close without another kill', async () => {
  const child = new EventEmitter()
  child.pid = 789
  const signals = []
  child.kill = signal => { signals.push(signal); return true }
  const state = watchChild(child)
  child.emit('exit', null, 'SIGTERM')
  setTimeout(() => child.emit('close', null, 'SIGTERM'), 1)
  await stopChild(state, 1)
  assert.deepEqual(signals, [])
  assert.equal(state.closed, true)
})
