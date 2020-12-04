module.exports =
class BufferPool {
  constructor ({db}) {
    this.db = db
    this.retainCountsByBuffer = new Map()
    this.retainedBuffersById = new Map()
    this.retainedBuffersByPath = new Map()
  }

  getUnretainedUnsavedBuffers () {
    return new Promise((resolve, reject) => {
      const buffers = []

      this.db.createValueStream()
        .on('data', (value) => {
          const {id, path} = JSON.parse(value)
          if (id && !path && !this.retainedBuffersById.has(id)) {
            buffers.push(this.getBufferForId(id))
          }
        })
        .on('error', (error) => reject(error))
        .on('end', () => resolve(buffers))
    })
  }

  getBufferForId (id) {
    return this.retainedBuffersById.get(id) || new Buffer({db: this.db, id})
  }

  getBufferForPath (path) {
    return this.retainedBuffersByPath.get(path) || new Buffer({db: this.db, path})
  }

  async retain (buffer) {
    const retainCount = this.retainCountsByBuffer.get(buffer) || 0
    const newRetainCount = retainCount + 1

    if (newRetainCount === 1) {
      if (buffer.id) this.retainedBuffersById.set(buffer.id, buffer)
      if (buffer.path) this.retainedBuffersByPath.set(buffer.path, buffer)

      await buffer.store()
    } else if (buffer.id && !buffer.path) {
      throw new Error('Cannot retain an unsaved buffer more than once')
    }

    this.retainCountsByBuffer.set(buffer, newRetainCount)
  }

  async release (buffer) {
    const retainCount = this.retainCountsByBuffer.get(buffer) || 0
    const newRetainCount = retainCount - 1

    if (newRetainCount > 0) {
      this.retainCountsByBuffer.set(buffer, newRetainCount)
    } else {
      this.retainCountsByBuffer.delete(buffer)
      if (buffer.id) this.retainedBuffersById.delete(buffer.id)
      if (buffer.path) this.retainedBuffersByPath.delete(buffer.path)

      await buffer.delete()
    }
  }
}

class Buffer {
  constructor ({db, id, path}) {
    this.db = db
    this.id = id
    this.path = path
  }

  async store () {
    await this.update({})
  }

  async delete () {
    await this.db.del(this.getDatabaseKey())
  }

  async hasBaseTextDigest (digest) {
    const state = await this.getSavedState()
    return state.baseTextDigest === digest
  }

  async update (props) {
    const oldState = await this.getSavedState()
    const newState = Object.assign(oldState || {}, props, {id: this.id, path: this.path})
    await this.db.put(this.getDatabaseKey(), JSON.stringify(newState))
  }

  async getSavedState () {
    try {
      const state = await this.db.get(this.getDatabaseKey())
      return JSON.parse(state)
    } catch (e) {
      if (e.notFound) {
        return null
      } else {
        throw e
      }
    }
  }

  getDatabaseKey () {
    let key = 'buffer.'
    if (this.id) {
      key += 'id=' + this.id
    } else if (this.path) {
      key += 'path=' + this.path
    } else {
      throw new Error('Buffer does not have path or ID')
    }

    return key
  }
}
