// This module exports a function that copies all the static assets into the
// appropriate location in the build output directory.

'use strict'

const path = require('path')
const fs = require('fs-extra')
const CONFIG = require('../config')
const glob = require('glob')
const includePathInPackagedApp = require('./include-path-in-packaged-app')

module.exports = function () {
  console.log(`Copying assets to ${CONFIG.intermediateAppPath}`)
  let srcPaths = [
    path.join(CONFIG.repositoryRootPath, 'benchmarks', 'benchmark-runner.js'),
    path.join(CONFIG.repositoryRootPath, 'dot-atom'),
    path.join(CONFIG.repositoryRootPath, 'exports'),
    path.join(CONFIG.repositoryRootPath, 'node_modules'),
    path.join(CONFIG.repositoryRootPath, 'package.json'),
    path.join(CONFIG.repositoryRootPath, 'static'),
    path.join(CONFIG.repositoryRootPath, 'src'),
    path.join(CONFIG.repositoryRootPath, 'vendor'),
    // The legacy test environment promises package tests that fixtures are available, so we need to ship them
    path.join(CONFIG.repositoryRootPath, 'spec', 'fixtures')
  ]
  srcPaths = srcPaths.concat(glob.sync(path.join(CONFIG.repositoryRootPath, 'spec', '*.*'), {ignore: path.join('**', '*-spec.*')}))
  for (let srcPath of srcPaths) {
    fs.copySync(srcPath, computeDestinationPath(srcPath), {filter: includePathInPackagedApp})
  }
  fs.copySync(
    path.join(CONFIG.repositoryRootPath, 'resources', 'app-icons', CONFIG.channel, 'png', '1024.png'),
    path.join(CONFIG.intermediateAppPath, 'resources', 'atom.png')
  )

  // If evil-files are included, the asar bundle gets corrupted, but a
  // newline in one the file names breaks the ability to ignore them with a
  // glob pattern. Let's just delete them after the copy instead.
  const evilFilesPath = path.join(CONFIG.intermediateAppPath, 'spec', 'fixtures', 'evil-files')
  if (fs.existsSync(evilFilesPath)) fs.removeSync(evilFilesPath)
}

function computeDestinationPath (srcPath) {
  const relativePath = path.relative(CONFIG.repositoryRootPath, srcPath)
  return path.join(CONFIG.intermediateAppPath, relativePath)
}
