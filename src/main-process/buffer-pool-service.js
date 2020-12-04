module.exports =
class BufferPoolService {
  constructor ({ipc, bufferPool}) {
    this.ipc = ipc
    this.bufferPool = bufferPool
  }

  listen () {
    this.ipc.on('buffer-pool:retain', this.handleRetainBuffer.bind(this))
    this.ipc.on('buffer-pool:release', this.handleReleaseBuffer.bind(this))
    this.ipc.on('buffer-pool:retrieve', this.handleRetrieveBufferState.bind(this))
    this.ipc.on('buffer-pool:retrieve-all-unsaved', this.handleRetrieveBufferState.bind(this))
    this.ipc.on('buffer-pool:update', this.handleUpdateBufferState.bind(this))
  }

  async handleRetainBuffer (event, {requestId, id, path}) {
    let buffer
    if (path) {
      buffer = this.bufferPool.getBufferForPath(path)
    } else if (id) {
      buffer = this.bufferPool.getBufferForId(id)
    }

    await this.bufferPool.retain(buffer)
    event.sender.send('buffer-pool:response', {requestId})
  }

  handleReleaseBuffer (event, {requestId, id, path}) {
    let buffer
    if (path) {
      buffer = this.bufferPool.getBufferForPath(path)
    } else if (id) {
      buffer = this.bufferPool.getBufferForId(id)
    }

    await this.bufferPool.release(buffer)
    event.sender.send('buffer-pool:response', {requestId})
  }

  handleRetrieveBufferState (event, {id, path}) {
    let buffer
    if (path) {
      buffer = this.bufferPool.getBufferForPath(path)
    } else if (id) {
      buffer = this.bufferPool.getBufferForId(id)
    }

    const state = await buffer.getSavedState()
    event.sender.send('buffer-pool:response', {requestId, state})
  }

  handleUpdateBufferState (event, {id, path, state}) {
    let buffer
    if (path) {
      buffer = this.bufferPool.getBufferForPath(path)
    } else if (id) {
      buffer = this.bufferPool.getBufferForId(id)
    }

    if (!state.baseText && !await buffer.hasBaseTextDigest(state.baseTextDigest)) {
      event.sender.send('buffer-pool:response', {requestId, needsBaseTextUpdate: true})
    } else {
      await buffer.update(state)
      event.sender.send('buffer-pool:response', {requestId})
    }
  }
}
