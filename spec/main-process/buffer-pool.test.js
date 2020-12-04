const leveldown = require('leveldown')
const levelup = require('levelup')
const temp = require('temp').track()

const BufferPool = require('../../src/main-process/buffer-pool')

describe('BufferPool', () => {
  let db

  beforeEach(() => {
    db = levelup(leveldown(temp.path()))
  })

  afterEach(async () => {
    await db.close()
  })

  it('persists retained buffers on-disk using the supplied database', async () => {
    {
      const bufferPool = new BufferPool({db})

      const buffer1 = await bufferPool.getBufferForId('1')
      await bufferPool.retain(buffer1)
      // Unsaved buffers can be retained only once.
      await assertAsyncThrow(() => bufferPool.retain(unsavedBuffer1))

      const buffer2 = await bufferPool.getBufferForPath('path-1')
      await bufferPool.retain(buffer2)
      await bufferPool.retain(buffer2)
      await bufferPool.retain(buffer2)

      const buffer3 = await bufferPool.getBufferForPath('path-2')
      await bufferPool.retain(buffer3)
      await bufferPool.retain(buffer3)
      await bufferPool.release(buffer3)
      await bufferPool.release(buffer3)
    }

    {
      const bufferPool = new BufferPool({db})

      const buffer1 = await bufferPool.getBufferForId('1')
      assert.deepEqual(await buffer1.getSavedState(), {id: '1'})

      const buffer2 = await bufferPool.getBufferForPath('path-1')
      assert.deepEqual(await buffer2.getSavedState(), {path: 'path-1'})

      // Unretained buffers are not persisted.
      const buffer3 = await bufferPool.getBufferForPath('path-2')
      assert.deepEqual(await buffer3.getSavedState(), null)

      // Retain counts are persisted on a per BufferPool basis, so buffer2 gets
      // deleted after a single release even if it was retained more than once.
      await bufferPool.release(buffer2)
    }

    {
      const bufferPool = new BufferPool({db})

      const buffer1 = await bufferPool.getBufferForId('1')
      assert.deepEqual(await buffer1.getSavedState(), {id: '1'})

      const buffer2 = await bufferPool.getBufferForPath('path-1')
      assert.deepEqual(await buffer2.getSavedState(), null)
    }
  })

  it('allows retrieving unsaved buffers that have not been retained on new instances', async () => {
    {
      const bufferPool = new BufferPool({db})

      const buffer1 = await bufferPool.getBufferForId('1')
      await bufferPool.retain(buffer1)

      const buffer2 = await bufferPool.getBufferForId('2')
      await bufferPool.retain(buffer2)

      const buffer3 = await bufferPool.getBufferForId('3')
      await bufferPool.retain(buffer3)

      const buffer4 = await bufferPool.getBufferForPath('path')
      await bufferPool.retain(buffer4)
    }

    {
      const bufferPool = new BufferPool({db})

      const unretainedUnsavedBuffers = await bufferPool.getUnretainedUnsavedBuffers()
      assert.equal(unretainedUnsavedBuffers.length, 3)
      assert.equal(unretainedUnsavedBuffers[0].id, '1')
      assert.equal(unretainedUnsavedBuffers[1].id, '2')
      assert.equal(unretainedUnsavedBuffers[2].id, '3')

      await bufferPool.retain(unretainedUnsavedBuffers[1])
      assert.equal((await bufferPool.getUnretainedUnsavedBuffers()).length, 2)

      await bufferPool.retain(unretainedUnsavedBuffers[0])
      assert.equal((await bufferPool.getUnretainedUnsavedBuffers()).length, 1)

      await bufferPool.retain(unretainedUnsavedBuffers[2])
      assert.equal((await bufferPool.getUnretainedUnsavedBuffers()).length, 0)
    }
  })
})

async function assertAsyncThrow(fn) {
  let error
  try {
    await fn()
  } catch (e) {
    error = e
  }

  assert(error, 'Function ' + fn.toString() + ' should have thrown')
}
