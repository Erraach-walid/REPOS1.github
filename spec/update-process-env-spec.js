/** @babel */
/* eslint-env jasmine */

import path from 'path'
import temp from 'temp'
import child_process from 'child_process'
import {updateProcessEnv, shouldGetEnvFromShell} from '../src/update-process-env'
import dedent from 'dedent'

describe('updateProcessEnv(launchEnv)', function () {
  let originalProcessEnv, originalProcessPlatform

  beforeEach(function () {
    originalProcessEnv = process.env
    originalProcessPlatform = process.platform
    process.env = {}
  })

  afterEach(function () {
    process.env = originalProcessEnv
    process.platform = originalProcessPlatform
  })

  describe('when the launch environment appears to come from a shell', function () {
    it('updates process.env to match the launch environment', function () {
      process.env = {
        WILL_BE_DELETED: 'hi',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: '/the/atom/home'
      }

      const initialProcessEnv = process.env

      updateProcessEnv({ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true', PWD: '/the/dir', TERM: 'xterm-something', KEY1: 'value1', KEY2: 'value2'})
      expect(process.env).toEqual({
        ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true',
        PWD: '/the/dir',
        TERM: 'xterm-something',
        KEY1: 'value1',
        KEY2: 'value2',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: '/the/atom/home'
      })

      // See #11302. On Windows, `process.env` is a magic object that offers
      // case-insensitive environment variable matching, so we cannot replace it
      // with another object.
      expect(process.env).toBe(initialProcessEnv)
    })

    it('allows ATOM_HOME to be overwritten only if the new value is a valid path', function () {
      let newAtomHomePath = temp.mkdirSync('atom-home')

      process.env = {
        WILL_BE_DELETED: 'hi',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: '/the/atom/home'
      }

      updateProcessEnv({ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true', PWD: '/the/dir'})
      expect(process.env).toEqual({
        PWD: '/the/dir',
        ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: '/the/atom/home'
      })

      updateProcessEnv({ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true', PWD: '/the/dir', ATOM_HOME: path.join(newAtomHomePath, 'non-existent')})
      expect(process.env).toEqual({
        ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true',
        PWD: '/the/dir',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: '/the/atom/home'
      })

      updateProcessEnv({ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true', PWD: '/the/dir', ATOM_HOME: newAtomHomePath})
      expect(process.env).toEqual({
        ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true',
        PWD: '/the/dir',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: newAtomHomePath
      })
    })

    it('allows ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT to be preserved if set', function () {
      process.env = {
        WILL_BE_DELETED: 'hi',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: '/the/atom/home'
      }

      updateProcessEnv({ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true', PWD: '/the/dir', NODE_ENV: 'the-node-env', NODE_PATH: '/the/node/path', ATOM_HOME: '/the/atom/home'})
      expect(process.env).toEqual({
        ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true',
        PWD: '/the/dir',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: '/the/atom/home'
      })

      updateProcessEnv({PWD: '/the/dir', NODE_ENV: 'the-node-env', NODE_PATH: '/the/node/path', ATOM_HOME: '/the/atom/home'})
      expect(process.env).toEqual({
        ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true',
        PWD: '/the/dir',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: '/the/atom/home'
      })
    })

    it('allows an existing env variable to be updated', function () {
      process.env = {
        WILL_BE_UPDATED: 'old-value',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: '/the/atom/home'
      }

      updateProcessEnv(process.env)
      expect(process.env).toEqual(process.env)

      let updatedEnv = {
        ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true',
        WILL_BE_UPDATED: 'new-value',
        NODE_ENV: 'the-node-env',
        NODE_PATH: '/the/node/path',
        ATOM_HOME: '/the/atom/home',
        PWD: '/the/dir'
      }

      updateProcessEnv(updatedEnv)
      expect(process.env).toEqual(updatedEnv)
    })
  })

  describe('when the launch environment does not come from a shell', function () {
    describe('on osx', function () {
      it('updates process.env to match the environment in the user\'s login shell', function () {
        process.platform = 'darwin'
        process.env.SHELL = '/my/custom/bash'

        spyOn(child_process, 'spawnSync').andReturn({
          stdout: dedent`
            FOO=BAR=BAZ=QUUX
            TERM=xterm-something
            PATH=/usr/bin:/bin:/usr/sbin:/sbin:/crazy/path
          `
        })

        updateProcessEnv(process.env)
        expect(child_process.spawnSync.mostRecentCall.args[0]).toBe('/my/custom/bash')
        expect(process.env).toEqual({
          FOO: 'BAR=BAZ=QUUX',
          TERM: 'xterm-something',
          PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/crazy/path'
        })

        // Doesn't error
        updateProcessEnv(null)
      })
    })

    describe('on linux', function () {
      it('updates process.env to match the environment in the user\'s login shell', function () {
        process.platform = 'linux'
        process.env.SHELL = '/my/custom/bash'

        spyOn(child_process, 'spawnSync').andReturn({
          stdout: dedent`
            FOO=BAR=BAZ=QUUX
            TERM=xterm-something
            PATH=/usr/bin:/bin:/usr/sbin:/sbin:/crazy/path
          `
        })

        updateProcessEnv(process.env)
        expect(child_process.spawnSync.mostRecentCall.args[0]).toBe('/my/custom/bash')
        expect(process.env).toEqual({
          FOO: 'BAR=BAZ=QUUX',
          TERM: 'xterm-something',
          PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/crazy/path'
        })

        // Doesn't error
        updateProcessEnv(null)
      })
    })

    describe('on windows', function () {
      it('does not update process.env', function () {
        process.platform = 'win32'
        spyOn(child_process, 'spawnSync')
        process.env = {FOO: 'bar'}

        updateProcessEnv(process.env)
        expect(child_process.spawnSync).not.toHaveBeenCalled()
        expect(process.env).toEqual({FOO: 'bar'})
      })
    })

    describe('shouldGetEnvFromShell()', function () {
      it('indicates when the environment should be fetched from the shell', function () {
        process.platform = 'darwin'
        expect(shouldGetEnvFromShell({SHELL: '/bin/sh'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/usr/local/bin/sh'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/bin/bash'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/usr/local/bin/bash'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/bin/zsh'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/usr/local/bin/zsh'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/bin/fish'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/usr/local/bin/fish'})).toBe(true)
        process.platform = 'linux'
        expect(shouldGetEnvFromShell({SHELL: '/bin/sh'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/usr/local/bin/sh'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/bin/bash'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/usr/local/bin/bash'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/bin/zsh'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/usr/local/bin/zsh'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/bin/fish'})).toBe(true)
        expect(shouldGetEnvFromShell({SHELL: '/usr/local/bin/fish'})).toBe(true)
      })

      it('returns false when the environment indicates that Atom was launched from a shell', function () {
        process.platform = 'darwin'
        expect(shouldGetEnvFromShell({ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true', SHELL: '/bin/sh'})).toBe(false)
        process.platform = 'linux'
        expect(shouldGetEnvFromShell({ATOM_DISABLE_SHELLING_OUT_FOR_ENVIRONMENT: 'true', SHELL: '/bin/sh'})).toBe(false)
      })

      it('returns false when the shell is undefined or empty', function () {
        process.platform = 'darwin'
        expect(shouldGetEnvFromShell(undefined)).toBe(false)
        expect(shouldGetEnvFromShell({})).toBe(false)

        process.platform = 'linux'
        expect(shouldGetEnvFromShell(undefined)).toBe(false)
        expect(shouldGetEnvFromShell({})).toBe(false)
      })
    })
  })
})
