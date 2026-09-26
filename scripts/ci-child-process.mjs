// Register before any await after spawn. "exit" means no longer running;
// "close" means stdio has also closed. A child_process error alone means neither.
export function watchChild(child) {
  const state = {
    child, exited: false, closed: false, spawnFailed: false,
    settled: false, code: null, signal: null, error: null,
  }
  let reportExit, reportClose, reportError
  state.exitWait = new Promise(resolve => { reportExit = resolve })
  state.wait = new Promise(resolve => { reportClose = resolve })
  state.failure = new Promise(resolve => { reportError = resolve })
  child.once('exit', (code, signal) => {
    state.exited = true
    state.code = code
    state.signal = signal
    reportExit(state)
  })
  child.once('close', (code, signal) => {
    state.exited = true
    state.closed = true
    state.settled = true
    state.code = code
    state.signal = signal
    reportExit(state)
    reportClose(state)
  })
  child.on('error', error => {
    state.error = error
    reportError(error)
    if (!child.pid) {
      state.spawnFailed = true
      state.settled = true
      reportExit(state)
      reportClose(state)
    }
  })
  return state
}

async function waitUpTo(promise, milliseconds) {
  let timer
  try {
    return await Promise.race([
      promise.then(() => true),
      new Promise(resolve => { timer = setTimeout(() => resolve(false), milliseconds) }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

export async function stopChild(state, graceMilliseconds = 10_000) {
  if (state.spawnFailed || state.closed) return state
  if (!state.exited) {
    const termSent = state.child.kill('SIGTERM')
    if (!termSent && !state.exited) throw state.error || new Error('SIGTERM was not sent')
    await waitUpTo(state.exitWait, graceMilliseconds)
    if (!state.exited && !state.closed) {
      const forceSent = state.child.kill('SIGKILL')
      if (!forceSent && !state.exited) throw state.error || new Error('SIGKILL was not sent')
      await waitUpTo(state.exitWait, 10_000)
    }
  }
  if (!state.exited && !state.closed) throw state.error || new Error('Child process did not exit after SIGKILL')
  if (!state.closed && !(await waitUpTo(state.wait, 10_000))) {
    throw new Error('Child process exited but stdio did not close')
  }
  return state
}
